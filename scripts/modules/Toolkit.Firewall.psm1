<#
    Toolkit.Firewall.psm1
    Firewall de Windows y bloqueos de red para el puesto de agente.

    TRES BLOQUES:
      1. Firewall   : estado de los perfiles, "esta fallando por el firewall?"
                      (Test-FirewallConnection) y pausa temporal con reactivacion
                      automatica por tarea programada (Suspend-Firewall).
      2. Programas  : cortar la red a un .exe con una regla de bloqueo del propio
                      firewall de Windows (Block-ProgramNetwork). Todas las reglas
                      del toolkit van en el grupo 'Toolkit BPO' para listarlas y
                      quitarlas sin tocar las demas.
      3. Filtro web : bloquear categorias de sitios (redes sociales, video,
                      mensajeria, juegos, apuestas, adulto) en TRES capas:
                        - URLBlocklist de Chrome y Edge (politica; el agente ve la
                          pagina "bloqueado por tu organizacion", no un error raro)
                        - WebsiteFilter de Firefox (politica)
                        - archivo hosts (apps de escritorio: WhatsApp, Telegram...)
                      La politica es lo que bloquea de verdad en el navegador
                      (sobrevive a que cambien las IPs y a DNS sobre HTTPS); el
                      archivo hosts es el respaldo para lo que no es navegador.

    REVERSIBLE: las listas numeradas de las politicas (URLBlocklist, Block) son
    compartidas con las GPO de la empresa. El toolkit solo anade y quita SUS
    dominios (los recuerda en HKLM\SOFTWARE\Toolkit\WebFilter) y respeta los
    que ya hubiera. En el archivo hosts escribe entre dos marcadores y solo toca
    ese bloque. Clear-WebFilter deja todo como estaba.
#>

# Dependencia de Toolkit.Core (Write-Log, Set-RegValue, Add-Result, Test-ReportOnly...).
# Permite importar este modulo de forma aislada sin que falle la resolucion de comandos.
if (-not (Get-Command 'Write-Log' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking -Global
}

$script:RuleGroup        = 'Toolkit BPO'
$script:RulePrefix       = 'Toolkit: '
$script:PauseTaskPath    = '\Toolkit BPO\'
$script:PauseTaskName    = 'Reactivar firewall'
$script:RegState         = 'HKLM:\SOFTWARE\Toolkit\Firewall'
$script:RegWebState      = 'HKLM:\SOFTWARE\Toolkit\WebFilter'
$script:RegChromeBlock   = 'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
$script:RegEdgeBlock     = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
$script:RegFirefoxBlock  = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block'
$script:HostsPath        = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:HostsBegin       = '# >>> Toolkit BPO - filtro web (no editar este bloque) >>>'
$script:HostsEnd         = '# <<< Toolkit BPO - filtro web <<<'
# Dominios que NUNCA van al archivo hosts: Microsoft Defender detecta cualquier entrada de hosts
# para dominios de Microsoft como SettingsModifier:Win32/HostsFileHijack y la elimina (y avisa).
# En la politica del navegador si se pueden bloquear.
$script:HostsProtected   = @('microsoft.com', 'windowsupdate.com', 'windows.com', 'live.com', 'msn.com', 'bing.com',
                            'office.com', 'office365.com', 'skype.com', 'msftconnecttest.com', 'azure.com', 'xbox.com')

# Categorias por defecto. El catalogo (webFilter.categories) las sustituye o
# amplia sin recompilar: misma estructura { id, name, domains }.
# Un dominio bloquea tambien sus subdominios en Chrome/Edge/Firefox; en hosts se
# escriben el dominio y www.dominio (hosts no admite comodines), por eso las
# listas incluyen los CDN y hosts secundarios que usan las apps de escritorio.
$script:DefaultWebCategories = @(
    [pscustomobject]@{ id = 'social';    name = 'Redes sociales';       domains = @(
        'facebook.com', 'fbcdn.net', 'messenger.com', 'instagram.com', 'cdninstagram.com',
        'twitter.com', 'x.com', 'twimg.com', 'tiktok.com', 'tiktokcdn.com', 'tiktokv.com',
        'snapchat.com', 'pinterest.com', 'reddit.com', 'threads.net', 'tumblr.com', 'linkedin.com') }
    [pscustomobject]@{ id = 'video';     name = 'Video y streaming';    domains = @(
        'youtube.com', 'youtu.be', 'googlevideo.com', 'netflix.com', 'nflxvideo.net',
        'twitch.tv', 'ttvnw.net', 'kick.com', 'vimeo.com', 'dailymotion.com',
        'disneyplus.com', 'primevideo.com', 'hbomax.com', 'max.com', 'crunchyroll.com') }
    [pscustomobject]@{ id = 'messaging'; name = 'Mensajeria personal';  domains = @(
        'whatsapp.com', 'whatsapp.net', 'web.whatsapp.com', 'telegram.org', 'web.telegram.org', 't.me',
        'discord.com', 'discordapp.com', 'discord.gg', 'signal.org', 'wechat.com') }
    [pscustomobject]@{ id = 'games';     name = 'Juegos';               domains = @(
        'steampowered.com', 'steamcommunity.com', 'epicgames.com', 'roblox.com', 'rbxcdn.com',
        'minecraft.net', 'battle.net', 'riotgames.com', 'leagueoflegends.com',
        'miniclip.com', 'poki.com', 'crazygames.com', 'y8.com', 'friv.com', 'agame.com') }
    [pscustomobject]@{ id = 'betting';   name = 'Apuestas y casino';    domains = @(
        'bet365.com', 'betway.com', 'betfair.com', 'bwin.com', 'williamhill.com', '888.com',
        'pokerstars.com', '1xbet.com', 'stake.com', 'betano.com', 'codere.es', 'sportium.es',
        'wplay.co', 'betplay.com.co', 'rushbet.co', 'caliente.mx') }
    [pscustomobject]@{ id = 'adult';     name = 'Contenido adulto';     domains = @(
        'pornhub.com', 'xvideos.com', 'xnxx.com', 'xhamster.com', 'redtube.com', 'youporn.com',
        'onlyfans.com', 'chaturbate.com', 'stripchat.com', 'livejasmin.com') }
)

#region ---------- Bloque 1: firewall de Windows ----------

function Get-FirewallState {
    <# Perfiles, servicio, firewalls de terceros y pausa activa. Solo lectura. #>
    [CmdletBinding()]
    param()

    $state = [ordered]@{
        ServiceStatus    = $null
        Profiles         = @()
        AnyDisabled      = $false
        ThirdParty       = @()
        Paused           = $false
        PauseEndsAt      = $null
        ToolkitRules     = 0
        Issues           = @()
    }

    $svc = Get-Service -Name 'MpsSvc' -ErrorAction SilentlyContinue
    $state.ServiceStatus = if ($svc) { "$($svc.Status)" } else { 'no existe' }
    if (-not $svc -or $svc.Status -ne 'Running') { $state.Issues += 'El servicio Firewall de Windows (MpsSvc) no esta en ejecucion' }

    try {
        foreach ($p in Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop) {
            $state.Profiles += [pscustomobject]@{
                Name            = $p.Name
                Enabled         = [bool]$p.Enabled
                # NotConfigured = el valor por defecto de Windows: entrada Block, salida Allow.
                InboundDefault  = $(if ("$($p.DefaultInboundAction)"  -eq "NotConfigured") { "Block" } else { "$($p.DefaultInboundAction)" })
                OutboundDefault = $(if ("$($p.DefaultOutboundAction)" -eq "NotConfigured") { "Allow" } else { "$($p.DefaultOutboundAction)" })
            }
            if (-not $p.Enabled) { $state.AnyDisabled = $true }
            if ("$($p.DefaultOutboundAction)" -eq 'Block') {
                $state.Issues += "Perfil $($p.Name): la salida esta BLOQUEADA por defecto (solo pasa lo que tenga regla de permiso)"
            }
        }
    } catch {
        $state.Issues += "No se pudieron leer los perfiles: $($_.Exception.Message)"
    }

    # Firewalls de terceros registrados en el Centro de seguridad (antivirus con firewall propio).
    try {
        $fw = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop
        foreach ($f in @($fw)) {
            # productState: byte medio 0x10 = activado.
            $on = (($f.productState -band 0x1000) -ne 0)
            $state.ThirdParty += [pscustomobject]@{ Name = $f.displayName; Enabled = $on }
        }
    } catch { }

    $pause = Get-FirewallPause
    if ($pause) { $state.Paused = $true; $state.PauseEndsAt = $pause.EndsAt }
    if ($state.AnyDisabled -and -not $state.Paused) { $state.Issues += 'Hay perfiles con el firewall DESACTIVADO y no es una pausa del toolkit' }

    try { $state.ToolkitRules = @(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction Stop).Count } catch { }

    return [pscustomobject]$state
}

function Show-FirewallState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    Write-Log 'FIREWALL DE WINDOWS' -Level STEP
    Write-Log ("  Servicio MpsSvc : {0}" -f $State.ServiceStatus) -Level $(if ($State.ServiceStatus -eq 'Running') { 'OK' } else { 'ERROR' })
    foreach ($p in $State.Profiles) {
        Write-Log ("  Perfil {0,-8}: {1,-11}  entrada={2,-5}  salida={3}" -f $p.Name,
                   $(if ($p.Enabled) { 'ACTIVADO' } else { 'desactivado' }), $p.InboundDefault, $p.OutboundDefault) `
                  -Level $(if ($p.Enabled) { 'OK' } else { 'WARN' })
    }
    if ($State.Paused) {
        Write-Log ("  ! PAUSA ACTIVA del toolkit: se reactiva solo a las {0:HH:mm:ss}" -f $State.PauseEndsAt) -Level WARN
    }
    foreach ($t in $State.ThirdParty) {
        Write-Log ("  Firewall de terceros: {0} ({1})" -f $t.Name, $(if ($t.Enabled) { 'activo' } else { 'inactivo' })) -Level $(if ($t.Enabled) { 'WARN' } else { 'INFO' })
        if ($t.Enabled) { Write-Log '    Si ese producto filtra, pausar el firewall de Windows no cambia nada: hay que mirar en su consola.' -Level INFO }
    }
    Write-Log ("  Reglas del toolkit (grupo '{0}'): {1}" -f $script:RuleGroup, $State.ToolkitRules) -Level INFO
    foreach ($i in $State.Issues) { Write-Log "  ! $i" -Level WARN }
    if ($State.Issues.Count -eq 0) { Write-Log '  + Firewall en estado normal' -Level OK }
}

function Test-FirewallConnection {
    <#
        "No me conecta a X: es el firewall?" Comprueba en orden:
          1. DNS (y si el archivo hosts lo esta desviando)
          2. Conexion TCP real al puerto
          3. Reglas de BLOQUEO activas del firewall de Windows que casen con el destino
             (salida; por puerto, direccion o programa)
          4. Politica de salida del perfil activo y URLBlocklist de los navegadores
        Devuelve un veredicto claro para el tecnico. No cambia nada.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [int]$Port = 443,
        [int]$TimeoutMs = 4000
    )

    $ComputerName = $ComputerName.Trim()
    # Acepta una URL o "host:puerto" pegados tal cual.
    if ($ComputerName -match '^[a-z]+://') {
        try { $u = [uri]$ComputerName; $ComputerName = $u.Host; if (-not $u.IsDefaultPort) { $Port = $u.Port } elseif ($u.Scheme -eq 'http') { $Port = 80 } else { $Port = 443 } } catch { }
    } elseif ($ComputerName -match '^([^:\s]+):(\d{1,5})$') {
        $ComputerName = $Matches[1]; $Port = [int]$Matches[2]
    }

    Write-Log ("COMPROBAR CONEXION  {0}:{1}" -f $ComputerName, $Port) -Level STEP
    $r = [ordered]@{
        Target      = "$ComputerName`:$Port"
        Host        = $ComputerName
        Port        = $Port
        Addresses   = @()
        HostsBlock  = $false
        DnsOk       = $false
        TcpOpen     = $false
        TcpTimeMs   = 0
        TcpError    = $null
        BlockRules  = @()
        OutboundDefaultBlock = $false
        WebFiltered = @()
        Verdict     = ''
        Cause       = ''
    }

    # 1. hosts + DNS
    $hostsHit = Get-HostsEntries | Where-Object { $_.Host -eq $ComputerName.ToLower() } | Select-Object -First 1
    if ($hostsHit -and $hostsHit.Address -in @('0.0.0.0', '127.0.0.1', '::1')) {
        $r.HostsBlock = $true
        Write-Log ("  ! El archivo hosts desvia {0} a {1}{2}" -f $ComputerName, $hostsHit.Address, $(if ($hostsHit.Toolkit) { ' (bloque del toolkit)' } else { '' })) -Level WARN
    }
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($ComputerName) | ForEach-Object { $_.IPAddressToString }
        $r.Addresses = @($ips)
        $r.DnsOk = ($r.Addresses.Count -gt 0)
        Write-Log ("  DNS: {0}" -f ($r.Addresses -join ', ')) -Level $(if ($r.DnsOk) { 'OK' } else { 'ERROR' })
    } catch {
        Write-Log ("  x DNS no resuelve {0}: {1}" -f $ComputerName, $_.Exception.Message) -Level ERROR
    }

    # 2. TCP real
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.EndConnect($iar); $r.TcpOpen = $true }
        else { $r.TcpError = 'tiempo de espera agotado' }
    } catch { $r.TcpError = $_.Exception.InnerException.Message; if (-not $r.TcpError) { $r.TcpError = $_.Exception.Message } }
    finally { $sw.Stop(); try { $client.Close() } catch { } }
    $r.TcpTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds)
    Write-Log ("  TCP {0}: {1}" -f $Port, $(if ($r.TcpOpen) { "ABIERTO ($($r.TcpTimeMs) ms)" } else { "CERRADO - $($r.TcpError)" })) -Level $(if ($r.TcpOpen) { 'OK' } else { 'ERROR' })

    # 3. Reglas de bloqueo que casan
    $r.BlockRules = @(Find-BlockingRule -Addresses $r.Addresses -Port $Port)
    foreach ($b in $r.BlockRules) {
        Write-Log ("  ! Regla de BLOQUEO activa: '{0}'  [{1}] {2}" -f $b.DisplayName, $b.Direction, $b.Match) -Level WARN
    }

    # 4. Perfil y filtro web
    try {
        $active = Get-NetConnectionProfile -ErrorAction Stop | Select-Object -First 1
        $profName = "$($active.NetworkCategory)" -replace 'Authenticated', ''
        $prof = Get-NetFirewallProfile -Name $profName -PolicyStore ActiveStore -ErrorAction SilentlyContinue
        if ($prof -and "$($prof.DefaultOutboundAction)" -eq 'Block') {
            $r.OutboundDefaultBlock = $true
            Write-Log ("  ! Perfil {0}: salida bloqueada por defecto" -f $profName) -Level WARN
        }
    } catch { }
    $r.WebFiltered = @(Test-WebFilterDomain -Domain $ComputerName | Where-Object { $_.Blocked } | ForEach-Object { $_.Layer })
    if ($r.WebFiltered.Count -gt 0) {
        Write-Log ("  ! Filtro web del toolkit/politica lo bloquea en: {0}" -f ($r.WebFiltered -join ', ')) -Level WARN
    }

    # Veredicto
    if ($r.HostsBlock) {
        $r.Verdict = 'BLOQUEADO'; $r.Cause = 'archivo hosts (filtro web)'
    } elseif (-not $r.DnsOk) {
        $r.Verdict = 'SIN DNS';   $r.Cause = 'el nombre no resuelve: no es el firewall, revisar DNS/red'
    } elseif ($r.TcpOpen -and $r.BlockRules.Count -eq 0) {
        $r.Verdict = 'OK';        $r.Cause = 'conecta; el firewall no lo bloquea'
        if ($r.WebFiltered.Count -gt 0) { $r.Cause += ' (pero el navegador lo bloqueara por politica)' }
    } elseif ($r.BlockRules.Count -gt 0) {
        $r.Verdict = 'BLOQUEADO'; $r.Cause = 'regla del firewall de Windows: ' + (($r.BlockRules | ForEach-Object { $_.DisplayName }) -join '; ')
    } elseif ($r.OutboundDefaultBlock) {
        $r.Verdict = 'BLOQUEADO'; $r.Cause = 'el perfil bloquea toda la salida por defecto y no hay regla de permiso'
    } else {
        $r.Verdict = 'NO CONECTA'; $r.Cause = 'no hay regla de bloqueo en Windows: el corte esta fuera (red, proxy, firewall perimetral o el propio servidor)'
    }
    Write-Log ("  => {0}: {1}" -f $r.Verdict, $r.Cause) -Level $(if ($r.Verdict -eq 'OK') { 'OK' } else { 'ERROR' })

    Add-Result -Module 'Firewall' -Task "Conexion $($r.Target)" -Status $(if ($r.Verdict -eq 'OK') { 'OK' } else { 'AVISO' }) -Message $r.Cause -Detail ([pscustomobject]$r)
    return [pscustomobject]$r
}

function Find-BlockingRule {
    <# Reglas de bloqueo activas (salida) cuyo puerto/direccion/programa casan con el destino. #>
    [CmdletBinding()]
    param([string[]]$Addresses, [int]$Port)

    $out = @()
    $rules = @()
    # ActiveStore = politica efectiva (local + GPO). Sin el, las reglas que llegan por
    # directiva de dominio no aparecen, y son justo las que el tecnico no encuentra.
    try { $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Action Block -Direction Outbound -ErrorAction Stop) } catch { return $out }
    foreach ($rule in $rules) {
        $pf = $null; $af = $null; $app = $null
        try { $pf = $rule | Get-NetFirewallPortFilter -ErrorAction Stop } catch { }
        try { $af = $rule | Get-NetFirewallAddressFilter -ErrorAction Stop } catch { }
        try { $app = $rule | Get-NetFirewallApplicationFilter -ErrorAction Stop } catch { }

        $portOk = (-not $pf) -or ((Test-PortMatch -Filter $pf.RemotePort -Port $Port) -and ("$($pf.Protocol)" -in @('Any', 'TCP', '6')))
        $addrOk = (-not $af) -or (Test-AddressMatch -Filter $af.RemoteAddress -Addresses $Addresses)
        if (-not ($portOk -and $addrOk)) { continue }

        $why = @()
        if ($pf -and "$($pf.RemotePort)" -ne 'Any') { $why += "puerto $($pf.RemotePort)" }
        if ($af -and "$($af.RemoteAddress)" -ne 'Any') { $why += "direccion $($af.RemoteAddress -join ',')" }
        if ($app -and "$($app.Program)" -ne 'Any') { $why += "programa $($app.Program)" }
        if ($why.Count -eq 0) { $why += 'todo el trafico' }
        $out += [pscustomobject]@{
            Name        = $rule.Name
            DisplayName = $rule.DisplayName
            Direction   = "$($rule.Direction)"
            Program     = $(if ($app) { "$($app.Program)" } else { 'Any' })
            Match       = ($why -join ', ')
            Toolkit     = ($rule.Group -eq $script:RuleGroup)
        }
    }
    return $out
}

function Test-PortMatch {
    param($Filter, [int]$Port)
    foreach ($f in @($Filter)) {
        $f = "$f"
        if ($f -eq 'Any') { return $true }
        if ($f -match '^\d+$' -and [int]$f -eq $Port) { return $true }
        if ($f -match '^(\d+)-(\d+)$' -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return $true }
    }
    return $false
}

function Test-AddressMatch {
    param($Filter, [string[]]$Addresses)
    foreach ($f in @($Filter)) {
        $f = "$f"
        if ($f -eq 'Any' -or $f -eq 'Internet') { return $true }
        foreach ($ip in $Addresses) {
            if ($f -eq $ip) { return $true }
            if ($f -match '/' -and (Test-IpInList -Ip $ip -List @($f))) { return $true }
            if ($f -match '^([\d\.]+)-([\d\.]+)$') {
                try {
                    $n = [BitConverter]::ToUInt32(([ipaddress]$ip).GetAddressBytes()[3..0], 0)
                    $a = [BitConverter]::ToUInt32(([ipaddress]$Matches[1]).GetAddressBytes()[3..0], 0)
                    $b = [BitConverter]::ToUInt32(([ipaddress]$Matches[2]).GetAddressBytes()[3..0], 0)
                    if ($n -ge $a -and $n -le $b) { return $true }
                } catch { }
            }
        }
    }
    return $false
}

function Get-FirewallPause {
    <# Pausa activa del toolkit (tarea de reactivacion pendiente) o $null. #>
    try {
        $t = Get-ScheduledTask -TaskPath $script:PauseTaskPath -TaskName $script:PauseTaskName -ErrorAction Stop
        $ends = $null
        try { $ends = [datetime]$t.Triggers[0].StartBoundary } catch { }
        return [pscustomobject]@{ EndsAt = $ends; State = "$($t.State)" }
    } catch { return $null }
}

function Suspend-Firewall {
    <#
        Desactiva el firewall de Windows en todos los perfiles durante N minutos
        para descartar que sea el la causa de un fallo de conexion. La reactivacion
        NO depende del toolkit: se programa una tarea de SYSTEM que vuelve a
        activarlo y se borra sola. Si la tarea no se puede crear, no se desactiva nada.
        Guarda el estado previo por perfil para que Resume-Firewall lo restaure exacto.
    #>
    [CmdletBinding()]
    param([ValidateRange(1, 30)][int]$Minutes = 5)

    Write-Log ("PAUSAR FIREWALL {0} min" -f $Minutes) -Level STEP
    if (Test-ReportOnly) { Write-Log '  ! MODO REPORTE: no se pausa' -Level WARN; return $false }

    $third = @((Get-FirewallState).ThirdParty | Where-Object { $_.Enabled })
    foreach ($t in $third) { Write-Log ("  ! Firewall de terceros activo: {0}. La pausa solo afecta al de Windows." -f $t.Name) -Level WARN }

    $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    $prev = @($profiles | ForEach-Object { "{0}={1}" -f $_.Name, [int][bool]$_.Enabled })

    $ends = (Get-Date).AddMinutes($Minutes)
    try {
        $cmd = '/c netsh advfirewall set allprofiles state on & schtasks /delete /tn "{0}{1}" /f' -f $script:PauseTaskPath.TrimStart('\'), $script:PauseTaskName
        $action   = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmd
        $trigger  = New-ScheduledTaskTrigger -Once -At $ends
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
        Register-ScheduledTask -TaskPath $script:PauseTaskPath -TaskName $script:PauseTaskName -Action $action -Trigger $trigger `
                               -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Write-Log ("  + Tarea de reactivacion programada para las {0:HH:mm:ss} (SYSTEM, se borra sola)" -f $ends) -Level OK
    } catch {
        Write-Log ("  x No se pudo programar la reactivacion: {0}. NO se pausa el firewall." -f $_.Exception.Message) -Level ERROR
        Add-Result -Module 'Firewall' -Task 'Pausar firewall' -Status 'FALLO' -Message 'Sin tarea de reactivacion'
        return $false
    }

    try {
        if (-not (Test-Path -LiteralPath $script:RegState)) { New-Item -Path $script:RegState -Force | Out-Null }
        # Si ya hay una pausa activa, el estado "previo" es el de antes de esa pausa, no el actual (todo apagado).
        if (-not (Get-RegValue -Path $script:RegState -Name 'PausePrevious')) {
            New-ItemProperty -LiteralPath $script:RegState -Name 'PausePrevious' -Value $prev -PropertyType MultiString -Force | Out-Null
        }
        Set-NetFirewallProfile -All -Enabled False -ErrorAction Stop
        Write-Log ("  + Firewall DESACTIVADO en todos los perfiles hasta las {0:HH:mm:ss}. Repite la prueba ahora." -f $ends) -Level WARN
        Add-Result -Module 'Firewall' -Task 'Pausar firewall' -Status 'CAMBIADO' -Message ("{0} min, hasta {1:HH:mm}" -f $Minutes, $ends)
        return $true
    } catch {
        Write-Log ("  x No se pudo desactivar: {0}" -f $_.Exception.Message) -Level ERROR
        Unregister-ScheduledTask -TaskPath $script:PauseTaskPath -TaskName $script:PauseTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Add-Result -Module 'Firewall' -Task 'Pausar firewall' -Status 'FALLO' -Message $_.Exception.Message
        return $false
    }
}

function Resume-Firewall {
    <# Reactiva el firewall ya (sin esperar a la tarea) y restaura el estado previo por perfil. #>
    [CmdletBinding()]
    param()

    Write-Log 'REACTIVAR FIREWALL' -Level STEP
    if (Test-ReportOnly) { Write-Log '  ! MODO REPORTE: sin cambios' -Level WARN; return $false }

    $prev = Get-RegValue -Path $script:RegState -Name 'PausePrevious'
    try {
        if ($prev) {
            foreach ($e in @($prev)) {
                if ($e -match '^(\w+)=(\d)$') {
                    Set-NetFirewallProfile -Name $Matches[1] -Enabled ([bool][int]$Matches[2]) -ErrorAction Stop
                    Write-Log ("  + Perfil {0}: {1}" -f $Matches[1], $(if ([int]$Matches[2]) { 'activado' } else { 'desactivado (como estaba)' })) -Level OK
                }
            }
            Remove-ItemProperty -LiteralPath $script:RegState -Name 'PausePrevious' -Force -ErrorAction SilentlyContinue
        } else {
            Set-NetFirewallProfile -All -Enabled True -ErrorAction Stop
            Write-Log '  + Firewall activado en todos los perfiles' -Level OK
        }
    } catch {
        Write-Log ("  x {0}" -f $_.Exception.Message) -Level ERROR
        Add-Result -Module 'Firewall' -Task 'Reactivar firewall' -Status 'FALLO' -Message $_.Exception.Message
        return $false
    }
    Unregister-ScheduledTask -TaskPath $script:PauseTaskPath -TaskName $script:PauseTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Add-Result -Module 'Firewall' -Task 'Reactivar firewall' -Status 'CAMBIADO' -Message 'Firewall activo'
    return $true
}

#endregion

#region ---------- Bloque 2: bloquear programas ----------

function Get-ToolkitBlockRules {
    <# Reglas creadas por el toolkit (grupo 'Toolkit BPO'), con programa y direccion. Solo lectura. #>
    [CmdletBinding()]
    param()

    $out = @()
    $rules = @()
    try { $rules = @(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction Stop) } catch { return $out }
    foreach ($r in $rules) {
        $prog = 'Any'; $port = 'Any'; $addr = 'Any'
        try { $prog = "$(($r | Get-NetFirewallApplicationFilter -ErrorAction Stop).Program)" } catch { }
        try { $port = "$(($r | Get-NetFirewallPortFilter -ErrorAction Stop).RemotePort)" } catch { }
        try { $addr = "$(($r | Get-NetFirewallAddressFilter -ErrorAction Stop).RemoteAddress)" } catch { }
        $out += [pscustomobject]@{
            Name        = $r.Name
            DisplayName = $r.DisplayName
            Direction   = "$($r.Direction)"
            Action      = "$($r.Action)"
            Enabled     = ("$($r.Enabled)" -eq 'True')
            Program     = $prog
            RemotePort  = $port
            RemoteAddress = $addr
            Exists      = $(if ($prog -ne 'Any') { Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($prog)) } else { $true })
        }
    }
    return $out | Sort-Object Program, Direction
}

function Show-ToolkitBlockRules {
    [CmdletBinding()]
    param()
    $rules = @(Get-ToolkitBlockRules)
    Write-Log ("REGLAS DEL TOOLKIT ({0})" -f $rules.Count) -Level STEP
    if ($rules.Count -eq 0) { Write-Log '  (ninguna)' -Level INFO; return $rules }
    foreach ($r in $rules) {
        Write-Log ("  {0} [{1,-8}] {2}  {3}{4}" -f $(if ($r.Enabled) { 'x' } else { '-' }), $r.Direction, $r.DisplayName,
                   $(if ($r.Program -ne 'Any') { $r.Program } else { "$($r.RemoteAddress):$($r.RemotePort)" }),
                   $(if (-not $r.Exists) { '  (el exe ya no existe)' } else { '' })) -Level $(if ($r.Enabled) { 'INFO' } else { 'DEBUG' })
    }
    return $rules
}

function Block-ProgramNetwork {
    <#
        Corta la red a un ejecutable con reglas de bloqueo del firewall de Windows.
        Idempotente: si ya existe la regla del toolkit para ese exe y direccion, no duplica.
        -Direction Both (por defecto) crea salida y entrada.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Outbound', 'Inbound', 'Both')][string]$Direction = 'Both'
    )

    $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
    Write-Log ("BLOQUEAR RED A {0}" -f $Path) -Level STEP
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log '  ! El archivo no existe en este equipo; la regla se crea igual (vale para cuando se instale)' -Level WARN }
    if (Test-ReportOnly) { Write-Log '  ! MODO REPORTE: sin cambios' -Level WARN; return $false }

    $leaf = Split-Path $Path -Leaf
    $dirs = if ($Direction -eq 'Both') { @('Outbound', 'Inbound') } else { @($Direction) }
    $created = 0
    foreach ($d in $dirs) {
        $display = '{0}{1} ({2})' -f $script:RulePrefix, $leaf, $(if ($d -eq 'Outbound') { 'salida' } else { 'entrada' })
        $exists = @(Get-NetFirewallRule -Group $script:RuleGroup -Direction $d -ErrorAction SilentlyContinue |
                    Where-Object { $prog = $null; try { $prog = ($_ | Get-NetFirewallApplicationFilter).Program } catch { }; $prog -and ($prog -ieq $Path) })
        if ($exists.Count -gt 0) {
            if (-not $exists[0].Enabled) { $exists[0] | Enable-NetFirewallRule; Write-Log "  + Regla '$display' reactivada" -Level OK; $created++ }
            else { Write-Log "  = Regla '$display' ya existe" -Level DEBUG }
            continue
        }
        try {
            New-NetFirewallRule -DisplayName $display -Group $script:RuleGroup -Direction $d -Action Block -Program $Path `
                                -Profile Any -Enabled True -Description 'Creada por Toolkit BPO. Quitar desde el toolkit o con Remove-NetFirewallRule.' -ErrorAction Stop | Out-Null
            Write-Log "  + Regla '$display' creada" -Level OK
            $created++
        } catch {
            Write-Log ("  x No se pudo crear '{0}': {1}" -f $display, $_.Exception.Message) -Level ERROR
            Add-Result -Module 'Firewall' -Task "Bloquear $leaf" -Status 'FALLO' -Message $_.Exception.Message
            return $false
        }
    }
    Add-Result -Module 'Firewall' -Task "Bloquear $leaf" -Status $(if ($created) { 'CAMBIADO' } else { 'YA-OK' }) -Message "$($dirs -join '+')"
    return $true
}

function Unblock-ProgramNetwork {
    <# Quita las reglas del toolkit para un exe (-Path) o una regla concreta (-Name). #>
    [CmdletBinding()]
    param([string]$Path, [string]$Name)

    if (Test-ReportOnly) { Write-Log '  ! MODO REPORTE: sin cambios' -Level WARN; return $false }
    $targets = @()
    if ($Name) {
        $targets = @(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.Group -eq $script:RuleGroup })
    } elseif ($Path) {
        $Path = [Environment]::ExpandEnvironmentVariables($Path.Trim('"'))
        $targets = @(Get-ToolkitBlockRules | Where-Object { $_.Program -ieq $Path } | ForEach-Object { Get-NetFirewallRule -Name $_.Name })
    }
    Write-Log ("DESBLOQUEAR {0}" -f $(if ($Name) { $Name } else { $Path })) -Level STEP
    if ($targets.Count -eq 0) { Write-Log '  = No hay reglas del toolkit para eso' -Level INFO; return $false }
    foreach ($t in $targets) {
        try { $t | Remove-NetFirewallRule -ErrorAction Stop; Write-Log "  + Regla '$($t.DisplayName)' eliminada" -Level OK }
        catch { Write-Log ("  x {0}: {1}" -f $t.DisplayName, $_.Exception.Message) -Level ERROR }
    }
    Add-Result -Module 'Firewall' -Task 'Desbloquear' -Status 'CAMBIADO' -Message "$($targets.Count) regla(s)"
    return $true
}

function Remove-AllToolkitBlockRules {
    [CmdletBinding()]
    param()
    if (Test-ReportOnly) { Write-Log '  ! MODO REPORTE: sin cambios' -Level WARN; return 0 }
    $rules = @(Get-NetFirewallRule -Group $script:RuleGroup -ErrorAction SilentlyContinue)
    Write-Log ("QUITAR TODAS LAS REGLAS DEL TOOLKIT ({0})" -f $rules.Count) -Level STEP
    foreach ($r in $rules) { try { $r | Remove-NetFirewallRule -ErrorAction Stop; Write-Log "  + '$($r.DisplayName)' eliminada" -Level OK } catch { Write-Log "  x $($r.DisplayName): $($_.Exception.Message)" -Level ERROR } }
    if ($rules.Count) { Add-Result -Module 'Firewall' -Task 'Quitar reglas' -Status 'CAMBIADO' -Message "$($rules.Count) regla(s)" }
    return $rules.Count
}

#endregion

#region ---------- Bloque 3: filtro web ----------

function Get-WebFilterCategories {
    <#
        Categorias disponibles: las del catalogo (webFilter.categories) sustituyen a
        las del modulo con el mismo id y se anaden las nuevas. Sin catalogo, las del modulo.
    #>
    [CmdletBinding()]
    param([string]$CatalogJson, $Catalog)

    $cats = @{}
    $order = New-Object System.Collections.ArrayList
    foreach ($c in $script:DefaultWebCategories) { $cats[$c.id] = $c; $null = $order.Add($c.id) }

    if ($CatalogJson -and -not $Catalog) { try { $Catalog = $CatalogJson | ConvertFrom-Json } catch { } }
    if ($Catalog -and $Catalog.PSObject.Properties.Name -contains 'webFilter' -and $Catalog.webFilter -and
        $Catalog.webFilter.PSObject.Properties.Name -contains 'categories') {
        foreach ($c in @($Catalog.webFilter.categories)) {
            if (-not $c.id) { continue }
            $obj = [pscustomobject]@{ id = "$($c.id)"; name = $(if ($c.name) { "$($c.name)" } else { "$($c.id)" }); domains = @($c.domains | ForEach-Object { "$_".Trim().ToLower() } | Where-Object { $_ }) }
            if (-not $cats.ContainsKey($obj.id)) { $null = $order.Add($obj.id) }
            $cats[$obj.id] = $obj
        }
    }
    return @($order | ForEach-Object { $cats[$_] })
}

function Get-WebFilterState {
    <# Que hay aplicado ahora mismo: dominios del toolkit, categorias, y lo que hay en cada capa. Solo lectura. #>
    [CmdletBinding()]
    param()

    $domains = @(Get-RegValue -Path $script:RegWebState -Name 'Domains'    | Where-Object { $_ })
    $cats    = @(Get-RegValue -Path $script:RegWebState -Name 'Categories' | Where-Object { $_ })
    $applied = Get-RegValue -Path $script:RegWebState -Name 'Applied'
    $hostsCount = @(Get-HostsEntries | Where-Object { $_.Toolkit }).Count

    return [pscustomobject]@{
        Active      = ($domains.Count -gt 0)
        Categories  = $cats
        Domains     = $domains
        Applied     = $applied
        ChromeCount  = @(Get-NumberedList -Path $script:RegChromeBlock).Count
        EdgeCount    = @(Get-NumberedList -Path $script:RegEdgeBlock).Count
        FirefoxCount = @(Get-NumberedList -Path $script:RegFirefoxBlock).Count
        HostsCount   = $hostsCount
    }
}

function Show-WebFilterState {
    [CmdletBinding()]
    param($State = (Get-WebFilterState), [string]$CatalogJson)

    Write-Log 'FILTRO WEB' -Level STEP
    if (-not $State.Active) {
        Write-Log '  Sin filtro del toolkit aplicado' -Level INFO
    } else {
        $names = @(Get-WebFilterCategories -CatalogJson $CatalogJson | Where-Object { $State.Categories -contains $_.id } | ForEach-Object { $_.name })
        Write-Log ("  Activo desde {0}: {1} dominio(s)" -f $State.Applied, $State.Domains.Count) -Level OK
        Write-Log ("  Categorias: {0}" -f $(if ($names) { $names -join ', ' } else { '(solo dominios sueltos)' })) -Level INFO
    }
    Write-Log ("  Entradas totales en politica: Chrome {0}, Edge {1}, Firefox {2}  |  hosts (toolkit) {3}" -f `
               $State.ChromeCount, $State.EdgeCount, $State.FirefoxCount, $State.HostsCount) -Level INFO
    return $State
}

function Set-WebFilter {
    <#
        Aplica el filtro: categorias (por id) y/o dominios sueltos. SUSTITUYE el
        filtro anterior del toolkit (no acumula): lo que no este en esta llamada
        deja de estar bloqueado. Con nada que bloquear, equivale a Clear-WebFilter.
    #>
    [CmdletBinding()]
    param(
        [string[]]$CategoryIds = @(),
        [string[]]$Domains = @(),
        [string]$CatalogJson,
        [switch]$NoHosts
    )

    $cats = @(Get-WebFilterCategories -CatalogJson $CatalogJson | Where-Object { $CategoryIds -contains $_.id })
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cats) { foreach ($d in $c.domains) { $all.Add($d) } }
    foreach ($d in $Domains) {
        $d = "$d".Trim().ToLower() -replace '^[a-z]+://', '' -replace '/.*$', '' -replace '^www\.', ''
        if ($d -and $d -match '^[a-z0-9\.\-]+\.[a-z]{2,}$') { $all.Add($d) }
        elseif ($d) { Write-Log "  ! Dominio ignorado (no valido): $d" -Level WARN }
    }
    $new = @($all | Sort-Object -Unique)

    Write-Log ("FILTRO WEB: {0} categoria(s), {1} dominio(s)" -f $cats.Count, $new.Count) -Level STEP
    foreach ($c in $cats) { Write-Log ("  - {0}: {1} dominios" -f $c.name, $c.domains.Count) -Level INFO }
    if ($new.Count -eq 0) { return (Clear-WebFilter) }
    if (Test-ReportOnly) { Write-Log '  ! MODO REPORTE: sin cambios' -Level WARN; return $false }

    $prev = @(Get-RegValue -Path $script:RegWebState -Name 'Domains' | Where-Object { $_ })

    # Politicas de navegador. Chrome/Edge: 'dominio' bloquea el dominio y sus subdominios.
    # Firefox: match pattern *://*.dominio/* (cubre el dominio y sus subdominios).
    $c1 = Set-NumberedList -Path $script:RegChromeBlock  -Remove $prev -Add $new -Label 'Chrome URLBlocklist'
    $c2 = Set-NumberedList -Path $script:RegEdgeBlock    -Remove $prev -Add $new -Label 'Edge URLBlocklist'
    $c3 = Set-NumberedList -Path $script:RegFirefoxBlock -Remove (ConvertTo-FirefoxPattern $prev) -Add (ConvertTo-FirefoxPattern $new) -Label 'Firefox WebsiteFilter'

    # Archivo hosts: apps de escritorio. Se escribe dominio y www.dominio.
    $c4 = 0
    if (-not $NoHosts) { $c4 = Set-HostsBlock -Domains $new } else { $c4 = Set-HostsBlock -Domains @() }

    try {
        if (-not (Test-Path -LiteralPath $script:RegWebState)) { New-Item -Path $script:RegWebState -Force | Out-Null }
        New-ItemProperty -LiteralPath $script:RegWebState -Name 'Domains'    -Value ([string[]]$new) -PropertyType MultiString -Force | Out-Null
        New-ItemProperty -LiteralPath $script:RegWebState -Name 'Categories' -Value ([string[]]@($cats | ForEach-Object { $_.id })) -PropertyType MultiString -Force | Out-Null
        New-ItemProperty -LiteralPath $script:RegWebState -Name 'Applied'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm') -PropertyType String -Force | Out-Null
    } catch { Write-Log "  ! No se pudo guardar el estado del filtro: $($_.Exception.Message)" -Level WARN }

    Write-Log '  i Chrome y Edge aplican la politica al momento (el agente ve "Bloqueado por tu organizacion"); Firefox al reiniciarse.' -Level INFO
    Write-Log '  i Apps de escritorio: se cortan al reconectar. Si alguna ya tenia la sesion abierta, cerrarla y abrirla.' -Level INFO
    Add-Result -Module 'Firewall' -Task 'Filtro web' -Status 'CAMBIADO' -Message ("{0} dominio(s); {1}" -f $new.Count, ($cats | ForEach-Object { $_.name }) -join ', ')
    return $true
}

function Clear-WebFilter {
    <# Quita SOLO lo que puso el toolkit en las tres capas. Las entradas ajenas (GPO) se quedan. #>
    [CmdletBinding()]
    param()

    Write-Log 'QUITAR FILTRO WEB' -Level STEP
    if (Test-ReportOnly) { Write-Log '  ! MODO REPORTE: sin cambios' -Level WARN; return $false }
    $prev = @(Get-RegValue -Path $script:RegWebState -Name 'Domains' | Where-Object { $_ })

    $null = Set-NumberedList -Path $script:RegChromeBlock  -Remove $prev -Add @() -Label 'Chrome URLBlocklist'
    $null = Set-NumberedList -Path $script:RegEdgeBlock    -Remove $prev -Add @() -Label 'Edge URLBlocklist'
    $null = Set-NumberedList -Path $script:RegFirefoxBlock -Remove (ConvertTo-FirefoxPattern $prev) -Add @() -Label 'Firefox WebsiteFilter'
    $null = Set-HostsBlock -Domains @()

    if (Test-Path -LiteralPath $script:RegWebState) { Remove-Item -LiteralPath $script:RegWebState -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Log '  + Filtro web retirado' -Level OK
    Add-Result -Module 'Firewall' -Task 'Filtro web' -Status 'CAMBIADO' -Message 'Retirado'
    return $true
}

function Test-WebFilterDomain {
    <# En que capas esta bloqueado un dominio (o un padre suyo). Solo lectura. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Domain)

    $Domain = $Domain.Trim().ToLower()
    $parents = @()
    $parts = $Domain.Split('.')
    for ($i = 0; $i -lt $parts.Count - 1; $i++) { $parents += ($parts[$i..($parts.Count - 1)] -join '.') }

    $out = @()
    foreach ($layer in @(@{ L = 'Chrome'; P = $script:RegChromeBlock }, @{ L = 'Edge'; P = $script:RegEdgeBlock })) {
        $list = @(Get-NumberedList -Path $layer.P | ForEach-Object { "$_".ToLower().TrimStart('.') })
        $hit = @($parents | Where-Object { $list -contains $_ }) | Select-Object -First 1
        $out += [pscustomobject]@{ Layer = $layer.L; Blocked = [bool]$hit; Entry = $hit }
    }
    $ff = @(Get-NumberedList -Path $script:RegFirefoxBlock)
    $ffHit = @($parents | Where-Object { $p = $_; $ff | Where-Object { $_ -like "*://*.$p/*" -or $_ -like "*://$p/*" } }) | Select-Object -First 1
    $out += [pscustomobject]@{ Layer = 'Firefox'; Blocked = [bool]$ffHit; Entry = $ffHit }
    $h = Get-HostsEntries | Where-Object { $_.Host -eq $Domain -and $_.Address -in @('0.0.0.0', '127.0.0.1', '::1') } | Select-Object -First 1
    $out += [pscustomobject]@{ Layer = 'hosts'; Blocked = [bool]$h; Entry = $(if ($h) { $h.Address } else { $null }) }
    return $out
}

# --- Utilidades internas del filtro ---

function ConvertTo-FirefoxPattern {
    param([string[]]$Domains)
    $o = @()
    # Match pattern de WebExtensions: "*.dominio" incluye el dominio base y sus subdominios.
    foreach ($d in @($Domains | Where-Object { $_ })) { $o += "*://*.$d/*" }
    return $o
}

function Get-NumberedList {
    <# Valores "1","2",... de una clave de politica de lista, en orden. #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $props = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $props) { return @() }
    return @($props.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' } |
             Sort-Object { [int]$_.Name } | ForEach-Object { "$($_.Value)" })
}

function Set-NumberedList {
    <#
        Reescribe una lista numerada de politica: quita las entradas de -Remove
        (las que el toolkit puso la vez anterior), anade -Add, respeta el resto
        (GPO u otros) y renumera desde 1. Devuelve cuantas entradas cambio.
    #>
    param([string]$Path, [string[]]$Remove, [string[]]$Add, [string]$Label)

    $current = @(Get-NumberedList -Path $Path)
    $rm = @($Remove | ForEach-Object { "$_".ToLower() })
    $kept = @($current | Where-Object { $rm -notcontains "$_".ToLower() })
    $final = @($kept + @($Add | Where-Object { $_ })) | Select-Object -Unique
    if ($final.Count -eq 0 -and $current.Count -eq 0) { return 0 }

    $same = ($final.Count -eq $current.Count) -and (@(Compare-Object $final $current -SyncWindow 0).Count -eq 0)
    if ($same) { Write-Log ("  = {0}: sin cambios ({1} entradas)" -f $Label, $final.Count) -Level DEBUG; return 0 }

    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        $props = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in @($props.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' })) {
                Remove-ItemProperty -LiteralPath $Path -Name $p.Name -Force -ErrorAction SilentlyContinue
            }
        }
        $i = 0
        foreach ($v in $final) { $i++; New-ItemProperty -LiteralPath $Path -Name "$i" -Value $v -PropertyType String -Force | Out-Null }
        if ($final.Count -eq 0) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        Write-Log ("  + {0}: {1} entrada(s) (antes {2}; {3} ajenas conservadas)" -f $Label, $final.Count, $current.Count, $kept.Count) -Level OK
        return [math]::Abs($final.Count - $current.Count) + 1
    } catch {
        Write-Log ("  x {0}: {1}" -f $Label, $_.Exception.Message) -Level ERROR
        return 0
    }
}

function Get-HostsEntries {
    <# Lineas activas del archivo hosts como objetos {Address, Host, Toolkit}. #>
    $out = @()
    if (-not (Test-Path -LiteralPath $script:HostsPath)) { return $out }
    $inBlock = $false
    foreach ($line in (Get-Content -LiteralPath $script:HostsPath -ErrorAction SilentlyContinue)) {
        if ($line -eq $script:HostsBegin) { $inBlock = $true; continue }
        if ($line -eq $script:HostsEnd)   { $inBlock = $false; continue }
        $t = ($line -replace '#.*$', '').Trim()
        if (-not $t) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -lt 2) { continue }
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $out += [pscustomobject]@{ Address = $parts[0]; Host = $parts[$i].ToLower(); Toolkit = $inBlock }
        }
    }
    return $out
}

function Set-HostsBlock {
    <# Sustituye el bloque del toolkit en hosts por los dominios dados (vacio = quitar el bloque). #>
    param([string[]]$Domains)

    $lines = @()
    if (Test-Path -LiteralPath $script:HostsPath) { $lines = @(Get-Content -LiteralPath $script:HostsPath -ErrorAction SilentlyContinue) }
    $kept = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($l in $lines) {
        if ($l -eq $script:HostsBegin) { $inBlock = $true; continue }
        if ($l -eq $script:HostsEnd)   { $inBlock = $false; continue }
        if (-not $inBlock) { $kept.Add($l) }
    }
    while ($kept.Count -gt 0 -and -not $kept[$kept.Count - 1].Trim()) { $kept.RemoveAt($kept.Count - 1) }

    $skipped = @($Domains | Where-Object { $d = $_; $script:HostsProtected | Where-Object { $d -eq $_ -or $d.EndsWith(".$_") } })
    if ($skipped.Count) { Write-Log ("  ! No se escriben en hosts (Defender los trataria como secuestro): {0}" -f ($skipped -join ', ')) -Level WARN }
    $Domains = @($Domains | Where-Object { $skipped -notcontains $_ })

    $block = @()
    if ($Domains.Count -gt 0) {
        $block += ''
        $block += $script:HostsBegin
        foreach ($d in $Domains) { $block += "0.0.0.0 $d"; if ($d -notmatch '^www\.' -and ($d.Split('.').Count -le 2)) { $block += "0.0.0.0 www.$d" } }
        $block += $script:HostsEnd
    }
    $final = @($kept) + $block
    $hadBlock = ($lines -contains $script:HostsBegin)
    if (-not $hadBlock -and $Domains.Count -eq 0) { return 0 }

    try {
        $item = Get-Item -LiteralPath $script:HostsPath -ErrorAction SilentlyContinue
        $ro = $item -and ($item.Attributes -band [IO.FileAttributes]::ReadOnly)
        if ($ro) { $item.Attributes = $item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
        [IO.File]::WriteAllLines($script:HostsPath, [string[]]$final, (New-Object System.Text.ASCIIEncoding))
        if ($ro) { (Get-Item -LiteralPath $script:HostsPath).Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly }
        & ipconfig.exe /flushdns 2>&1 | Out-Null
        Write-Log ("  + hosts: {0}" -f $(if ($Domains.Count) { "$($Domains.Count) dominio(s) desviados a 0.0.0.0" } else { 'bloque del toolkit retirado' })) -Level OK
        return 1
    } catch {
        Write-Log ("  x hosts: {0} (antivirus protegiendo el archivo?)" -f $_.Exception.Message) -Level ERROR
        return 0
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-FirewallState', 'Show-FirewallState', 'Test-FirewallConnection',
    'Get-FirewallPause', 'Suspend-Firewall', 'Resume-Firewall',
    'Get-ToolkitBlockRules', 'Show-ToolkitBlockRules', 'Block-ProgramNetwork', 'Unblock-ProgramNetwork', 'Remove-AllToolkitBlockRules',
    'Get-WebFilterCategories', 'Get-WebFilterState', 'Show-WebFilterState', 'Set-WebFilter', 'Clear-WebFilter', 'Test-WebFilterDomain'
)
