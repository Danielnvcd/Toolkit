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
    param([switch]$GetPosition, [int]$TimeoutSeconds = 20, [int]$MaxAccuracyMeters = 500)

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
                if ($result.Accuracy -gt $MaxAccuracyMeters) {
                    Write-Log (("  ! Precision baja (>{0} m). Sin GPS, Windows ubica por Wi-Fi (decenas de m) o por IP (km). " +
                                "Con geovalla en Zoho, el check-in puede fallar.") -f $MaxAccuracyMeters) -Level WARN
                }
            } else {
                $result.Error = "Tiempo de espera agotado ($TimeoutSeconds s)"
                Write-Log "  ! No se obtuvo posicion en $TimeoutSeconds s" -Level WARN
            }
        }
    } catch {
        # Task.Wait envuelve el error real en AggregateException: se busca el de fondo.
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        # Los errores COM traen el texto duplicado y con saltos de linea.
        $result.Error = (($ex.Message -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1).Trim()
        if ($result.LocationStatus -and $result.LocationStatus -ne 'Ready') {
            $result.Error = "estado $($result.LocationStatus): $($ex.Message)"
        }
        Write-Log "  ! No se pudo obtener posicion: $($result.Error)" -Level WARN
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

#region ---------- Navegadores (check-in de Zoho) ----------
<#
    El check-in de Zoho se hace en el navegador y usa la API de geolocalizacion
    del navegador. Con Windows bien configurado todavia faltan dos cosas:

      a) Que el navegador tenga permiso para dar la ubicacion al sitio. Sin
         politica, cada agente ve "zoho.com quiere conocer tu ubicacion"; si
         pulsa Bloquear una vez, el check-in deja de funcionar en ese perfil
         y nadie sabe por que.
           - Chrome y Edge: DefaultGeolocationSetting = 1 (permitir sin preguntar).
             No existe lista por sitio para geolocalizacion en estos dos.
           - Firefox: Permissions\Location\Allow = lista de origenes.
      b) Que la posicion sea suficientemente precisa para la geovalla de Zoho.
         Sin GPS, Windows ubica por Wi-Fi (decenas de metros) o, si no hay
         adaptador Wi-Fi, por IP (kilometros). Test-CheckInReadiness lo mide.

    Chrome y Edge releen las politicas del registro en caliente; Firefox al arrancar.
#>

$script:RegPolChrome     = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$script:RegPolEdge       = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$script:RegPolFirefoxLoc = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\Permissions\Location'
# Servicio de posicionamiento de Microsoft (resolucion Wi-Fi/IP). Si esta
# bloqueado en el firewall, lfsvc arranca pero nunca devuelve posicion.
$script:PositioningHost  = 'inference.location.live.net'
$script:DefaultCheckInUrls = @('https://people.zoho.com', 'https://accounts.zoho.com')

function Get-InstalledBrowsers {
    <# Chrome / Edge / Firefox instalados en el equipo (App Paths de HKLM). Solo lectura. #>
    [CmdletBinding()]
    param()

    $known = @(
        @{ Id = 'chrome';  Name = 'Google Chrome';  Exe = 'chrome.exe'  },
        @{ Id = 'edge';    Name = 'Microsoft Edge'; Exe = 'msedge.exe'  },
        @{ Id = 'firefox'; Name = 'Mozilla Firefox'; Exe = 'firefox.exe' }
    )
    $out = @()
    foreach ($b in $known) {
        $path = $null
        foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')) {
            $p = Get-RegValue -Path (Join-Path $root $b.Exe) -Name '(default)'
            if ($p -and (Test-Path -LiteralPath $p)) { $path = $p; break }
        }
        $version = $null
        if ($path) {
            try { $version = (Get-Item -LiteralPath $path).VersionInfo.ProductVersion } catch { }
        }
        $out += [pscustomobject]@{
            Id        = $b.Id
            Name      = $b.Name
            Installed = [bool]$path
            Path      = $path
            Version   = $version
        }
    }
    return $out
}

function Test-BrowserGeolocation {
    <#
        Evalua la politica de geolocalizacion de cada navegador SIN modificar nada.
        Devuelve un objeto por navegador con Compliant e Issues.
    #>
    [CmdletBinding()]
    param([string[]]$Urls = $script:DefaultCheckInUrls)

    $out = @()
    foreach ($b in Get-InstalledBrowsers) {
        $issues = @()
        $policy = $null

        switch ($b.Id) {
            'chrome'  { $policy = Get-RegValue -Path $script:RegPolChrome -Name 'DefaultGeolocationSetting' }
            'edge'    { $policy = Get-RegValue -Path $script:RegPolEdge   -Name 'DefaultGeolocationSetting' }
            'firefox' {
                $allowed = @()
                $allowKey = Join-Path $script:RegPolFirefoxLoc 'Allow'
                if (Test-Path -LiteralPath $allowKey) {
                    $props = Get-ItemProperty -LiteralPath $allowKey -ErrorAction SilentlyContinue
                    if ($props) {
                        $allowed = @($props.PSObject.Properties |
                                     Where-Object { $_.Name -match '^\d+$' } |
                                     ForEach-Object { "$($_.Value)" })
                    }
                }
                $policy = $allowed -join ', '
                foreach ($u in $Urls) {
                    if ($allowed -notcontains $u) { $issues += "Firefox: $u no esta en Permissions\Location\Allow" }
                }
                $blocked = Get-RegValue -Path $script:RegPolFirefoxLoc -Name 'BlockNewRequests'
                if ($blocked -eq 1) { $issues += 'Firefox: BlockNewRequests=1 bloquea las peticiones de ubicacion' }
            }
        }

        if ($b.Id -in @('chrome', 'edge')) {
            # 1 = permitir, 2 = bloquear, 3 = preguntar (o ausente = preguntar).
            switch ("$policy") {
                '1'     { }
                '2'     { $issues += "$($b.Name): DefaultGeolocationSetting=2 BLOQUEA la ubicacion en todos los sitios" }
                default { $issues += "$($b.Name): sin politica; el agente vera el aviso de permiso y puede bloquearlo por error" }
            }
        }

        # Un navegador no instalado no bloquea nada, pero su politica se evalua
        # igualmente: si se instala manana, ya tiene que funcionar.
        if (-not $b.Installed) { $issues = @($issues | ForEach-Object { "$_ (no instalado)" }) }

        $out += [pscustomobject]@{
            Id        = $b.Id
            Name      = $b.Name
            Installed = $b.Installed
            Version   = $b.Version
            Policy    = $policy
            Compliant = ($issues.Count -eq 0)
            Issues    = $issues
        }
    }
    return $out
}

function Enable-BrowserGeolocation {
    <#
        Escribe las politicas para que el navegador entregue la ubicacion al sitio
        sin preguntar. Idempotente y con rollback (pasa por Set-RegValue).
        Se aplica a los tres navegadores aunque no esten instalados: las claves son
        inofensivas y asi el equipo queda listo si se instala otro navegador.
    #>
    [CmdletBinding()]
    param([string[]]$Urls = $script:DefaultCheckInUrls)

    $changed = 0
    Write-Log 'Navegadores - permiso de ubicacion para el check-in' -Level INFO

    # Chrome y Edge: no hay lista por sitio para geolocalizacion, solo el valor por defecto.
    if (Set-RegValue -Path $script:RegPolChrome -Name 'DefaultGeolocationSetting' -Value 1 -Type DWord) { $changed++ }
    if (Set-RegValue -Path $script:RegPolEdge   -Name 'DefaultGeolocationSetting' -Value 1 -Type DWord) { $changed++ }

    # Firefox: lista numerada de origenes permitidos (formato de politicas por registro).
    $allowKey = Join-Path $script:RegPolFirefoxLoc 'Allow'
    $i = 0
    foreach ($u in $Urls) {
        $i++
        if (Set-RegValue -Path $allowKey -Name "$i" -Value $u -Type String) { $changed++ }
    }
    if (Set-RegValue -Path $script:RegPolFirefoxLoc -Name 'BlockNewRequests' -Value 0 -Type DWord) { $changed++ }

    if ($changed -gt 0 -and -not (Test-ReportOnly)) {
        Write-Log '  i Chrome y Edge aplican la politica en caliente; Firefox al reiniciarse.' -Level INFO
    }

    Add-Result -Module 'Location' -Task 'Navegadores (check-in)' `
               -Status $(if ($changed -eq 0) { 'YA-OK' } elseif (Test-ReportOnly) { 'AVISO' } else { 'CAMBIADO' }) `
               -Message $(if ($changed -eq 0) { 'Politicas ya correctas' } else { "$changed ajuste(s)" })
    return $changed
}

function Test-CheckInEndpoint {
    <# DNS + TCP hacia un host:puerto. Sin dependencia del modulo de red. #>
    param([Parameter(Mandatory)][string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 4000)

    $r = [ordered]@{ Host = $HostName; Port = $Port; Resolved = $false; Addresses = @(); Open = $false; Error = $null }
    try {
        $r.Addresses = @([Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { $_.IPAddressToString })
        $r.Resolved  = ($r.Addresses.Count -gt 0)
    } catch { $r.Error = "DNS: $($_.Exception.Message)"; return [pscustomobject]$r }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.EndConnect($iar); $r.Open = $true }
        else { $r.Error = 'TCP: tiempo de espera agotado' }
    } catch { $r.Error = "TCP: $($_.Exception.Message)" }
    finally { try { $client.Close() } catch { } }
    return [pscustomobject]$r
}

function Test-CheckInReadiness {
    <#
        Comprobacion de extremo a extremo para el check-in de Zoho en el navegador.
        SOLO LECTURA. Recorre, en orden, todo lo que tiene que estar bien:
          1. Capas de Windows            (Test-LocationState)
          2. Politica de cada navegador  (Test-BrowserGeolocation)
          3. Adaptador Wi-Fi             (sin el, la posicion es por IP: km de error)
          4. Posicion real y precision   (Test-LocationApi -GetPosition)
          5. Conectividad a Zoho y al servicio de posicionamiento de Microsoft
        Devuelve un objeto con Ready (bool), Issues y el detalle de cada paso.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Urls = $script:DefaultCheckInUrls,
        [int]$MaxAccuracyMeters = 500
    )

    $issues = @()
    $warns  = @()

    # 1. Windows
    Write-Log '1/5  Capas de ubicacion de Windows' -Level INFO
    $state = Test-LocationState
    if ($state.Compliant) { Write-Log '  + Servicio, interruptor, consentimiento y politicas correctos' -Level OK }
    else {
        foreach ($i in $state.Issues) { Write-Log "  x $i" -Level ERROR }
        $issues += $state.Issues
    }

    # 2. Navegadores
    Write-Log '2/5  Permiso de ubicacion en los navegadores' -Level INFO
    $browsers = @(Test-BrowserGeolocation -Urls $Urls)
    $anyInstalled = $false
    foreach ($b in $browsers) {
        if ($b.Installed) { $anyInstalled = $true }
        $tag = if ($b.Installed) { "v$($b.Version)" } else { 'no instalado' }
        if ($b.Compliant) {
            Write-Log ("  + {0,-16} {1,-14} politica OK" -f $b.Name, $tag) -Level $(if ($b.Installed) { 'OK' } else { 'DEBUG' })
        } else {
            foreach ($i in $b.Issues) {
                Write-Log "  $(if ($b.Installed) { 'x' } else { '-' }) $i" -Level $(if ($b.Installed) { 'ERROR' } else { 'DEBUG' })
            }
            # Solo cuenta como problema si el navegador existe en el equipo.
            if ($b.Installed) { $issues += $b.Issues }
        }
    }
    if (-not $anyInstalled) {
        $issues += 'No hay ningun navegador soportado instalado (Chrome, Edge o Firefox)'
        Write-Log '  x No se encontro Chrome, Edge ni Firefox' -Level ERROR
    }

    # 3. Wi-Fi
    Write-Log '3/5  Adaptador Wi-Fi (fuente de posicion sin GPS)' -Level INFO
    $wifi = $null
    try {
        $wifi = @(Get-NetAdapter -Physical -ErrorAction Stop |
                  Where-Object { $_.PhysicalMediaType -match '802\.11|Wireless' })
    } catch { }
    if ($null -eq $wifi) {
        Write-Log '  ! No se pudo enumerar adaptadores (Get-NetAdapter no disponible)' -Level WARN
    } elseif ($wifi.Count -eq 0) {
        # Caso tipico de call center: sobremesa por Ethernet. Windows solo tiene la IP publica.
        $warns += 'Equipo solo Ethernet (sin Wi-Fi): Windows ubica por IP publica, con kilometros de error. Con geovalla en Zoho el check-in puede caer fuera del radio.'
        Write-Log '  ! Equipo solo Ethernet: sin Wi-Fi, Windows ubica por la IP publica (precision de km).' -Level WARN
        Write-Log '    Opciones: (a) en Zoho People usar restriccion por IP de la oficina en vez de geovalla;' -Level INFO
        Write-Log '              (b) un adaptador Wi-Fi USB (no hace falta conectarlo: Windows triangula con las redes cercanas);' -Level INFO
        Write-Log '              (c) fijar la "ubicacion predeterminada" en Configuracion > Privacidad > Ubicacion (se usa como respaldo).' -Level INFO
    } else {
        foreach ($w in $wifi) {
            if ($w.Status -eq 'Disabled') {
                $warns += "Adaptador Wi-Fi '$($w.Name)' deshabilitado: sin el, la posicion es por IP"
                Write-Log "  ! Wi-Fi '$($w.Name)' DESHABILITADO. No hace falta conectarlo, pero si tenerlo activo para que escanee redes" -Level WARN
            } else {
                Write-Log "  + Wi-Fi '$($w.Name)' presente ($($w.Status)); Windows puede triangular por redes cercanas" -Level OK
            }
        }
    }

    # 4. Posicion real
    Write-Log '4/5  Posicion real desde la API de Windows (hasta 20 s)' -Level INFO
    $api = Test-LocationApi -GetPosition -MaxAccuracyMeters $MaxAccuracyMeters
    if (-not $api.ApiAvailable) {
        $warns += 'No se pudo consultar la API de ubicacion (WinRT no disponible en esta sesion)'
    } elseif ($api.LocationStatus -in @('Disabled', 'NotAvailable')) {
        $issues += "La API de ubicacion esta en estado $($api.LocationStatus): el navegador no recibira posicion"
    } elseif (-not $api.Position) {
        $issues += "Windows no devolvio posicion ($($api.Error)). Sin posicion, el check-in no puede completarse"
    } elseif ($api.Accuracy -gt $MaxAccuracyMeters) {
        $warns += ("Precision de ~{0} m, por encima de {1} m. Revisar la geovalla de Zoho o anadir Wi-Fi al equipo" -f [math]::Round($api.Accuracy), $MaxAccuracyMeters)
    }

    # 5. Conectividad
    Write-Log '5/5  Conectividad (DNS + puerto 443)' -Level INFO
    $endpoints = @()
    $hosts = @($Urls | ForEach-Object { try { ([uri]$_).Host } catch { $_ } } | Where-Object { $_ } | Select-Object -Unique)
    $hosts += $script:PositioningHost
    foreach ($h in $hosts) {
        $e = Test-CheckInEndpoint -HostName $h -Port 443
        $endpoints += $e
        $label = if ($h -eq $script:PositioningHost) { "$h (posicionamiento Microsoft)" } else { $h }
        if ($e.Open) {
            Write-Log ("  + {0,-48} {1}" -f $label, ($e.Addresses -join ', ')) -Level OK
        } else {
            Write-Log ("  x {0,-48} {1}" -f $label, $e.Error) -Level ERROR
            if ($h -eq $script:PositioningHost) {
                $issues += "Sin acceso a $h`:443 -- Windows no puede resolver la posicion por Wi-Fi/IP (revisar firewall/proxy)"
            } else {
                $issues += "Sin acceso a $h`:443 -- el navegador no llegara a Zoho ($($e.Error))"
            }
        }
    }

    # Veredicto
    $ready = ($issues.Count -eq 0)
    Write-Log '' -Level INFO
    if ($ready -and $warns.Count -eq 0) {
        Write-Log '[OK] El equipo esta listo para el check-in de Zoho con ubicacion.' -Level OK
    } elseif ($ready) {
        Write-Log '[OK con avisos] El check-in deberia funcionar, pero revisa:' -Level WARN
        foreach ($w in $warns) { Write-Log "  - $w" -Level WARN }
    } else {
        Write-Log '[NO LISTO] El check-in con ubicacion NO va a funcionar hasta corregir:' -Level ERROR
        foreach ($i in $issues) { Write-Log "  - $i" -Level ERROR }
        foreach ($w in $warns)  { Write-Log "  - (aviso) $w" -Level WARN }
        Write-Log 'Pulsa "Activar ubicacion" para corregir lo que depende de la configuracion del equipo.' -Level INFO
    }

    return [pscustomobject]@{
        Ready     = $ready
        Issues    = $issues
        Warnings  = $warns
        Windows   = $state
        Browsers  = $browsers
        WifiAdapters = @($wifi | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = "$($_.Status)" } })
        Api       = $api
        Endpoints = $endpoints
    }
}

function Open-BrowserGeoTest {
    <#
        La prueba definitiva: una pagina local que pide la ubicacion con la misma
        API que usa Zoho (navigator.geolocation) y muestra coordenadas, precision
        y el error exacto si falla. Se abre en el navegador predeterminado.
        Nota: como el toolkit va elevado, el navegador se abre con el perfil del
        administrador, no el del agente; sirve para validar Windows + politica.
    #>
    [CmdletBinding()]
    param([string]$Root = 'C:\ProgramData\Toolkit', [int]$MaxAccuracyMeters = 500)

    $path = Join-Path $Root 'geo-test.html'
    $html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Toolkit BPO - prueba de ubicacion</title>
<style>body{font-family:Segoe UI,Arial;margin:40px;max-width:720px;color:#222}h1{font-size:20px}#out{padding:16px;border-radius:8px;background:#f3f3f3;white-space:pre-wrap;font-family:Consolas,monospace}
.ok{background:#e3f6e8;border:1px solid #2e8b57}.bad{background:#fdecea;border:1px solid #c0392b}.warn{background:#fff6e0;border:1px solid #b8860b}small{color:#666}</style></head><body>
<h1>Prueba de ubicacion en el navegador</h1>
<p>Esta pagina pide la ubicacion exactamente igual que lo hace Zoho. Si aqui funciona, el check-in funciona.</p>
<div id="out">Pidiendo ubicacion al navegador...</div>
<p><small>Navegador: <span id="ua"></span></small></p>
<script>
document.getElementById('ua').textContent=navigator.userAgent;
var out=document.getElementById('out');
if(!navigator.geolocation){out.className='bad';out.textContent='Este navegador no soporta geolocalizacion.';}
else{navigator.geolocation.getCurrentPosition(function(p){
  var a=Math.round(p.coords.accuracy);var lim=$MaxAccuracyMeters;
  out.className=(a<=lim)?'ok':'warn';
  out.textContent='OK - el navegador entrega la ubicacion.\n\nLatitud : '+p.coords.latitude+'\nLongitud: '+p.coords.longitude+'\nPrecision: ~'+a+' m'+(a>lim?'  (por encima de '+lim+' m: con geovalla en Zoho puede fallar)':'')+'\nHora: '+new Date(p.timestamp).toLocaleString()+'\n\nVer en el mapa: https://www.google.com/maps?q='+p.coords.latitude+','+p.coords.longitude;
},function(e){
  var why={1:'PERMISSION_DENIED - el navegador o Windows deniegan la ubicacion (politica del navegador, permiso del sitio o ubicacion de Windows apagada).',2:'POSITION_UNAVAILABLE - Windows no devuelve posicion (servicio lfsvc parado, sin Wi-Fi ni acceso al servicio de posicionamiento).',3:'TIMEOUT - el navegador no obtuvo posicion a tiempo.'};
  out.className='bad';out.textContent='FALLO (codigo '+e.code+')\n'+(why[e.code]||e.message)+'\n\nMensaje del navegador: '+e.message;
},{enableHighAccuracy:true,timeout:25000,maximumAge:0});}
</script></body></html>
"@
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [IO.File]::WriteAllText($path, $html, (New-Object Text.UTF8Encoding($false)))
    Write-Log "  > Abriendo prueba de ubicacion en el navegador predeterminado: $path" -Level INFO
    Write-Log '    (se abre con el perfil del administrador; valida Windows y la politica del navegador)' -Level DEBUG
    Start-Process $path
    return $path
}

function Open-LocationSettings {
    <# Abre Configuracion > Privacidad > Ubicacion de Windows, para ver o fijar la ubicacion predeterminada. #>
    [CmdletBinding()]
    param()
    Write-Log '  > Abriendo Configuracion > Privacidad > Ubicacion' -Level INFO
    Start-Process 'ms-settings:privacy-location'
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
    'Restart-LocationService', 'Test-LocationApi', 'Show-LocationState',
    'Get-InstalledBrowsers', 'Test-BrowserGeolocation', 'Enable-BrowserGeolocation', 'Test-CheckInReadiness',
    'Open-BrowserGeoTest', 'Open-LocationSettings'
)
