<#
.SYNOPSIS
    Latido del agente. Lo ejecuta la tarea programada 'Toolkit Agent' como SYSTEM.

.DESCRIPTION
    1. Lee agent.json (local) para saber cual es el share
    2. Lee manifest.json (share) -> version objetivo, anillo y trabajos a ejecutar
    3. Si hay version nueva: se auto-actualiza (con verificacion y copia de seguridad)
    4. Ejecuta el trabajo que corresponda a su anillo de despliegue
    5. Sube el reporte

    Si el share no esta disponible, sigue funcionando en modo autonomo con
    la configuracion embebida. El share es optimizacion, no dependencia dura.
#>

[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\ProgramData\Toolkit'
)

$ErrorActionPreference = 'Continue'
$binDir     = Join-Path $InstallRoot 'bin'
$toolkit    = Join-Path $binDir 'Toolkit.ps1'
$agentLog   = Join-Path $InstallRoot 'logs\agent.log'

function Write-AgentLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [AGENT/{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $agentLog -Value $line -Encoding UTF8 } catch { }
    Write-Verbose $line
}

Write-AgentLog '--- latido del agente ---'

if (-not (Test-Path -LiteralPath $toolkit)) {
    Write-AgentLog "No se encuentra $toolkit. Instalacion corrupta." 'ERROR'
    exit 1
}

# ---------------------------------------------------------------------------
#  Configuracion local
# ---------------------------------------------------------------------------
$share = $null
$ring  = 'default'
try {
    $cfg = Get-Content -LiteralPath (Join-Path $InstallRoot 'agent.json') -Raw | ConvertFrom-Json
    $share = $cfg.SharePath
    if ($cfg.PSObject.Properties.Name -contains 'Ring') { $ring = $cfg.Ring }
} catch {
    Write-AgentLog 'Sin agent.json: modo autonomo.' 'WARN'
}

# ---------------------------------------------------------------------------
#  Manifiesto del share
# ---------------------------------------------------------------------------
$manifest = $null
if ($share) {
    $manifestPath = Join-Path $share 'manifest.json'
    try {
        if (Test-Path -LiteralPath $manifestPath) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            Write-AgentLog "Manifiesto leido (version objetivo: $($manifest.targetVersion))"
        } else {
            Write-AgentLog "No hay manifest.json en $share" 'WARN'
        }
    } catch {
        Write-AgentLog "Share inalcanzable: $($_.Exception.Message)" 'WARN'
    }
}

# ---------------------------------------------------------------------------
#  Auto-actualizacion
# ---------------------------------------------------------------------------
if ($manifest -and $manifest.targetVersion) {
    $localVersion = '0.0.0'
    try {
        Import-Module (Join-Path $binDir 'modules\Toolkit.Core.psm1') -Force -DisableNameChecking
        $localVersion = Get-ToolkitVersion
    } catch { }

    if ([version]$manifest.targetVersion -gt [version]$localVersion) {
        Write-AgentLog "Actualizando $localVersion -> $($manifest.targetVersion)"
        try {
            $src = Join-Path $share ('releases\{0}\scripts' -f $manifest.targetVersion)
            if (Test-Path -LiteralPath $src) {
                # Copia de seguridad antes de pisar: si la version nueva esta rota,
                # hay a donde volver sin tocar 400 equipos a mano.
                $backup = Join-Path $InstallRoot ('bin-backup-{0}' -f $localVersion)
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $binDir -Destination $backup -Recurse -Force -ErrorAction SilentlyContinue

                Copy-Item -Path (Join-Path $src '*') -Destination $binDir -Recurse -Force
                Write-AgentLog "Actualizado a $($manifest.targetVersion). Copia previa en $backup" 'OK'
            } else {
                Write-AgentLog "No existe la carpeta de la version: $src" 'ERROR'
            }
        } catch {
            Write-AgentLog "Fallo la actualizacion: $($_.Exception.Message)" 'ERROR'
        }
    }
}

# ---------------------------------------------------------------------------
#  Ejecutar el trabajo del anillo
# ---------------------------------------------------------------------------
$jobArgs = @('-Silent', '-All')

if ($manifest) {
    $job = $null
    if ($manifest.PSObject.Properties.Name -contains 'jobs') {
        $job = $manifest.jobs | Where-Object { $_.ring -eq $ring -or $_.ring -eq 'all' } | Select-Object -First 1
    }
    if ($job) {
        $jobArgs = @('-Silent')
        if ($job.PSObject.Properties.Name -contains 'modules' -and $job.modules) {
            $jobArgs += @('-Modules', ($job.modules -join ','))
        } else {
            $jobArgs += '-All'
        }
        if ($job.PSObject.Properties.Name -contains 'apps' -and $job.apps) {
            $jobArgs += @('-Apps', ($job.apps -join ','))
        }
        Write-AgentLog "Trabajo del anillo '$ring': $($jobArgs -join ' ')"
    }
}

if ($share) { $jobArgs += @('-SharePath', ('"{0}"' -f $share)) }

$cmd = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $toolkit, ($jobArgs -join ' ')
Write-AgentLog "Ejecutando: powershell.exe $cmd"

try {
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $cmd -PassThru -WindowStyle Hidden -Wait
    Write-AgentLog "Toolkit finalizado con codigo $($proc.ExitCode)" $(if ($proc.ExitCode -eq 0) { 'OK' } else { 'WARN' })
    exit $proc.ExitCode
} catch {
    Write-AgentLog "No se pudo ejecutar el toolkit: $($_.Exception.Message)" 'ERROR'
    exit 1
}
