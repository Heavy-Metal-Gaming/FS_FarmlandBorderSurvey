<#
.SYNOPSIS
    Convert a PNG to DDS (DXT1/BC1) with no mipmaps using pure .NET.
.PARAMETER InputPath
    Path to the source PNG file.
.PARAMETER OutputPath
    Path for the output DDS file.
#>
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputPath
)

Add-Type -AssemblyName System.Drawing

$img = [System.Drawing.Bitmap]::new($InputPath)
$w = $img.Width
$h = $img.Height

if (($w % 4) -ne 0 -or ($h % 4) -ne 0) {
    throw "Image dimensions ($w x $h) must be multiples of 4 for DXT1."
}

# Read all pixels into an array
$pixels = New-Object 'int[]' ($w * $h)
for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
        $c = $img.GetPixel($x, $y)
        $pixels[$y * $w + $x] = ($c.R -shl 16) -bor ($c.G -shl 8) -bor $c.B
    }
}
$img.Dispose()
Write-Host "Read ${w}x${h} pixels."

# --- DXT1 compression ---
# Each 4x4 block -> 8 bytes (2x RGB565 endpoints + 4 bytes of 2-bit indices)
function ConvertTo-RGB565([int]$r, [int]$g, [int]$b) {
    $r5 = [int][Math]::Round($r * 31.0 / 255.0)
    $g6 = [int][Math]::Round($g * 63.0 / 255.0)
    $b5 = [int][Math]::Round($b * 31.0 / 255.0)
    return [uint16](($r5 -shl 11) -bor ($g6 -shl 5) -bor $b5)
}

function Expand-RGB565([uint16]$c) {
    $r = (($c -shr 11) -band 0x1F) * 255 / 31
    $g = (($c -shr 5) -band 0x3F) * 255 / 63
    $b = ($c -band 0x1F) * 255 / 31
    return @([int]$r, [int]$g, [int]$b)
}

$blocksX = $w / 4
$blocksY = $h / 4
$blockData = New-Object 'byte[]' ($blocksX * $blocksY * 8)
$blockIdx = 0

for ($by = 0; $by -lt $blocksY; $by++) {
    for ($bx = 0; $bx -lt $blocksX; $bx++) {
        # Gather 16 pixels for this block
        $blockPixels = New-Object 'int[]' 16
        for ($py = 0; $py -lt 4; $py++) {
            for ($px = 0; $px -lt 4; $px++) {
                $sx = $bx * 4 + $px
                $sy = $by * 4 + $py
                $blockPixels[$py * 4 + $px] = $pixels[$sy * $w + $sx]
            }
        }

        # Find min/max color along the principal axis (simplified: use bounding box diagonal)
        $minR = 255; $minG = 255; $minB = 255
        $maxR = 0;   $maxG = 0;   $maxB = 0
        foreach ($p in $blockPixels) {
            $pr = ($p -shr 16) -band 0xFF
            $pg = ($p -shr 8)  -band 0xFF
            $pb = $p -band 0xFF
            if ($pr -lt $minR) { $minR = $pr }
            if ($pg -lt $minG) { $minG = $pg }
            if ($pb -lt $minB) { $minB = $pb }
            if ($pr -gt $maxR) { $maxR = $pr }
            if ($pg -gt $maxG) { $maxG = $pg }
            if ($pb -gt $maxB) { $maxB = $pb }
        }

        # Inset the bounding box slightly for better quality
        $insetR = [int](($maxR - $minR) / 16)
        $insetG = [int](($maxG - $minG) / 16)
        $insetB = [int](($maxB - $minB) / 16)
        $minR = [Math]::Min(255, $minR + $insetR)
        $minG = [Math]::Min(255, $minG + $insetG)
        $minB = [Math]::Min(255, $minB + $insetB)
        $maxR = [Math]::Max(0, $maxR - $insetR)
        $maxG = [Math]::Max(0, $maxG - $insetG)
        $maxB = [Math]::Max(0, $maxB - $insetB)

        $c0 = ConvertTo-RGB565 $maxR $maxG $maxB
        $c1 = ConvertTo-RGB565 $minR $minG $minB

        # DXT1 opaque mode: c0 > c1 means 4-color mode (no alpha)
        if ($c0 -lt $c1) {
            $temp = $c0; $c0 = $c1; $c1 = $temp
            $tempR = $minR; $minR = $maxR; $maxR = $tempR
            $tempG = $minG; $minG = $maxG; $maxG = $tempG
            $tempB = $minB; $minB = $maxB; $maxB = $tempB
        }
        if ($c0 -eq $c1) {
            # Force c0 > c1 for 4-color mode
            if ($c0 -lt 65535) { $c0 = [uint16]($c0 + 1) }
            else { $c1 = [uint16]($c1 - 1) }
        }

        # Build palette (4 colors for opaque DXT1)
        $e0 = Expand-RGB565 $c0
        $e1 = Expand-RGB565 $c1
        $palette = @(
            @($e0[0], $e0[1], $e0[2]),
            @($e1[0], $e1[1], $e1[2]),
            @([int](($e0[0] * 2 + $e1[0]) / 3), [int](($e0[1] * 2 + $e1[1]) / 3), [int](($e0[2] * 2 + $e1[2]) / 3)),
            @([int](($e0[0] + $e1[0] * 2) / 3), [int](($e0[1] + $e1[1] * 2) / 3), [int](($e0[2] + $e1[2] * 2) / 3))
        )

        # Determine best index for each pixel
        [uint32]$indices = 0
        for ($i = 0; $i -lt 16; $i++) {
            $pr = ($blockPixels[$i] -shr 16) -band 0xFF
            $pg = ($blockPixels[$i] -shr 8)  -band 0xFF
            $pb = $blockPixels[$i] -band 0xFF
            $bestDist = [int]::MaxValue
            $bestIdx = 0
            for ($j = 0; $j -lt 4; $j++) {
                $dr = $pr - $palette[$j][0]
                $dg = $pg - $palette[$j][1]
                $db = $pb - $palette[$j][2]
                $dist = $dr * $dr + $dg * $dg + $db * $db
                if ($dist -lt $bestDist) {
                    $bestDist = $dist
                    $bestIdx = $j
                }
            }
            $indices = $indices -bor ([uint32]$bestIdx -shl ($i * 2))
        }

        # Write block: c0 (2 bytes LE), c1 (2 bytes LE), indices (4 bytes LE)
        $off = $blockIdx * 8
        $blockData[$off]     = [byte]($c0 -band 0xFF)
        $blockData[$off + 1] = [byte](($c0 -shr 8) -band 0xFF)
        $blockData[$off + 2] = [byte]($c1 -band 0xFF)
        $blockData[$off + 3] = [byte](($c1 -shr 8) -band 0xFF)
        $blockData[$off + 4] = [byte]($indices -band 0xFF)
        $blockData[$off + 5] = [byte](($indices -shr 8) -band 0xFF)
        $blockData[$off + 6] = [byte](($indices -shr 16) -band 0xFF)
        $blockData[$off + 7] = [byte](($indices -shr 24) -band 0xFF)
        $blockIdx++
    }
}

Write-Host "Compressed $blockIdx blocks ($(8 * $blockIdx) bytes)."

# --- Write DDS file ---
$linearSize = $blocksX * $blocksY * 8

$ms = [System.IO.MemoryStream]::new()
$bw = [System.IO.BinaryWriter]::new($ms)

# Magic
$bw.Write([uint32]0x20534444)  # "DDS "

# DDS_HEADER (124 bytes)
$bw.Write([uint32]124)         # dwSize
# dwFlags: DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_LINEARSIZE
$bw.Write([uint32]0x000A1007)
$bw.Write([uint32]$h)          # dwHeight
$bw.Write([uint32]$w)          # dwWidth
$bw.Write([uint32]$linearSize) # dwPitchOrLinearSize
$bw.Write([uint32]0)           # dwDepth
$bw.Write([uint32]0)           # dwMipMapCount (0 = no mipmaps)
# dwReserved1[11]
for ($i = 0; $i -lt 11; $i++) { $bw.Write([uint32]0) }

# DDS_PIXELFORMAT (32 bytes)
$bw.Write([uint32]32)          # dwSize
$bw.Write([uint32]0x04)        # dwFlags = DDPF_FOURCC
# FourCC = "DXT1"
$bw.Write([byte]0x44); $bw.Write([byte]0x58); $bw.Write([byte]0x54); $bw.Write([byte]0x31)
$bw.Write([uint32]0)           # dwRGBBitCount
$bw.Write([uint32]0)           # dwRBitMask
$bw.Write([uint32]0)           # dwGBitMask
$bw.Write([uint32]0)           # dwBBitMask
$bw.Write([uint32]0)           # dwABitMask

# dwCaps
$bw.Write([uint32]0x1000)      # DDSCAPS_TEXTURE
$bw.Write([uint32]0)           # dwCaps2
$bw.Write([uint32]0)           # dwCaps3
$bw.Write([uint32]0)           # dwCaps4
$bw.Write([uint32]0)           # dwReserved2

# Compressed pixel data
$bw.Write($blockData)

$bw.Flush()
[System.IO.File]::WriteAllBytes($OutputPath, $ms.ToArray())
$bw.Dispose()
$ms.Dispose()

$sizeKB = [Math]::Round((Get-Item $OutputPath).Length / 1024, 1)
Write-Host "Written DDS: $OutputPath ($sizeKB KB)"
