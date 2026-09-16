<#
.SYNOPSIS
    Envoltorio de linea de comandos del toolkit (uso en desarrollo y depuracion).

.DESCRIPTION
    IMPORTANTE: en produccion el entregable es Toolkit.exe, que lleva estos
    mismos scripts embebidos. Este archivo existe para poder probar y depurar
    los modulos SIN recompilar el exe.

    La logica de ejecucion no vive aqui: vive en Invoke-ToolkitRun.ps1,
    que es la unica fuente compartida por el exe y por este envoltorio.

.EXAMPLE
    .\Toolkit.ps1                      # menu interactivo
    .\Toolkit.ps1 -Silent -All         # desatendido
    .\Toolkit.ps1 -Report              # auditoria, sin cambios
    .\Toolkit.ps1 -Rollback            # revertir cambios de registro

.NOTES
    Codigos de salida: 0 OK | 5 sin privilegios | 1001 ubicacion | 1002 apps | 1003 red | 1 generico
#>

[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$All,
    [ValidateSet('location', 'apps', 'network')][string[]]$Modules,
    [string[]]$Apps,
    [switch]$Report,
    [switch]$NoLockDown,
    [switch]$Rollback,
    [string]$ConfigPath,
    [string]$SharePath,
    [string]$Root = 'C:\ProgramData\Toolkit'
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---------------------------------------------------------------------------
#  Carga de modulos
# ---------------------------------------------------------------------------
foreach ($m in @('Toolkit.Core', 'Toolkit.Location', 'Toolkit.Apps', 'Toolkit.Network')) {
    $path = Join-Path $here "modules\$m.psm1"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "ERROR: falta el modulo $path" -ForegroundColor Red
        exit 1
    }
    Import-Module $path -Force -DisableNameChecking
}

$runner = Join-Path $here 'Invoke-ToolkitRun.ps1'
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config\catalog.json' }

# ---------------------------------------------------------------------------
#  Elevacion
# ---------------------------------------------------------------------------
if (-not (Test-IsAdmin)) {
    if ($Silent -or $Rollback) {
        Write-Host 'ERROR: se requieren privilegios de administrador (modo desatendido, no se puede elevar).' -ForegroundColor Red
        exit 5
    }
    Write-Host 'Se requieren privilegios de administrador. Reiniciando elevado...' -ForegroundColor Yellow

    # $MyInvocation.UnboundArguments esta vacio con CmdletBinding: hay que
    # reconstruir la linea desde los parametros enlazados o se pierden al elevar.
    $argLine = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Definition))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if     ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $argLine += "-$($kv.Key)" } }
        elseif ($kv.Value -is [array])  { $argLine += "-$($kv.Key)"; $argLine += ($kv.Value -join ',') }
        else                            { $argLine += "-$($kv.Key)"; $argLine += ('"{0}"' -f $kv.Value) }
    }
    try   { Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs }
    catch { Write-Host "No se pudo elevar: $($_.Exception.Message)" -ForegroundColor Red; exit 5 }
    exit 0
}

# ---------------------------------------------------------------------------
#  Reversion
# ---------------------------------------------------------------------------
if ($Rollback) {
    Initialize-Toolkit -Root $Root
    Invoke-ToolkitRollback
    exit 0
}

# ---------------------------------------------------------------------------
#  Invocacion del orquestador compartido
# ---------------------------------------------------------------------------
function Invoke-Run {
    param([string[]]$Mods, [switch]$AsReport)

    $splat = @{
        Modules    = $Mods
        ConfigPath = $ConfigPath
        Root       = $Root
        ReportOnly = $AsReport
        Silent     = $Silent
        NoLockDown = $NoLockDown
    }
    if ($Apps)      { $splat.Apps = $Apps }
    if ($SharePath) { $splat.SharePath = $SharePath }

    return & $runner @splat
}

# ---------------------------------------------------------------------------
#  Menu interactivo
# ---------------------------------------------------------------------------
function Show-Menu {
    $config = Get-ToolkitConfig -Path $ConfigPath

    while ($true) {
        Clear-Host
        $mi = Get-MachineInfo
        Write-Host ''
        Write-Host '  ############################################################' -ForegroundColor Cyan
        Write-Host ('  #  TOOLKIT CALL CENTER  v{0,-33}#' -f (Get-ToolkitVersion))  -ForegroundColor Cyan
        Write-Host '  #  (modo scripts - en produccion se usa Toolkit.exe)       #' -ForegroundColor DarkCyan
        Write-Host '  ############################################################' -ForegroundColor Cyan
        Write-Host ('   Equipo : {0}   ({1} {2})' -f $mi.ComputerName, $mi.OSCaption, $mi.DisplayVersion) -ForegroundColor DarkGray
        Write-Host ('   Usuario: {0}' -f $mi.LoggedOnUser) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   --- DIAGNOSTICO (no modifica nada) ---' -ForegroundColor Gray
        Write-Host '    1) Estado de la ubicacion'
        Write-Host '    2) Inventario de aplicaciones'
        Write-Host '    3) Diagnostico de red completo'
        Write-Host '    4) Auditoria completa del equipo'
        Write-Host ''
        Write-Host '   --- APLICAR CAMBIOS ---' -ForegroundColor Gray
        Write-Host '    5) Activar ubicacion (servicio + politicas + todos los perfiles)'
        Write-Host '    6) Instalar aplicaciones del catalogo'
        Write-Host '    7) EJECUTAR TODO'
        Write-Host ''
        Write-Host '   --- MANTENIMIENTO ---' -ForegroundColor Gray
        Write-Host '    8) Revertir cambios de registro (rollback)'
        Write-Host '    9) Abrir carpeta de logs'
        Write-Host '    0) Salir'
        Write-Host ''

        switch (Read-Host '   Opcion') {
            '1' { Show-LocationState -State (Test-LocationState); Wait-Key }
            '2' { Show-AppInventory  -Catalog $config;            Wait-Key }
            '3' { Invoke-Run -Mods @('network')                    | Out-Null; Wait-Key }
            '4' { Invoke-Run -Mods @('location','apps','network') -AsReport | Out-Null; Wait-Key }
            '5' { Invoke-Run -Mods @('location')                   | Out-Null; Wait-Key }
            '6' { Invoke-Run -Mods @('apps')                       | Out-Null; Wait-Key }
            '7' { Invoke-Run -Mods @('location','apps','network')  | Out-Null; Wait-Key }
            '8' {
                Write-Host ''
                Write-Host '   Esto revertira TODOS los cambios de registro aplicados por el toolkit.' -ForegroundColor Yellow
                if ((Read-Host '   Escribe SI para confirmar') -eq 'SI') {
                    Initialize-Toolkit -Root $Root
                    Invoke-ToolkitRollback
                } else { Write-Host '   Cancelado.' -ForegroundColor DarkGray }
                Wait-Key
            }
            '9' { Start-Process (Join-Path $Root 'logs') }
            '0' { return }
        }
    }
}

function Wait-Key {
    Write-Host ''
    Write-Host '   Pulsa Intro para volver al menu...' -ForegroundColor DarkGray
    [void](Read-Host)
}

# ---------------------------------------------------------------------------
#  Principal
# ---------------------------------------------------------------------------
$selected = @()
if     ($All)     { $selected = @('location', 'apps', 'network') }
elseif ($Modules) { $selected = $Modules }
elseif ($Report)  { $selected = @('location', 'apps', 'network') }

if ($selected.Count -eq 0 -and -not $Silent) {
    Show-Menu
    exit 0
}

if ($selected.Count -eq 0) {
    Write-Host 'Modo desatendido sin modulos: usa -All o -Modules.' -ForegroundColor Yellow
    exit 1
}

$result = Invoke-Run -Mods $selected -AsReport:$Report
exit $(if ($result -and $result.ExitCode -ne $null) { $result.ExitCode } else { 1 })
