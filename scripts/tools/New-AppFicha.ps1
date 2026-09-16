<#
.SYNOPSIS
    Genera la ficha de una aplicacion a partir de su instalador real.

.DESCRIPTION
    Es la herramienta que desbloquea el modulo de aplicaciones.

    El catalogo no se rellena a mano ni a ojo: se apunta a un instalador real,
    este script lo inspecciona y emite el bloque JSON listo para pegar en
    catalog.json, mas la ficha en markdown para docs\APP-FICHAS\.

    Que extrae:
      MSI  -> ProductCode (GUID exacto), ProductName, ProductVersion, fabricante
              y la lista de propiedades publicas que admite (SERVER, COMPANYKEY...)
      EXE  -> tipo de empaquetador (Inno / NSIS / InstallShield / WiX burn / 7z SFX)
              y, con el, el conmutador silencioso correcto
      Ambos-> SHA-256, que es obligatorio en el catalogo

.PARAMETER Path
    Ruta al instalador (.msi o .exe).

.PARAMETER Id
    Identificador corto para el catalogo. Por defecto se deriva del nombre.

.EXAMPLE
    .\New-AppFicha.ps1 -Path 'D:\instaladores\NetExtender.msi' -Id netextender

.EXAMPLE
    .\New-AppFicha.ps1 -Path '.\GoToResolve.msi' -Id goto -OutputDir ..\..\docs\APP-FICHAS

.NOTES
    Ejecutar en Windows. El analisis de MSI usa el COM de Windows Installer.
    Aun asi: SIEMPRE probar la instalacion real en una maquina virtual limpia
    antes de poner enabled=true. Este script reduce la adivinanza, no la elimina.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Id,
    [string]$OutputDir,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { throw "No existe el instalador: $Path" }
$file = Get-Item -LiteralPath $Path
if (-not $Id) { $Id = ($file.BaseName -replace '[^\w]', '').ToLower() }

function Write-Info { param($m, $c = 'Gray') if (-not $Quiet) { Write-Host $m -ForegroundColor $c } }

Write-Info ''
Write-Info ("Analizando: {0}  ({1} MB)" -f $file.Name, [math]::Round($file.Length / 1MB, 1)) 'Cyan'

# ---------------------------------------------------------------------------
#  SHA-256 (obligatorio en el catalogo)
# ---------------------------------------------------------------------------
$sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
Write-Info "  SHA-256 : $sha" 'DarkGray'

# ---------------------------------------------------------------------------
#  Firma Authenticode del instalador
# ---------------------------------------------------------------------------
$publisher = ''
try {
    $sig = Get-AuthenticodeSignature -LiteralPath $file.FullName
    if ($sig.Status -eq 'Valid') {
        $publisher = ($sig.SignerCertificate.Subject -replace '^CN=([^,]+).*', '$1')
        Write-Info "  Firmado : $publisher" 'Green'
    } else {
        Write-Info "  Firma   : $($sig.Status) -- instalador SIN firma valida, verificar origen" 'Yellow'
    }
} catch { }

# ---------------------------------------------------------------------------
#  Analisis segun tipo
# ---------------------------------------------------------------------------
$info = [ordered]@{
    InstallerType = 'exe'
    ProductName   = $file.BaseName
    ProductVersion= ''
    ProductCode   = ''
    Manufacturer  = $publisher
    SilentArgs    = ''
    Properties    = @()
    DetectMethod  = 'uninstall'
    Notes         = @()
}

if ($file.Extension -ieq '.msi') {
    $info.InstallerType = 'msi'
    $info.SilentArgs    = '/qn /norestart'
    $info.DetectMethod  = 'productCode'

    function Get-MsiProperty {
        param($Database, [string]$Name)
        try {
            $view = $Database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $Database,
                    @("SELECT Value FROM Property WHERE Property='$Name'"))
            $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($rec) { return $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
        } catch { }
        return ''
    }

    $wi = $null
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($file.FullName, 0))

        $info.ProductCode    = Get-MsiProperty $db 'ProductCode'
        $info.ProductName    = Get-MsiProperty $db 'ProductName'
        $info.ProductVersion = Get-MsiProperty $db 'ProductVersion'
        $m                   = Get-MsiProperty $db 'Manufacturer'
        if ($m) { $info.Manufacturer = $m }

        Write-Info ''
        Write-Info '  --- MSI ---' 'White'
        Write-Info ("  Producto    : {0}" -f $info.ProductName)
        Write-Info ("  Version     : {0}" -f $info.ProductVersion)
        Write-Info ("  ProductCode : {0}" -f $info.ProductCode) 'Green'
        Write-Info ("  Fabricante  : {0}" -f $info.Manufacturer)

        # Propiedades publicas = las que se pueden pasar en la linea de comandos.
        # Aqui es donde aparecen SERVER, COMPANYKEY, LICENSEKEY y demas.
        try {
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db,
                    @("SELECT Property FROM Property"))
            $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            while ($true) {
                $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if (-not $rec) { break }
                $name = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
                # Publicas: todo en mayusculas y no reservadas de Windows Installer
                if ($name -cmatch '^[A-Z][A-Z0-9_]+$' -and
                    $name -notin @('ALLUSERS','ARPCOMMENTS','ARPCONTACT','ARPHELPLINK','ARPNOMODIFY',
                                   'ARPNOREMOVE','ARPNOREPAIR','ARPPRODUCTICON','ARPSIZE','ARPURLINFOABOUT',
                                   'ARPURLUPDATEINFO','REBOOT','REINSTALLMODE','INSTALLLEVEL','LIMITUI',
                                   'MSIFASTINSTALL','SECURECUSTOMPROPERTIES','UPGRADECODE','MSIRESTARTMANAGERCONTROL')) {
                    $info.Properties += $name
                }
            }
        } catch { }

        if ($info.Properties.Count -gt 0) {
            Write-Info ''
            Write-Info '  Propiedades publicas admitidas (candidatas a configuracion):' 'Yellow'
            foreach ($prop in ($info.Properties | Sort-Object -Unique)) { Write-Info "    $prop" 'Yellow' }
            $info.Notes += 'Revisar las propiedades publicas listadas: ahi suelen estar el servidor, la clave de empresa o el token de despliegue.'
        }
    } catch {
        Write-Info "  ! No se pudo abrir el MSI: $($_.Exception.Message)" 'Red'
        $info.Notes += 'No se pudo leer el MSI. Ejecutar este script en Windows con permisos suficientes.'
    } finally {
        if ($wi) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wi) }
    }
}
else {
    # --- EXE: identificar el empaquetador para acertar con el conmutador ---
    try { $info.ProductVersion = $file.VersionInfo.ProductVersion } catch { }
    try { if ($file.VersionInfo.ProductName) { $info.ProductName = $file.VersionInfo.ProductName } } catch { }

    # Se leen los primeros MB en busca de firmas conocidas del empaquetador.
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $probe = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min($bytes.Length, 6MB))

    $detected = $null
    if     ($probe -match 'Inno Setup')                  { $detected = 'inno' }
    elseif ($probe -match 'Nullsoft\.NSIS|NullsoftInst') { $detected = 'nsis' }
    elseif ($probe -match 'InstallShield')               { $detected = 'installshield' }
    elseif ($probe -match 'WixBundle|Burn\.')            { $detected = 'wix-burn' }
    elseif ($probe -match '7-Zip|7zS\.sfx')              { $detected = '7zsfx' }

    $switches = @{
        'inno'          = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        'nsis'          = '/S'
        'installshield' = '/s /v"/qn /norestart"'
        'wix-burn'      = '/quiet /norestart'
        '7zsfx'         = '/S'
    }

    Write-Info ''
    Write-Info '  --- EXE ---' 'White'
    Write-Info ("  Producto : {0}" -f $info.ProductName)
    Write-Info ("  Version  : {0}" -f $info.ProductVersion)

    if ($detected) {
        $info.SilentArgs = $switches[$detected]
        Write-Info ("  Empaquetador : {0}" -f $detected) 'Green'
        Write-Info ("  Conmutador   : {0}" -f $info.SilentArgs) 'Green'
        $info.Notes += "Empaquetador detectado: $detected. CONFIRMAR el conmutador ejecutandolo a mano en una maquina virtual."
    } else {
        Write-Info '  Empaquetador : NO IDENTIFICADO' 'Red'
        $info.Notes += 'BLOQUEANTE: empaquetador no identificado. Probar a mano /?, /help, /S, /silent, /quiet antes de activar la app en el catalogo.'
    }

    if ($detected -eq 'installshield') {
        $info.Notes += 'InstallShield admite grabar un archivo de respuesta: setup.exe /r /f1"C:\\setup.iss" y luego desplegar con /s /f1"C:\\setup.iss". Es lo mas fiable cuando hay configuracion que introducir.'
    }
}

# ---------------------------------------------------------------------------
#  Bloque JSON para catalog.json
# ---------------------------------------------------------------------------
$props = [ordered]@{}
foreach ($prop in ($info.Properties | Sort-Object -Unique | Select-Object -First 8)) { $props[$prop] = '' }

$detection = if ($info.DetectMethod -eq 'productCode' -and $info.ProductCode) {
    [ordered]@{ method = 'productCode'; productCode = $info.ProductCode; minVersion = $info.ProductVersion }
} else {
    [ordered]@{ method = 'uninstall'; displayName = $info.ProductName; minVersion = $info.ProductVersion }
}

$entry = [ordered]@{
    id            = $Id
    name          = $info.ProductName
    version       = $info.ProductVersion
    enabled       = $false
    installerType = $info.InstallerType
    source        = [ordered]@{ share = ('{0}\{1}\{2}' -f $Id, $info.ProductVersion, $file.Name); url = '' }
    sha256        = $sha
    silentArgs    = $info.SilentArgs
    detection     = $detection
    successCodes  = @(0, 3010, 1641)
    requiresReboot= $false
    notes         = ($info.Notes -join ' | ')
}
if ($props.Count -gt 0) { $entry.Insert(8, 'properties', $props) }

$json = $entry | ConvertTo-Json -Depth 6

Write-Info ''
Write-Info '  --- BLOQUE PARA catalog.json (pegar en "apps") ---' 'Cyan'
if (-not $Quiet) { Write-Host $json -ForegroundColor White }

# ---------------------------------------------------------------------------
#  Ficha markdown
# ---------------------------------------------------------------------------
if ($OutputDir) {
    if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

    $md = @"
# Ficha: $($info.ProductName)

| Campo | Valor |
|---|---|
| id | ``$Id`` |
| Producto | $($info.ProductName) |
| Version | $($info.ProductVersion) |
| Fabricante | $($info.Manufacturer) |
| Instalador | $($file.Name) |
| Tipo | $($info.InstallerType) |
| ProductCode | ``$($info.ProductCode)`` |
| SHA-256 | ``$sha`` |
| Conmutador silencioso | ``$($info.SilentArgs)`` |
| Analizado | $(Get-Date -Format 'yyyy-MM-dd HH:mm') |

## Propiedades publicas detectadas

$(if ($info.Properties.Count -gt 0) { ($info.Properties | Sort-Object -Unique | ForEach-Object { "- ``$_``" }) -join "`n" } else { '_Ninguna detectada._' })

## Notas del analisis

$(if ($info.Notes.Count -gt 0) { ($info.Notes | ForEach-Object { "- $_" }) -join "`n" } else { '_Sin notas._' })

## Validacion en laboratorio  (OBLIGATORIA antes de enabled=true)

- [ ] Instala en silencio en una VM limpia de Windows 10 22H2
- [ ] Instala en silencio en una VM limpia de Windows 11
- [ ] Codigo de salida observado: ______
- [ ] Se detecta correctamente tras instalar (``Test-AppInstalled``)
- [ ] Reinstalar sobre una instalacion existente no falla (idempotencia)
- [ ] Requiere reinicio: si / no
- [ ] La aplicacion arranca y conecta con el servidor corporativo
- [ ] Desinstalacion limpia verificada

## Bloque de catalogo

``````json
$json
``````
"@

    $mdPath = Join-Path $OutputDir ("{0}.md" -f $Id)
    $md | Set-Content -LiteralPath $mdPath -Encoding UTF8
    Write-Info ''
    Write-Info "  Ficha escrita: $mdPath" 'Green'
}

Write-Info ''
Write-Info '  RECUERDA: esto es el punto de partida, no la verdad.' 'Yellow'
Write-Info '  Valida la instalacion en una VM limpia antes de poner enabled=true.' 'Yellow'
Write-Info ''

return [pscustomobject]@{ Entry = $entry; Json = $json; Sha256 = $sha; Info = [pscustomobject]$info }
