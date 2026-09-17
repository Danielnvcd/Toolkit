<#
    Toolkit.Support.psm1
    Utilidades de soporte tecnico de primer nivel para el call center.

    Cada funcion es una accion de un clic desde la pestana "Soporte" de la GUI
    (o desde el menu de Toolkit.ps1). Todas usan SOLO lo que trae Windows
    10/11: nada de modulos externos, para que funcionen en cualquier equipo.

    Dos familias:
      - Get-* / Test-*   : diagnostico, no modifican nada.
      - Repair-* / Clear-* / Sync-* / Set-* / Enable-* : reparaciones rapidas.
        Escriben en el log lo que hacen; las de registro pasan por Set-RegValue
        y son reversibles con el rollback del toolkit.
#>

# Dependencia de Toolkit.Core (Write-Log, Set-RegValue, Get-RegValue, Get-MachineInfo...).
if (-not (Get-Command 'Write-Log' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking -Global
}

$script:ConsentStore   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:UserConsentSub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:RegPolAppPriv  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$script:RegProfileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

#region ---------- Diagnostico ----------

function Get-SupportSummary {
    <#
        Ficha del equipo en una pantalla: lo primero que pide cualquier ticket.
        Solo lectura.
    #>
    [CmdletBinding()]
    param()

    $mi = Get-MachineInfo
    $s = [ordered]@{
        Equipo        = $mi.ComputerName
        Fabricante    = $mi.Manufacturer
        Modelo        = $mi.Model
        NumeroSerie   = $mi.Serial
        SistemaOp     = "$($mi.OSCaption) $($mi.DisplayVersion) (build $($mi.OSVersion).$($mi.UBR))"
        Arquitectura  = $env:PROCESSOR_ARCHITECTURE
        Dominio       = $(if ($mi.PartOfDomain) { $mi.Domain } else { "$($mi.Domain) (grupo de trabajo)" })
        UsuarioSesion = $mi.LoggedOnUser
        IPv4          = ($mi.IPv4 -join ', ')
        CPU           = $null
        RAM_GB        = $null
        RAM_LibreGB   = $null
        Discos        = @()
        UltimoArranque= $null
        Encendido     = $null
        BIOS          = $null
        TPM           = $null
        SecureBoot    = $null
        Antivirus     = @()
    }

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $s.CPU = ('{0} ({1} nucleos / {2} hilos)' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $s.RAM_GB       = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $s.RAM_LibreGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $s.UltimoArranque = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
        $up = (Get-Date) - $os.LastBootUpTime
        $s.Encendido = ('{0} d {1} h {2} min' -f $up.Days, $up.Hours, $up.Minutes)
    } catch { }
    try {
        $s.Discos = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
            $free = [math]::Round($_.FreeSpace / 1GB, 1); $size = [math]::Round($_.Size / 1GB, 1)
            $pct  = if ($_.Size) { [math]::Round(100 * $_.FreeSpace / $_.Size) } else { 0 }
            [pscustomobject]@{ Unidad = $_.DeviceID; LibreGB = $free; TotalGB = $size; LibrePct = $pct }
        })
    } catch { }
    try {
        $b = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $s.BIOS = "$($b.SMBIOSBIOSVersion) ($($b.ReleaseDate.ToString('yyyy-MM-dd')))"
    } catch { }
    try {
        $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        $s.TPM = if ($tpm) { "presente, v$($tpm.SpecVersion.Split(',')[0])" } else { 'no' }
    } catch { $s.TPM = 'no detectado' }
    try { $s.SecureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'activo' } else { 'inactivo' } } catch { $s.SecureBoot = 'no disponible (BIOS legacy?)' }
    try {
        $s.Antivirus = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
                         ForEach-Object { $_.displayName })
    } catch { }

    Write-Log 'FICHA DEL EQUIPO' -Level STEP
    $fmt = '  {0,-16} {1}'
    foreach ($k in 'Equipo','Fabricante','Modelo','NumeroSerie','SistemaOp','Arquitectura','BIOS','TPM','SecureBoot','Dominio','UsuarioSesion','IPv4','CPU') {
        Write-Log ($fmt -f $k, $s[$k]) -Level INFO
    }
    Write-Log ($fmt -f 'RAM', "$($s.RAM_GB) GB total, $($s.RAM_LibreGB) GB libres") -Level $(if ($s.RAM_LibreGB -lt 1) { 'WARN' } else { 'INFO' })
    foreach ($d in $s.Discos) {
        Write-Log ($fmt -f "Disco $($d.Unidad)", "$($d.LibreGB) GB libres de $($d.TotalGB) GB ($($d.LibrePct) %)") -Level $(if ($d.LibrePct -lt 10) { 'WARN' } else { 'INFO' })
    }
    $longUptime = $false
    if ($s.UltimoArranque) { try { $longUptime = ((Get-Date) - [datetime]$s.UltimoArranque) -gt [timespan]::FromDays(14) } catch { } }
    Write-Log ($fmt -f 'Encendido', "$($s.Encendido)  (desde $($s.UltimoArranque))") -Level $(if ($longUptime) { 'WARN' } else { 'INFO' })
    if ($longUptime) { Write-Log '  ! Mas de 14 dias sin reiniciar: muchos "va lento" y fallos de audio se arreglan reiniciando.' -Level WARN }
    Write-Log ($fmt -f 'Antivirus', $(if ($s.Antivirus.Count) { $s.Antivirus -join ', ' } else { 'ninguno registrado' })) -Level INFO
    if ($s.RAM_LibreGB -lt 1)  { Write-Log '  ! Menos de 1 GB de RAM libre: el equipo ira lento; cerrar programas o reiniciar.' -Level WARN }
    foreach ($d in $s.Discos) { if ($d.LibrePct -lt 10) { Write-Log "  ! Disco $($d.Unidad) con menos del 10 % libre: usar 'Limpiar temporales'." -Level WARN } }

    return [pscustomobject]$s
}

function Test-AudioSetup {
    <#
        Audio: dispositivos, servicios y permisos de microfono/camara.
        El 80 % de los tickets "no me oyen / no oigo" del call center se
        resuelven mirando esto. Solo lectura.
    #>
    [CmdletBinding()]
    param()

    Write-Log 'AUDIO Y MICROFONO' -Level STEP
    $issues = @()

    # Servicios
    foreach ($svcName in 'Audiosrv', 'AudioEndpointBuilder') {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) { $issues += "Servicio $svcName no existe"; continue }
        if ($svc.Status -eq 'Running') { Write-Log "  + Servicio $svcName en ejecucion" -Level OK }
        else { $issues += "Servicio $svcName esta $($svc.Status)"; Write-Log "  x Servicio $svcName esta $($svc.Status)" -Level ERROR }
    }

    # Dispositivos de audio (tarjetas / USB)
    $cards = @()
    try { $cards = @(Get-CimInstance Win32_SoundDevice -ErrorAction Stop) } catch { }
    if ($cards.Count -eq 0) { $issues += 'No hay ningun dispositivo de sonido'; Write-Log '  x No se detecta ningun dispositivo de sonido' -Level ERROR }
    foreach ($c in $cards) {
        $ok = ($c.Status -eq 'OK')
        Write-Log ("  {0} {1,-45} {2}" -f $(if ($ok) { '+' } else { 'x' }), $c.Name, $c.Status) -Level $(if ($ok) { 'OK' } else { 'ERROR' })
        if (-not $ok) { $issues += "Dispositivo '$($c.Name)' en estado $($c.Status)" }
    }

    # Puntos finales (altavoces / microfonos tal como los ve Windows)
    $endpoints = @()
    try { $endpoints = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop) } catch { }
    $active = @($endpoints | Where-Object { $_.Status -eq 'OK' })
    if ($endpoints.Count -gt 0) {
        Write-Log ("  Puntos finales de audio: {0} activos de {1}" -f $active.Count, $endpoints.Count) -Level INFO
        foreach ($e in $active) { Write-Log ("    + {0}" -f $e.FriendlyName) -Level DEBUG }
        $mics = @($active | Where-Object { $_.FriendlyName -match 'Micr|Mic|Headset|Auricular|Diadema|Input|Entrada' })
        if ($mics.Count -eq 0) {
            $issues += 'No hay ningun microfono activo (diadema desconectada o deshabilitada?)'
            Write-Log '  ! No se ve ningun microfono activo. Revisar que la diadema este conectada y habilitada en Sonido > Entrada.' -Level WARN
        }
    }

    # Permisos de microfono y camara (Windows los corta igual que la ubicacion)
    foreach ($cap in 'microphone', 'webcam') {
        $label = if ($cap -eq 'microphone') { 'Microfono' } else { 'Camara' }
        $m  = Get-RegValue -Path "$($script:ConsentStore)\$cap"             -Name 'Value'
        $np = Get-RegValue -Path "$($script:ConsentStore)\$cap\NonPackaged" -Name 'Value'
        $pol = Get-RegValue -Path $script:RegPolAppPriv -Name $(if ($cap -eq 'microphone') { 'LetAppsAccessMicrophone' } else { 'LetAppsAccessCamera' })
        $okM = ($m -eq 'Allow' -or $null -eq $m); $okN = ($np -eq 'Allow' -or $null -eq $np)
        if ($pol -eq 2) { $issues += "Politica LetAppsAccess$label = 2 (denegado por directiva)"; Write-Log "  x $label bloqueado por directiva (LetAppsAccess = 2)" -Level ERROR }
        elseif ($okM -and $okN) { Write-Log "  + $label permitido a nivel de equipo (apps de escritorio incluidas)" -Level OK }
        else {
            $issues += "$label denegado a nivel de equipo (maquina: $m, escritorio: $np)"
            Write-Log "  x $label denegado a nivel de equipo (maquina: $m, escritorio: $np). Usa 'Permitir microfono y camara'." -Level ERROR
        }
        # Usuario con sesion (HKCU del que ejecuta; si es SYSTEM/otro admin no aplica)
        $u = Get-RegValue -Path "HKCU:\$($script:UserConsentSub)\$cap" -Name 'Value'
        if ($u -eq 'Deny') { $issues += "$label denegado para el usuario actual"; Write-Log "  x $label denegado para el usuario que ejecuta el toolkit" -Level ERROR }
    }

    if ($issues.Count -eq 0) { Write-Log '  [OK] Audio y permisos correctos' -Level OK }
    return [pscustomobject]@{ Ok = ($issues.Count -eq 0); Issues = $issues; Cards = $cards; Endpoints = $endpoints }
}

function Get-PrinterReport {
    <# Impresoras instaladas, predeterminada, estado y trabajos en cola. Solo lectura. #>
    [CmdletBinding()]
    param()

    Write-Log 'IMPRESORAS' -Level STEP
    $spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($spooler -and $spooler.Status -ne 'Running') { Write-Log "  x Servicio de cola de impresion (Spooler) esta $($spooler.Status)" -Level ERROR }
    elseif ($spooler) { Write-Log '  + Servicio Spooler en ejecucion' -Level OK }

    $printers = @()
    try { $printers = @(Get-CimInstance Win32_Printer -ErrorAction Stop) } catch { }
    if ($printers.Count -eq 0) { Write-Log '  (no hay impresoras instaladas)' -Level INFO }
    $out = @()
    foreach ($p in $printers) {
        $jobs = 0
        try { $jobs = @(Get-CimInstance Win32_PrintJob -ErrorAction Stop | Where-Object { $_.Name -like "$($p.Name),*" }).Count } catch { }
        $state = switch ($p.PrinterStatus) { 3 { 'Lista' } 4 { 'Imprimiendo' } 5 { 'Calentando' } 1 { 'Otro' } 2 { 'Desconocido' } 6 { 'Parada' } 7 { 'Sin conexion' } default { "estado $($p.PrinterStatus)" } }
        if ($p.WorkOffline) { $state = 'SIN CONEXION' }
        $flag = if ($p.Default) { '*' } else { ' ' }
        $lvl  = if ($p.WorkOffline -or $p.PrinterStatus -in 6,7 -or $jobs -gt 5) { 'WARN' } else { 'INFO' }
        Write-Log ("  {0} {1,-40} {2,-14} cola: {3,2}   puerto: {4}" -f $flag, $p.Name, $state, $jobs, $p.PortName) -Level $lvl
        $out += [pscustomobject]@{ Nombre = $p.Name; Predeterminada = [bool]$p.Default; Estado = $state; Trabajos = $jobs; Puerto = $p.PortName; Driver = $p.DriverName }
    }
    if ($printers.Count -gt 0) { Write-Log '  (* = predeterminada)' -Level DEBUG }
    return $out
}

function Get-UpdateStatus {
    <# Windows Update: ultimo parche, reinicio pendiente, estado del servicio. Solo lectura. #>
    [CmdletBinding()]
    param()

    Write-Log 'WINDOWS UPDATE' -Level STEP
    $r = [ordered]@{ UltimoParche = $null; UltimoParcheFecha = $null; UltimaInstalacionOK = $null; ReinicioPendiente = $false; Motivos = @(); Servicio = $null }

    try {
        $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) { $r.UltimoParche = $hf.HotFixID; $r.UltimoParcheFecha = $hf.InstalledOn.ToString('yyyy-MM-dd') }
    } catch { }
    $last = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' -Name 'LastSuccessTime'
    if ($last) { $r.UltimaInstalacionOK = $last }

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r.Motivos += 'Component Based Servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $r.Motivos += 'Windows Update' }
    $pfro = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    if ($pfro) { $r.Motivos += 'Archivos pendientes de renombrar' }
    $r.ReinicioPendiente = ($r.Motivos.Count -gt 0)

    $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($svc) { $r.Servicio = "$($svc.Status) / $($svc.StartType)" }

    Write-Log ("  Ultimo parche instalado : {0} ({1})" -f $r.UltimoParche, $r.UltimoParcheFecha) -Level INFO
    if ($r.UltimaInstalacionOK) { Write-Log ("  Ultima instalacion OK   : {0}" -f $r.UltimaInstalacionOK) -Level INFO }
    Write-Log ("  Servicio wuauserv       : {0}" -f $r.Servicio) -Level $(if ($svc -and $svc.StartType -eq 'Disabled') { 'WARN' } else { 'INFO' })
    if ($r.ReinicioPendiente) { Write-Log ("  ! REINICIO PENDIENTE ({0}). Muchos fallos raros se van reiniciando." -f ($r.Motivos -join ', ')) -Level WARN }
    else { Write-Log '  + Sin reinicio pendiente' -Level OK }
    if ($r.UltimoParcheFecha -and ((Get-Date) - [datetime]$r.UltimoParcheFecha).Days -gt 60) {
        Write-Log '  ! Mas de 60 dias sin parches. Usa "Buscar actualizaciones".' -Level WARN
    }
    return [pscustomobject]$r
}

function Get-TimeStatus {
    <# Hora, zona horaria y sincronizacion. Una hora desviada rompe TLS, el check-in y el inicio de sesion en dominio. #>
    [CmdletBinding()]
    param()

    Write-Log 'HORA DEL SISTEMA' -Level STEP
    $tz = $null; try { $tz = (Get-TimeZone).DisplayName } catch { }
    Write-Log ("  Hora local  : {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Level INFO
    Write-Log ("  Zona horaria: {0}" -f $tz) -Level INFO
    $svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') { Write-Log "  ! Servicio de hora (W32Time) esta $($svc.Status)" -Level WARN }

    $offset = $null; $source = $null
    try {
        $st = & w32tm.exe /query /status 2>&1 | Out-String
        if ($st -match '(?im)^\s*(Source|Origen)\s*:\s*(.+)$')                 { $source = $Matches[2].Trim() }
        if ($st -match '(?im)^\s*(Phase Offset|Desplazamiento de fase)\s*:\s*([-\d\.,]+)s') { $offset = [double]($Matches[2] -replace ',', '.') }
    } catch { }
    if ($source) { Write-Log ("  Fuente NTP  : {0}" -f $source) -Level $(if ($source -match 'Local CMOS|Free-running') { 'WARN' } else { 'INFO' }) }
    if ($null -ne $offset) {
        Write-Log ("  Desfase     : {0:N3} s" -f $offset) -Level $(if ([math]::Abs($offset) -gt 60) { 'ERROR' } elseif ([math]::Abs($offset) -gt 5) { 'WARN' } else { 'OK' })
        if ([math]::Abs($offset) -gt 60) { Write-Log '  x Mas de 1 minuto de desfase: usa "Sincronizar hora".' -Level ERROR }
    } else {
        Write-Log '  ! No se pudo leer el desfase (equipo sin sincronizar nunca?). Usa "Sincronizar hora".' -Level WARN
    }
    return [pscustomobject]@{ Hora = (Get-Date); ZonaHoraria = $tz; Fuente = $source; DesfaseSeg = $offset }
}

function Get-RecentErrors {
    <#
        Errores y fallos criticos del registro de eventos (Sistema y Aplicacion)
        en las ultimas horas, agrupados por origen. Es donde se ve "por que se
        reinicio solo", "por que se cerro el softphone" o un disco que falla.
    #>
    [CmdletBinding()]
    param([int]$Hours = 24, [int]$Top = 15)

    Write-Log ("EVENTOS DE ERROR (ultimas {0} h)" -f $Hours) -Level STEP
    $since = (Get-Date).AddHours(-$Hours)
    $events = @()
    foreach ($log in 'System', 'Application') {
        try {
            # -MaxEvents: un equipo con un servicio en bucle genera miles de errores por hora; con 1000 sobra para agrupar por origen.
            $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2; StartTime = $since } -MaxEvents 1000 -ErrorAction Stop |
                         Select-Object TimeCreated, LogName, ProviderName, Id, LevelDisplayName, Message)
        } catch { }   # sin eventos = Get-WinEvent lanza excepcion; no es un error
    }
    if ($events.Count -eq 0) { Write-Log '  + Sin errores ni eventos criticos en el periodo' -Level OK; return @() }

    # Apagados inesperados y reinicios: lo primero que hay que saber.
    $unexpected = @($events | Where-Object { $_.Id -in 41, 6008, 1001 -and $_.ProviderName -match 'Kernel-Power|EventLog|BugCheck' })
    foreach ($u in $unexpected) {
        Write-Log ("  x {0:yyyy-MM-dd HH:mm}  APAGADO INESPERADO / PANTALLAZO ({1} {2})" -f $u.TimeCreated, $u.ProviderName, $u.Id) -Level ERROR
    }
    $disk = @($events | Where-Object { $_.ProviderName -match '^disk$|Ntfs|volmgr|storahci|stornvme' })
    if ($disk.Count -gt 0) { Write-Log ("  x {0} evento(s) de DISCO/NTFS: revisar el disco (chkdsk, SMART) antes de nada" -f $disk.Count) -Level ERROR }

    $groups = $events | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First $Top
    Write-Log ("  {0} evento(s) en total; los {1} origenes mas repetidos:" -f $events.Count, $groups.Count) -Level INFO
    foreach ($g in $groups) {
        $e = $g.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
        $msg = if ($e.Message) { ($e.Message -split "`r?`n")[0] } else { '' }
        if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 90) + '...' }
        Write-Log ("  {0,3}x  {1,-11} {2,-32} {3,6}  {4}" -f $g.Count, $e.LogName, $e.ProviderName, $e.Id, $msg) -Level $(if ($e.LevelDisplayName -match 'Cr') { 'ERROR' } else { 'WARN' })
    }
    return $events
}

function Get-TopProcesses {
    <# Procesos que mas CPU y memoria consumen ahora mismo. Para el "va lento" con el agente al telefono. #>
    [CmdletBinding()]
    param([int]$Top = 10)

    Write-Log 'PROCESOS QUE MAS CONSUMEN' -Level STEP
    # CPU: dos muestras separadas 2 s (Get-Process solo da CPU acumulada).
    $s1 = @{}; Get-Process | ForEach-Object { try { $s1[$_.Id] = $_.CPU } catch { } }
    Start-Sleep -Seconds 2
    $cores = [Environment]::ProcessorCount
    $rows = @()
    foreach ($p in Get-Process) {
        $cpuPct = 0
        try { if ($s1.ContainsKey($p.Id) -and $null -ne $p.CPU) { $cpuPct = [math]::Round(100 * ($p.CPU - $s1[$p.Id]) / 2 / $cores, 1) } } catch { }
        $rows += [pscustomobject]@{ Proceso = $p.ProcessName; PID = $p.Id; CpuPct = [math]::Max(0, $cpuPct); MemMB = [math]::Round($p.WorkingSet64 / 1MB); Titulo = $p.MainWindowTitle }
    }
    Write-Log '  Por CPU:' -Level INFO
    foreach ($r in ($rows | Sort-Object CpuPct -Descending | Select-Object -First $Top)) {
        Write-Log ("    {0,5:N1} %  {1,7} MB  {2,-28} {3}" -f $r.CpuPct, $r.MemMB, $r.Proceso, $r.Titulo) -Level $(if ($r.CpuPct -gt 50) { 'WARN' } else { 'INFO' })
    }
    Write-Log '  Por memoria:' -Level INFO
    foreach ($r in ($rows | Sort-Object MemMB -Descending | Select-Object -First $Top)) {
        Write-Log ("    {0,7} MB  {1,5:N1} %  {2,-28} {3}" -f $r.MemMB, $r.CpuPct, $r.Proceso, $r.Titulo) -Level $(if ($r.MemMB -gt 2048) { 'WARN' } else { 'INFO' })
    }
    $total = ($rows | Measure-Object MemMB -Sum).Sum
    Write-Log ("  {0} procesos, {1:N0} MB en uso" -f $rows.Count, $total) -Level INFO
    return $rows | Sort-Object CpuPct -Descending
}

#endregion

#region ---------- Reparaciones rapidas ----------

function Restart-ComputerDelayed {
    <#
        Reinicio con aviso: el agente ve un mensaje de Windows con cuenta atras y
        puede guardar. Se cancela con -Cancel (shutdown /a) mientras no haya vencido.
    #>
    [CmdletBinding()]
    param([int]$Seconds = 60, [string]$Message = 'Toolkit BPO: el equipo se reiniciara por mantenimiento. Guarda tu trabajo.', [switch]$Cancel)

    if ($Cancel) {
        & shutdown.exe /a 2>&1 | Out-Null
        Write-Log $(if ($LASTEXITCODE -eq 0) { '  + Reinicio cancelado' } else { '  = No habia ningun reinicio programado' }) -Level $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'INFO' })
        return ($LASTEXITCODE -eq 0)
    }
    Write-Log ("REINICIAR EQUIPO en {0} s" -f $Seconds) -Level STEP
    & shutdown.exe /r /t $Seconds /c "$Message" /d p:4:1 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Log "  + Reinicio programado en $Seconds s. El usuario ve el aviso. Cancelar: shutdown /a" -Level OK; return $true }
    Write-Log "  x shutdown devolvio $LASTEXITCODE (ya habia uno programado? usa 'cancelar' primero)" -Level ERROR
    return $false
}

function Repair-Network {
    <#
        Reparacion de red suave: vacia DNS, renueva DHCP y comprueba puerta de
        enlace e Internet. No requiere reinicio. -Deep anade reset de Winsock
        y de la pila IP (eso SI requiere reiniciar).
    #>
    [CmdletBinding()]
    param([switch]$Deep)

    Write-Log 'REPARAR RED' -Level STEP
    try { Clear-DnsClientCache -ErrorAction Stop; Write-Log '  + Cache DNS vaciada' -Level OK } catch { & ipconfig.exe /flushdns | Out-Null; Write-Log '  + Cache DNS vaciada (ipconfig)' -Level OK }
    & ipconfig.exe /registerdns 2>&1 | Out-Null

    $dhcp = @()
    try { $dhcp = @(Get-NetIPInterface -AddressFamily IPv4 -Dhcp Enabled -ConnectionState Connected -ErrorAction Stop) } catch { }
    if ($dhcp.Count -gt 0) {
        Write-Log ("  Renovando DHCP en: {0}" -f (($dhcp | ForEach-Object { $_.InterfaceAlias }) -join ', ')) -Level INFO
        & ipconfig.exe /release 2>&1 | Out-Null
        & ipconfig.exe /renew   2>&1 | Out-Null
        Start-Sleep -Seconds 2
        Write-Log '  + Direccion IP renovada' -Level OK
    } else {
        Write-Log '  = Sin interfaces DHCP conectadas (IP fija o sin cable): no se renueva' -Level DEBUG
    }

    if ($Deep) {
        Write-Log '  Reset profundo: Winsock + pila TCP/IP (requiere reiniciar el equipo)' -Level WARN
        & netsh.exe winsock reset      2>&1 | Out-Null
        & netsh.exe int ip reset       2>&1 | Out-Null
        & netsh.exe int ipv6 reset     2>&1 | Out-Null
        Set-RebootPending
        Write-Log '  + Winsock y TCP/IP restablecidos. REINICIA el equipo para completar.' -Level OK
    }

    # Comprobacion final
    $ok = $true
    $gw = $null
    try { $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch { }
    if ($gw) {
        $p = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
        Write-Log ("  {0} Puerta de enlace {1}: {2}" -f $(if ($p) { '+' } else { 'x' }), $gw, $(if ($p) { 'responde' } else { 'NO responde' })) -Level $(if ($p) { 'OK' } else { 'ERROR' })
        if (-not $p) { $ok = $false }
    } else { Write-Log '  x Sin puerta de enlace: el equipo no tiene red (cable/Wi-Fi?)' -Level ERROR; $ok = $false }
    try {
        $null = [Net.Dns]::GetHostAddresses('www.microsoft.com')
        Write-Log '  + DNS resuelve nombres de Internet' -Level OK
    } catch { Write-Log "  x DNS no resuelve: $($_.Exception.Message)" -Level ERROR; $ok = $false }
    $ip = @(); try { $ip = @((Get-MachineInfo).IPv4) } catch { }
    Write-Log ("  IP actual: {0}" -f $(if ($ip.Count) { $ip -join ', ' } else { 'ninguna' })) -Level INFO
    return $ok
}

function Restart-SupportService {
    <# Reinicia un servicio y espera a que vuelva. Para audio, cola de impresion, Windows Update... #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSeconds = 30)

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log "  x El servicio '$Name' no existe" -Level ERROR; return $false }
    Write-Log ("  Reiniciando {0} ({1})..." -f $svc.DisplayName, $Name) -Level INFO
    try {
        if ($svc.StartType -eq 'Disabled') { Set-Service -Name $Name -StartupType Manual -ErrorAction Stop; Write-Log '    (estaba deshabilitado: puesto en Manual)' -Level WARN }
        Restart-Service -Name $Name -Force -ErrorAction Stop
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($TimeoutSeconds))
        Write-Log "  + $($svc.DisplayName) en ejecucion" -Level OK
        return $true
    } catch {
        Write-Log "  x No se pudo reiniciar $Name : $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Restart-AudioServices {
    <# El clasico "se me fue el audio": reinicia el generador de puntos finales y el servicio de audio. #>
    [CmdletBinding()]
    param()
    Write-Log 'REINICIAR AUDIO' -Level STEP
    $ok = Restart-SupportService -Name 'AudioEndpointBuilder'
    $ok = (Restart-SupportService -Name 'Audiosrv') -and $ok
    if ($ok) { Write-Log '  Listo. Si sigue sin oirse, desconecta y vuelve a conectar la diadema.' -Level INFO }
    return $ok
}

function Clear-PrintQueue {
    <# Trabajos atascados: para el Spooler, borra la cola en disco y lo arranca. #>
    [CmdletBinding()]
    param()
    Write-Log 'LIMPIAR COLA DE IMPRESION' -Level STEP
    $dir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
    try {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        (Get-Service Spooler).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)
        $files | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Log ("  + {0} archivo(s) de cola eliminados" -f $files.Count) -Level OK
    } catch {
        Write-Log "  x $($_.Exception.Message)" -Level ERROR
    } finally {
        try { Start-Service -Name Spooler -ErrorAction Stop; Write-Log '  + Spooler arrancado' -Level OK } catch { Write-Log "  x No arranca el Spooler: $($_.Exception.Message)" -Level ERROR }
    }
}

function Sync-SystemTime {
    <# Fuerza la sincronizacion de hora con la fuente configurada (dominio o time.windows.com). #>
    [CmdletBinding()]
    param()
    Write-Log 'SINCRONIZAR HORA' -Level STEP
    $svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        try { if ($svc.StartType -eq 'Disabled') { Set-Service W32Time -StartupType Manual }; Start-Service W32Time -ErrorAction Stop; Write-Log '  + Servicio W32Time arrancado' -Level OK }
        catch { Write-Log "  x No arranca W32Time: $($_.Exception.Message)" -Level ERROR; return $false }
    }
    $before = Get-Date
    $out = & w32tm.exe /resync /force 2>&1 | Out-String
    $ok = ($out -match 'correctamente|successfully|completed')
    if ($ok) { Write-Log ("  + Hora sincronizada. Antes: {0}  Ahora: {1}" -f $before.ToString('HH:mm:ss'), (Get-Date).ToString('HH:mm:ss')) -Level OK }
    else {
        Write-Log ("  x w32tm: {0}" -f $out.Trim()) -Level ERROR
        Write-Log '  Si el equipo no esta en dominio, prueba: w32tm /config /manualpeerlist:time.windows.com /syncfromflags:manual /update' -Level INFO
    }
    Get-TimeStatus | Out-Null
    return $ok
}

function Clear-TempFiles {
    <#
        Libera espacio sin riesgo: temporales de todos los perfiles y de Windows
        (solo archivos de mas de 1 dia, para no romper instalaciones en curso)
        y papelera de reciclaje. Devuelve MB liberados.
    #>
    [CmdletBinding()]
    param([int]$OlderThanDays = 1)

    Write-Log 'LIMPIAR TEMPORALES' -Level STEP
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $targets = @(Join-Path $env:SystemRoot 'Temp')
    $targets += @(Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } | Where-Object { Test-Path -LiteralPath $_ })

    $bytes = 0L; $count = 0; $locked = 0
    foreach ($t in $targets) {
        $files = @(Get-ChildItem -LiteralPath $t -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
        $freed = 0L; $n = 0
        foreach ($f in $files) {
            try { $len = $f.Length; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += $len; $n++ } catch { $locked++ }
        }
        # Carpetas que quedaron vacias
        Get-ChildItem -LiteralPath $t -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        if ($n -gt 0) { Write-Log ("  + {0,-55} {1,4} archivos, {2,7:N1} MB" -f $t, $n, ($freed / 1MB)) -Level OK }
        $bytes += $freed; $count += $n
    }
    try { Clear-RecycleBin -Force -ErrorAction Stop; Write-Log '  + Papelera de reciclaje vaciada' -Level OK } catch { }

    $mb = [math]::Round($bytes / 1MB, 1)
    Write-Log ("  Total: {0} archivos, {1} MB liberados{2}" -f $count, $mb, $(if ($locked) { " ($locked en uso, omitidos)" } else { '' })) -Level INFO
    return $mb
}

function Enable-MediaConsent {
    <#
        Permite microfono y camara para el equipo, las apps de escritorio y TODOS
        los perfiles de usuario. Mismo mecanismo que la ubicacion: sin esto el
        softphone o Zoho en el navegador "no encuentran" el microfono.
        Pasa por Set-RegValue: reversible con el rollback.
    #>
    [CmdletBinding()]
    param([string[]]$Capabilities = @('microphone', 'webcam'))

    Write-Log 'PERMITIR MICROFONO Y CAMARA' -Level STEP
    $changed = 0
    foreach ($cap in $Capabilities) {
        if (Set-RegValue -Path "$($script:ConsentStore)\$cap"             -Name 'Value' -Value 'Allow' -Type String) { $changed++ }
        if (Set-RegValue -Path "$($script:ConsentStore)\$cap\NonPackaged" -Name 'Value' -Value 'Allow' -Type String) { $changed++ }
        $polName = if ($cap -eq 'microphone') { 'LetAppsAccessMicrophone' } else { 'LetAppsAccessCamera' }
        if ((Get-RegValue -Path $script:RegPolAppPriv -Name $polName) -eq 2) {
            # 2 = forzar denegar: es lo unico que hay que tocar; se deja en "el usuario decide".
            if (Set-RegValue -Path $script:RegPolAppPriv -Name $polName -Value 0 -Type DWord) { $changed++ }
        }
    }
    $changed += Invoke-ForEachUserHive -Action {
        param($HiveRoot, $Account)
        $n = 0
        foreach ($cap in $Capabilities) {
            if (Set-RegValue -Path "$HiveRoot\$($script:UserConsentSub)\$cap"             -Name 'Value' -Value 'Allow' -Type String) { $n++ }
            if (Set-RegValue -Path "$HiveRoot\$($script:UserConsentSub)\$cap\NonPackaged" -Name 'Value' -Value 'Allow' -Type String) { $n++ }
        }
        if ($n -gt 0) { Write-Log "  + $Account : $n ajuste(s)" -Level OK }
        return $n
    }
    if ($changed -eq 0) { Write-Log '  = Todo estaba ya permitido' -Level OK }
    else { Write-Log "  + $changed ajuste(s) aplicados. Las apps abiertas pueden necesitar cerrarse y abrirse." -Level OK }
    return $changed
}

function Set-NoSleepPower {
    <#
        Evita que el equipo se suspenda o apague la pantalla en mitad del turno
        (con corriente). En bateria no se toca. No pasa por el registro: para
        revertirlo, powercfg /change standby-timeout-ac <minutos>.
    #>
    [CmdletBinding()]
    param([int]$MonitorMinutes = 15)

    Write-Log 'ENERGIA: NO SUSPENDER' -Level STEP
    $cmds = @(
        @('/change', 'standby-timeout-ac', '0'),
        @('/change', 'hibernate-timeout-ac', '0'),
        @('/change', 'monitor-timeout-ac', "$MonitorMinutes"),
        @('/change', 'disk-timeout-ac', '0')
    )
    foreach ($c in $cmds) { & powercfg.exe @c 2>&1 | Out-Null }
    & powercfg.exe /hibernate off 2>&1 | Out-Null
    Write-Log "  + Con corriente: nunca se suspende ni hiberna; la pantalla se apaga a los $MonitorMinutes min" -Level OK
    Write-Log '  + Hibernacion desactivada (libera hiberfil.sys, varios GB)' -Level OK
    return $true
}

function Start-UpdateScan {
    <# Pide a Windows Update que busque e instale. No bloquea: el progreso se ve en Configuracion. #>
    [CmdletBinding()]
    param()
    Write-Log 'BUSCAR ACTUALIZACIONES' -Level STEP
    $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($svc -and $svc.StartType -eq 'Disabled') { Set-Service wuauserv -StartupType Manual; Write-Log '  (wuauserv estaba deshabilitado: puesto en Manual)' -Level WARN }
    $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
    if (-not (Test-Path $uso)) { Write-Log '  x UsoClient.exe no existe en este Windows' -Level ERROR; return $false }
    foreach ($a in 'StartScan', 'StartDownload', 'StartInstall') { Start-Process -FilePath $uso -ArgumentList $a -WindowStyle Hidden -Wait }
    Write-Log '  + Busqueda, descarga e instalacion solicitadas. Ver progreso en Configuracion > Windows Update.' -Level OK
    return $true
}

function Repair-SystemFiles {
    <#
        sfc /scannow: repara archivos de sistema corruptos. Tarda entre 5 y 20
        minutos. Si SFC no puede, el siguiente paso es DISM /RestoreHealth
        (-Dism), que tarda aun mas y necesita Internet.
    #>
    [CmdletBinding()]
    param([switch]$Dism)

    Write-Log 'REPARAR ARCHIVOS DEL SISTEMA' -Level STEP
    if ($Dism) {
        Write-Log '  DISM /Online /Cleanup-Image /RestoreHealth (10-30 min)...' -Level INFO
        $d = & DISM.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String
        $line = ($d -split "`r?`n" | Where-Object { $_ -match 'correctamente|successfully|Error|error' } | Select-Object -Last 1)
        Write-Log "  DISM: $line" -Level $(if ($line -match 'correctamente|successfully') { 'OK' } else { 'WARN' })
    }
    Write-Log '  sfc /scannow (5-20 min, no cierres la ventana)...' -Level INFO
    # La salida de sfc es UTF-16 con caracteres nulos entre letras: se limpian.
    $raw = & sfc.exe /scannow 2>&1 | Out-String
    $txt = ($raw -replace "`0", '')
    $summary = ($txt -split "`r?`n" | Where-Object { $_ -match 'integrity|integridad' } | Select-Object -Last 1)
    if (-not $summary) { $summary = ($txt -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) }
    $ok = ($summary -match 'did not find|no encontr|successfully repaired|reparado correctamente')
    Write-Log "  SFC: $($summary.Trim())" -Level $(if ($ok) { 'OK' } else { 'WARN' })
    if (-not $ok) { Write-Log '  Detalle en C:\Windows\Logs\CBS\CBS.log. Si SFC no pudo reparar, ejecuta con DISM y repite.' -Level INFO }
    return $ok
}

#endregion

#region ---------- Reporte ----------

function Export-SupportReport {
    <#
        Reporte de texto con todo lo que pide un ticket de escalado, guardado en
        <Root>\reports. Devuelve la ruta.
    #>
    [CmdletBinding()]
    param([string]$Root = 'C:\ProgramData\Toolkit')

    Write-Log 'REPORTE PARA TICKET' -Level STEP
    $dir = Join-Path $Root 'reports'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir ('soporte-{0}-{1}.txt' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))

    $sb = New-Object Text.StringBuilder
    $add = { param($title, $obj)
        [void]$sb.AppendLine(('=' * 78)); [void]$sb.AppendLine("  $title"); [void]$sb.AppendLine(('=' * 78))
        [void]$sb.AppendLine((($obj | Format-List * | Out-String -Width 120).Trim())); [void]$sb.AppendLine()
    }
    [void]$sb.AppendLine("TOOLKIT BPO - REPORTE DE SOPORTE   $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$sb.AppendLine()
    & $add 'EQUIPO'          (Get-SupportSummary)
    & $add 'AUDIO'           (Test-AudioSetup | Select-Object Ok, @{n='Issues';e={$_.Issues -join '; '}})
    & $add 'IMPRESORAS'      (Get-PrinterReport)
    & $add 'WINDOWS UPDATE'  (Get-UpdateStatus)
    & $add 'HORA'            (Get-TimeStatus)
    & $add 'ERRORES 24 H'    (Get-RecentErrors | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 Count, Name)
    & $add 'PROCESOS'        (Get-TopProcesses | Select-Object -First 10 Proceso, PID, CpuPct, MemMB)
    if (Get-Command Test-LocationState -ErrorAction SilentlyContinue) {
        & $add 'UBICACION' (Test-LocationState | Select-Object Compliant, @{n='Issues';e={$_.Issues -join '; '}}, ServiceStatus, MasterSwitch, ConsentMachine, ConsentNonPackaged)
    }
    if (Get-Command Get-LocalUserInventory -ErrorAction SilentlyContinue) {
        & $add 'USUARIOS LOCALES' (Get-LocalUserInventory | Select-Object Name, Enabled, IsAdmin, PasswordRequired, LastLogon)
    }
    [void]$sb.AppendLine(('=' * 78)); [void]$sb.AppendLine('  RED (ipconfig /all)'); [void]$sb.AppendLine(('=' * 78))
    [void]$sb.AppendLine((& ipconfig.exe /all 2>&1 | Out-String))

    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    Write-Log "  + Reporte guardado: $path" -Level OK
    return $path
}

#endregion

#region ---------- Interno ----------

function Invoke-ForEachUserHive {
    <#
        Ejecuta -Action {param($HiveRoot, $Account)} sobre la colmena HKU de cada
        perfil real del equipo (cargando temporalmente las de usuarios sin sesion)
        y sobre el perfil Default. Suma lo que devuelva cada llamada.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)

    if (-not (Get-PSDrive -Name 'HKU' -ErrorAction SilentlyContinue)) {
        $null = New-PSDrive -Name 'HKU' -PSProvider Registry -Root 'HKEY_USERS' -Scope Global -ErrorAction SilentlyContinue
    }
    $total = 0
    $profiles = @()
    try { $profiles = @(Get-ChildItem -LiteralPath $script:RegProfileList -ErrorAction Stop | Where-Object { $_.PSChildName -match '^S-1-5-21-\d+' }) } catch { return 0 }

    $targets = @()
    foreach ($p in $profiles) {
        $path = $null; try { $path = (Get-ItemProperty -LiteralPath $p.PSPath -ErrorAction Stop).ProfileImagePath } catch { }
        if ($path) { $targets += @{ Key = $p.PSChildName; Dat = (Join-Path $path 'NTUSER.DAT'); Account = (Split-Path $path -Leaf) } }
    }
    $targets += @{ Key = 'ToolkitDefault'; Dat = (Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'); Account = '(perfil Default)' }

    foreach ($t in $targets) {
        $loaded = Test-Path -LiteralPath "HKU:\$($t.Key)"
        $temp = $false
        if (-not $loaded) {
            if (-not (Test-Path -LiteralPath $t.Dat)) { continue }
            if (Test-ReportOnly) { continue }
            $null = & reg.exe load "HKU\$($t.Key)" "$($t.Dat)" 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "  ! No se pudo cargar el perfil de $($t.Account) (en uso?)" -Level WARN; continue }
            $temp = $true
        }
        try { $total += [int](& $Action "HKU:\$($t.Key)" $t.Account) }
        catch { Write-Log "  x $($t.Account): $($_.Exception.Message)" -Level ERROR }
        finally {
            if ($temp) {
                [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300
                $null = & reg.exe unload "HKU\$($t.Key)" 2>&1
            }
        }
    }
    return $total
}

#endregion

Export-ModuleMember -Function @(
    'Get-SupportSummary', 'Test-AudioSetup', 'Get-PrinterReport', 'Get-UpdateStatus', 'Get-TimeStatus',
    'Get-RecentErrors', 'Get-TopProcesses',
    'Repair-Network', 'Restart-SupportService', 'Restart-AudioServices', 'Clear-PrintQueue', 'Sync-SystemTime',
    'Clear-TempFiles', 'Enable-MediaConsent', 'Set-NoSleepPower', 'Start-UpdateScan', 'Repair-SystemFiles',
    'Restart-ComputerDelayed', 'Export-SupportReport'
)
