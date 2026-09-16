<#
.SYNOPSIS
    Instala el certificado de firma del toolkit como de confianza en ESTE equipo.

.DESCRIPTION
    Copia build\cert\danielnvcd-codesign.cer (solo la parte publica) a dos
    almacenes de la maquina:
      - Entidades de certificacion raiz de confianza  (para que la cadena sea valida)
      - Editores de confianza                          (para que UAC lo muestre como "Editor comprobado")

    Requiere administrador. Se ejecuta una vez por equipo; despues, cualquier
    Toolkit.exe firmado con ese certificado se ve como de un editor conocido.
    Para muchos equipos: GPO (Configuracion del equipo > Directivas de clave
    publica) o incluirlo en el despliegue del agente.

.EXAMPLE
    scripts\tools\Install-SigningCert.ps1
    scripts\tools\Install-SigningCert.ps1 -Cer \\SRV-FILE\Toolkit$\danielnvcd-codesign.cer
    scripts\tools\Install-SigningCert.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Cer = (Join-Path $PSScriptRoot '..\..\build\cert\danielnvcd-codesign.cer'),
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Hace falta ejecutar como administrador (escribe en el almacen de la maquina).' }
if (-not (Test-Path -LiteralPath $Cer)) { throw "No existe $Cer" }

$cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 ((Resolve-Path $Cer).Path)

foreach ($storeName in 'Root', 'TrustedPublisher') {
    $store = New-Object Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
    $store.Open('ReadWrite')
    try {
        $present = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if ($Remove) {
            if ($present) { $store.Remove($present[0]); Write-Host "  - Quitado de $storeName" }
            else          { Write-Host "  = No estaba en $storeName" }
        } else {
            if ($present) { Write-Host "  = Ya estaba en $storeName" }
            else          { $store.Add($cert); Write-Host "  + Instalado en $storeName" -ForegroundColor Green }
        }
    } finally { $store.Close() }
}

if (-not $Remove) {
    Write-Host ''
    Write-Host ("Certificado de confianza: {0}  (huella {1}, caduca {2:yyyy-MM-dd})" -f $cert.Subject, $cert.Thumbprint, $cert.NotAfter) -ForegroundColor Green
    Write-Host 'A partir de ahora, Toolkit.exe firmado con el se muestra como "Editor comprobado: danielnvcd".'
}
