<#
.SYNOPSIS
    Compila Toolkit.exe con los scripts embebidos y, opcionalmente, lo firma.

.DESCRIPTION
    Los .psm1 de scripts\ entran en el exe como recursos en tiempo de compilacion
    (ver los EmbeddedResource de Toolkit.App.csproj). Cambiar un script y volver
    a ejecutar este build es todo el ciclo.

    LA FIRMA NO ES OPCIONAL EN PRODUCCION: sin ella, SmartScreen y el antivirus
    bloquean el exe y acabas creando 400 excepciones a mano (seccion 10 del PLAN).

.PARAMETER Sign
    Firma con Authenticode. Requiere certificado en el almacen o un token HSM.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Sign -Thumbprint A1B2C3... -TimestampUrl http://timestamp.digicert.com
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [switch]$Sign,
    [string]$Thumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipScriptCheck
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$project = Join-Path $root 'src\Toolkit.App\Toolkit.App.csproj'
$distDir = Join-Path $root 'dist'

Write-Host ''
Write-Host '=== TOOLKIT BUILD ===' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
#  1. Validar los scripts ANTES de embeberlos
#     Un error de sintaxis en un .psm1 no rompe la compilacion de C#: se
#     embeberia igual y explotaria en el equipo del cliente. Hay que atraparlo aqui.
# ---------------------------------------------------------------------------
if (-not $SkipScriptCheck) {
    Write-Host ''
    Write-Host '[1/4] Validando sintaxis de los scripts...' -ForegroundColor White
    $scriptFiles = Get-ChildItem -Path (Join-Path $root 'scripts') -Include '*.ps1', '*.psm1' -Recurse
    $errors = 0

    foreach ($f in $scriptFiles) {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $errors += $parseErrors.Count
            Write-Host ("  x {0}" -f $f.Name) -ForegroundColor Red
            foreach ($e in $parseErrors) {
                Write-Host ("      linea {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
            }
        } else {
            Write-Host ("  + {0}" -f $f.Name) -ForegroundColor DarkGray
        }
    }

    if ($errors -gt 0) { throw "$errors error(es) de sintaxis en los scripts. Build abortado." }

    # El catalogo tambien se embebe: si no es JSON valido, el exe no arranca.
    $catalog = Join-Path $root 'scripts\config\catalog.json'
    try   { $null = Get-Content $catalog -Raw | ConvertFrom-Json; Write-Host '  + catalog.json' -ForegroundColor DarkGray }
    catch { throw "catalog.json no es JSON valido: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  2. Compilar
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[2/4] Compilando...' -ForegroundColor White

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'No se encuentra dotnet. Instala el SDK de .NET (incluye el targeting pack de .NET Framework 4.8).'
}

& dotnet build $project -c $Configuration --nologo
if ($LASTEXITCODE -ne 0) { throw "La compilacion fallo (codigo $LASTEXITCODE)." }

$exe = Join-Path $root ('src\Toolkit.App\bin\{0}\net48\Toolkit.exe' -f $Configuration)
if (-not (Test-Path $exe)) { throw "No se genero el ejecutable en $exe" }

$sizeMb = [math]::Round((Get-Item $exe).Length / 1MB, 2)
Write-Host ("  + Toolkit.exe  ({0} MB)" -f $sizeMb) -ForegroundColor Green

# ---------------------------------------------------------------------------
#  3. Verificar que los scripts quedaron DENTRO del exe
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[3/4] Verificando recursos embebidos...' -ForegroundColor White
# Se carga desde bytes, no con LoadFrom: LoadFrom deja el exe bloqueado hasta que
# muere el proceso y despues no se puede firmar ni copiar a dist\.
$asm = [System.Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
$resources = $asm.GetManifestResourceNames()

$expected = @(
    'Scripts/Toolkit.Core.psm1'
    'Scripts/Toolkit.Location.psm1'
    'Scripts/Toolkit.Apps.psm1'
    'Scripts/Toolkit.Network.psm1'
    'Scripts/Toolkit.Users.psm1'
    'Scripts/Toolkit.Support.psm1'
    'Scripts/Invoke-ToolkitRun.ps1'
    'Scripts/catalog.json'
)
$missing = @($expected | Where-Object { $_ -notin $resources })
if ($missing.Count -gt 0) {
    throw ("Faltan recursos embebidos: {0}" -f ($missing -join ', '))
}
foreach ($r in $resources) { Write-Host "  + $r" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
#  3b. Verificar que es PORTABLE: un solo archivo
#      Si el SDK dejo DLLs o un .config junto al exe, es que alguna referencia
#      se esta copiando en local y el exe podria depender de ellas.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[3b] Verificando que el exe es portable (un solo archivo)...' -ForegroundColor White
$binDir  = Split-Path $exe -Parent
$extras  = @(Get-ChildItem -Path $binDir -File | Where-Object { $_.Name -ne 'Toolkit.exe' -and $_.Extension -in '.dll', '.config', '.pdb' })
if ($extras.Count -gt 0) {
    foreach ($x in $extras) { Write-Host ("  x {0}" -f $x.Name) -ForegroundColor Red }
    throw 'El build dejo dependencias junto al exe. Revisa las referencias del csproj (ExcludeAssets/Private=false).'
}
# Comprobacion cruzada: ninguna referencia del exe debe apuntar fuera del GAC de .NET / PowerShell.
$allowed = '^(mscorlib|System(\..+)?|Microsoft\.CSharp|System\.Management\.Automation|Microsoft\.PowerShell\..+|netstandard|WindowsBase|PresentationCore)$'
$foreign = @($asm.GetReferencedAssemblies() | Where-Object { $_.Name -notmatch $allowed })
if ($foreign.Count -gt 0) {
    foreach ($f in $foreign) { Write-Host ("  x referencia externa: {0}" -f $f.FullName) -ForegroundColor Red }
    throw 'El exe referencia ensamblados que no vienen con Windows. No seria portable.'
}
Write-Host '  + Un solo archivo, sin dependencias fuera de Windows / .NET 4.8 / PowerShell 5.1' -ForegroundColor Green

# ---------------------------------------------------------------------------
#  4. Firmar
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '[4/4] Firma Authenticode...' -ForegroundColor White

if ($Sign) {
    # Certificado: por huella si se indica; si no, el de firma de codigo de
    # danielnvcd en el almacen del usuario (el que crea scripts\tools\New-SigningCert.ps1).
    $cert = $null
    if ($Thumbprint) {
        $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -ieq $Thumbprint } | Select-Object -First 1
        if (-not $cert) { throw "No hay ningun certificado de firma de codigo con huella $Thumbprint." }
    } else {
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -like 'CN=danielnvcd*' -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert) { throw 'No hay certificado de firma. Crea uno con scripts\tools\New-SigningCert.ps1 o indica -Thumbprint.' }
    }
    Write-Host ("  Certificado: {0}  (huella {1}, caduca {2:yyyy-MM-dd})" -f $cert.Subject, $cert.Thumbprint, $cert.NotAfter)

    $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'x64' } |
                Sort-Object FullName -Descending | Select-Object -First 1

    if ($signtool) {
        & $signtool.FullName sign /sha1 $cert.Thumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 /v $exe
        if ($LASTEXITCODE -ne 0) { throw "signtool fallo (codigo $LASTEXITCODE)." }
    } else {
        # Sin Windows SDK: PowerShell firma igual de bien (Authenticode + sello de tiempo RFC 3161).
        $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $TimestampUrl -ErrorAction Stop
        if ($sig.Status -ne 'Valid' -and $sig.Status -ne 'UnknownError') { throw "La firma no es valida: $($sig.Status) - $($sig.StatusMessage)" }
    }

    $check = Get-AuthenticodeSignature $exe
    # 'UnknownError' = firmado correctamente pero el emisor no es de confianza en ESTE
    # equipo (certificado autofirmado sin instalar). En los equipos con el .cer
    # instalado sale 'Valid'.
    $selfSigned = ($check.SignerCertificate.Subject -eq $check.SignerCertificate.Issuer)
    Write-Host ("  + Firmado por {0}; estado aqui: {1}" -f $check.SignerCertificate.Subject, $check.Status) -ForegroundColor Green
    if ($selfSigned) {
        Write-Host '  i Certificado AUTOFIRMADO: en cada equipo destino hay que instalar build\cert\*.cer' -ForegroundColor Yellow
        Write-Host '    (scripts\tools\Install-SigningCert.ps1) para que UAC muestre "Editor comprobado".' -ForegroundColor Yellow
        Write-Host '    SmartScreen seguira avisando la primera vez: eso solo lo quita un certificado de CA publica.' -ForegroundColor Yellow
    }
} else {
    Write-Host '  ! SIN FIRMAR.' -ForegroundColor Yellow
    Write-Host '    Valido para laboratorio. En los 400 equipos, SmartScreen y el antivirus' -ForegroundColor Yellow
    Write-Host '    lo bloquearan. Usa -Sign (ver seccion 10 del PLAN).' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
#  Publicar en dist\
# ---------------------------------------------------------------------------
New-Item -Path $distDir -ItemType Directory -Force | Out-Null
try {
    Copy-Item $exe -Destination $distDir -Force -ErrorAction Stop
} catch {
    $running = Get-Process -Name Toolkit -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  x No se pudo copiar a dist\Toolkit.exe: el archivo esta en uso.' -ForegroundColor Red
    if ($running) { Write-Host ("    Toolkit.exe esta abierto (PID {0}). Cierralo y vuelve a ejecutar el build." -f ($running.Id -join ', ')) -ForegroundColor Red }
    Write-Host ("    El exe nuevo (compilado y {0}) esta en: {1}" -f $(if ($Sign) { 'firmado' } else { 'sin firmar' }), $exe) -ForegroundColor Yellow
    exit 2
}

$hash = (Get-FileHash (Join-Path $distDir 'Toolkit.exe') -Algorithm SHA256).Hash

Write-Host ''
Write-Host '=== LISTO ===' -ForegroundColor Cyan
Write-Host ("  Ejecutable : {0}" -f (Join-Path $distDir 'Toolkit.exe'))
Write-Host ("  Tamano     : {0} MB" -f $sizeMb)
Write-Host ("  SHA-256    : {0}" -f $hash)
Write-Host ("  Firmado    : {0}" -f $(if ($Sign) { 'si' } else { 'NO' }))
Write-Host '  Portable   : si (un solo archivo; copiar a USB o share y ejecutar)'
Write-Host ''
Write-Host '  Publica el hash junto al binario: es como los equipos verifican' -ForegroundColor DarkGray
Write-Host '  que la version que reciben del share no ha sido manipulada.' -ForegroundColor DarkGray
Write-Host ''
