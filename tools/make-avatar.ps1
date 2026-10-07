param([string]$OutPath)
Add-Type -AssemblyName System.Drawing

$size = 640
$bmp = New-Object System.Drawing.Bitmap $size, $size
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.InterpolationMode = 'HighQualityBicubic'

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Fondo: degradado diagonal terracota -> ciruela oscuro
$rect = New-Object System.Drawing.Rectangle 0, 0, $size, $size
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, 217, 119, 87)), ([System.Drawing.Color]::FromArgb(255, 60, 36, 52)), 45
$g.FillRectangle($bg, $rect)

# Halo suave detrás de la ventana
$halo = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 255, 255, 255))
$g.FillEllipse($halo, 90, 90, 460, 460)

# Ventana de terminal (centrada para que sobreviva al recorte circular)
$wx = 150; $wy = 190; $ww = 340; $wh = 250
$shadow = New-RoundRect ($wx + 8) ($wy + 12) $ww $wh 34
$g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90, 0, 0, 0))), $shadow)
$win = New-RoundRect $wx $wy $ww $wh 34
$g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 31, 30, 29))), $win)

# Barra superior con los tres puntos
$dots = @(
    [System.Drawing.Color]::FromArgb(255, 255, 95, 86),
    [System.Drawing.Color]::FromArgb(255, 255, 189, 46),
    [System.Drawing.Color]::FromArgb(255, 39, 201, 63)
)
for ($i = 0; $i -lt 3; $i++) {
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $dots[$i]), ($wx + 30 + $i * 34), ($wy + 26), 20, 20)
}

# Prompt ">_"
$font = New-Object System.Drawing.Font 'Consolas', 110, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$accent = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 240, 150, 110))
$g.DrawString('>_', $font, $accent, ($wx + 40), ($wy + 80))

# Avión de papel (Telegram) saliendo por la esquina superior derecha
$cx = 455; $cy = 175
$circle = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 42, 171, 238))
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 0, 0, 0))), ($cx - 66), ($cy - 60), 136, 136)
$g.FillEllipse($circle, ($cx - 70), ($cy - 70), 140, 140)
$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$plane = [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF ($cx - 42), ($cy + 2)),
    (New-Object System.Drawing.PointF ($cx + 40), ($cy - 32)),
    (New-Object System.Drawing.PointF ($cx + 22), ($cy + 38)),
    (New-Object System.Drawing.PointF ($cx - 2), ($cy + 18)),
    (New-Object System.Drawing.PointF ($cx - 14), ($cy + 34)),
    (New-Object System.Drawing.PointF ($cx - 14), ($cy + 12))
)
$g.FillPolygon($white, $plane)
$fold = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 200, 225, 245))
$g.FillPolygon($fold, [System.Drawing.PointF[]]@(
    (New-Object System.Drawing.PointF ($cx - 14), ($cy + 12)),
    (New-Object System.Drawing.PointF ($cx + 40), ($cy - 32)),
    (New-Object System.Drawing.PointF ($cx - 2), ($cy + 18)),
    (New-Object System.Drawing.PointF ($cx - 14), ($cy + 34))
))

$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$ep = New-Object System.Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 95L
$bmp.Save($OutPath, $codec, $ep)
$g.Dispose(); $bmp.Dispose()
"ok: $OutPath"
