<#
.SYNOPSIS
    Saca, de un equipo donde una aplicacion YA esta instalada, lo que hace falta
    para escribir su ficha en catalog.json.

.DESCRIPTION
    Busca en las tres ramas de desinstalacion (64 bits, 32 bits y por usuario)
    y muestra: nombre exacto (displayName para detection), version, editor,
    tipo de instalador (MSI con ProductCode, o EXE con su cadena de
    desinstalacion, que delata si es NSIS, Inno, InstallShield o Burn),
    carpeta de instalacion y el instalador cacheado si Windows lo guardo.

    Es lo que se necesita para MaxAssist o cualquier app que el proveedor
    entrega a mano: se ejecuta en el PC de un agente que ya la tiene y con
    la salida se rellena la ficha.

.EXAMPLE
    scripts\tools\Get-InstalledAppInfo.ps1 -Name MaxAssist
    scripts\tools\Get-InstalledAppInfo.ps1 -Name "Genesys"
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Name)

$paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$hits = @()
foreach ($p in $paths) {
    $hits += Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -like "*$Name*" }
}
if ($hits.Count -eq 0) {
    Write-Host "No hay nada instalado cuyo nombre contenga '$Name'." -ForegroundColor Yellow
    Write-Host 'Prueba con una parte del nombre, o mira en Configuracion > Aplicaciones como se llama exactamente.'
    exit 1
}

foreach ($h in $hits) {
    $isMsi   = ($h.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') -or ($h.UninstallString -match 'msiexec')
    $engine  = if ($isMsi) { 'MSI (Windows Installer)' }
               elseif ($h.UninstallString -match 'unins\d*\.exe')      { 'EXE Inno Setup  -> silencioso: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
               elseif ($h.UninstallString -match 'Uninstall\.exe|uninst\.exe') { 'EXE NSIS (probable) -> silencioso: /S' }
               elseif ($h.UninstallString -match 'InstallShield|setup\.exe.*-runfromtemp|\{[0-9A-F-]{36}\}.*setup') { 'EXE InstallShield -> silencioso: /s /v"/qn"' }
               elseif ($h.PSObject.Properties.Name -contains 'BundleProviderKey' -or $h.UninstallString -match '/uninstall') { 'EXE WiX Burn -> silencioso: /install /quiet /norestart' }
               else { 'EXE (tipo no reconocido: probar /S, /silent, /quiet, /verysilent)' }

    Write-Host ''
    Write-Host ("=== {0}" -f $h.DisplayName) -ForegroundColor Cyan
    Write-Host ("  displayName      : {0}" -f $h.DisplayName)
    Write-Host ("  version          : {0}" -f $h.DisplayVersion)
    Write-Host ("  editor           : {0}" -f $h.Publisher)
    Write-Host ("  instalador       : {0}" -f $engine)
    if ($isMsi) { Write-Host ("  productCode      : {0}" -f $h.PSChildName) -ForegroundColor Green }
    Write-Host ("  carpeta          : {0}" -f $h.InstallLocation)
    Write-Host ("  desinstalacion   : {0}" -f $h.UninstallString)
    if ($h.PSObject.Properties.Name -contains 'InstallSource' -and $h.InstallSource) {
        Write-Host ("  origen instalac. : {0}" -f $h.InstallSource) -ForegroundColor Green
    }
    if ($isMsi) {
        # Windows guarda una copia del MSI en C:\Windows\Installer: sirve para sacar el sha256 y redistribuirlo.
        $cached = Get-ItemProperty "HKLM:\SOFTWARE\Classes\Installer\Products\*" -ErrorAction SilentlyContinue |
                  Where-Object { $_.ProductName -eq $h.DisplayName } | Select-Object -First 1
        if ($cached) {
            $src = Get-ItemProperty "$($cached.PSPath)\InstallProperties" -ErrorAction SilentlyContinue
            if ($src -and $src.LocalPackage) { Write-Host ("  MSI cacheado     : {0}" -f $src.LocalPackage) -ForegroundColor Green }
        }
    }
    Write-Host ''
    Write-Host '  Ficha sugerida para catalog.json:' -ForegroundColor Gray
    $det = if ($isMsi) { "{ ""method"": ""productCode"", ""productCode"": ""$($h.PSChildName)"", ""minVersion"": """" }" }
           else        { "{ ""method"": ""uninstall"", ""displayName"": ""$($h.DisplayName)"", ""minVersion"": """" }" }
    Write-Host ("    ""name"": ""{0}"", ""version"": ""{1}"", ""installerType"": ""{2}"", ""detection"": {3}" -f $h.DisplayName, $h.DisplayVersion, $(if ($isMsi) { 'msi' } else { 'exe' }), $det) -ForegroundColor Gray
}
