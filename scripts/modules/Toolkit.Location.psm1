<#
    Toolkit.Location.psm1
    Activacion completa de la ubicacion en Windows 10/11.

    LAS CUATRO CAPAS (si falta una, la app consumidora falla sin decir por que):
      1. Servicio lfsvc en Automatico y arrancado
      2. Interruptor maestro: lfsvc\Service\Configuration\Status = 1
      3. ConsentStore: HKLM + HKLM\NonPackaged (apps de escritorio) + cada HKU
      4. Politicas: LocationAndSensors + AppPrivacy (impiden que el usuario lo revierta)

    SIN REINICIAR EL EQUIPO: lfsvc lee Status y el consentimiento al arrancar y NO
    los relee. Por eso, tras escribir el registro, se reinicia el servicio
    (Restart-LocationService). Es lo que evita tener que reiniciar la PC.
#>

# Dependencia de Toolkit.Core (Write-Log, Set-RegValue, Add-Result, Test-ReportOnly...).
# Permite importar este modulo de forma aislada sin que falle la resolucion de comandos.
if (-not (Get-Command 'Write-Log' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking -Global
}


# --- Rutas de registro (constantes) ---
$script:RegLfsvcConfig   = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'
$script:RegConsentHKLM   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$script:RegConsentNonPkg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location\NonPackaged'
$script:RegPolLocation   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
$script:RegPolAppPrivacy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$script:RegProfileList   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$script:UserConsentSub   = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
# Clave heredada (Windows 10 < 1809). Inofensiva en builds modernos; cubre equipos sin actualizar.
$script:RegSensorLegacy  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'

#region ---------- Diagnostico ----------

function Test-LocationState {
    <# Evalua las cuatro capas SIN modificar nada. Devuelve un objeto con el detalle. #>
    [CmdletBinding()]
    param()

    $state = [ordered]@{
        ServiceExists      = $false
        ServiceStartType   = $null
        ServiceStatus      = $null
        MasterSwitch       = $null   # lfsvc Status
        ConsentMachine     = $null
        ConsentNonPackaged = $null
        PolDisableLocation = $null
        PolDisableScripting= $null
        PolDisableProvider = $null
        PolLetAppsAccess   = $null
        UserProfiles       = @()
        Compliant          = $false
        Issues             = @()
    }

    # Capa 1 - servicio
    $svc = Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
    if ($svc) {
        $state.ServiceExists = $true
        $state.ServiceStatus = "$($svc.Status)"
        try {
            $wmi = Get-CimInstance Win32_Service -Filter "Name='lfsvc'" -ErrorAction Stop
            $state.ServiceStartType = $wmi.StartMode   # Auto | Manual | Disabled
        } catch { }
        if ($state.ServiceStatus -ne 'Running')  { $state.Issues += 'El servicio lfsvc no esta en ejecucion' }
        if ($state.ServiceStartType -eq 'Disabled') { $state.Issues += 'El servicio lfsvc esta DESHABILITADO' }
    } else {
        $state.Issues += 'El servicio lfsvc no existe en este equipo'
    }

    # Capa 2 - interruptor maestro
    $state.MasterSwitch = Get-RegValue -Path $script:RegLfsvcConfig -Name 'Status'
    if ($state.MasterSwitch -ne 1) { $state.Issues += 'Interruptor maestro de ubicacion desactivado (Status != 1)' }

    # Capa 3 - consentimiento
    $state.ConsentMachine     = Get-RegValue -Path $script:RegConsentHKLM   -Name 'Value'
    $state.ConsentNonPackaged = Get-RegValue -Path $script:RegConsentNonPkg -Name 'Value'
    if ($state.ConsentMachine -ne 'Allow')     { $state.Issues += 'ConsentStore de maquina no es Allow' }
    if ($state.ConsentNonPackaged -ne 'Allow') { $state.Issues += 'ConsentStore NonPackaged no es Allow (apps de escritorio NO veran la ubicacion)' }

    # Capa 4 - politicas
    $state.PolDisableLocation  = Get-RegValue -Path $script:RegPolLocation   -Name 'DisableLocation'
    $state.PolDisableScripting = Get-RegValue -Path $script:RegPolLocation   -Name 'DisableLocationScripting'
    $state.PolDisableProvider  = Get-RegValue -Path $script:RegPolLocation   -Name 'DisableWindowsLocationProvider'
    $state.PolLetAppsAccess    = Get-RegValue -Path $script:RegPolAppPrivacy -Name 'LetAppsAccessLocation'
    if ($state.PolDisableLocation -eq 1)  { $state.Issues += 'La politica DisableLocation esta BLOQUEANDO la ubicacion' }
    if ($state.PolDisableProvider -eq 1)  { $state.Issues += 'La politica DisableWindowsLocationProvider esta bloqueando el proveedor' }
    if ($state.PolLetAppsAccess -eq 2)    { $state.Issues += 'La politica LetAppsAccessLocation = 2 (Forzar denegar)' }

    # Consentimiento por usuario
    $state.UserProfiles = @(Get-UserLocationConsent)
    foreach ($u in $state.UserProfiles) {
        if ($u.Consent -ne 'Allow') {
            $state.Issues += ("Usuario {0} sin consentimiento de ubicacion ({1})" -f $u.Account, $u.Consent)
        } elseif ($u.ConsentDesktop -ne 'Allow') {
            $state.Issues += ("Usuario {0} sin consentimiento para apps de escritorio ({1})" -f $u.Account, $u.ConsentDesktop)
        }
    }

    $state.Compliant = ($state.Issues.Count -eq 0)
    return [pscustomobject]$state
}

function Get-UserLocationConsent {
    <#
        Lee el consentimiento de cada perfil de usuario real del equipo. Solo lectura.
        Las colmenas descargadas (usuarios sin sesion) se cargan temporalmente para
        poder leerlas: si no, la auditoria no puede decir si estan bien o mal.
    #>
    [CmdletBinding()]
    param()

    $out = @()
    Ensure-HKUDrive

    $profiles = @()
    try {
        $profiles = @(Get-ChildItem -LiteralPath $script:RegProfileList -ErrorAction Stop |
                      Where-Object { $_.PSChildName -match '^S-1-5-21-\d+' })
    } catch { return $out }

    foreach ($p in $profiles) {
        $sid  = $p.PSChildName
        $path = $null
        try { $path = (Get-ItemProperty -LiteralPath $p.PSPath -ErrorAction Stop).ProfileImagePath } catch { }

        $account = $sid
        try {
            $account = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value
        } catch { if ($path) { $account = Split-Path $path -Leaf } }

        $loaded      = Test-Path -LiteralPath "HKU:\$sid"
        $consent     = '<colmena descargada>'
        $consentDesk = '<colmena descargada>'
        $tempLoaded  = $false

        if (-not $loaded -and $path) {
            $dat = Join-Path $path 'NTUSER.DAT'
            if (Test-Path -LiteralPath $dat) {
                $null = & reg.exe load "HKU\$sid" "$dat" 2>&1
                if ($LASTEXITCODE -eq 0) { $tempLoaded = $true }
            }
        }

        if ($loaded -or $tempLoaded) {
            $v = Get-RegValue -Path "HKU:\$sid\$($script:UserConsentSub)" -Name 'Value'
            $consent = if ($null -eq $v) { '<ausente>' } else { $v }
            $d = Get-RegValue -Path "HKU:\$sid\$($script:UserConsentSub)\NonPackaged" -Name 'Value'
            $consentDesk = if ($null -eq $d) { '<ausente>' } else { $d }
        }

        if ($tempLoaded) { Dismount-UserHive -Key "HKU\$sid" }

        $out += [pscustomobject]@{
            Sid            = $sid
            Account        = $account
            ProfilePath    = $path
            HiveLoaded     = $loaded
            Consent        = $consent
            ConsentDesktop = $consentDesk
        }
    }
    return $out
}

#endregion

#region ---------- Aplicacion ----------

function Enable-LocationService {
    <#
        Aplica las cuatro capas. Idempotente.
        -LockDown  : aplica LetAppsAccessLocation=1 (bloquea el conmutador en la interfaz;
                     impide que un usuario administrador local lo revierta).
    #>
    [CmdletBinding()]
    param(
        [switch]$LockDown,
        [switch]$SkipUserProfiles
    )

    $changed = 0

    # ---- Capa 1: servicio ----
    Write-Log 'Capa 1/4 - servicio de geolocalizacion (lfsvc)' -Level INFO
    $svc = Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log '  x El servicio lfsvc no existe. Edicion de Windows no soportada?' -Level ERROR
        Add-Result -Module 'Location' -Task 'Servicio lfsvc' -Status 'FALLO' -Message 'Servicio inexistente'
    } else {
        # Dependencia: sin DeviceAssociationService, lfsvc arranca pero no resuelve posicion.
        $dep = Get-Service -Name 'DeviceAssociationService' -ErrorAction SilentlyContinue
        if ($dep -and $dep.Status -ne 'Running' -and -not (Test-ReportOnly)) {
            try { Start-Service -Name 'DeviceAssociationService' -ErrorAction Stop; Write-Log '  + DeviceAssociationService arrancado' -Level OK }
            catch { Write-Log "  ! No se pudo arrancar DeviceAssociationService: $($_.Exception.Message)" -Level WARN }
        }

        $startMode = $null
        try { $startMode = (Get-CimInstance Win32_Service -Filter "Name='lfsvc'" -ErrorAction Stop).StartMode } catch { }

        if ($startMode -ne 'Auto') {
            if (Test-ReportOnly) {
                Write-Log "  ! lfsvc esta en '$startMode', deberia estar en 'Auto' -- MODO REPORTE" -Level WARN
                $changed++
            } else {
                try {
                    Set-Service -Name 'lfsvc' -StartupType Automatic -ErrorAction Stop
                    Write-Log "  + lfsvc: tipo de inicio $startMode -> Automatic" -Level OK
                    $changed++
                } catch {
                    Write-Log "  x No se pudo cambiar el tipo de inicio de lfsvc: $($_.Exception.Message)" -Level ERROR
                    Add-Result -Module 'Location' -Task 'Servicio lfsvc (inicio)' -Status 'FALLO' -Message $_.Exception.Message
                }
            }
        } else {
            Write-Log '  = lfsvc ya esta en Automatic' -Level DEBUG
        }

        $svc.Refresh()
        if ($svc.Status -ne 'Running') {
            if (Test-ReportOnly) {
                Write-Log "  ! lfsvc esta $($svc.Status), deberia estar Running -- MODO REPORTE" -Level WARN
                $changed++
            } else {
                try {
                    Start-Service -Name 'lfsvc' -ErrorAction Stop
                    Write-Log '  + lfsvc arrancado' -Level OK
                    $changed++
                } catch {
                    Write-Log "  x No se pudo arrancar lfsvc: $($_.Exception.Message)" -Level ERROR
                    Add-Result -Module 'Location' -Task 'Servicio lfsvc (arranque)' -Status 'FALLO' -Message $_.Exception.Message
                }
            }
        } else {
            Write-Log '  = lfsvc ya esta en ejecucion' -Level DEBUG
        }
    }

    # ---- Capa 2: interruptor maestro ----
    Write-Log 'Capa 2/4 - interruptor maestro del sistema' -Level INFO
    if (Set-RegValue -Path $script:RegLfsvcConfig -Name 'Status' -Value 1 -Type DWord) { $changed++ }
    # Clave heredada: en Windows 10 anteriores a 1809 es la que manda.
    if (Set-RegValue -Path $script:RegSensorLegacy -Name 'SensorPermissionState' -Value 1 -Type DWord) { $changed++ }

    # ---- Capa 3: ConsentStore de maquina ----
    Write-Log 'Capa 3/4 - almacen de consentimiento (maquina)' -Level INFO
    if (Set-RegValue -Path $script:RegConsentHKLM   -Name 'Value' -Value 'Allow' -Type String) { $changed++ }
    # NonPackaged = aplicaciones de escritorio clasicas (softphone, CRM, NetExtender...).
    # Es la clave que todo el mundo olvida.
    if (Set-RegValue -Path $script:RegConsentNonPkg -Name 'Value' -Value 'Allow' -Type String) { $changed++ }

    # ---- Capa 4: politicas ----
    Write-Log 'Capa 4/4 - politicas' -Level INFO
    if (Set-RegValue -Path $script:RegPolLocation -Name 'DisableLocation'                -Value 0 -Type DWord) { $changed++ }
    if (Set-RegValue -Path $script:RegPolLocation -Name 'DisableLocationScripting'       -Value 0 -Type DWord) { $changed++ }
    if (Set-RegValue -Path $script:RegPolLocation -Name 'DisableWindowsLocationProvider' -Value 0 -Type DWord) { $changed++ }

    if ($LockDown) {
        # 1 = Forzar permitir. Bloquea el conmutador en Configuracion ("Administrado por tu organizacion").
        if (Set-RegValue -Path $script:RegPolAppPrivacy -Name 'LetAppsAccessLocation' -Value 1 -Type DWord) { $changed++ }
        Write-Log '  i LockDown activo: el usuario NO podra desactivar la ubicacion desde Configuracion.' -Level INFO
    } else {
        Write-Log '  i Sin -LockDown: el usuario puede revertirlo desde Configuracion.' -Level WARN
    }

    # ---- Consentimiento por usuario ----
    if (-not $SkipUserProfiles) {
        Write-Log 'Extra - consentimiento por perfil de usuario' -Level INFO
        $changed += Set-AllUserLocationConsent
    }

    # ---- Aplicar en caliente ----
    # lfsvc solo lee Status y el consentimiento al arrancar. Si se cambio algo,
    # se reinicia el servicio para que surta efecto YA, sin reiniciar el equipo.
    if ($changed -gt 0 -and -not (Test-ReportOnly)) {
        Write-Log 'Aplicando en caliente - reinicio del servicio lfsvc (sin reiniciar el equipo)' -Level INFO
        Restart-LocationService | Out-Null
    }

    if ($changed -gt 0) {
        Add-Result -Module 'Location' -Task 'Activar ubicacion' -Status $(if (Test-ReportOnly) { 'AVISO' } else { 'CAMBIADO' }) `
                   -Message ("{0} ajuste(s) {1}" -f $changed, $(if (Test-ReportOnly) { 'pendientes' } else { 'aplicados' }))
    } else {
        Add-Result -Module 'Location' -Task 'Activar ubicacion' -Status 'YA-OK' -Message 'Todas las capas ya estaban correctas'
    }

    return $changed
}

function Restart-LocationService {
    <#
        Reinicia lfsvc para que relea la configuracion. Es lo que hace innecesario
        reiniciar el equipo. Devuelve $true si el servicio queda en ejecucion.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 20)

    if (Test-ReportOnly) { return $false }

    $svc = Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }

    try {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name 'lfsvc' -Force -ErrorAction Stop
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        Start-Service -Name 'lfsvc' -ErrorAction Stop
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($TimeoutSeconds))
        Write-Log '  + lfsvc reiniciado: la ubicacion queda activa sin reiniciar el equipo' -Level OK
        return $true
    } catch {
        Write-Log "  ! No se pudo reiniciar lfsvc en caliente: $($_.Exception.Message)" -Level WARN
        Write-Log '    La configuracion esta escrita; se aplicara en el proximo arranque.' -Level WARN
        try { Start-Service -Name 'lfsvc' -ErrorAction SilentlyContinue } catch { }
        $svc.Refresh()
        return ($svc.Status -eq 'Running')
    }
}

function Set-AllUserLocationConsent {
    <#
        Escribe el consentimiento en HKCU de TODOS los perfiles del equipo.
        Necesario porque al correr como SYSTEM, HKCU apunta al perfil de SYSTEM.

        Cubre: perfiles con sesion activa, perfiles con colmena descargada (reg load),
        y el perfil Default (para usuarios futuros y equipos reimaginados).
    #>
    [CmdletBinding()]
    param()

    $changed = 0
    Ensure-HKUDrive

    $profiles = @()
    try {
        $profiles = @(Get-ChildItem -LiteralPath $script:RegProfileList -ErrorAction Stop |
                      Where-Object { $_.PSChildName -match '^S-1-5-21-\d+' })
    } catch {
        Write-Log "  ! No se pudo enumerar ProfileList: $($_.Exception.Message)" -Level WARN
        return 0
    }

    foreach ($p in $profiles) {
        $sid         = $p.PSChildName
        $profilePath = $null
        try { $profilePath = (Get-ItemProperty -LiteralPath $p.PSPath -ErrorAction Stop).ProfileImagePath } catch { }
        if (-not $profilePath) { continue }

        $wasLoaded    = Test-Path -LiteralPath "HKU:\$sid"
        $needsUnload  = $false

        if (-not $wasLoaded) {
            $dat = Join-Path $profilePath 'NTUSER.DAT'
            if (-not (Test-Path -LiteralPath $dat)) {
                Write-Log "  ! Sin NTUSER.DAT para $sid, se omite" -Level DEBUG
                continue
            }
            if (Test-ReportOnly) { continue }
            $null = & reg.exe load "HKU\$sid" "$dat" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "  ! No se pudo cargar la colmena de $sid (perfil en uso o bloqueado)" -Level WARN
                continue
            }
            $needsUnload = $true
        }

        try {
            $changed += Set-UserHiveConsent -HiveRoot "HKU:\$sid"
        } catch {
            Write-Log "  x Fallo escribiendo consentimiento de $sid : $($_.Exception.Message)" -Level ERROR
        } finally {
            if ($needsUnload) { Dismount-UserHive -Key "HKU\$sid" }
        }
    }

    # --- Perfil Default: cubre usuarios nuevos y equipos reimaginados ---
    $changed += Set-DefaultProfileConsent
    return $changed
}

function Set-DefaultProfileConsent {
    [CmdletBinding()]
    param()

    if (Test-ReportOnly) { return 0 }

    $defaultDat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $defaultDat)) {
        Write-Log '  ! No se encuentra el perfil Default, se omite' -Level WARN
        return 0
    }

    $tempKey = 'ToolkitDefault'
    $changed = 0
    $null = & reg.exe load "HKU\$tempKey" "$defaultDat" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log '  ! No se pudo cargar el perfil Default' -Level WARN
        return 0
    }

    try {
        Ensure-HKUDrive
        $changed = Set-UserHiveConsent -HiveRoot "HKU:\$tempKey"
        if ($changed -gt 0) { Write-Log '  + Perfil Default configurado (aplica a usuarios futuros)' -Level OK }
    } catch {
        Write-Log "  x Fallo en el perfil Default: $($_.Exception.Message)" -Level ERROR
    } finally {
        Dismount-UserHive -Key "HKU\$tempKey"
    }
    return $changed
}

#endregion

#region ---------- Verificacion real ----------

function Test-LocationApi {
    <#
        Verificacion REAL: pregunta a la API de geolocalizacion de Windows.
        No basta con que el registro este bien; esto confirma que el proveedor responde.
        Best-effort: si WinRT no esta disponible, se degrada sin romper.
    #>
    [CmdletBinding()]
    param([switch]$GetPosition, [int]$TimeoutSeconds = 20)

    $result = [ordered]@{
        ApiAvailable   = $false
        LocationStatus = $null
        Position       = $null
        Accuracy       = $null
        Error          = $null
    }

    try {
        [void][Windows.Devices.Geolocation.Geolocator, Windows.Devices.Geolocation, ContentType = WindowsRuntime]
        $geo = New-Object Windows.Devices.Geolocation.Geolocator
        $result.ApiAvailable   = $true
        $result.LocationStatus = "$($geo.LocationStatus)"

        # Estados posibles: Ready | Initializing | NoData | Disabled | NotInitialized | NotAvailable
        if ($result.LocationStatus -in @('Disabled', 'NotAvailable')) {
            Write-Log "  x API de ubicacion en estado '$($result.LocationStatus)' -- la configuracion NO esta surtiendo efecto" -Level ERROR
        } else {
            Write-Log "  + API de ubicacion responde: $($result.LocationStatus)" -Level OK
        }

        if ($GetPosition) {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
            $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            })[0]
            $generic = $asTask.MakeGenericMethod([Windows.Devices.Geolocation.Geoposition])
            $task    = $generic.Invoke($null, @($geo.GetGeopositionAsync()))
            if ($task.Wait($TimeoutSeconds * 1000)) {
                $pos = $task.Result.Coordinate
                $result.Position = ('{0},{1}' -f $pos.Point.Position.Latitude, $pos.Point.Position.Longitude)
                $result.Accuracy = $pos.Accuracy
                Write-Log ("  + Posicion obtenida: {0} (precision ~{1} m)" -f $result.Position, [math]::Round($result.Accuracy)) -Level OK
                if ($result.Accuracy -gt 500) {
                    Write-Log '  ! Precision baja (>500 m). Sin GPS, Windows usa WiFi/IP. Validar si sirve para el caso de uso (E911).' -Level WARN
                }
            } else {
                $result.Error = "Tiempo de espera agotado ($TimeoutSeconds s)"
                Write-Log "  ! No se obtuvo posicion en $TimeoutSeconds s" -Level WARN
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
        Write-Log "  ! No se pudo consultar la API de ubicacion: $($_.Exception.Message)" -Level WARN
    }

    return [pscustomobject]$result
}

function Show-LocationState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    Write-Host ''
    Write-Host '  ESTADO DE LA UBICACION' -ForegroundColor Cyan
    Write-Host '  ----------------------' -ForegroundColor Cyan
    $fmt = '    {0,-34} {1}'
    Write-Host ($fmt -f 'Servicio lfsvc',            "$($State.ServiceStartType) / $($State.ServiceStatus)")
    Write-Host ($fmt -f 'Interruptor maestro',       $State.MasterSwitch)
    Write-Host ($fmt -f 'Consent maquina',           $State.ConsentMachine)
    Write-Host ($fmt -f 'Consent NonPackaged',       $State.ConsentNonPackaged)
    Write-Host ($fmt -f 'Pol. DisableLocation',      $State.PolDisableLocation)
    Write-Host ($fmt -f 'Pol. LetAppsAccessLocation',$State.PolLetAppsAccess)
    Write-Host ''
    Write-Host '    Perfiles de usuario:' -ForegroundColor Gray
    foreach ($u in $State.UserProfiles) {
        $ok = ($u.Consent -eq 'Allow' -and $u.ConsentDesktop -eq 'Allow')
        $c  = if ($ok) { 'Green' } else { 'Yellow' }
        Write-Host ('      {0,-30} {1,-8} escritorio: {2}' -f $u.Account, $u.Consent, $u.ConsentDesktop) -ForegroundColor $c
    }
    Write-Host ''
    if ($State.Compliant) {
        Write-Host '    [OK] Todas las capas correctas' -ForegroundColor Green
    } else {
        Write-Host '    [!] Problemas detectados:' -ForegroundColor Yellow
        foreach ($i in $State.Issues) { Write-Host "      - $i" -ForegroundColor Yellow }
    }
    Write-Host ''
}

#endregion

#region ---------- Interno ----------

function Ensure-HKUDrive {
    if (-not (Get-PSDrive -Name 'HKU' -ErrorAction SilentlyContinue)) {
        $null = New-PSDrive -Name 'HKU' -PSProvider Registry -Root 'HKEY_USERS' -Scope Global -ErrorAction SilentlyContinue
    }
}

function Set-UserHiveConsent {
    <#
        Escribe el consentimiento de ubicacion en una colmena de usuario ya montada.
        Dos valores: el general (apps de la tienda) y NonPackaged (apps de escritorio:
        softphone, CRM...). Sin el segundo, el usuario ve la ubicacion "activada"
        pero las apps clasicas no la reciben. Devuelve cuantos valores cambiaron.
    #>
    param([Parameter(Mandatory)][string]$HiveRoot)
    $n = 0
    if (Set-RegValue -Path "$HiveRoot\$($script:UserConsentSub)"             -Name 'Value' -Value 'Allow' -Type String) { $n++ }
    if (Set-RegValue -Path "$HiveRoot\$($script:UserConsentSub)\NonPackaged" -Name 'Value' -Value 'Allow' -Type String) { $n++ }
    return $n
}

function Dismount-UserHive {
    <# CRITICO: liberar handles antes de descargar, o reg unload falla y deja la colmena colgada. #>
    param([Parameter(Mandatory)][string]$Key)
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 300
    $null = & reg.exe unload "$Key" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ! No se pudo descargar la colmena $Key -- revisar manualmente" -Level WARN
    }
}

#endregion

Export-ModuleMember -Function @(
    'Test-LocationState', 'Get-UserLocationConsent',
    'Enable-LocationService', 'Set-AllUserLocationConsent', 'Set-DefaultProfileConsent',
    'Restart-LocationService', 'Test-LocationApi', 'Show-LocationState'
)
