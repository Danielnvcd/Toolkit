<#
.SYNOPSIS
    Genera assets\logo.ico (y logo.png) a partir de assets\logo.svg.

.DESCRIPTION
    El SVG es la unica fuente del logo. Este script lo renderiza con Microsoft
    Edge en modo headless (viene en todo Windows 10/11; no hace falta instalar
    nada) a cada tamano que usa Windows para iconos, y empaqueta los PNG en un
    .ico multi-resolucion. El exe y las ventanas cargan ese .ico.

    Solo hay que ejecutarlo cuando cambie el SVG. El .ico se versiona.

.EXAMPLE
    scripts\tools\New-Logo.ps1
#>
[CmdletBinding()]
param(
    [string]$Svg  = (Join-Path $PSScriptRoot '..\..\assets\logo.svg'),
    [string]$Ico  = (Join-Path $PSScriptRoot '..\..\assets\logo.ico'),
    [string]$Png  = (Join-Path $PSScriptRoot '..\..\assets\logo.png'),
    [int[]]$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'
$Svg = [IO.Path]::GetFullPath($Svg)
$Ico = [IO.Path]::GetFullPath($Ico)
$Png = [IO.Path]::GetFullPath($Png)
if (-not (Test-Path -LiteralPath $Svg)) { throw "No existe $Svg" }

$edge = @(
    "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) { throw 'No se encuentra Microsoft Edge (msedge.exe); hace falta para renderizar el SVG.' }

$work = Join-Path $env:TEMP ('toolkit-logo-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    # Edge impone un tamano minimo de ventana, asi que no se puede pedir una
    # captura de 16x16. En su lugar: el SVG a tamano fijo en la esquina superior
    # izquierda de una ventana grande, y se recorta la captura. Cada tamano se
    # renderiza de forma nativa (mas nitido que reducir un PNG grande).
    $svgText = Get-Content -LiteralPath $Svg -Raw
    $window  = [Math]::Max(600, ($Sizes | Measure-Object -Maximum).Maximum + 100)

    Add-Type -AssemblyName System.Drawing
    $frames = @()
    foreach ($s in $Sizes) {
        $html = @"
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0;background:transparent;overflow:hidden}
svg{display:block;position:absolute;left:0;top:0;width:${s}px;height:${s}px}
</style></head><body>$svgText</body></html>
"@
        $htmlPath = Join-Path $work "logo-$s.html"
        [IO.File]::WriteAllText($htmlPath, $html, (New-Object Text.UTF8Encoding($false)))

        $out = Join-Path $work "logo-$s.png"
        $args = @(
            '--headless=new', '--disable-gpu', '--hide-scrollbars',
            '--default-background-color=00000000',      # transparente
            "--window-size=$window,$window",
            "--screenshot=$out",
            "--user-data-dir=$work\profile",
            "file:///$($htmlPath -replace '\\','/')"
        )
        $p = Start-Process -FilePath $edge -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if (-not (Test-Path -LiteralPath $out)) { throw "Edge no genero $out (codigo $($p.ExitCode))" }

        # Recorte exacto de la esquina superior izquierda.
        $src = [Drawing.Image]::FromFile($out)
        $bmp = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $s, $s), (New-Object Drawing.Rectangle 0, 0, $s, $s), [Drawing.GraphicsUnit]::Pixel)
        $g.Dispose(); $src.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $frames += ,@{ Size = $s; Bytes = $ms.ToArray() }
        Write-Host ("  + {0,3}x{0,-3} {1,6} bytes" -f $s, $ms.Length)
    }

    # ICO con entradas PNG (soportado desde Windows Vista). Formato:
    #   ICONDIR (6) + ICONDIRENTRY (16) x N + datos
    $bw = New-Object IO.BinaryWriter ([IO.File]::Create($Ico))
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }   # 0 = 256
        $bw.Write([byte]$dim); $bw.Write([byte]$dim)
        $bw.Write([byte]0); $bw.Write([byte]0)               # paleta, reservado
        $bw.Write([uint16]1); $bw.Write([uint16]32)          # planos, bpp
        $bw.Write([uint32]$f.Bytes.Length); $bw.Write([uint32]$offset)
        $offset += $f.Bytes.Length
    }
    foreach ($f in $frames) { $bw.Write($f.Bytes) }
    $bw.Dispose()

    # PNG grande suelto (README, documentacion, instaladores).
    [IO.File]::WriteAllBytes($Png, ($frames | Where-Object { $_.Size -eq ($Sizes | Measure-Object -Maximum).Maximum }).Bytes)

    Write-Host ''
    Write-Host "  Icono : $Ico  ($((Get-Item $Ico).Length) bytes, $($frames.Count) tamanos)" -ForegroundColor Green
    Write-Host "  PNG   : $Png" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
