<#
.SYNOPSIS
    Orquestador del toolkit. UNICA fuente de la logica de ejecucion.

.DESCRIPTION
    Este script NO se ejecuta suelto: lo invocan dos consumidores.

      1. Toolkit.exe  -> lo carga como recurso embebido y lo ejecuta en un
                         runspace en proceso (ver src/Toolkit.App/ScriptHost.cs)
      2. Toolkit.ps1  -> envoltorio de linea de comandos para desarrollo y
                         depuracion sin tener que recompilar el exe

    Presupone que los modulos Toolkit.* ya estan importados en la sesion.
    Devuelve un objeto con ExitCode, Summary y Results.

.PARAMETER ConfigJson
    Contenido JSON del catalogo. Es lo que usa el exe (catalogo embebido).

.PARAMETER ConfigPath
    Alternativa a ConfigJson: ruta a catalog.json en disco.
#>

[CmdletBinding()]
param(
    [ValidateSet('location', 'apps', 'network', 'users')][string[]]$Modules = @('location', 'apps', 'network', 'users'),
    [string[]]$Apps,
    [switch]$ReportOnly,
    [switch]$Silent,
    [string]$ConfigJson,
    [string]$ConfigPath,
    [string]$SharePath,
    [string]$Root = 'C:\ProgramData\Toolkit',
    [switch]$NoLockDown,
    [switch]$GetPosition,
    [int]$PingCount = 0,
    [switch]$IgnoreMaintenanceWindow
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
#  Configuracion
# ---------------------------------------------------------------------------
$config = $null
if ($ConfigJson) {
    try {
        $config = $ConfigJson | ConvertFrom-Json
    } catch {
        throw "El catalogo embebido no es JSON valido: $($_.Exception.Message)"
    }
} elseif ($ConfigPath) {
    $config = Get-ToolkitConfig -Path $ConfigPath
} else {
    throw 'Falta configuracion: indica -ConfigJson o -ConfigPath.'
}

if (-not $SharePath -and $config.PSObject.Properties.Name -contains 'reportShare') {
    $SharePath = $config.reportShare
}

Initialize-Toolkit -Root $Root -SharePath $SharePath -Silent:$Silent -ReportOnly:$ReportOnly

# Instancia unica: el modo auditoria no escribe nada, asi que puede convivir.
if (-not $ReportOnly) {
    if (-not (Enter-ToolkitInstance -WaitSeconds 120)) {
        Write-Log 'Otra instancia esta aplicando cambios. Se aborta para no corromper el estado.' -Level ERROR
        return [pscustomobject]@{ ExitCode = 1; Summary = $null; Results = @(); LogPath = Get-ToolkitLogPath }
    }
}

# ---------------------------------------------------------------------------
#  Modulo A - Ubicacion
# ---------------------------------------------------------------------------
function Invoke-ModuleLocation {
    Write-Step 'MODULO A - UBICACION'

    $before = Test-LocationState
    if (-not $Silent) { Show-LocationState -State $before }

    if ($ReportOnly) {
        Add-Result -Module 'Location' -Task 'Auditoria' `
                   -Status $(if ($before.Compliant) { 'OK' } else { 'AVISO' }) `
                   -Message $(if ($before.Compliant) { 'Conforme' } else { ('{0} problema(s)' -f $before.Issues.Count) }) `
                   -Detail $before
    } else {
        $lockDown = $true
        if ($config.location.PSObject.Properties.Name -contains 'lockDown') { $lockDown = [bool]$config.location.lockDown }
        if ($NoLockDown) { $lockDown = $false }
        Enable-LocationService -LockDown:$lockDown | Out-Null
    }

    # El registro correcto NO garantiza que funcione: hay que preguntarle a la API.
    if ($config.location.verifyWithApi) {
        Write-Log 'Verificacion contra la API de geolocalizacion...' -Level INFO
        # -GetPosition (GUI) fuerza coordenadas reales aunque el catalogo diga que no.
        $api = Test-LocationApi -GetPosition:($GetPosition -or [bool]$config.location.getPosition)
        if ($api.ApiAvailable -and $api.LocationStatus -in @('Disabled', 'NotAvailable')) {
            Add-Result -Module 'Location' -Task 'Verificacion API' -Status 'FALLO' `
                       -Message "API en estado $($api.LocationStatus)" -Detail $api
        } else {
            Add-Result -Module 'Location' -Task 'Verificacion API' -Status 'OK' `
                       -Message "Estado: $($api.LocationStatus)" -Detail $api
        }
    }
}

# ---------------------------------------------------------------------------
#  Modulo B - Aplicaciones
# ---------------------------------------------------------------------------
function Invoke-ModuleApps {
    Write-Step 'MODULO B - APLICACIONES'

    if ($ReportOnly) {
        if (-not $Silent) { Show-AppInventory -Catalog $config }
        foreach ($app in $config.apps) {
            if (-not $app.enabled) { continue }
            if ($Apps -and $Apps -notcontains $app.id) { continue }
            $d = Test-AppInstalled -App $app
            Add-Result -Module 'Apps' -Task $app.name `
                       -Status $(if ($d.Installed) { 'OK' } else { 'AVISO' }) `
                       -Message $(if ($d.Installed) { "v$($d.Version)" } else { 'No instalada' })
        }
        return
    }

    $enabled = @($config.apps | Where-Object { $_.enabled })
    if ($enabled.Count -eq 0) {
        Write-Log 'Ninguna aplicacion activada en el catalogo (todas con enabled=false).' -Level WARN
        Write-Log 'Rellena las fichas en docs/APP-FICHAS/ y pon enabled=true cuando esten validadas.' -Level WARN
        return
    }

    Install-AppSet -Catalog $config -Only $Apps
}

# ---------------------------------------------------------------------------
#  Modulo C - Red
# ---------------------------------------------------------------------------
function Invoke-ModuleNetwork {
    Write-Step 'MODULO C - DIAGNOSTICO DE RED'

    $count = 50
    if ($config.network.PSObject.Properties.Name -contains 'pingCount') { $count = [int]$config.network.pingCount }
    if ($PingCount -gt 0) { $count = $PingCount }   # la GUI puede acortar o alargar la prueba

    $net = Invoke-NetworkDiagnostic -NetworkConfig $config.network -PingCount $count
    if (-not $Silent) { Show-NetworkSummary -Report $net }
}

# ---------------------------------------------------------------------------
#  Modulo D - Usuarios locales (solo inventario)
#  Las acciones (contrasena, eliminar, crear...) son interactivas: viven en la
#  GUI y en el menu de Toolkit.ps1, nunca en el despliegue desatendido.
# ---------------------------------------------------------------------------
function Invoke-ModuleUsers {
    Write-Step 'MODULO D - USUARIOS LOCALES (inventario)'

    $users = @(Get-LocalUserInventory)
    if (-not $Silent) { Show-LocalUserInventory -Users $users }

    $active = @($users | Where-Object { $_.Enabled -and -not $_.BuiltIn })
    $admins = @($active | Where-Object { $_.IsAdmin })
    $noPwd  = @($active | Where-Object { -not $_.PasswordRequired })

    Add-Result -Module 'Users' -Task 'Inventario' -Status 'OK' `
               -Message ('{0} cuenta(s) activa(s), {1} admin, {2} sin contrasena' -f $active.Count, $admins.Count, $noPwd.Count) `
               -Detail $users
}

# ---------------------------------------------------------------------------
#  Flujo
# ---------------------------------------------------------------------------
$exitCode = 0
try {
    $selected = @($Modules)

    # En produccion las acciones intrusivas se aplazan fuera de la ventana de mantenimiento.
    if ($Silent -and -not $ReportOnly -and -not $IgnoreMaintenanceWindow -and ($selected -contains 'apps')) {
        if (-not (Test-MaintenanceWindow)) {
            Write-Log 'Fuera de ventana de mantenimiento: se omite la instalacion de aplicaciones.' -Level WARN
            Write-Log 'Ajusta Test-MaintenanceWindow (Toolkit.Core.psm1) a los turnos reales del call center.' -Level INFO
            $selected = @($selected | Where-Object { $_ -ne 'apps' })
            Add-Result -Module 'Apps' -Task 'Instalacion' -Status 'OMITIDO' -Message 'Fuera de ventana de mantenimiento'
        }
    }

    if ($selected -contains 'location') { Invoke-ModuleLocation }
    if ($selected -contains 'apps')     { Invoke-ModuleApps }
    if ($selected -contains 'network')  { Invoke-ModuleNetwork }
    if ($selected -contains 'users')    { Invoke-ModuleUsers }

    Save-Report -SharePath $SharePath | Out-Null
    if (-not $Silent) { Show-Summary }
    $exitCode = Get-ExitCode
} catch {
    Write-Log "ERROR NO CONTROLADO: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level DEBUG
    $exitCode = 1
}

if (-not $ReportOnly) { Exit-ToolkitInstance }

Write-Log ('Finalizado con codigo de salida {0}. Log: {1}' -f $exitCode, (Get-ToolkitLogPath)) -Level INFO

# Objeto de retorno que consume el exe (ScriptHost.cs lee ExitCode).
[pscustomobject]@{
    ExitCode = $exitCode
    Summary  = Get-ResultSummary
    Results  = @(Get-Results)
    LogPath  = Get-ToolkitLogPath
}
