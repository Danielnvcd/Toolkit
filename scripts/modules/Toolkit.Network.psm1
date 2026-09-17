<#
    Toolkit.Network.psm1
    Diagnostico de red orientado a call center.

    En un call center la red no se mide con "hay Internet?".
    Se mide con lo que mata una llamada: latencia, jitter y perdida de paquetes.
#>

# Dependencia de Toolkit.Core (Write-Log, Set-RegValue, Add-Result, Test-ReportOnly...).
# Permite importar este modulo de forma aislada sin que falle la resolucion de comandos.
if (-not (Get-Command 'Write-Log' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking -Global
}


$script:Thresholds = @{
    LatencyWarn = 80;   LatencyFail = 150    # ms
    JitterWarn  = 20;   JitterFail  = 30     # ms
    LossWarn    = 0.5;  LossFail    = 1.0    # %
    DnsWarn     = 50;   DnsFail     = 100    # ms
}

#region ---------- Medicion base ----------

function Measure-PingQuality {
    <#
        Latencia / jitter / perdida sobre N paquetes.
        Usa System.Net.NetworkInformation.Ping (nativo) en vez de lanzar ping.exe.
        Jitter = media de la diferencia absoluta entre RTT consecutivos (aprox. RFC 3550).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$Count = 50,
        [int]$TimeoutMs = 1000,
        [int]$IntervalMs = 100
    )

    $rtts   = New-Object System.Collections.ArrayList
    $lost   = 0
    $ping   = New-Object System.Net.NetworkInformation.Ping
    $buffer = New-Object byte[] 32

    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, $TimeoutMs, $buffer)
            if ($r.Status -eq 'Success') { $null = $rtts.Add([double]$r.RoundtripTime) } else { $lost++ }
        } catch {
            $lost++
        }
        if ($IntervalMs -gt 0 -and $i -lt ($Count - 1)) { Start-Sleep -Milliseconds $IntervalMs }
    }
    $ping.Dispose()

    $result = [ordered]@{
        Target     = $Target
        Sent       = $Count
        Received   = $rtts.Count
        LossPct    = [math]::Round(($lost / [double]$Count) * 100, 2)
        MinMs      = $null
        AvgMs      = $null
        MaxMs      = $null
        JitterMs   = $null
        Verdict    = 'FALLO'
    }

    if ($rtts.Count -gt 0) {
        $arr = $rtts.ToArray()
        $result.MinMs = [math]::Round(($arr | Measure-Object -Minimum).Minimum, 1)
        $result.AvgMs = [math]::Round(($arr | Measure-Object -Average).Average, 1)
        $result.MaxMs = [math]::Round(($arr | Measure-Object -Maximum).Maximum, 1)

        if ($arr.Count -gt 1) {
            $diffs = @()
            for ($i = 1; $i -lt $arr.Count; $i++) { $diffs += [math]::Abs($arr[$i] - $arr[$i - 1]) }
            $result.JitterMs = [math]::Round(($diffs | Measure-Object -Average).Average, 1)
        } else {
            $result.JitterMs = 0
        }

        $result.Verdict = 'OK'
        if ($result.AvgMs    -ge $script:Thresholds.LatencyWarn -or
            $result.JitterMs -ge $script:Thresholds.JitterWarn  -or
            $result.LossPct  -ge $script:Thresholds.LossWarn)  { $result.Verdict = 'AVISO' }
        if ($result.AvgMs    -ge $script:Thresholds.LatencyFail -or
            $result.JitterMs -ge $script:Thresholds.JitterFail  -or
            $result.LossPct  -ge $script:Thresholds.LossFail)   { $result.Verdict = 'CRITICO' }
    }

    return [pscustomobject]$result
}

function Measure-DnsResolution {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = $false
    $addresses = @()
    try {
        $addresses = @([Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.IPAddressToString })
        $ok = $true
    } catch { }
    $sw.Stop()

    $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    $verdict = if (-not $ok) { 'FALLO' }
               elseif ($ms -ge $script:Thresholds.DnsFail) { 'CRITICO' }
               elseif ($ms -ge $script:Thresholds.DnsWarn) { 'AVISO' }
               else { 'OK' }

    return [pscustomobject]@{
        Name      = $Name
        Resolved  = $ok
        Addresses = $addresses
        TimeMs    = $ms
        Verdict   = $verdict
    }
}

function Test-TcpPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 3000
    )

    $sw     = [Diagnostics.Stopwatch]::StartNew()
    $open   = $false
    $errMsg = $null
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $client.EndConnect($iar)
            $open = $true
        } else {
            $errMsg = 'Tiempo de espera agotado'
        }
    } catch {
        $errMsg = $_.Exception.Message
    } finally {
        $sw.Stop()
        try { $client.Close() } catch { }
    }

    return [pscustomobject]@{
        Target  = "$ComputerName`:$Port"
        Open    = $open
        TimeMs  = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        Error   = $errMsg
        Verdict = $(if ($open) { 'OK' } else { 'CRITICO' })
    }
}

function Get-PathMtu {
    <#
        Descubre la MTU real con paquetes DF (no fragmentar), por busqueda binaria.
        MTU < 1500 hacia Internet suele significar tunel/VPN mal configurada,
        y es causa clasica de "la web carga pero la app corporativa se cuelga".
    #>
    [CmdletBinding()]
    param(
        [string]$Target = '8.8.8.8',
        [int]$Low = 1200,
        [int]$High = 1472        # 1472 payload + 28 cabeceras = 1500
    )

    $ping    = New-Object System.Net.NetworkInformation.Ping
    $options = New-Object System.Net.NetworkInformation.PingOptions(64, $true)   # dontFragment = $true
    $best    = 0

    try {
        while ($Low -le $High) {
            $mid    = [int](($Low + $High) / 2)
            $buffer = New-Object byte[] $mid
            $ok = $false
            try {
                $r  = $ping.Send($Target, 2000, $buffer, $options)
                $ok = ($r.Status -eq 'Success')
            } catch { $ok = $false }

            if ($ok) { $best = $mid; $Low = $mid + 1 } else { $High = $mid - 1 }
        }
    } finally {
        $ping.Dispose()
    }

    if ($best -eq 0) { return [pscustomobject]@{ PayloadBytes = 0; Mtu = $null; Verdict = 'FALLO' } }

    $mtu = $best + 28
    return [pscustomobject]@{
        PayloadBytes = $best
        Mtu          = $mtu
        Verdict      = $(if ($mtu -ge 1500) { 'OK' } elseif ($mtu -ge 1400) { 'AVISO' } else { 'CRITICO' })
    }
}

#endregion

#region ---------- Contexto del equipo ----------

function Get-ActiveAdapter {
    [CmdletBinding()]
    param()

    try {
        # Get-PhysicalAdapter (Core) en vez de Get-NetAdapter: evita cargar el modulo CDXML (2-3 s).
        $adapters = Get-PhysicalAdapter
        if ($null -eq $adapters) { return $null }
        $gwRoute = Get-DefaultGateway
        # Preferir el adaptador por el que sale la ruta por defecto; si no, el mas rapido de los conectados.
        $nic = $null
        if ($gwRoute) { $nic = $adapters | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceIndex -eq $gwRoute.InterfaceIndex } | Select-Object -First 1 }
        if (-not $nic) {
            $nic = $adapters | Where-Object { $_.Status -eq 'Up' } | Sort-Object -Property LinkSpeedBps -Descending | Select-Object -First 1
        }
        if (-not $nic) { return $null }

        $isWifi  = $nic.IsWireless
        $signal  = $null
        if ($isWifi) {
            try {
                $wlan = (& netsh.exe wlan show interfaces) 2>$null
                $line = $wlan | Where-Object { $_ -match 'Se.al|Signal' } | Select-Object -First 1
                if ($line -and $line -match '(\d+)\s*%') { $signal = [int]$Matches[1] }
            } catch { }
        }

        $gw = $(if ($gwRoute) { $gwRoute.NextHop } else { $null })

        $bps = $nic.LinkSpeedBps
        $linkSpeed = if ($bps -ge 1000000000) { '{0:0.#} Gbps' -f ($bps / 1e9) }
                     elseif ($bps -ge 1000000) { '{0:0} Mbps'  -f ($bps / 1e6) }
                     elseif ($bps -gt 0)       { '{0:0} Kbps'  -f ($bps / 1e3) }
                     else                      { 'desconocido' }

        return [pscustomobject]@{
            Name         = $nic.Name
            Description  = $nic.Description
            LinkSpeed    = $linkSpeed
            IsWireless   = $isWifi
            SignalPct    = $signal
            Gateway      = $gw
            MacAddress   = $nic.MacAddress
            # Un agente de call center en WiFi es una bandera amarilla permanente.
            Verdict      = $(if (-not $isWifi) { 'OK' } elseif ($signal -and $signal -lt 60) { 'CRITICO' } else { 'AVISO' })
        }
    } catch {
        return $null
    }
}

function Get-ProxyState {
    <#
        WinINET (por usuario) y WinHTTP (por maquina) son configuraciones DISTINTAS.
        Que no coincidan es causa clasica de fallos intermitentes que nadie sabe explicar.
    #>
    [CmdletBinding()]
    param()

    $wininet = [ordered]@{ Enabled = $null; Server = $null; AutoConfigUrl = $null }
    try {
        $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($k.PSObject.Properties.Name -contains 'ProxyEnable')   { $wininet.Enabled = [bool]$k.ProxyEnable }
        if ($k.PSObject.Properties.Name -contains 'ProxyServer')   { $wininet.Server = $k.ProxyServer }
        if ($k.PSObject.Properties.Name -contains 'AutoConfigURL') { $wininet.AutoConfigUrl = $k.AutoConfigURL }
    } catch { }

    $winhttp = 'desconocido'
    try { $winhttp = ((& netsh.exe winhttp show proxy) 2>$null | Out-String).Trim() } catch { }

    return [pscustomobject]@{
        WinINET = [pscustomobject]$wininet
        WinHTTP = $winhttp
    }
}

function Test-TlsEndpoint {
    <#
        Abre TLS y devuelve el emisor del certificado.
        Si el emisor NO es una CA publica conocida, hay inspeccion SSL en medio
        (firewall/proxy corporativo) -- explica muchos fallos de apps que no confian en ese CA.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [int]$Port = 443,
        [int]$TimeoutMs = 5000
    )

    $out = [ordered]@{
        Target = "$ComputerName`:$Port"; Success = $false
        Issuer = $null; Subject = $null; Expires = $null; Protocol = $null; Error = $null
        Inspected = $null
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { throw 'Tiempo de espera agotado en TCP' }
        $client.EndConnect($iar)

        $callback = [Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) return $true }
        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($ComputerName)

        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $out.Success   = $true
        $out.Issuer    = $cert.Issuer
        $out.Subject   = $cert.Subject
        $out.Expires   = $cert.NotAfter.ToString('yyyy-MM-dd')
        $out.Protocol  = "$($ssl.SslProtocol)"
        $out.Inspected = -not ($cert.Issuer -match 'DigiCert|Let''s Encrypt|GlobalSign|Sectigo|Amazon|Google Trust|Microsoft|Entrust|GoDaddy|ISRG')
        $ssl.Dispose()
    } catch {
        $out.Error = $_.Exception.Message
    } finally {
        try { $client.Close() } catch { }
    }

    $out.Verdict = $(if ($out.Success) { if ($out.Inspected) { 'AVISO' } else { 'OK' } } else { 'CRITICO' })
    return [pscustomobject]$out
}

#endregion

#region ---------- Orquestacion ----------

function Invoke-NetworkDiagnostic {
    <# Ejecuta la bateria completa segun la seccion 'network' de catalog.json. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$NetworkConfig,
        [int]$PingCount = 50
    )

    $report = [ordered]@{
        Adapter     = $null
        Gateway     = $null
        Dns         = @()
        Ping        = @()
        TcpPorts    = @()
        Tls         = @()
        Mtu         = $null
        Proxy       = $null
        Verdict     = 'OK'
        Timestamp   = (Get-Date).ToString('o')
    }

    # --- Adaptador ---
    Write-Log 'Adaptador de red activo...' -Level INFO
    $report.Adapter = Get-ActiveAdapter
    if ($report.Adapter) {
        Write-Log ("  {0} | {1} | {2}" -f $report.Adapter.Name, $report.Adapter.LinkSpeed,
                   $(if ($report.Adapter.IsWireless) { "WiFi $($report.Adapter.SignalPct)%" } else { 'Cable' })) -Level INFO
        if ($report.Adapter.IsWireless) {
            Write-Log '  ! Puesto en WiFi. Para VoIP, el cable siempre es preferible.' -Level WARN
        }
    } else {
        Write-Log '  x No se detecto adaptador activo' -Level ERROR
    }

    # --- Puerta de enlace ---
    if ($report.Adapter -and $report.Adapter.Gateway) {
        Write-Log "Puerta de enlace ($($report.Adapter.Gateway))..." -Level INFO
        $report.Gateway = Measure-PingQuality -Target $report.Adapter.Gateway -Count 20 -IntervalMs 50
        Write-Log ("  {0} ms avg | jitter {1} ms | perdida {2}%  [{3}]" -f `
                   $report.Gateway.AvgMs, $report.Gateway.JitterMs, $report.Gateway.LossPct, $report.Gateway.Verdict) -Level INFO
    }

    # --- DNS ---
    Write-Log 'Resolucion DNS...' -Level INFO
    foreach ($n in @($NetworkConfig.dnsNames)) {
        $d = Measure-DnsResolution -Name $n
        $report.Dns += $d
        Write-Log ("  {0,-34} {1,7} ms  [{2}]" -f $d.Name, $d.TimeMs, $d.Verdict) -Level $(if ($d.Verdict -eq 'OK') { 'OK' } else { 'WARN' })
    }

    # --- Latencia / jitter / perdida ---
    Write-Log "Calidad de enlace ($PingCount paquetes por destino)..." -Level INFO
    foreach ($t in @($NetworkConfig.pingTargets)) {
        $q = Measure-PingQuality -Target $t.host -Count $PingCount
        $q | Add-Member -NotePropertyName 'Label' -NotePropertyValue $t.label -Force
        $report.Ping += $q
        Write-Log ("  {0,-24} avg {1,6} ms | jitter {2,5} ms | perdida {3,5}%  [{4}]" -f `
                   $t.label, $q.AvgMs, $q.JitterMs, $q.LossPct, $q.Verdict) `
                   -Level $(if ($q.Verdict -eq 'OK') { 'OK' } elseif ($q.Verdict -eq 'AVISO') { 'WARN' } else { 'ERROR' })
    }

    # --- Puertos TCP ---
    Write-Log 'Puertos TCP...' -Level INFO
    foreach ($p in @($NetworkConfig.tcpTargets)) {
        $r = Test-TcpPort -ComputerName $p.host -Port $p.port
        $r | Add-Member -NotePropertyName 'Label' -NotePropertyValue $p.label -Force
        $report.TcpPorts += $r
        Write-Log ("  {0,-34} {1}" -f ("$($p.label) ($($p.host):$($p.port))"),
                   $(if ($r.Open) { "ABIERTO ($($r.TimeMs) ms)" } else { "CERRADO - $($r.Error)" })) `
                   -Level $(if ($r.Open) { 'OK' } else { 'ERROR' })
    }

    # --- TLS ---
    if ($NetworkConfig.PSObject.Properties.Name -contains 'tlsTargets') {
        Write-Log 'Certificados TLS (deteccion de inspeccion SSL)...' -Level INFO
        foreach ($t in @($NetworkConfig.tlsTargets)) {
            $r = Test-TlsEndpoint -ComputerName $t.host -Port $(if ($t.port) { $t.port } else { 443 })
            $report.Tls += $r
            if ($r.Success) {
                Write-Log ("  {0,-30} {1} | emisor: {2}" -f $t.host, $r.Protocol, ($r.Issuer -replace '^CN=([^,]+).*', '$1')) `
                           -Level $(if ($r.Inspected) { 'WARN' } else { 'OK' })
                if ($r.Inspected) { Write-Log '    ! Certificado no emitido por CA publica: hay inspeccion SSL en medio' -Level WARN }
            } else {
                Write-Log ("  {0,-30} FALLO: {1}" -f $t.host, $r.Error) -Level ERROR
            }
        }
    }

    # --- MTU ---
    Write-Log 'Descubrimiento de MTU...' -Level INFO
    $report.Mtu = Get-PathMtu
    if ($report.Mtu.Mtu) {
        Write-Log ("  MTU efectiva: {0} bytes  [{1}]" -f $report.Mtu.Mtu, $report.Mtu.Verdict) `
                   -Level $(if ($report.Mtu.Verdict -eq 'OK') { 'OK' } else { 'WARN' })
        if ($report.Mtu.Mtu -lt 1500) { Write-Log '  ! MTU < 1500: revisar VPN/tunel. Causa tipica de apps que se cuelgan.' -Level WARN }
    }

    # --- Proxy ---
    $report.Proxy = Get-ProxyState

    # --- Veredicto global ---
    $all = @()
    $all += $report.Dns.Verdict
    $all += $report.Ping.Verdict
    $all += $report.TcpPorts.Verdict
    if ($report.Adapter) { $all += $report.Adapter.Verdict }
    if ($report.Mtu)     { $all += $report.Mtu.Verdict }
    $all += $report.Tls.Verdict

    $report.Verdict = if ($all -contains 'CRITICO' -or $all -contains 'FALLO') { 'CRITICO' }
                      elseif ($all -contains 'AVISO') { 'AVISO' }
                      else { 'OK' }

    $status = switch ($report.Verdict) { 'OK' { 'OK' } 'AVISO' { 'AVISO' } default { 'FALLO' } }
    Add-Result -Module 'Network' -Task 'Diagnostico de red' -Status $status -Message "Veredicto: $($report.Verdict)" -Detail ([pscustomobject]$report)

    return [pscustomobject]$report
}

function Show-NetworkSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)

    $color = switch ($Report.Verdict) { 'OK' { 'Green' } 'AVISO' { 'Yellow' } default { 'Red' } }
    Write-Host ''
    Write-Host ('  VEREDICTO DE RED: {0}' -f $Report.Verdict) -ForegroundColor $color

    $problems = @()
    foreach ($p in $Report.Ping)     { if ($p.Verdict -ne 'OK') { $problems += "Enlace a $($p.Label): avg $($p.AvgMs) ms, jitter $($p.JitterMs) ms, perdida $($p.LossPct)%" } }
    foreach ($d in $Report.Dns)      { if ($d.Verdict -ne 'OK') { $problems += "DNS $($d.Name): $($d.TimeMs) ms" } }
    foreach ($t in $Report.TcpPorts) { if (-not $t.Open)        { $problems += "Puerto cerrado: $($t.Target) ($($t.Label))" } }
    if ($Report.Adapter -and $Report.Adapter.IsWireless) { $problems += "Puesto en WiFi (senal $($Report.Adapter.SignalPct)%)" }
    if ($Report.Mtu -and $Report.Mtu.Mtu -and $Report.Mtu.Mtu -lt 1500) { $problems += "MTU reducida: $($Report.Mtu.Mtu)" }

    if ($problems.Count -gt 0) {
        Write-Host '  Hallazgos:' -ForegroundColor Yellow
        foreach ($p in $problems) { Write-Host "    - $p" -ForegroundColor Yellow }
    }
    Write-Host ''
}

#endregion

Export-ModuleMember -Function @(
    'Measure-PingQuality', 'Measure-DnsResolution', 'Test-TcpPort', 'Get-PathMtu',
    'Get-ActiveAdapter', 'Get-ProxyState', 'Test-TlsEndpoint',
    'Invoke-NetworkDiagnostic', 'Show-NetworkSummary'
)
