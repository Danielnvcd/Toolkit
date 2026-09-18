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
    [ValidateSet('location', 'apps', 'network', 'users')][string[]]$Modules,
    [string[]]$Apps,
    [switch]$Report,
    [switch]$CheckIn,
    [switch]$NoLockDown,
    [switch]$NoBrowsers,
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
foreach ($m in @('Toolkit.Core', 'Toolkit.Location', 'Toolkit.Apps', 'Toolkit.Network', 'Toolkit.Users', 'Toolkit.Support', 'Toolkit.Firewall')) {
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
    param([string[]]$Mods, [switch]$AsReport, [switch]$AsCheckIn, [switch]$AsReinstall, [switch]$AsUninstall, [string[]]$OnlyApps)

    $splat = @{
        Modules    = $Mods
        ConfigPath = $ConfigPath
        Root       = $Root
        ReportOnly = $AsReport
        Silent     = $Silent
        NoLockDown = $NoLockDown
        NoBrowsers = $NoBrowsers
        CheckIn    = $AsCheckIn
    }
    if ($AsReinstall) { $splat.ForceReinstall = $true }
    if ($AsUninstall) { $splat.UninstallApps = $true; $splat.AllowInteractive = $true }
    if ($OnlyApps)  { $splat.Apps = $OnlyApps }
    elseif ($Apps)  { $splat.Apps = $Apps }
    if ($SharePath) { $splat.SharePath = $SharePath }

    return & $runner @splat
}

# ---------------------------------------------------------------------------
#  Menu interactivo
# ---------------------------------------------------------------------------
function Read-AppIds {
    <# Pide al tecnico los ids del catalogo sobre los que actuar. #>
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Accion)

    Write-Host ''
    Write-Host ("   Aplicaciones del catalogo:") -ForegroundColor Gray
    foreach ($a in $Catalog.apps) { Write-Host ('     {0,-16} {1}' -f $a.id, $a.name) -ForegroundColor DarkGray }
    Write-Host ''
    $raw = Read-Host ("   Ids a $Accion (separados por coma, vacio = cancelar)")
    $ids = @($raw -split '[,; ]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ids.Count -eq 0) { Write-Host '   Cancelado.' -ForegroundColor DarkGray; return @() }
    return $ids
}

function Show-Menu {
    $config = Get-ToolkitConfig -Path $ConfigPath

    while ($true) {
        Clear-Host
        $mi = Get-MachineInfo
        Write-Host ''
        Write-Host '  ############################################################' -ForegroundColor Cyan
        Write-Host ('  #  TOOLKIT BPO  v{0,-41}#' -f (Get-ToolkitVersion))  -ForegroundColor Cyan
        Write-Host '  #  (modo scripts - en produccion se usa Toolkit.exe)       #' -ForegroundColor DarkCyan
        Write-Host '  ############################################################' -ForegroundColor Cyan
        Write-Host ('   Equipo : {0}   ({1} {2})' -f $mi.ComputerName, $mi.OSCaption, $mi.DisplayVersion) -ForegroundColor DarkGray
        Write-Host ('   Usuario: {0}' -f $mi.LoggedOnUser) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   --- DIAGNOSTICO (no modifica nada) ---' -ForegroundColor Gray
        Write-Host '    1) Estado de la ubicacion'
        Write-Host '    Z) Comprobar check-in de Zoho (ubicacion en el navegador)'
        Write-Host '    2) Inventario de aplicaciones'
        Write-Host '    3) Diagnostico de red completo'
        Write-Host '    4) Auditoria completa del equipo'
        Write-Host ''
        Write-Host '   --- APLICAR CAMBIOS ---' -ForegroundColor Gray
        Write-Host '    5) Activar ubicacion (servicio + politicas + todos los perfiles)'
        Write-Host '    6) Instalar aplicaciones del catalogo'
        Write-Host '    R) Reinstalar aplicaciones (encima, para subir de version)'
        Write-Host '    D) Desinstalar aplicaciones'
        Write-Host '    7) EJECUTAR TODO'
        Write-Host ''
        Write-Host '   --- USUARIOS LOCALES ---' -ForegroundColor Gray
        Write-Host '    U) Gestionar usuarios (listar, contrasena, eliminar, crear...)'
        Write-Host '    S) Soporte: info del equipo, audio, red, impresoras, hora, temporales...'
        Write-Host '    F) Firewall y bloqueos: es el firewall?, programas sin red, filtro web'
        Write-Host ''
        Write-Host '   --- MANTENIMIENTO ---' -ForegroundColor Gray
        Write-Host '    8) Revertir cambios de registro (rollback)'
        Write-Host '    9) Abrir carpeta de logs'
        Write-Host '    0) Salir'
        Write-Host ''

        switch ((Read-Host '   Opcion').Trim().ToUpper()) {
            '1' { Show-LocationState -State (Test-LocationState); Wait-Key }
            'Z' { Invoke-Run -Mods @('location') -AsReport -AsCheckIn    | Out-Null; Wait-Key }
            '2' { Show-AppInventory  -Catalog $config;            Wait-Key }
            '3' { Invoke-Run -Mods @('network')                    | Out-Null; Wait-Key }
            '4' { Invoke-Run -Mods @('location','apps','network','users') -AsReport | Out-Null; Wait-Key }
            '5' { Invoke-Run -Mods @('location')                   | Out-Null; Wait-Key }
            '6' { Invoke-Run -Mods @('apps')                       | Out-Null; Wait-Key }
            'R' {
                $ids = Read-AppIds -Catalog $config -Accion 'reinstalar'
                if ($ids) { Invoke-Run -Mods @('apps') -AsReinstall -OnlyApps $ids | Out-Null }
                Wait-Key
            }
            'D' {
                $ids = Read-AppIds -Catalog $config -Accion 'desinstalar'
                if ($ids) { Invoke-Run -Mods @('apps') -AsUninstall -OnlyApps $ids | Out-Null }
                Wait-Key
            }
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
            'U' { Show-UsersMenu }
            'S' { Show-SupportMenu }
            'F' { Show-FirewallMenu }
            '0' { return }
        }
    }
}

function Show-UsersMenu {
    # Las acciones sobre cuentas no pasan por el orquestador ni por rollback.json:
    # solo se registran en el log. Initialize-Toolkit abre ese log.
    Initialize-Toolkit -Root $Root

    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ############################################################' -ForegroundColor Cyan
        Write-Host '  #  USUARIOS LOCALES                                        #' -ForegroundColor Cyan
        Write-Host '  ############################################################' -ForegroundColor Cyan
        Show-LocalUserInventory -Users (Get-LocalUserInventory)
        Write-Host '    1) Cambiar contrasena'
        Write-Host '    2) Dejar SIN contrasena'
        Write-Host '    3) Habilitar cuenta'
        Write-Host '    4) Deshabilitar cuenta'
        Write-Host '    5) Eliminar cuenta'
        Write-Host '    6) Crear cuenta'
        Write-Host '    0) Volver'
        Write-Host ''

        $r = $null
        switch ((Read-Host '   Opcion').Trim()) {
            '1' {
                $n = Read-Host '   Usuario'
                $p1 = Read-Host '   Nueva contrasena' -AsSecureString
                $p2 = Read-Host '   Repetir contrasena' -AsSecureString
                $s1 = ConvertFrom-SecureStringPlain $p1
                $s2 = ConvertFrom-SecureStringPlain $p2
                if ($s1 -ne $s2) { Write-Host '   Las contrasenas no coinciden.' -ForegroundColor Red }
                else { $r = Set-LocalUserPassword -Name $n -Password $s1 }
            }
            '2' {
                $n = Read-Host '   Usuario'
                if ((Read-Host "   Dejar a '$n' sin contrasena. Escribe SI para confirmar") -eq 'SI') { $r = Clear-LocalUserPassword -Name $n }
            }
            '3' { $r = Enable-LocalUserAccount  -Name (Read-Host '   Usuario') }
            '4' { $r = Disable-LocalUserAccount -Name (Read-Host '   Usuario') }
            '5' {
                $n = Read-Host '   Usuario'
                $prof = ((Read-Host '   Eliminar tambien su carpeta de perfil? (s/N)').Trim().ToLower() -eq 's')
                if ((Read-Host "   ELIMINAR la cuenta '$n' (irreversible). Escribe SI para confirmar") -eq 'SI') {
                    $r = Remove-LocalUserAccount -Name $n -RemoveProfile:$prof
                }
            }
            '6' {
                $n  = Read-Host '   Nombre de usuario'
                $fn = Read-Host '   Nombre completo (opcional)'
                $noPwd = ((Read-Host '   Sin contrasena? (s/N)').Trim().ToLower() -eq 's')
                $adm   = ((Read-Host '   Administrador? (s/N)').Trim().ToLower() -eq 's')
                $pwd = ''
                $ok  = $true
                if (-not $noPwd) {
                    $s1 = ConvertFrom-SecureStringPlain (Read-Host '   Contrasena' -AsSecureString)
                    $s2 = ConvertFrom-SecureStringPlain (Read-Host '   Repetir contrasena' -AsSecureString)
                    if ($s1 -ne $s2) { Write-Host '   Las contrasenas no coinciden.' -ForegroundColor Red; $ok = $false }
                    $pwd = $s1
                }
                if ($ok) { $r = New-LocalUserAccount -Name $n -Password $pwd -FullName $fn -NoPassword:$noPwd -Administrator:$adm }
            }
            '0' { return }
        }

        if ($r) {
            Write-Host ''
            Write-Host ("   {0}" -f $r.Message) -ForegroundColor $(if ($r.Success) { 'Green' } else { 'Red' })
        }
        Wait-Key
    }
}

function ConvertFrom-SecureStringPlain {
    param([Security.SecureString]$Secure)
    if (-not $Secure) { return '' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Show-SupportMenu {
    Initialize-Toolkit -Root $Root
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '   --- SOPORTE: DIAGNOSTICO (no modifica nada) ---' -ForegroundColor Gray
        Write-Host '    1) Info del equipo'
        Write-Host '    2) Audio y microfono'
        Write-Host '    3) Impresoras'
        Write-Host '    4) Windows Update'
        Write-Host '    5) Hora del sistema'
        Write-Host ''
        Write-Host '   --- REPARACIONES RAPIDAS ---' -ForegroundColor Gray
        Write-Host '    A) Reparar red            B) Reset de red (requiere reinicio)'
        Write-Host '    C) Reiniciar audio        D) Limpiar cola de impresion'
        Write-Host '    E) Sincronizar hora       F) Limpiar temporales'
        Write-Host '    G) Permitir microfono y camara'
        Write-Host '    H) No suspender el equipo I) Buscar actualizaciones'
        Write-Host '    J) Reparar archivos del sistema (sfc, 5-20 min)'
        Write-Host ''
        Write-Host '    6) Estado del antivirus'
        Write-Host '    K) Desactivar antivirus 30 min (se reactiva solo)'
        Write-Host '    L) Reactivar antivirus ahora'
        Write-Host ''
        Write-Host '    R) Informe PDF para el ticket        T) Informe en texto plano'
        Write-Host '    0) Volver'
        Write-Host ''
        switch ((Read-Host '   Opcion').Trim().ToUpper()) {
            '1' { Get-SupportSummary | Out-Null; Wait-Key }
            '2' { Test-AudioSetup    | Out-Null; Wait-Key }
            '3' { Get-PrinterReport  | Out-Null; Wait-Key }
            '4' { Get-UpdateStatus   | Out-Null; Wait-Key }
            '5' { Get-TimeStatus     | Out-Null; Wait-Key }
            'A' { Repair-Network       | Out-Null; Wait-Key }
            'B' { Repair-Network -Deep | Out-Null; Wait-Key }
            'C' { Restart-AudioServices | Out-Null; Wait-Key }
            'D' { Clear-PrintQueue; Wait-Key }
            'E' { Sync-SystemTime  | Out-Null; Wait-Key }
            'F' { Clear-TempFiles  | Out-Null; Wait-Key }
            'G' { Enable-MediaConsent | Out-Null; Wait-Key }
            'H' { Set-NoSleepPower | Out-Null; Wait-Key }
            'I' { Start-UpdateScan | Out-Null; Wait-Key }
            'J' { Repair-SystemFiles | Out-Null; Wait-Key }
            '6' { Get-AntivirusStatus | Out-Null; Wait-Key }
            'K' {
                Write-Host ''
                Write-Host '   El equipo quedara SIN proteccion durante 30 minutos (se reactiva solo).' -ForegroundColor Yellow
                if ((Read-Host '   Escribe SI para confirmar') -eq 'SI') { Set-DefenderRealtime -Disable -ReenableAfterMinutes 30 | Out-Null }
                else { Write-Host '   Cancelado.' -ForegroundColor DarkGray }
                Wait-Key
            }
            'L' { Set-DefenderRealtime -Enable | Out-Null; Wait-Key }
            'R' { $p = Export-SupportReport -Root $Root -Tecnico $env:USERNAME; Start-Process explorer.exe "/select,`"$p`""; Wait-Key }
            'T' { $p = Export-SupportReport -Root $Root -Format Texto; Start-Process explorer.exe "/select,`"$p`""; Wait-Key }
            '0' { return }
        }
    }
}

function Show-FirewallMenu {
    Initialize-Toolkit -Root $Root
    $config = Get-ToolkitConfig -Path $ConfigPath
    $json = $config | ConvertTo-Json -Depth 10
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '   --- FIREWALL DE WINDOWS ---' -ForegroundColor Gray
        Write-Host '    1) Estado del firewall'
        Write-Host '    2) Comprobar conexion a host:puerto (es el firewall?)'
        Write-Host '    3) Pausar firewall 5 min (se reactiva solo)'
        Write-Host '    4) Reactivar firewall ahora'
        Write-Host ''
        Write-Host '   --- PROGRAMAS SIN RED ---' -ForegroundColor Gray
        Write-Host '    5) Listar reglas del toolkit'
        Write-Host '    6) Bloquear programa (ruta al .exe)'
        Write-Host '    7) Desbloquear programa (ruta al .exe)'
        Write-Host ''
        Write-Host '   --- FILTRO WEB ---' -ForegroundColor Gray
        Write-Host '    8) Estado del filtro y categorias'
        Write-Host '    9) Aplicar filtro (categorias por id, separadas por coma)'
        Write-Host '    Q) Quitar filtro web'
        Write-Host '    0) Volver'
        Write-Host ''
        switch ((Read-Host '   Opcion').Trim().ToUpper()) {
            '1' { Show-FirewallState -State (Get-FirewallState); Wait-Key }
            '2' { $t = Read-Host '   Destino (host, host:puerto o URL)'; if ($t) { Test-FirewallConnection -ComputerName $t | Out-Null }; Wait-Key }
            '3' { Suspend-Firewall -Minutes 5 | Out-Null; Wait-Key }
            '4' { Resume-Firewall | Out-Null; Wait-Key }
            '5' { Show-ToolkitBlockRules | Out-Null; Wait-Key }
            '6' { $p = Read-Host '   Ruta del .exe'; if ($p) { Block-ProgramNetwork -Path $p | Out-Null }; Wait-Key }
            '7' { $p = Read-Host '   Ruta del .exe'; if ($p) { Unblock-ProgramNetwork -Path $p | Out-Null }; Wait-Key }
            '8' {
                Show-WebFilterState -CatalogJson $json | Out-Null
                Write-Host ''
                foreach ($c in Get-WebFilterCategories -CatalogJson $json) { Write-Host ('   {0,-10} {1,-22} {2} dominios' -f $c.id, $c.name, $c.domains.Count) }
                Wait-Key
            }
            '9' {
                $ids = (Read-Host '   Ids de categorias (ej. social,video,messaging)') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                $dom = (Read-Host '   Dominios sueltos (opcional, separados por coma)') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                Set-WebFilter -CategoryIds $ids -Domains $dom -CatalogJson $json | Out-Null
                Wait-Key
            }
            'Q' { Clear-WebFilter | Out-Null; Wait-Key }
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
if     ($CheckIn) { $selected = @('location'); $Report = $true }
elseif ($All)     { $selected = @('location', 'apps', 'network', 'users') }
elseif ($Modules) { $selected = $Modules }
elseif ($Report)  { $selected = @('location', 'apps', 'network', 'users') }

if ($selected.Count -eq 0 -and -not $Silent) {
    Show-Menu
    exit 0
}

if ($selected.Count -eq 0) {
    Write-Host 'Modo desatendido sin modulos: usa -All o -Modules.' -ForegroundColor Yellow
    exit 1
}

$result = Invoke-Run -Mods $selected -AsReport:$Report -AsCheckIn:$CheckIn
exit $(if ($result -and $result.ExitCode -ne $null) { $result.ExitCode } else { 1 })
