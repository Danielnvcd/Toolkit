<#
.SYNOPSIS
    Despliegue masivo del toolkit sin infraestructura de gestion.

.DESCRIPTION
    Resuelve el problema de arranque de la seccion 12 del PLAN: como llega el
    toolkit a 400 equipos la primera vez cuando no hay GPO, ni Intune, ni RMM.

    Dos metodos:
      WinRM  (preferido) : Copy-Item -ToSession + Invoke-Command
      SMB    (respaldo)  : copia por \\PC\C$ + schtasks.exe remoto

    Procesa en paralelo por lotes y deja un CSV con el resultado por equipo,
    para saber exactamente cuales quedan pendientes de pasada manual.

.PARAMETER ComputerList
    Archivo de texto con un nombre o IP por linea. Lineas con # se ignoran.

.EXAMPLE
    .\Deploy-Remote.ps1 -ComputerList .\equipos-anillo1.txt -SharePath \\SRV-FILE\Toolkit$ -Credential (Get-Credential)

.EXAMPLE
    .\Deploy-Remote.ps1 -ComputerList .\equipos.txt -TestOnly
    Solo comprueba alcanzabilidad, no despliega nada.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputerList,
    [string]$SharePath,
    [System.Management.Automation.PSCredential]$Credential,
    [ValidateSet('WinRM', 'SMB', 'Auto')][string]$Method = 'Auto',
    [int]$ThrottleLimit = 20,
    [switch]$TestOnly,
    [string]$OutputCsv
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
#  Preparacion
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ComputerList)) { throw "No existe la lista: $ComputerList" }

$computers = @(Get-Content -LiteralPath $ComputerList |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') })

if ($computers.Count -eq 0) { throw 'La lista de equipos esta vacia.' }

$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
if (-not $OutputCsv) {
    $OutputCsv = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) `
                           ('despliegue-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

Write-Host ''
Write-Host ('  DESPLIEGUE MASIVO  -  {0} equipos  -  metodo {1}' -f $computers.Count, $Method) -ForegroundColor Cyan
Write-Host ('  Origen: {0}' -f $sourceRoot) -ForegroundColor DarkGray
Write-Host ('  Salida: {0}' -f $OutputCsv) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
#  Bloque que se ejecuta por equipo
# ---------------------------------------------------------------------------
$worker = {
    param($Computer, $SourceRoot, $SharePath, $Credential, $Method, $TestOnly)

    $r = [ordered]@{
        Computer   = $Computer
        Reachable  = $false
        Method     = ''
        Status     = 'PENDIENTE'
        Message    = ''
        DurationMs = 0
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        # --- Alcanzabilidad ---
        $ping = New-Object System.Net.NetworkInformation.Ping
        try { $r.Reachable = ($ping.Send($Computer, 2000).Status -eq 'Success') } catch { $r.Reachable = $false }
        finally { $ping.Dispose() }

        if (-not $r.Reachable) {
            $r.Status  = 'INALCANZABLE'
            $r.Message = 'No responde a ICMP (apagado, otra red o firewall)'
            return [pscustomobject]$r
        }

        if ($TestOnly) {
            $winrmOk = Test-NetConnection -ComputerName $Computer -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue
            $smbOk   = Test-NetConnection -ComputerName $Computer -Port 445  -InformationLevel Quiet -WarningAction SilentlyContinue
            $r.Status  = 'ALCANZABLE'
            $r.Message = "WinRM:$winrmOk SMB:$smbOk"
            return [pscustomobject]$r
        }

        # --- Metodo ---
        $useWinRM = $false
        if ($Method -eq 'WinRM') { $useWinRM = $true }
        elseif ($Method -eq 'Auto') {
            $useWinRM = Test-NetConnection -ComputerName $Computer -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue
        }

        # =====================  WinRM  =====================
        if ($useWinRM) {
            $r.Method = 'WinRM'
            $sessionParams = @{ ComputerName = $Computer; ErrorAction = 'Stop' }
            if ($Credential) { $sessionParams.Credential = $Credential }
            $session = New-PSSession @sessionParams

            try {
                Invoke-Command -Session $session -ScriptBlock {
                    $d = 'C:\ProgramData\Toolkit\staging'
                    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
                    New-Item -Path $d -ItemType Directory -Force | Out-Null
                } -ErrorAction Stop

                Copy-Item -Path (Join-Path $SourceRoot '*') -Destination 'C:\ProgramData\Toolkit\staging' `
                          -ToSession $session -Recurse -Force -ErrorAction Stop

                $out = Invoke-Command -Session $session -ScriptBlock {
                    param($Share)
                    $installer = 'C:\ProgramData\Toolkit\staging\deploy\Install-Agent.ps1'
                    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer)
                    if ($Share) { $psArgs += @('-SharePath', $Share) }
                    $p = Start-Process powershell.exe -ArgumentList $psArgs -Wait -PassThru -WindowStyle Hidden
                    [pscustomobject]@{ ExitCode = $p.ExitCode }
                } -ArgumentList $SharePath -ErrorAction Stop

                if ($out.ExitCode -eq 0) {
                    $r.Status = 'OK'; $r.Message = 'Agente instalado'
                } else {
                    $r.Status = 'FALLO'; $r.Message = "Install-Agent devolvio $($out.ExitCode)"
                }
            } finally {
                Remove-PSSession $session -ErrorAction SilentlyContinue
            }
        }
        # =====================  SMB + schtasks  =====================
        else {
            $r.Method = 'SMB'
            $dest = "\\$Computer\C$\ProgramData\Toolkit\staging"

            if (-not (Test-Path -LiteralPath "\\$Computer\C$")) {
                throw 'Sin acceso al recurso administrativo C$ (credenciales o firewall)'
            }
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -Path $dest -ItemType Directory -Force | Out-Null
            Copy-Item -Path (Join-Path $SourceRoot '*') -Destination $dest -Recurse -Force -ErrorAction Stop

            # Tarea de un solo uso que instala el agente y se autoelimina.
            $taskName = 'ToolkitBootstrap'
            $inner = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\Toolkit\staging\deploy\Install-Agent.ps1'
            if ($SharePath) { $inner += " -SharePath `"$SharePath`"" }

            $null = & schtasks.exe /Create /S $Computer /TN $taskName /TR $inner /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F 2>&1
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Create fallo (codigo $LASTEXITCODE)" }

            $null = & schtasks.exe /Run /S $Computer /TN $taskName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "schtasks /Run fallo (codigo $LASTEXITCODE)" }

            Start-Sleep -Seconds 20
            $null = & schtasks.exe /Delete /S $Computer /TN $taskName /F 2>&1

            # Verificacion: la tarea del agente debe existir en el destino
            $check = & schtasks.exe /Query /S $Computer /TN 'Toolkit Agent' 2>&1
            if ($LASTEXITCODE -eq 0) {
                $r.Status = 'OK'; $r.Message = 'Agente instalado (verificado)'
            } else {
                $r.Status = 'DUDOSO'; $r.Message = 'Bootstrap lanzado pero la tarea Toolkit Agent no se verifica'
            }
        }
    } catch {
        $r.Status  = 'FALLO'
        $r.Message = $_.Exception.Message
    } finally {
        $sw.Stop()
        $r.DurationMs = [int]$sw.Elapsed.TotalMilliseconds
    }

    return [pscustomobject]$r
}

# ---------------------------------------------------------------------------
#  Ejecucion por lotes
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.ArrayList
$batches = [math]::Ceiling($computers.Count / $ThrottleLimit)
$n = 0

for ($b = 0; $b -lt $batches; $b++) {
    $batch = $computers[($b * $ThrottleLimit)..([math]::Min(($b + 1) * $ThrottleLimit - 1, $computers.Count - 1))]
    $jobs = @()

    foreach ($c in $batch) {
        $jobs += Start-Job -ScriptBlock $worker -ArgumentList $c, $sourceRoot, $SharePath, $Credential, $Method, $TestOnly.IsPresent
    }

    $null = Wait-Job -Job $jobs -Timeout 600
    foreach ($j in $jobs) {
        $n++
        $res = $null
        if ($j.State -eq 'Completed') {
            $res = Receive-Job -Job $j
        } else {
            $res = [pscustomobject]@{ Computer = '?'; Reachable = $false; Method = ''; Status = 'TIMEOUT'; Message = "Job en estado $($j.State)"; DurationMs = 0 }
            Stop-Job -Job $j -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue

        if ($res) {
            [void]$results.Add($res)
            $color = switch ($res.Status) {
                'OK'           { 'Green' }
                'ALCANZABLE'   { 'Green' }
                'INALCANZABLE' { 'DarkGray' }
                'DUDOSO'       { 'Yellow' }
                default        { 'Red' }
            }
            Write-Host ('  [{0,4}/{1}] {2,-20} {3,-14} {4}' -f $n, $computers.Count, $res.Computer, $res.Status, $res.Message) -ForegroundColor $color
        }
    }
}

# ---------------------------------------------------------------------------
#  Resumen
# ---------------------------------------------------------------------------
$results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

$ok      = @($results | Where-Object { $_.Status -eq 'OK' }).Count
$unreach = @($results | Where-Object { $_.Status -eq 'INALCANZABLE' }).Count
$failed  = @($results | Where-Object { $_.Status -in @('FALLO', 'TIMEOUT', 'DUDOSO') }).Count

Write-Host ''
Write-Host ('  ' + ('=' * 60)) -ForegroundColor Cyan
Write-Host ('  Total {0}  |  OK {1}  |  Inalcanzables {2}  |  Fallos {3}' -f $computers.Count, $ok, $unreach, $failed) -ForegroundColor White
Write-Host ('  Cobertura: {0}%' -f ([math]::Round(($ok / [double]$computers.Count) * 100, 1))) -ForegroundColor White
Write-Host ('  CSV: {0}' -f $OutputCsv) -ForegroundColor DarkGray
Write-Host ('  ' + ('=' * 60)) -ForegroundColor Cyan

if ($failed -gt 0 -or $unreach -gt 0) {
    $pendingFile = [IO.Path]::ChangeExtension($OutputCsv, '.pendientes.txt')
    $results | Where-Object { $_.Status -ne 'OK' -and $_.Computer -ne '?' } |
        Select-Object -ExpandProperty Computer |
        Set-Content -LiteralPath $pendingFile -Encoding UTF8
    Write-Host ''
    Write-Host ('  Equipos pendientes para reintento o pasada manual: {0}' -f $pendingFile) -ForegroundColor Yellow
    Write-Host '  Reintenta con:  .\Deploy-Remote.ps1 -ComputerList "' -NoNewline -ForegroundColor DarkGray
    Write-Host ($pendingFile + '"') -ForegroundColor DarkGray
}
