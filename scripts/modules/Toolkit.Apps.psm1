<#
    Toolkit.Apps.psm1
    Motor de instalacion desatendida dirigido por catalogo (config\catalog.json).

    Secuencia por aplicacion:
      1. Detectar -> si ya esta en version >= objetivo, SALTAR
      2. Obtener  -> share primero, URL como respaldo
      3. Verificar-> SHA-256 contra la ficha. Si no coincide: ABORTAR
      4. Instalar -> silencioso, con tiempo limite
      5. Interpretar codigo de salida (3010/1641 = reinicio pendiente)
      6. Verificar -> repetir deteccion. Si sigue sin verse: FALLO real
#>

# Dependencia de Toolkit.Core (Write-Log, Set-RegValue, Add-Result, Test-ReportOnly...).
# Permite importar este modulo de forma aislada sin que falle la resolucion de comandos.
if (-not (Get-Command 'Write-Log' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking -Global
}


#region ---------- Deteccion ----------

function Get-InstalledPrograms {
    <# Inventario desde las tres ramas de desinstalacion (64, 32 y por usuario). #>
    [CmdletBinding()]
    param([switch]$Refresh)

    if ($script:ProgramCache -and -not $Refresh) { return $script:ProgramCache }

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $list = @()
    foreach ($p in $paths) {
        try {
            $list += Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, UninstallString, PSChildName
        } catch { }
    }

    $script:ProgramCache = $list
    return $list
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
    param([Parameter(Mandatory)]$App)

    $result = [ordered]@{
        Installed = $false
        Version   = $null
        Method    = $App.detection.method
        Evidence  = $null
    }

    try {
        switch ($App.detection.method) {

            'uninstall' {
                $pattern = $App.detection.displayName
                $match = Get-InstalledPrograms | Where-Object { $_.DisplayName -like "*$pattern*" } | Select-Object -First 1
                if ($match) {
                    $result.Installed = $true
                    $result.Version   = $match.DisplayVersion
                    $result.Evidence  = $match.DisplayName
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
                foreach ($hive in @(
                    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$code",
                    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code")) {
                    if (Test-Path -LiteralPath $hive) {
                        $result.Installed = $true
                        $result.Evidence  = $hive
                        $result.Version   = (Get-RegValue -Path $hive -Name 'DisplayVersion')
                        break
                    }
                }
            }

            default {
                Write-Log "  ! Metodo de deteccion desconocido '$($App.detection.method)' para $($App.id)" -Level WARN
            }
        }
    } catch {
        Write-Log "  ! Error detectando $($App.id): $($_.Exception.Message)" -Level WARN
    }

    # Si hay version minima exigida y la instalada es menor, se trata como NO instalada (hay que actualizar).
    if ($result.Installed -and $App.detection.PSObject.Properties.Name -contains 'minVersion' -and $App.detection.minVersion) {
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
        Write-Log '  ! Sin SHA-256 en la ficha: no se puede verificar la integridad del instalador' -Level WARN
        return $true   # se permite, pero queda registrado
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

function Install-CatalogApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$App,
        [string]$PackageRepo,
        [string]$WorkDir = (Join-Path $env:ProgramData 'Toolkit\temp'),
        [int]$TimeoutMinutes = 15,
        [switch]$NoRetry
    )

    Write-Log ("--> {0} (objetivo v{1})" -f $App.name, $App.version) -Level STEP

    # --- 1. Deteccion previa ---
    $pre = Test-AppInstalled -App $App
    if ($pre.Installed) {
        Write-Log ("  = Ya instalado: {0} v{1}" -f $pre.Evidence, $pre.Version) -Level OK
        Add-Result -Module 'Apps' -Task $App.name -Status 'YA-OK' -Message "v$($pre.Version)"
        return $true
    }

    if (Test-ReportOnly) {
        Write-Log '  ! NO instalado -- MODO REPORTE, no se instala' -Level WARN
        Add-Result -Module 'Apps' -Task $App.name -Status 'AVISO' -Message 'Falta instalar'
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
        return Install-CatalogApp -App $App -PackageRepo $PackageRepo -WorkDir $WorkDir -TimeoutMinutes $TimeoutMinutes -NoRetry
    }

    if ($exitCode -notin $successCodes) {
        Write-Log ("  x Instalacion fallida. Codigo de salida: {0} ({1}). Log: {2}" -f `
                   $exitCode, (Get-MsiExitMeaning $exitCode), $logFile) -Level ERROR
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' `
                   -Message ("Codigo {0}: {1}" -f $exitCode, (Get-MsiExitMeaning $exitCode))
        return $false
    }

    # --- 6. Verificacion posterior (el codigo 0 NO garantiza que se instalara) ---
    Start-Sleep -Seconds 3
    $null = Get-InstalledPrograms -Refresh
    $post = Test-AppInstalled -App $App

    if (-not $post.Installed) {
        Write-Log '  x El instalador devolvio exito pero la aplicacion NO se detecta. Revisar la ficha de deteccion.' -Level ERROR
        Add-Result -Module 'Apps' -Task $App.name -Status 'FALLO' -Message 'Instalada pero no detectable (revisar ficha)'
        return $false
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
        [int]$TimeoutMinutes = 15
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

    $ok = 0
    foreach ($app in $apps) {
        if (Install-CatalogApp -App $app -PackageRepo $repo -TimeoutMinutes $TimeoutMinutes) { $ok++ }
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
    'Wait-MsiExecFree', 'Get-MsiExitMeaning'
)
