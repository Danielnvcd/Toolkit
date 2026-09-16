<#
.SYNOPSIS
    Crea el certificado de firma de codigo del toolkit (autofirmado, 5 anos).

.DESCRIPTION
    Genera un certificado "CN=danielnvcd, O=Toolkit BPO" en el almacen personal
    del usuario (Cert:\CurrentUser\My) y exporta su parte PUBLICA a
    build\cert\danielnvcd-codesign.cer, que es lo que se instala en los equipos
    destino (Install-SigningCert.ps1). La clave privada no sale de este equipo
    salvo que se exporte a mano (-ExportPfx) para firmar desde otra maquina.

    Con este certificado, build.ps1 -Sign firma el exe y en los equipos que
    tengan el .cer instalado UAC muestra "Editor comprobado: danielnvcd".

    LIMITE: es autofirmado. SmartScreen ("Windows protegio tu PC") solo deja de
    avisar con un certificado emitido por una CA publica (DigiCert, Sectigo...),
    que hay que comprar. Este script sirve para la flota propia, donde el .cer
    se puede desplegar por GPO o con el agente.

.EXAMPLE
    scripts\tools\New-SigningCert.ps1
    scripts\tools\New-SigningCert.ps1 -ExportPfx     # ademas guarda el .pfx (pide contrasena)
#>
[CmdletBinding()]
param(
    [string]$Subject = 'CN=danielnvcd, O=Toolkit BPO',
    [int]$Years = 5,
    [switch]$ExportPfx,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$certDir = Join-Path $PSScriptRoot '..\..\build\cert'
$cerPath = Join-Path $certDir 'danielnvcd-codesign.cer'
New-Item -ItemType Directory -Path $certDir -Force | Out-Null

$existing = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) }
if ($existing -and -not $Force) {
    Write-Host "Ya existe un certificado vigente para '$Subject' (huella $($existing[0].Thumbprint)). Usa -Force para crear otro." -ForegroundColor Yellow
    $cert = $existing | Sort-Object NotAfter -Descending | Select-Object -First 1
} else {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
        -FriendlyName 'Toolkit BPO - firma de codigo (danielnvcd)' `
        -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears($Years)
    Write-Host "Certificado creado: $($cert.Subject)  huella $($cert.Thumbprint)  caduca $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Green
}

Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
Write-Host "Parte publica exportada: $cerPath  (esto es lo que se instala en los equipos)" -ForegroundColor Green

if ($ExportPfx) {
    $pfxPath = Join-Path $certDir 'danielnvcd-codesign.pfx'
    $pwd = Read-Host 'Contrasena para el .pfx' -AsSecureString
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pwd | Out-Null
    Write-Host "Clave privada exportada: $pfxPath  -- NO la subas al repositorio (esta en .gitignore)." -ForegroundColor Yellow
}
