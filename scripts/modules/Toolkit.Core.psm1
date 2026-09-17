<#
    Toolkit.Core.psm1
    Motor comun: logging, registro con rollback, resultados, reportes.
    Compatible con Windows PowerShell 5.1 (no requiere PowerShell 7).
#>

$script:Version      = '0.1.0'
$script:Root         = 'C:\ProgramData\Toolkit'
$script:LogPath      = $null
$script:RollbackPath = $null
$script:SharePath    = $null
$script:Silent       = $false
$script:ReportOnly   = $false
$script:Results      = New-Object System.Collections.ArrayList
$script:RebootPending = $false
$script:LogWriter    = $null

#region ---------- Inicializacion ----------

function Initialize-Toolkit {
    [CmdletBinding()]
    param(
        [string]$Root = 'C:\ProgramData\Toolkit',
        [string]$SharePath,
        [switch]$Silent,
        [switch]$ReportOnly
    )

    $script:Root       = $Root
    $script:Silent     = $Silent.IsPresent
    $script:ReportOnly = $ReportOnly.IsPresent
    $script:SharePath  = $SharePath
    $script:Results    = New-Object System.Collections.ArrayList
    $script:RebootPending = $false

    foreach ($dir in @($Root, (Join-Path $Root 'logs'), (Join-Path $Root 'reports'), (Join-Path $Root 'temp'))) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    $stamp               = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogPath      = Join-Path $Root ('logs\toolkit-{0}-{1}.log' -f $env:COMPUTERNAME, $stamp)
    $script:RollbackPath = Join-Path $Root 'rollback.json'
    Open-LogWriter

    Write-Log ('=' * 78) -Level INFO
    Write-Log ("Toolkit v{0}  |  {1}  |  modo: {2}" -f $script:Version, $env:COMPUTERNAME,
               $(if ($script:ReportOnly) { 'SOLO REPORTE (sin cambios)' } elseif ($script:Silent) { 'DESATENDIDO' } else { 'INTERACTIVO' })) -Level INFO
    Write-Log ("Ejecutado por: {0}  |  Elevado: {1}" -f "$env:USERDOMAIN\$env:USERNAME", (Test-IsAdmin)) -Level INFO
    Write-Log ('=' * 78) -Level INFO

    Remove-OldLogs -Days 30
}

function Remove-OldLogs {
    param([int]$Days = 30)
    try {
        $logDir = Join-Path $script:Root 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { return }
        $limit = (Get-Date).AddDays(-$Days)
        Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Set-ToolkitMode {
    <#
        Fija el modo (solo reporte / desatendido) sin abrir un log nuevo.
        Sin parametros = interactivo. Lo usa el exe al terminar una ejecucion
        del orquestador: el runspace es compartido y, si no, una auditoria
        dejaria el modo "solo reporte" pegado a las acciones de Soporte y
        Usuarios que vienen despues.
    #>
    param([switch]$ReportOnly, [switch]$Silent)
    $script:ReportOnly = $ReportOnly.IsPresent
    $script:Silent     = $Silent.IsPresent
}

#endregion

#region ---------- Logging ----------

# El archivo de log se mantiene abierto (StreamWriter con AutoFlush) en vez de
# Add-Content por linea: abrir y cerrar el archivo en cada linea cuesta ~1 ms y
# una auditoria escribe cientos. FileShare.Read: se puede abrir en el Bloc de
# notas mientras se escribe.
function Open-LogWriter {
    Close-LogWriter
    if (-not $script:LogPath) { return }
    try {
        $fs = New-Object System.IO.FileStream($script:LogPath, [System.IO.FileMode]::Append,
                                              [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $script:LogWriter = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($true)))
        $script:LogWriter.AutoFlush = $true
    } catch {
        $script:LogWriter = $null   # se cae a Add-Content
    }
}

function Close-LogWriter {
    if ($script:LogWriter) {
        try { $script:LogWriter.Dispose() } catch { }
        $script:LogWriter = $null
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG', 'STEP')][string]$Level = 'INFO',
        [switch]$NoConsole
    )

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if ($script:LogWriter) {
        try { $script:LogWriter.WriteLine($line) } catch { }
    } elseif ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    }

    if (-not $NoConsole -and -not $script:Silent) {
        $color = switch ($Level) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            'DEBUG' { 'DarkGray' }
            'STEP'  { 'Cyan' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Log '' -Level INFO -NoConsole
    Write-Log ('--- {0} ' -f $Message).PadRight(78, '-') -Level STEP
}

#endregion

#region ---------- Privilegios ----------

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-IsSystem {
    try {
        return ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value -eq 'S-1-5-18'
    } catch { return $false }
}

#endregion

#region ---------- Registro con rollback ----------

function Get-RegValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch {
        return $null
    }
}

function Save-RegBackup {
    param(
        [string]$Path,
        [string]$Name,
        $Current,
        [string]$Type
    )
    try {
        $entries = @()
        if (Test-Path -LiteralPath $script:RollbackPath) {
            $raw = Get-Content -LiteralPath $script:RollbackPath -Raw -ErrorAction SilentlyContinue
            if ($raw) { $entries = @(ConvertFrom-Json $raw) }
        }

        # Solo se guarda el PRIMER valor original. Nunca se pisa con un intermedio.
        foreach ($e in $entries) {
            if ($e.Path -eq $Path -and $e.Name -eq $Name) { return }
        }

        $entries += [pscustomobject]@{
            Path      = $Path
            Name      = $Name
            HadValue  = ($null -ne $Current)
            Value     = $Current
            Type      = $Type
            Timestamp = (Get-Date).ToString('o')
        }
        # Escritura atomica: si el proceso muere a mitad de un Set-Content, el
        # rollback.json queda truncado y se pierde la capacidad de revertir
        # en ese equipo. Se escribe a temporal y se mueve.
        $tmp = $script:RollbackPath + '.tmp'
        $entries | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
        [System.IO.File]::Copy($tmp, $script:RollbackPath, $true)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "No se pudo guardar el respaldo de $Path\$Name : $($_.Exception.Message)" -Level WARN
    }
}

function Set-RegValue {
    <#
        Escribe un valor de registro de forma idempotente.
        Devuelve $true si REALMENTE cambio algo, $false si ya estaba correcto.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()]$Value,
        [ValidateSet('String', 'DWord', 'QWord', 'MultiString', 'ExpandString', 'Binary')]
        [string]$Type = 'DWord'
    )

    $current = Get-RegValue -Path $Path -Name $Name

    if ($null -ne $current) {
        $same = if ($Type -eq 'MultiString') {
            ((@($current) -join "`0") -eq (@($Value) -join "`0"))
        } else {
            ("$current" -eq "$Value")
        }
        if ($same) {
            Write-Log ("  = {0}\{1} ya vale '{2}'" -f $Path, $Name, $Value) -Level DEBUG
            return $false
        }
    }

    if ($script:ReportOnly) {
        Write-Log ("  ! {0}\{1} deberia ser '{2}' (actual: {3}) -- MODO REPORTE, sin cambios" -f `
                   $Path, $Name, $Value, $(if ($null -eq $current) { '<ausente>' } else { $current })) -Level WARN
        return $true
    }

    try {
        Save-RegBackup -Path $Path -Name $Name -Current $current -Type $Type
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Log ("  + {0}\{1} = {2}   (antes: {3})" -f `
                   $Path, $Name, $Value, $(if ($null -eq $current) { '<ausente>' } else { $current })) -Level OK
        return $true
    } catch {
        Write-Log ("  x FALLO al escribir {0}\{1} : {2}" -f $Path, $Name, $_.Exception.Message) -Level ERROR
        throw
    }
}

function Invoke-ToolkitRollback {
    <# Revierte todos los cambios de registro registrados en rollback.json #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:RollbackPath)) {
        Write-Log 'No hay nada que revertir (rollback.json no existe).' -Level WARN
        return
    }

    $entries = @(ConvertFrom-Json (Get-Content -LiteralPath $script:RollbackPath -Raw))
    Write-Step ("Revirtiendo {0} cambio(s) de registro" -f $entries.Count)

    # Orden inverso: se deshace lo ultimo primero.
    [array]::Reverse($entries)

    foreach ($e in $entries) {
        try {
            if ($e.HadValue) {
                if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $e.Value -PropertyType $e.Type -Force | Out-Null
                Write-Log ("  < restaurado {0}\{1} = {2}" -f $e.Path, $e.Name, $e.Value) -Level OK
            } else {
                if (Test-Path -LiteralPath $e.Path) {
                    Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -Force -ErrorAction SilentlyContinue
                    Write-Log ("  < eliminado  {0}\{1} (no existia antes)" -f $e.Path, $e.Name) -Level OK
                }
            }
        } catch {
            Write-Log ("  x no se pudo revertir {0}\{1} : {2}" -f $e.Path, $e.Name, $_.Exception.Message) -Level ERROR
        }
    }

    Rename-Item -LiteralPath $script:RollbackPath -NewName ("rollback-aplicado-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    Write-Log 'Reversion completada.' -Level OK
}

#endregion

#region ---------- Resultados y reportes ----------

function Add-Result {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][ValidateSet('OK', 'CAMBIADO', 'YA-OK', 'FALLO', 'OMITIDO', 'AVISO')][string]$Status,
        [string]$Message = '',
        $Detail = $null
    )
    $null = $script:Results.Add([pscustomobject]@{
        Module    = $Module
        Task      = $Task
        Status    = $Status
        Message   = $Message
        Detail    = $Detail
        Timestamp = (Get-Date).ToString('o')
    })
}

function Get-Results { return $script:Results }

function Get-MachineInfo {
    [CmdletBinding()]
    param()
    $info = [ordered]@{
        ComputerName   = $env:COMPUTERNAME
        ToolkitVersion = $script:Version
        Timestamp      = (Get-Date).ToString('o')
        Serial         = $null
        Manufacturer   = $null
        Model          = $null
        OSCaption      = $null
        OSVersion      = $null
        DisplayVersion = $null
        UBR            = $null
        LoggedOnUser   = $null
        Domain         = $null
        PartOfDomain   = $null
        IPv4           = @()
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $info.OSCaption = $os.Caption
        $info.OSVersion = $os.Version
    } catch { }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $info.Manufacturer = $cs.Manufacturer
        $info.Model        = $cs.Model
        $info.LoggedOnUser = $cs.UserName
        $info.Domain       = $cs.Domain
        $info.PartOfDomain = $cs.PartOfDomain
    } catch { }
    try { $info.Serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch { }
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $info.DisplayVersion = $cv.DisplayVersion }
        if ($cv.PSObject.Properties.Name -contains 'UBR')            { $info.UBR = $cv.UBR }
    } catch { }
    try {
        $info.IPv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress)
    } catch { }
    return [pscustomobject]$info
}

function Save-Report {
    <# Guarda el reporte en JSON localmente y, si hay share alcanzable, tambien alli. #>
    [CmdletBinding()]
    param([string]$SharePath = $script:SharePath)

    $report = [pscustomobject]@{
        Machine = Get-MachineInfo
        Mode    = $(if ($script:ReportOnly) { 'report' } elseif ($script:Silent) { 'silent' } else { 'interactive' })
        Results = @($script:Results)
        Summary = Get-ResultSummary
    }

    $json  = $report | ConvertTo-Json -Depth 8
    $local = Join-Path $script:Root ('reports\{0}.json' -f $env:COMPUTERNAME)
    try {
        $json | Set-Content -LiteralPath $local -Encoding UTF8
        Write-Log "Reporte local: $local" -Level INFO
    } catch {
        Write-Log "No se pudo escribir el reporte local: $($_.Exception.Message)" -Level WARN
    }

    if ($SharePath) {
        try {
            $dir = Join-Path $SharePath 'reports'
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
            $json | Set-Content -LiteralPath (Join-Path $dir ('{0}.json' -f $env:COMPUTERNAME)) -Encoding UTF8 -ErrorAction Stop
            Write-Log "Reporte subido al share: $dir" -Level OK
        } catch {
            Write-Log "Share inalcanzable, reporte solo en local: $($_.Exception.Message)" -Level WARN
        }
    }

    return $report
}

function Get-ResultSummary {
    $s = [ordered]@{}
    foreach ($k in @('OK', 'CAMBIADO', 'YA-OK', 'FALLO', 'OMITIDO', 'AVISO')) {
        $s[$k] = @($script:Results | Where-Object { $_.Status -eq $k }).Count
    }
    return [pscustomobject]$s
}

function Show-Summary {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host ' RESUMEN' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan

    foreach ($r in $script:Results) {
        $color = switch ($r.Status) {
            'OK'       { 'Green' }
            'CAMBIADO' { 'Green' }
            'YA-OK'    { 'DarkGray' }
            'FALLO'    { 'Red' }
            'AVISO'    { 'Yellow' }
            default    { 'Gray' }
        }
        Write-Host ('  [{0,-8}] {1,-14} {2}' -f $r.Status, $r.Module, $r.Task) -ForegroundColor $color -NoNewline
        if ($r.Message) { Write-Host ("  -> {0}" -f $r.Message) -ForegroundColor DarkGray } else { Write-Host '' }
    }

    $sum = Get-ResultSummary
    Write-Host ''
    Write-Host ("  Cambiado: {0}   Ya correcto: {1}   Fallos: {2}   Avisos: {3}   Omitido: {4}" -f `
                $sum.CAMBIADO, $sum.'YA-OK', $sum.FALLO, $sum.AVISO, $sum.OMITIDO) -ForegroundColor White
    Write-Host ("  Log: {0}" -f $script:LogPath) -ForegroundColor DarkGray
    Write-Host ('=' * 78) -ForegroundColor Cyan
}

function Set-RebootPending {
    <# Lo marca cualquier instalador que devuelva 3010/1641. #>
    $script:RebootPending = $true
}

function Test-RebootPendingFlag { return $script:RebootPending }

function Get-ExitCode {
    <# Codigos de salida segun el plan (seccion 9). #>
    $sum = Get-ResultSummary
    if ($sum.FALLO -eq 0) {
        # 3010 = correcto PERO requiere reinicio. Sin esto, el equipo queda a
        # medias y ni la tarea programada ni el RMM se enteran.
        if ($script:RebootPending) { return 3010 }
        return 0
    }

    $failedModules = @($script:Results | Where-Object { $_.Status -eq 'FALLO' } | Select-Object -ExpandProperty Module -Unique)
    if ($failedModules -contains 'Location') { return 1001 }
    if ($failedModules -contains 'Apps')     { return 1002 }
    if ($failedModules -contains 'Network')  { return 1003 }
    return 1
}

#endregion

#region ---------- Instancia unica ----------

$script:InstanceMutex = $null

function Enter-ToolkitInstance {
    <#
        Impide que dos ejecuciones coincidan en el mismo equipo.
        Sin esto, la tarea programada del agente y el tecnico con la interfaz
        pueden escribir rollback.json a la vez y dejarlo inservible, o pelearse
        por el mutex de Windows Installer.
        Devuelve $true si se obtuvo la exclusividad.
    #>
    [CmdletBinding()]
    param([int]$WaitSeconds = 0)

    try {
        $created = $false
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Global\ToolkitCallCenter', [ref]$created)
        if ($created) { return $true }

        if ($WaitSeconds -gt 0) {
            if ($script:InstanceMutex.WaitOne([TimeSpan]::FromSeconds($WaitSeconds))) { return $true }
        }
        Write-Log 'Ya hay otra instancia del toolkit en ejecucion en este equipo.' -Level WARN
        return $false
    } catch [System.Threading.AbandonedMutexException] {
        # La instancia anterior murio sin liberar: se hereda el mutex.
        return $true
    } catch {
        Write-Log "No se pudo crear el mutex de instancia: $($_.Exception.Message)" -Level WARN
        return $true   # nunca bloquear la ejecucion por no poder crear el mutex
    }
}

function Exit-ToolkitInstance {
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        try { $script:InstanceMutex.Dispose() }      catch { }
        $script:InstanceMutex = $null
    }
}

#endregion

#region ---------- Utilidades ----------

function Test-MaintenanceWindow {
    <#
        Devuelve $true si AHORA es momento seguro para acciones intrusivas.
        Por defecto: fuera de 07:00-23:00 (call center con turnos largos).
        Ajustar a los turnos reales antes de desplegar.
    #>
    param(
        [int]$StartHour = 23,
        [int]$EndHour   = 7
    )
    $h = (Get-Date).Hour
    if ($StartHour -gt $EndHour) { return ($h -ge $StartHour -or $h -lt $EndHour) }
    return ($h -ge $StartHour -and $h -lt $EndHour)
}

function Get-ToolkitConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No se encuentra el archivo de configuracion: $Path"
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "El archivo de configuracion no es JSON valido ($Path): $($_.Exception.Message)"
    }
}

function Get-PhysicalAdapter {
    <#
        Adaptadores de red fisicos (incluidos los deshabilitados).
        Se usa Win32_NetworkAdapter y no Get-NetAdapter porque este ultimo carga
        el modulo NetAdapter (CDXML) la primera vez: 2-3 s en un equipo normal.
        La clase WMI da lo mismo en una fraccion, y CIM ya esta caliente por el
        resto del toolkit.
    #>
    [CmdletBinding()]
    param()

    $rows = @()
    try {
        foreach ($a in @(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' -ErrorAction Stop)) {
            # NetEnabled es $false tambien con el cable desconectado: no sirve para
            # saber si el adaptador esta deshabilitado. Eso lo dice ConfigManagerErrorCode
            # 22 (dispositivo deshabilitado) o NetConnectionStatus 5 (hardware deshabilitado).
            $status = if ([int]$a.ConfigManagerErrorCode -eq 22 -or [int]$a.NetConnectionStatus -eq 5) { 'Disabled' }
                      else {
                          switch ([int]$a.NetConnectionStatus) {
                              2       { 'Up' }
                              0       { 'Disconnected' }
                              7       { 'Disconnected' }
                              default { 'Unknown' }
                          }
                      }
            $desc = [string]$a.Name
            $rows += [pscustomobject]@{
                Name           = $(if ($a.NetConnectionID) { [string]$a.NetConnectionID } else { $desc })
                Description    = $desc
                Status         = $status
                IsWireless     = ($desc -match 'Wi-?Fi|Wireless|802\.11|WLAN' -or [string]$a.NetConnectionID -match 'Wi-?Fi|WLAN')
                # Speed llega como UInt64.MaxValue cuando el enlace esta caido.
                LinkSpeedBps   = $(if ($a.Speed -and $a.Speed -lt [int64]::MaxValue) { [int64]$a.Speed } else { 0 })
                MacAddress     = [string]$a.MACAddress
                InterfaceIndex = [int]$a.InterfaceIndex
            }
        }
    } catch {
        return $null   # WMI no disponible: el llamador decide que decir
    }
    return $rows
}

function Get-DefaultGateway {
    <# Puerta de enlace IPv4 por defecto (ruta 0.0.0.0 de menor metrica). Win32_IP4RouteTable: ~30 ms; Get-NetRoute: >1 s la primera vez. #>
    [CmdletBinding()]
    param()
    try {
        $r = Get-CimInstance Win32_IP4RouteTable -Filter "Destination='0.0.0.0'" -ErrorAction Stop |
             Sort-Object Metric1 | Select-Object -First 1
        if ($r) { return [pscustomobject]@{ NextHop = [string]$r.NextHop; InterfaceIndex = [int]$r.InterfaceIndex } }
    } catch { }
    return $null
}

function Get-ToolkitHistory {
    <#
        Ultimas ejecuciones del toolkit en este equipo, a partir de los logs
        (toolkit-<equipo>-<fecha>.log). Cada log es una sesion: se extraen el
        modo, los pasos (lineas STEP) y el codigo de salida si lo hubo.
        Solo lectura; lo usa el boton "Historial" de la GUI.
    #>
    [CmdletBinding()]
    param([string]$Root = $script:Root, [int]$Last = 60)

    $dir = Join-Path $Root 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $files = Get-ChildItem -LiteralPath $dir -Filter 'toolkit-*.log' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First $Last

    foreach ($f in $files) {
        $mode = ''; $user = ''; $exit = $null; $steps = New-Object System.Collections.ArrayList
        $errors = 0; $warns = 0
        try {
            foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
                if ($line -match '\|\s+modo:\s+(.+)$')                    { $mode = $Matches[1].Trim(); continue }
                if ($line -match 'Ejecutado por:\s+(\S+)')                 { $user = $Matches[1]; continue }
                if ($line -match '\[STEP \]\s+(?:--- )?(.+?)\s*-*$')       { [void]$steps.Add($Matches[1].Trim()); continue }
                if ($line -match 'Finalizado con codigo de salida (-?\d+)') { $exit = [int]$Matches[1]; continue }
                if ($line -match '\[ERROR\]') { $errors++ } elseif ($line -match '\[WARN \]') { $warns++ }
            }
        } catch { }
        # Sesion sin nada que contar (abrir la app y cerrarla): no aporta al historial.
        if ($steps.Count -eq 0 -and $null -eq $exit -and $errors -eq 0 -and $warns -eq 0) { continue }
        $stamp = $f.LastWriteTime
        if ($f.BaseName -match '(\d{8})-(\d{6})$') {
            try { $stamp = [datetime]::ParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmmss', $null) } catch { }
        }
        [pscustomobject]@{
            Date     = $stamp
            Mode     = $mode
            User     = $user
            Steps    = ($steps | Select-Object -Unique) -join ' · '
            ExitCode = $exit
            Errors   = $errors
            Warnings = $warns
            Path     = $f.FullName
        }
    }
}

function Get-PublicIpAddress {
    <#
        IP publica con la que sale el equipo a Internet (la que ve Zoho). Dos
        servicios por si uno falla; 5 s cada uno para no colgar el check-in.
    #>
    [CmdletBinding()]
    param()
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($url in 'https://api.ipify.org', 'https://checkip.amazonaws.com') {
        try {
            $ip = (Invoke-RestMethod -Uri $url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop).ToString().Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch { }
    }
    return $null
}

function Test-IpInList {
    <# $true si la IP esta en la lista: entradas sueltas (1.2.3.4) o rangos CIDR (1.2.3.0/24). #>
    param([Parameter(Mandatory)][string]$Ip, [string[]]$List)
    try { $addr = [Net.IPAddress]::Parse($Ip) } catch { return $false }
    $ipBits = [BitConverter]::ToUInt32(($addr.GetAddressBytes()[3..0]), 0)
    foreach ($entry in @($List | Where-Object { $_ })) {
        $e = "$entry".Trim()
        if ($e -notmatch '/') { if ($e -eq $Ip) { return $true }; continue }
        $net, $len = $e -split '/', 2
        try {
            $netBits = [BitConverter]::ToUInt32(([Net.IPAddress]::Parse($net).GetAddressBytes()[3..0]), 0)
            # 0xFFFFFFFF es Int32 (-1) en PowerShell: hay que operar en 64 bits y recortar.
            $mask = if ([int]$len -eq 0) { [uint32]0 } else { [uint32]((([uint64][uint32]::MaxValue) -shl (32 - [int]$len)) -band [uint64][uint32]::MaxValue) }
            if (($ipBits -band $mask) -eq ($netBits -band $mask)) { return $true }
        } catch { }
    }
    return $false
}

function Get-ToolkitVersion { return $script:Version }
function Get-ToolkitLogPath { return $script:LogPath }
function Test-ReportOnly    { return $script:ReportOnly }

#endregion

Export-ModuleMember -Function @(
    'Initialize-Toolkit', 'Write-Log', 'Write-Step',
    'Test-IsAdmin', 'Test-IsSystem',
    'Get-RegValue', 'Set-RegValue', 'Invoke-ToolkitRollback',
    'Add-Result', 'Get-Results', 'Get-MachineInfo', 'Save-Report',
    'Get-ResultSummary', 'Show-Summary', 'Get-ExitCode',
    'Set-RebootPending', 'Test-RebootPendingFlag',
    'Test-MaintenanceWindow', 'Get-ToolkitConfig',
    'Enter-ToolkitInstance', 'Exit-ToolkitInstance',
    'Get-ToolkitVersion', 'Get-ToolkitLogPath', 'Test-ReportOnly',
    'Set-ToolkitMode', 'Close-LogWriter', 'Get-PhysicalAdapter', 'Get-DefaultGateway',
    'Get-PublicIpAddress', 'Test-IpInList', 'Get-ToolkitHistory'
)
