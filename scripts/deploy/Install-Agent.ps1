<#
.SYNOPSIS
    Instala el toolkit como agente local auto-actualizable.

.DESCRIPTION
    Es el "mini-RMM" descrito en la seccion 12 del PLAN.
    Una sola pasada manual por equipo; a partir de ahi todo se despliega
    editando manifest.json en el share.

    Que hace:
      1. Copia el toolkit a C:\ProgramData\Toolkit\bin (ACL: solo SYSTEM y Administradores)
      2. Crea la tarea programada 'Toolkit Agent' como SYSTEM
         - Al arrancar (+5 min) y cada 4 horas
      3. La tarea ejecuta Invoke-AgentCheck.ps1, que lee manifest.json del share

.PARAMETER SharePath
    Ruta UNC del share del toolkit. Ej: \\SRV-FILE\Toolkit$

.EXAMPLE
    .\Install-Agent.ps1 -SharePath \\SRV-FILE\Toolkit$

.EXAMPLE
    .\Install-Agent.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string]$SharePath,
    [string]$InstallRoot = 'C:\ProgramData\Toolkit',
    [int]$IntervalHours  = 4,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Toolkit Agent'

function Test-IsAdminLocal {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdminLocal)) {
    Write-Host 'ERROR: requiere privilegios de administrador.' -ForegroundColor Red
    exit 5
}

# ---------------------------------------------------------------------------
#  Desinstalacion  (imprescindible tenerla desde el dia 1)
# ---------------------------------------------------------------------------
if ($Uninstall) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "Tarea '$TaskName' eliminada." -ForegroundColor Green
    } catch {
        Write-Host "No habia tarea que eliminar ($($_.Exception.Message))" -ForegroundColor Yellow
    }
    $bin = Join-Path $InstallRoot 'bin'
    if (Test-Path -LiteralPath $bin) {
        Remove-Item -LiteralPath $bin -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Binarios eliminados de $bin" -ForegroundColor Green
    }
    Write-Host "Se CONSERVAN logs, reportes y rollback.json en $InstallRoot" -ForegroundColor DarkGray
    Write-Host 'Para revertir los cambios de registro: Toolkit.ps1 -Rollback (antes de borrar).' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
#  1. Copiar el toolkit
# ---------------------------------------------------------------------------
$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)   # ...\scripts
$binDir     = Join-Path $InstallRoot 'bin'

Write-Host "Instalando toolkit en $binDir ..." -ForegroundColor Cyan
New-Item -Path $binDir -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $binDir -Recurse -Force

# ACL: solo SYSTEM y Administradores pueden escribir.
# Sin esto, un agente con admin local podria alterar el toolkit.
try {
    $acl = Get-Acl -LiteralPath $binDir
    $acl.SetAccessRuleProtection($true, $false)   # rompe herencia
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    foreach ($principal in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $binDir -AclObject $acl
    Write-Host '  + ACL aplicada (escritura solo SYSTEM/Administradores)' -ForegroundColor Green
} catch {
    Write-Host "  ! No se pudo aplicar la ACL: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
#  2. Guardar configuracion del agente
# ---------------------------------------------------------------------------
$agentConfig = @{
    SharePath     = $SharePath
    InstalledAt   = (Get-Date).ToString('o')
    InstalledBy   = "$env:USERDOMAIN\$env:USERNAME"
    IntervalHours = $IntervalHours
} | ConvertTo-Json

$agentConfig | Set-Content -LiteralPath (Join-Path $InstallRoot 'agent.json') -Encoding UTF8

# ---------------------------------------------------------------------------
#  3. Crear la tarea programada
# ---------------------------------------------------------------------------
Write-Host "Creando tarea programada '$TaskName' ..." -ForegroundColor Cyan

$agentScript = Join-Path $binDir 'deploy\Invoke-AgentCheck.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $agentScript)

$triggers = @(
    $(New-ScheduledTaskTrigger -AtStartup),
    $(New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) -RepetitionDuration ([TimeSpan]::MaxValue))
)
$triggers[0].Delay = 'PT5M'   # 5 min tras el arranque: no competir con el inicio de sesion del agente

$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 10)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings -Force `
        -Description 'Toolkit call center: reaplica configuracion y reporta estado.' | Out-Null
    Write-Host "  + Tarea creada (cada $IntervalHours h y al arrancar)" -ForegroundColor Green
} catch {
    Write-Host "  x No se pudo crear la tarea: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'AGENTE INSTALADO' -ForegroundColor Green
Write-Host "  Binarios : $binDir"
Write-Host "  Share    : $(if ($SharePath) { $SharePath } else { '<sin share: modo autonomo>' })"
Write-Host "  Logs     : $(Join-Path $InstallRoot 'logs')"
Write-Host ''
Write-Host 'Prueba inmediata:  Start-ScheduledTask -TaskName "Toolkit Agent"' -ForegroundColor DarkGray
Write-Host 'Desinstalar:       .\Install-Agent.ps1 -Uninstall' -ForegroundColor DarkGray
exit 0
