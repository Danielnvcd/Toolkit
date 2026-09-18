<#
    Toolkit.Apps.psm1
    Motor de instalacion desatendida dirigido por catalogo (config\catalog.json).

    Secuencia por aplicacion:
      1. Detectar -> si ya esta en version >= objetivo, SALTAR
      2. Obtener  -> share primero, URL como respaldo
      3. Verificar-> SHA-256 contra la ficha. Si no coincide: ABORTAR
      4. Instalar -> silencioso, con tiempo limite
      5. Interpretar codigo de salida (3010/1641 = reinicio pendiente)
      6. Esperar a que el instalador termine de verdad y repetir la deteccion
         hasta que aparezca. Si el instalador dijo OK y aun asi no se ve, es
         AVISO ("revisar la ficha"), no FALLO: la aplicacion suele estar puesta.

    Tambien desinstala (Uninstall-CatalogApp), que es el paso previo para poner
    una version nueva cuando el instalador no admite actualizar encima.
#>

# Dependencia de Toolkit.Core (Write-Log, Set-RegValue, Add-Result, Test-ReportOnly...).
# Permite importar este modulo de forma aislada sin que falle la resolucion de comandos.
if (-not (Get-Command 'Write-Log' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking -Global
}


#region ---------- Deteccion ----------

function Get-InstalledPrograms {
    <#
        Inventario de las ramas de desinstalacion: equipo (64 y 32 bits) y la de
        CADA usuario con perfil cargado, no solo la del que ejecuta el toolkit.

        Lo de los usuarios importa: Genesys Cloud, Krisp sin INSTALLPERUSER=0,
        Teams y compania se registran en HKCU del AGENTE. El toolkit corre
        elevado, asi que su HKCU es el del administrador y ahi no hay nada: la
        aplicacion quedaba instalada y el toolkit la daba por fallida.
    #>
    [CmdletBinding()]
    param([switch]$Refresh)

    if ($script:ProgramCache -and -not $Refresh) { return $script:ProgramCache }

    $roots = [ordered]@{
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'             = 'equipo'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' = 'equipo (32 bits)'
    }

    if (-not (Get-PSDrive -Name 'HKU' -ErrorAction SilentlyContinue)) {
        $null = New-PSDrive -Name 'HKU' -PSProvider Registry -Root 'HKEY_USERS' -Scope Global -ErrorAction SilentlyContinue
    }

    $mySid = ''
    try { $mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }

    # SilentlyContinue y no Stop: HKU siempre tiene colmenas de servicio (S-1-5-19,
    # S-1-5-20) a las que ni un administrador puede asomarse. Con -Stop, la primera
    # de ellas abortaba la enumeracion entera y no se veia ningun perfil de usuario.
    $sids = @(Get-ChildItem -LiteralPath 'HKU:\' -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -match '^S-1-5-21-[\d\-]+$' } |
              Select-Object -ExpandProperty PSChildName)

    # Si por lo que sea la colmena propia no aparece en HKU, HKCU la cubre.
    if (-not $mySid -or $sids -notcontains $mySid) {
        $roots['HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall']             = 'usuario actual'
        $roots['HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'] = 'usuario actual (32 bits)'
    }

    foreach ($sid in $sids) {
        $who = $sid
        try { $who = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value } catch { }
        $roots["HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"]             = "usuario $who"
        $roots["HKU:\$sid\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"] = "usuario $who (32 bits)"
    }

    $list = New-Object System.Collections.ArrayList
    foreach ($root in @($roots.Keys)) {
        try {
            foreach ($e in @(Get-ItemProperty -Path ($root + '\*') -ErrorAction SilentlyContinue)) {
                if (-not ($e.PSObject.Properties.Name -contains 'DisplayName') -or -not $e.DisplayName) { continue }
                $get = { param($n) if ($e.PSObject.Properties.Name -contains $n) { $e.$n } else { $null } }
                $null = $list.Add([pscustomobject]@{
                    DisplayName          = $e.DisplayName
                    DisplayVersion       = (& $get 'DisplayVersion')
                    Publisher            = (& $get 'Publisher')
                    InstallDate          = (& $get 'InstallDate')
                    UninstallString      = (& $get 'UninstallString')
                    QuietUninstallString = (& $get 'QuietUninstallString')
                    PSChildName          = $e.PSChildName
                    RegPath              = ($root + '\' + $e.PSChildName)
                    Scope                = $roots[$root]
                })
            }
        } catch { }
    }

    $script:ProgramCache = @($list)
    return $script:ProgramCache
}

function Compare-AppVersion {
    <# Devuelve -1/0/1. Tolerante con versiones no estandar. #>
    param([string]$Found, [string]$Required)
    if (-not $Required) { return 1 }
    if (-not $Found)    { return -1 }
    try {
        $f = [version](($Found   -replace '[^\d\.]', '') -replace '\.+$', '')
        $r = [version](($Required -replace '[^\d\.]', '') -replace '\.+$', '')
        return $f.CompareTo($r)
    } catch {
        return [string]::Compare($Found, $Required, $true)
    }
}

function Test-AppInstalled {
    <#
        Detecta si una aplicacion del catalogo ya esta instalada.
        Metodos: uninstall (nombre en el registro) | file (ruta + version) | service (servicio presente)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$App,
        # Para desinstalar hace falta encontrar la aplicacion AUNQUE este por
        # debajo de minVersion: si no, no habria forma de quitar una version vieja.
        [switch]$IgnoreMinVersion
    )

    $result = [ordered]@{
        Installed            = $false
        Version              = $null
        Method               = $App.detection.method
        Evidence             = $null
        DisplayName          = $null
        UninstallString      = $null
        QuietUninstallString = $null
        RegPath              = $null
        Scope                = $null
    }

    # Copia los datos de desinstalacion de una entrada del registro al resultado.
    $take = {
        param($entry)
        $result.DisplayName          = $entry.DisplayName
        $result.Version              = $entry.DisplayVersion
        $result.UninstallString      = $entry.UninstallString
        $result.QuietUninstallString = $entry.QuietUninstallString
        $result.RegPath              = $entry.RegPath
        $result.Scope                = $entry.Scope
    }

    try {
        switch ($App.detection.method) {

            'uninstall' {
                # displayName es el patron principal; displayNames (opcional) permite
                # alias para los fabricantes que renombran el producto entre versiones.
                $patterns = @()
                if ($App.detection.PSObject.Properties.Name -contains 'displayName' -and $App.detection.displayName) {
                    $patterns += $App.detection.displayName
                }
                if ($App.detection.PSObject.Properties.Name -contains 'displayNames' -and $App.detection.displayNames) {
                    $patterns += @($App.detection.displayNames)
                }
                $inventory = Get-InstalledPrograms
                foreach ($pattern in $patterns) {
                    $match = $inventory | Where-Object { $_.DisplayName -like "*$pattern*" } | Select-Object -First 1
                    if ($match) {
                        $result.Installed = $true
                        $result.Evidence  = "$($match.DisplayName) [$($match.Scope)]"
                        & $take $match
                        break
                    }
                }
            }

            'file' {
                $path = [Environment]::ExpandEnvironmentVariables($App.detection.path)
                if (Test-Path -LiteralPath $path) {
                    $result.Installed = $true
                    $result.Evidence  = $path
                    try { $result.Version = (Get-Item -LiteralPath $path).VersionInfo.FileVersion } catch { }
                }
            }

            'service' {
                $svc = Get-Service -Name $App.detection.serviceName -ErrorAction SilentlyContinue
                if ($svc) {
                    $result.Installed = $true
                    $result.Evidence  = "Servicio $($svc.Name) ($($svc.Status))"
                }
            }

            'productCode' {
                # El metodo mas fiable para MSI: el ProductCode es un GUID exacto,
                # inmune a cambios de nombre comercial y a traducciones del DisplayName.
                $code = $App.detection.productCode
                if ($code -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
                    Write-Log "  ! productCode con formato invalido para $($App.id): '$code'" -Level WARN
                    break
                }
                $entry = Get-InstalledPrograms | Where-Object { $_.PSChildName -ieq $code } | Select-Object -First 1
                if ($entry) {
                    $result.Installed = $true
                    $result.Evidence  = "$($entry.DisplayName) [$($entry.Scope)]"
                    & $take $entry
                } else {
                    foreach ($hive in @(
                        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code",
                        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code")) {
                        if (Test-Path -LiteralPath $hive) {
                            $result.Installed = $true
                            $result.Evidence  = $hive
                            $result.Version   = (Get-RegValue -Path $hive -Name 'DisplayVersion')
                            $result.RegPath   = $hive
                            break
                        }
                    }
                }
                # El ProductCode siempre sirve para desinstalar, este o no la entrada.
                if ($result.Installed -and -not $result.UninstallString) {
                    $result.UninstallString = ('MsiExec.exe /X{0}' -f $code)
                }
            }

            default {
                Write-Log "  ! Metodo de deteccion desconocido '$($App.detection.method)' para $($App.id)" -Level WARN
            }
        }
    } catch {
        Write-Log "  ! Error detectando $($App.id): $($_.Exception.Message)" -Level WARN
    }

    # Deteccion por archivo o servicio: no dan entrada de registro, pero para poder
    # desinstalar se busca una que coincida con el nombre del catalogo.
    if ($result.Installed -and -not $result.UninstallString -and -not $result.QuietUninstallString) {
        $guess = ($App.name -replace '\s*\(.*$', '').Trim()
        if ($guess) {
            $entry = Get-InstalledPrograms | Where-Object { $_.DisplayName -like "*$guess*" } | Select-Object -First 1
            if ($entry) {
                $keep = $result.Version
                & $take $entry
                if ($keep) { $result.Version = $keep }   # la version del archivo es mas fiable que la del registro
            }
        }
    }

    # Si hay version minima exigida y la instalada es menor, se trata como NO instalada (hay que actualizar).
    if (-not $IgnoreMinVersion -and $result.Installed -and $App.detection.PSObject.Properties.Name -contains 'minVersion' -and $App.detection.minVersion) {
        if ((Compare-AppVersion -Found $result.Version -Required $App.detection.minVersion) -lt 0) {
            Write-Log ("  i {0} instalado en {1}, por debajo del minimo {2} -> se actualizara" -f `
                       $App.name, $result.Version, $App.detection.minVersion) -Level INFO
            $result.Installed = $false
        }
    }

    return [pscustomobject]$result
}

#endregion

#region ---------- Obtencion del instalador ----------

function Get-AppInstaller {
    <# Resuelve el instalador: share primero (no satura el enlace), URL como respaldo. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$App,
        [string]$PackageRepo,
        [string]$WorkDir
    )

    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }

    # --- 1) Share ---
    if ($PackageRepo -and $App.source.share) {
        $sharePath = Join-Path $PackageRepo $App.source.share
        try {
            if (Test-Path -LiteralPath $sharePath) {
                $dest = Join-Path $WorkDir (Split-Path $sharePath -Leaf)
                Copy-Item -LiteralPath $sharePath -Destination $dest -Force -ErrorAction Stop
                Write-Log "  + Instalador obtenido del share: $sharePath" -Level OK
                return $dest
            }
            Write-Log "  ! No esta en el share: $sharePath" -Level DEBUG
        } catch {
            Write-Log "  ! Fallo copiando del share: $($_.Exception.Message)" -Level WARN
        }
    }

    # --- 2) URL ---
    if ($App.source.url) {
        $dest = Join-Path $WorkDir (Split-Path ([uri]$App.source.url).LocalPath -Leaf)
        try {
            Write-Log "  > Descargando de $($App.source.url) ..." -Level INFO
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $pp = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'   # sin esto, Invoke-WebRequest es ~10x mas lento
            try {
                # 30 min: Krisp/Genesys pesan 150-330 MB y hay sedes con enlaces de pocos Mbps.
                Invoke-WebRequest -Uri $App.source.url -OutFile $dest -UseBasicParsing -TimeoutSec 1800 -ErrorAction Stop
            } finally {
                $ProgressPreference = $pp
            }
            Write-Log "  + Descargado: $dest ($([math]::Round((Get-Item $dest).Length / 1MB, 1)) MB)" -Level OK
            return $dest
        } catch {
            Write-Log "  x Fallo la descarga: $($_.Exception.Message)" -Level ERROR
            return $null
        }
    }

    Write-Log "  x $($App.name): sin origen valido (ni share ni url en el catalogo)" -Level ERROR
    return $null
}

function Expand-InstallerArchive {
    <#
        Extrae un zip descargado y devuelve la ruta del instalador que contiene.
        Con source.innerFile se toma ese nombre; si no, el unico .msi/.exe del zip.
        Se usa Expand-Archive (PS 5.1) en una carpeta propia para no mezclar con
        otros paquetes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Zip,
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)][string]$WorkDir
    )

    $dir = Join-Path $WorkDir ($App.id + '-zip')
    try {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Log "  > Extrayendo $(Split-Path $Zip -Leaf) ..." -Level INFO
        Expand-Archive -LiteralPath $Zip -DestinationPath $dir -Force -ErrorAction Stop
    } catch {
        Write-Log "  x No se pudo extraer el zip: $($_.Exception.Message)" -Level ERROR
        return $null
    }

    $innerName = $null
    if ($App.source.PSObject.Properties.Name -contains 'innerFile' -and $App.source.innerFile) { $innerName = $App.source.innerFile }

    $candidates = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.msi', '.exe' })
    $found = if ($innerName) { $candidates | Where-Object { $_.Name -ieq $innerName } | Select-Object -First 1 }
             elseif ($candidates.Count -eq 1) { $candidates[0] }
             else { $null }

    if (-not $found) {
        Write-Log ("  x El zip no contiene el instalador esperado ({0}). Contiene: {1}" -f
                   $(if ($innerName) { $innerName } else { 'un unico .msi/.exe' }),
                   $(if ($candidates.Count) { ($candidates.Name -join ', ') } else { 'ningun .msi/.exe' })) -Level ERROR
        return $null
    }
    Write-Log ("  + Instalador extraido: {0} ({1} MB)" -f $found.Name, [math]::Round($found.Length / 1MB, 1)) -Level OK
    return $found.FullName
}

function Test-FileHash256 {
    param([string]$Path, [string]$Expected)
    if (-not $Expected) {
        # Obligatorio: un catalog.json junto al exe o en el share lo puede editar
        # cualquiera con acceso y apuntar url a un instalador manipulado. Sin hash
        # no hay forma de detectarlo, asi que no se instala.
        Write-Log '  x Sin SHA-256 en la ficha: no se instala sin poder verificar la integridad (Get-FileHash y rellena sha256)' -Level ERROR
        return $false
    }
    try {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actual -ieq $Expected) {
            Write-Log '  + SHA-256 verificado' -Level OK
            return $true
        }
        Write-Log "  x SHA-256 NO COINCIDE. Esperado $Expected, obtenido $actual" -Level ERROR
        return $false
    } catch {
        Write-Log "  x No se pudo calcular el hash: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

#endregion

#region ---------- Instalacion ----------

function Wait-MsiExecFree {
    <#
        Windows Installer solo admite UNA instalacion a la vez en todo el equipo.
        Si Windows Update o el propio usuario estan instalando algo, msiexec
        devuelve 1618 y la instalacion se pierde sin explicacion clara.
        Esto espera a que se libere el mutex global _MSIExecute.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 600)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $mutex = $null
        try {
            # Si se puede abrir, hay una instalacion en curso.
            $mutex = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
            $mutex.Dispose()
            Write-Log '  . Windows Installer ocupado, esperando...' -Level DEBUG
            Start-Sleep -Seconds 10
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return $true    # el mutex no existe: libre
        } catch {
            return $true    # sin permisos para abrirlo: se intenta igualmente
        }
    }
    Write-Log "  ! Windows Installer sigue ocupado tras $TimeoutSeconds s" -Level WARN
    return $false
}

function Get-MsiExitMeaning {
    param([int]$Code)
    switch ($Code) {
        1601 { 'El servicio Windows Installer no esta accesible' }
        1602 { 'Cancelado por el usuario' }
        1603 { 'Error fatal durante la instalacion (revisar el log /l*v)' }
        1605 { 'El producto no esta instalado' }
        1618 { 'Otra instalacion en curso' }
        1619 { 'No se pudo abrir el paquete: ruta o permisos' }
        1620 { 'Paquete invalido o corrupto' }
        1622 { 'Error al abrir el archivo de log' }
        1625 { 'Bloqueado por politica del sistema' }
        1633 { 'Plataforma no soportada (x86 vs x64)' }
        1638 { 'Ya hay otra version del producto instalada' }
        1639 { 'Parametro de linea de comandos invalido' }
        3010 { 'Correcto, requiere reinicio' }
        1641 { 'Correcto, reinicio iniciado' }
        default { 'Codigo no catalogado' }
    }
}

function Wait-InstallerProcessExit {
    <#
        Los instaladores empaquetados con WiX Burn (Genesys Cloud, Krisp) se copian
        a %TEMP% y relanzan una copia elevada de si mismos: el proceso que lanza el
        toolkit termina con codigo 0 mientras la instalacion de verdad sigue
        corriendo. Sin esperar aqui, la comprobacion posterior mira el registro
        demasiado pronto y reporta un fallo que no existe.

        Se espera por NOMBRE de proceso, asi que el tiempo limite es corto a
        proposito: si la aplicacion instalada se llamara igual que su instalador y
        arrancara sola, esto no puede quedarse colgado un cuarto de hora.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [int]$TimeoutSeconds = 300
    )

    $name = [IO.Path]::GetFileNameWithoutExtension($InstallerPath)
    if (-not $name) { return }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $announced = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $running = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) { break }
        if (-not $announced) {
            Write-Log "  . El instalador sigue trabajando en segundo plano ($name). Esperando a que termine..." -Level INFO
            $announced = $true
        }
        Start-Sleep -Seconds 5
    }
    if ($announced) {
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Log "  ! '$name' sigue en ejecucion tras $TimeoutSeconds s; se comprueba igualmente." -Level WARN
        } else {
            Write-Log '  . El instalador ha terminado.' -Level DEBUG
        }
    }
}

function Wait-AppDetected {
    <#
        Reintenta la deteccion hasta que la aplicacion aparezca o se agote el
        tiempo. El registro de desinstalacion no se escribe en el instante en que
        el instalador devuelve el control: entre el codigo de salida y la entrada
        visible pueden pasar decenas de segundos.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$App,
        [int]$TimeoutSeconds = 180,
        [switch]$Gone
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $wait = 2
    while ($true) {
        $null = Get-InstalledPrograms -Refresh
        $d = Test-AppInstalled -App $App -IgnoreMinVersion:$Gone
        if ($Gone) { if (-not $d.Installed) { return $d } }
        elseif ($d.Installed) { return $d }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $d }
        Start-Sleep -Seconds $wait
        if ($wait -lt 15) { $wait += 2 }
    }
}

function Install-CatalogApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$App,
        [string]$PackageRepo,
        [string]$WorkDir = (Join-Path $env:ProgramData 'Toolkit\temp'),
        [int]$TimeoutMinutes = 15,
        [switch]$NoRetry,
        # Reinstala aunque ya este: es la unica forma de forzar una version mas
        # nueva cuando la ficha no lleva minVersion (las apps que se autoactualizan).
        [switch]$Force
    )

    Write-Log ("--> {0} (objetivo v{1})" -f $App.name, $App.version) -Level STEP

    # --- 1. Deteccion previa ---
    $pre = Test-AppInstalled -App $App
    if ($pre.Installed -and -not $Force) {
        Write-Log ("  = Ya instalado: {0} v{1}" -f $pre.Evidence, $pre.Version) -Level OK
        Add-Result -Module 'Apps' -Task $App.name -Status 'YA-OK' -Message "v$($pre.Version)"
        return $true
    }
    if ($pre.Installed -and $Force) {
        Write-Log ("  i Ya instalado ({0} v{1}), pero se reinstala por peticion expresa." -f $pre.Evidence, $pre.Version) -Level INFO
    }

    if (Test-ReportOnly) {
        Write-Log '  ! NO instalado -- MODO REPORTE, no se instala' -Level WARN
        Add-Result -Module 'Apps' -Task $App.name -Status 'AVISO' -Message 'Falta instalar'
        return $false
    }

    # --- 1b. Requisitos de la ficha ANTES de descargar nada: sha256 presente y
    #         descarga solo por HTTPS. Evita bajar 300 MB para luego rechazarlos,
    #         y cierra la puerta a un catalogo editado con una url http:// que un
    #         proxy en el camino pueda sustituir.
    $expected = if ($App.PSObject.Properties.Name -contains 'sha256') { "$($App.sha256)".Trim() } else { '' }
    if (-not $expected) {
        Write-Log "  x $($App.name): la ficha no tiene sha256. No se instala sin verificar la integridad." -Level ERROR
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message 'Ficha sin sha256'
        return $false
    }
    $url = if ($App.source.PSObject.Properties.Name -contains 'url') { "$($App.source.url)".Trim() } else { '' }
    if ($url -and $url -notmatch '^https://') {
        Write-Log "  x $($App.name): la url de descarga no es HTTPS ($url). Solo se aceptan descargas cifradas." -Level ERROR
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message 'URL de descarga no HTTPS'
        return $false
    }

    # --- 2. Obtener ---
    $installer = Get-AppInstaller -App $App -PackageRepo $PackageRepo -WorkDir $WorkDir
    if (-not $installer) {
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message 'No se pudo obtener el instalador'
        return $false
    }

    # --- 3. Verificar integridad ---
    $expected = if ($App.PSObject.Properties.Name -contains 'sha256') { $App.sha256 } else { $null }
    if (-not (Test-FileHash256 -Path $installer -Expected $expected)) {
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message 'SHA-256 no coincide -- posible instalador manipulado'
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        return $false
    }

    # --- 3b. Paquete comprimido: el hash se comprueba sobre el zip (lo que se
    #         descarga); dentro va el MSI/EXE real (source.innerFile o el unico
    #         instalador que contenga). FortiClient, por ejemplo, se publica asi.
    $archive = $null
    if ([IO.Path]::GetExtension($installer) -ieq '.zip') {
        $inner = Expand-InstallerArchive -Zip $installer -App $App -WorkDir $WorkDir
        if (-not $inner) {
            Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message 'El zip no contiene el instalador esperado'
            return $false
        }
        $archive   = $installer
        $installer = $inner
    }

    # --- 4. Instalar ---
    $logFile = Join-Path (Join-Path $env:ProgramData 'Toolkit\logs') ("install-{0}-{1}.log" -f $App.id, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $exe     = $null
    $argList = $null

    switch ($App.installerType.ToLower()) {
        'msi' {
            $exe  = "$env:SystemRoot\System32\msiexec.exe"
            $msiArgs = @('/i', ('"{0}"' -f $installer))
            $msiArgs += ($App.silentArgs -split '\s+' | Where-Object { $_ })
            $msiArgs += @('/l*v', ('"{0}"' -f $logFile))
            if ($App.PSObject.Properties.Name -contains 'properties' -and $App.properties) {
                foreach ($prop in $App.properties.PSObject.Properties) {
                    if ($prop.Value) { $msiArgs += ('{0}="{1}"' -f $prop.Name, $prop.Value) }
                }
            }
            $argList = $msiArgs -join ' '
        }
        default {
            # exe / inno / nsis / installshield: el catalogo trae los conmutadores exactos
            $exe     = $installer
            $argList = $null
            if ($App.PSObject.Properties.Name -contains 'silentArgs' -and
                -not [string]::IsNullOrWhiteSpace($App.silentArgs)) {
                $argList = $App.silentArgs
            } else {
                # Start-Process revienta con -ArgumentList vacio o nulo.
                # Sin conmutador silencioso el instalador abriria interfaz en un
                # equipo desatendido y se quedaria colgado hasta el tiempo limite.
                Write-Log "  x $($App.name): sin 'silentArgs' en el catalogo. Un instalador sin conmutador silencioso NO puede desplegarse desatendido." -Level ERROR
                Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message 'Falta silentArgs en la ficha'
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                return $false
            }
        }
    }

    if ($App.installerType.ToLower() -eq 'msi') { $null = Wait-MsiExecFree }

    Write-Log ("  > Ejecutando: {0} {1}" -f (Split-Path $exe -Leaf), $argList) -Level INFO
    $exitCode = -1
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            Write-Log "  x Tiempo limite de $TimeoutMinutes min superado. Terminando proceso." -Level ERROR
            try { $proc.Kill() } catch { }
            Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message "Tiempo limite ($TimeoutMinutes min)"
            return $false
        }
        $exitCode = $proc.ExitCode
    } catch {
        Write-Log "  x No se pudo lanzar el instalador: $($_.Exception.Message)" -Level ERROR
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message $_.Exception.Message
        return $false
    }

    # --- 5. Interpretar codigo de salida ---
    $successCodes = @(0, 3010, 1641)
    if ($App.PSObject.Properties.Name -contains 'successCodes' -and $App.successCodes) { $successCodes = @($App.successCodes) }

    $rebootPending = ($exitCode -in @(3010, 1641))
    if ($rebootPending) { Set-RebootPending }

    # 1618 = otra instalacion en curso. Es transitorio: merece un reintento
    # en vez de contarse como fallo y dejar el equipo sin la aplicacion.
    if ($exitCode -eq 1618 -and -not $NoRetry) {
        Write-Log '  ! Windows Installer ocupado (1618). Reintentando una vez...' -Level WARN
        Start-Sleep -Seconds 30
        return Install-CatalogApp -App $App -PackageRepo $PackageRepo -WorkDir $WorkDir -TimeoutMinutes $TimeoutMinutes -NoRetry -Force:$Force
    }

    if ($exitCode -notin $successCodes) {
        Write-Log ("  x Instalacion fallida. Codigo de salida: {0} ({1}). Log: {2}" -f `
                   $exitCode, (Get-MsiExitMeaning $exitCode), $logFile) -Level ERROR
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' `
                   -Message ("Codigo {0}: {1}" -f $exitCode, (Get-MsiExitMeaning $exitCode))
        return $false
    }

    # --- 6. Verificacion posterior (el codigo 0 NO garantiza que se instalara) ---
    # Antes de mirar el registro hay que dejar terminar lo que siga corriendo:
    # el hijo elevado de los paquetes Burn, o el msiexec de un MSI encadenado.
    if ($App.installerType.ToLower() -eq 'msi') { $null = Wait-MsiExecFree -TimeoutSeconds 900 }
    else { Wait-InstallerProcessExit -InstallerPath $installer }

    $verifySeconds = 180
    if ($App.PSObject.Properties.Name -contains 'verifyTimeoutSeconds' -and $App.verifyTimeoutSeconds) {
        $verifySeconds = [int]$App.verifyTimeoutSeconds
    }
    $post = Wait-AppDetected -App $App -TimeoutSeconds $verifySeconds

    if (-not $post.Installed) {
        # El instalador dijo que fue bien y hemos esperado a que terminara del todo.
        # Que no aparezca suele ser la FICHA (nombre distinto al del registro,
        # instalacion por usuario en un perfil sin cargar, ProductCode nuevo tras
        # una actualizacion), no una instalacion fallida. Se avisa, no se miente
        # diciendo que fallo: es exactamente el falso error de Genesys Cloud.
        Write-Log ("  ! El instalador termino correctamente (codigo {0}) pero la ficha de deteccion no encuentra la aplicacion tras {1} s." -f $exitCode, $verifySeconds) -Level WARN
        Write-Log ("    Comprueba el nombre real en Programas y caracteristicas (scripts\tools\Get-InstalledAppInfo.ps1 -Name '{0}') y ajusta detection en el catalogo." -f $App.detection.displayName) -Level WARN
        Add-Result -Module 'Apps' -Task $App.name -Status 'AVISO' `
                   -Message ("Instalador OK (codigo {0}); la ficha de deteccion no la ve: revisar 'detection' en el catalogo" -f $exitCode)
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        if ($archive) {
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $WorkDir ($App.id + '-zip')) -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $true
    }

    $msg = "v$($post.Version)"
    if ($rebootPending) { $msg += ' (requiere reinicio)' }
    Write-Log ("  + Instalado correctamente: {0}" -f $msg) -Level OK
    Add-Result -Module 'Apps' -Task $App.name -Status 'CAMBIADO' -Message $msg

    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    # Si venia en zip, fuera tambien el zip y la carpeta extraida (200 MB en el caso de FortiClient).
    if ($archive) {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $WorkDir ($App.id + '-zip')) -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}


#endregion

#region ---------- Desinstalacion ----------

function Split-UninstallCommand {
    <# Parte una linea de comandos del registro en ejecutable + argumentos. #>
    param([string]$Command)

    $c = "$Command".Trim()
    if (-not $c) { return $null }

    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -lt 0) { return @{ Exe = $c.Trim('"'); Args = '' } }
        return @{ Exe = $c.Substring(1, $end - 1); Args = $c.Substring($end + 1).Trim() }
    }
    # Sin comillas: el ejecutable llega hasta el primer .exe ("MsiExec.exe /X{...}").
    $m = [regex]::Match($c, '^(?<exe>.+?\.exe)\s*(?<args>.*)$', 'IgnoreCase')
    if ($m.Success) { return @{ Exe = $m.Groups['exe'].Value; Args = $m.Groups['args'].Value.Trim() } }

    $i = $c.IndexOf(' ')
    if ($i -lt 0) { return @{ Exe = $c; Args = '' } }
    return @{ Exe = $c.Substring(0, $i); Args = $c.Substring($i + 1).Trim() }
}

function Get-AppUninstallCommand {
    <#
        Resuelve como desinstalar en silencio. Prioridad:
          1. uninstallArgs de la ficha sobre UninstallString (control explicito)
          2. MSI  -> msiexec /x {ProductCode} /qn /norestart  (siempre silencioso)
          3. QuietUninstallString del registro (los paquetes Burn la publican)
          4. UninstallString a secas -> solo sirve en modo interactivo
        Devuelve @{ Exe; Args; Silent; Source } o $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)]$Detection
    )

    $extra = ''
    if ($App.PSObject.Properties.Name -contains 'uninstallArgs' -and $App.uninstallArgs) { $extra = "$($App.uninstallArgs)".Trim() }

    # 2) MSI: el ProductCode manda, venga de la ficha o de la cadena del registro.
    $code = ''
    if ($App.detection.PSObject.Properties.Name -contains 'productCode' -and $App.detection.productCode) {
        $code = "$($App.detection.productCode)".Trim()
    }
    if (-not $code) {
        foreach ($s in @($Detection.QuietUninstallString, $Detection.UninstallString)) {
            if ($s -and $s -match 'msiexec') {
                $g = [regex]::Match($s, '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}')
                if ($g.Success) { $code = $g.Value; break }
            }
        }
    }
    if ($code -match '^\{[0-9A-Fa-f-]{36}\}$') {
        $argLine = if ($extra) { "/x $code $extra" } else { "/x $code /qn /norestart" }
        return @{ Exe = "$env:SystemRoot\System32\msiexec.exe"; Args = $argLine; Silent = $true; Source = 'msiexec (ProductCode)' }
    }

    # 1/3/4) Cadenas del registro.
    foreach ($candidate in @(
        @{ Cmd = $Detection.QuietUninstallString; Silent = $true;  Source = 'QuietUninstallString del registro' }
        @{ Cmd = $Detection.UninstallString;      Silent = $false; Source = 'UninstallString del registro' })) {

        if (-not $candidate.Cmd) { continue }
        $parts = Split-UninstallCommand -Command $candidate.Cmd
        if (-not $parts) { continue }

        $argLine = $parts.Args
        $silent  = $candidate.Silent
        if ($extra) {
            # La ficha manda: con uninstallArgs se considera silenciosa.
            $argLine = (($parts.Args + ' ' + $extra).Trim())
            $silent  = $true
        }
        return @{ Exe = $parts.Exe; Args = $argLine; Silent = $silent; Source = $candidate.Source }
    }

    return $null
}

function Uninstall-CatalogApp {
    <#
        Desinstala una aplicacion del catalogo. Es el paso previo para poner una
        version mas nueva cuando el instalador no admite actualizar encima.

        -AllowInteractive abre el desinstalador del fabricante con ventana cuando
        no existe modo silencioso (el tecnico esta delante); en desatendido NO.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$App,
        [int]$TimeoutMinutes = 15,
        [switch]$AllowInteractive
    )

    Write-Log ("--> Desinstalando {0}" -f $App.name) -Level STEP

    $null = Get-InstalledPrograms -Refresh
    $det = Test-AppInstalled -App $App -IgnoreMinVersion
    if (-not $det.Installed) {
        Write-Log '  = No esta instalada: nada que desinstalar.' -Level OK
        Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'YA-OK' -Message 'No estaba instalada'
        return $true
    }

    Write-Log ("  i Encontrada: {0} v{1}" -f $det.Evidence, $det.Version) -Level INFO

    if (Test-ReportOnly) {
        Write-Log '  ! MODO REPORTE: no se desinstala nada.' -Level WARN
        Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'AVISO' -Message 'Pendiente de desinstalar (modo reporte)'
        return $false
    }

    $cmd = Get-AppUninstallCommand -App $App -Detection $det
    if (-not $cmd) {
        Write-Log '  x No hay forma de desinstalarla: el registro no publica UninstallString y la ficha no trae uninstallArgs.' -Level ERROR
        Write-Log '    Quitala desde Configuracion > Aplicaciones, o anade "uninstallArgs" al catalogo.' -Level ERROR
        Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'FALLO' -Message 'Sin comando de desinstalacion'
        return $false
    }

    if (-not $cmd.Silent -and -not $AllowInteractive) {
        Write-Log ("  x {0} no tiene desinstalacion silenciosa ({1}). No se abre una ventana en un equipo desatendido." -f $App.name, $cmd.Source) -Level ERROR
        Write-Log '    Anade "uninstallArgs" a la ficha con los conmutadores del fabricante.' -Level ERROR
        Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'FALLO' -Message 'Sin desinstalacion silenciosa'
        return $false
    }

    if ($cmd.Exe -match 'msiexec') { $null = Wait-MsiExecFree }

    Write-Log ("  > Ejecutando: {0} {1}" -f (Split-Path $cmd.Exe -Leaf), $cmd.Args) -Level INFO
    if (-not $cmd.Silent) { Write-Log '  ! Sin modo silencioso: se abrira el desinstalador del fabricante. Completalo en pantalla.' -Level WARN }

    $exitCode = -1
    try {
        $sp = @{ FilePath = $cmd.Exe; PassThru = $true; ErrorAction = 'Stop' }
        if ($cmd.Args) { $sp.ArgumentList = $cmd.Args }
        if ($cmd.Silent) { $sp.WindowStyle = 'Hidden' }
        $proc = Start-Process @sp
        if (-not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            Write-Log "  x Tiempo limite de $TimeoutMinutes min superado." -Level ERROR
            try { $proc.Kill() } catch { }
            Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'FALLO' -Message "Tiempo limite ($TimeoutMinutes min)"
            return $false
        }
        $exitCode = $proc.ExitCode
    } catch {
        Write-Log "  x No se pudo lanzar el desinstalador: $($_.Exception.Message)" -Level ERROR
        Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'FALLO' -Message $_.Exception.Message
        return $false
    }

    # 1605 = "el producto no esta instalado": para desinstalar, eso es exito.
    $okCodes = @(0, 1605, 3010, 1641)
    if ($exitCode -in @(3010, 1641)) { Set-RebootPending }

    if ($exitCode -notin $okCodes) {
        Write-Log ("  x Desinstalacion fallida. Codigo {0} ({1})." -f $exitCode, (Get-MsiExitMeaning $exitCode)) -Level ERROR
        Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'FALLO' `
                   -Message ("Codigo {0}: {1}" -f $exitCode, (Get-MsiExitMeaning $exitCode))
        return $false
    }

    if ($cmd.Exe -match 'msiexec') { $null = Wait-MsiExecFree -TimeoutSeconds 900 }
    else { Wait-InstallerProcessExit -InstallerPath $cmd.Exe }

    $post = Wait-AppDetected -App $App -TimeoutSeconds 120 -Gone
    if ($post.Installed) {
        Write-Log '  ! El desinstalador termino bien pero la aplicacion sigue detectandose. Puede requerir reinicio.' -Level WARN
        Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'AVISO' -Message 'Sigue detectandose (puede requerir reinicio)'
        return $false
    }

    $msg = if ($exitCode -in @(3010, 1641)) { 'Desinstalada (requiere reinicio)' } else { 'Desinstalada' }
    Write-Log "  + $msg" -Level OK
    Add-Result -Module 'Apps' -Task ("Desinstalar $($App.name)") -Status 'CAMBIADO' -Message $msg
    return $true
}

function Uninstall-AppSet {
    <# Desinstala los ids indicados. Siempre seleccion explicita: nunca todo el catalogo. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string[]]$Only,
        [int]$TimeoutMinutes = 15,
        [switch]$AllowInteractive
    )

    $apps = @($Catalog.apps | Where-Object { $Only -contains $_.id })
    foreach ($u in @($Only | Where-Object { $_ -notin $apps.id })) { Write-Log "  ! '$u' no existe en el catalogo" -Level WARN }
    if ($apps.Count -eq 0) { Write-Log 'No hay aplicaciones que desinstalar.' -Level WARN; return }

    Write-Log ("Aplicaciones a desinstalar: {0}" -f ($apps.name -join ', ')) -Level INFO
    $ok = 0
    foreach ($app in $apps) {
        if (Uninstall-CatalogApp -App $app -TimeoutMinutes $TimeoutMinutes -AllowInteractive:$AllowInteractive) { $ok++ }
    }
    Write-Log ("Desinstalaciones correctas: {0}/{1}" -f $ok, $apps.Count) -Level $(if ($ok -eq $apps.Count) { 'OK' } else { 'WARN' })
}

#endregion

#region ---------- Conjunto ----------

function Install-AppSet {
    <#
        Instala el conjunto de aplicaciones del catalogo.

        -Only limita a ids concretos y ademas es una SELECCION EXPLICITA: se
        instalan aunque tengan enabled=false. El flag enabled gobierna el
        despliegue desatendido (agente, /silent /all), no lo que el tecnico
        marca a mano en la pestana Aplicaciones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [string[]]$Only,
        [int]$TimeoutMinutes = 15,
        [switch]$Force
    )

    $repo = $null
    if ($Catalog.PSObject.Properties.Name -contains 'packageRepo') { $repo = $Catalog.packageRepo }

    $apps = @($Catalog.apps)
    if ($Only) {
        $apps = @($apps | Where-Object { $Only -contains $_.id })
        $unknown = @($Only | Where-Object { $_ -notin $apps.id })
        foreach ($u in $unknown) { Write-Log "  ! '$u' no existe en el catalogo" -Level WARN }
        foreach ($a in @($apps | Where-Object { -not $_.enabled })) {
            Write-Log ("  i {0}: enabled=false en el catalogo, pero se instala porque se selecciono explicitamente" -f $a.name) -Level INFO
        }
    } else {
        $skipped = @($apps | Where-Object { -not $_.enabled })
        foreach ($s in $skipped) {
            Write-Log ("  - {0}: desactivado en el catalogo (enabled=false)" -f $s.name) -Level DEBUG
            Add-Result -Module 'Apps' -Task $s.name -Status 'OMITIDO' -Message 'enabled=false en catalog.json'
        }
        $apps = @($apps | Where-Object { $_.enabled })
    }

    if ($apps.Count -eq 0) {
        Write-Log 'No hay aplicaciones que instalar (ninguna seleccionada o activa en el catalogo).' -Level WARN
        return
    }

    Write-Log ("Aplicaciones a procesar: {0}" -f ($apps.name -join ', ')) -Level INFO

    if ($Force) { Write-Log 'Reinstalacion forzada: se instalan aunque ya esten presentes.' -Level WARN }

    $ok = 0
    foreach ($app in $apps) {
        if (Install-CatalogApp -App $app -PackageRepo $repo -TimeoutMinutes $TimeoutMinutes -Force:$Force) { $ok++ }
    }
    Write-Log ("Aplicaciones correctas: {0}/{1}" -f $ok, $apps.Count) -Level $(if ($ok -eq $apps.Count) { 'OK' } else { 'WARN' })
}

function Show-AppInventory {
    <# Estado de cada aplicacion del catalogo, sin tocar nada. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)

    Write-Host ''
    Write-Host '  INVENTARIO DE APLICACIONES' -ForegroundColor Cyan
    Write-Host '  --------------------------' -ForegroundColor Cyan
    Write-Host ('    {0,-32} {1,-12} {2,-12} {3}' -f 'Aplicacion', 'Objetivo', 'Instalada', 'Estado') -ForegroundColor Gray

    foreach ($app in $Catalog.apps) {
        $d = Test-AppInstalled -App $app
        $status = if (-not $app.enabled)  { 'omitida' }
                  elseif ($d.Installed)   { 'OK' }
                  else                    { 'FALTA' }
        $color  = switch ($status) { 'OK' { 'Green' } 'FALTA' { 'Yellow' } default { 'DarkGray' } }
        Write-Host ('    {0,-32} {1,-12} {2,-12} {3}' -f `
                    $app.name, $app.version, $(if ($d.Version) { $d.Version } else { '-' }), $status) -ForegroundColor $color
    }
    Write-Host ''
}

#endregion

Export-ModuleMember -Function @(
    'Get-InstalledPrograms', 'Test-AppInstalled', 'Compare-AppVersion',
    'Get-AppInstaller', 'Test-FileHash256', 'Expand-InstallerArchive',
    'Install-CatalogApp', 'Install-AppSet', 'Show-AppInventory',
    'Uninstall-CatalogApp', 'Uninstall-AppSet', 'Get-AppUninstallCommand', 'Split-UninstallCommand',
    'Wait-MsiExecFree', 'Get-MsiExitMeaning', 'Wait-InstallerProcessExit', 'Wait-AppDetected'
)
