# =====================================================================
#  extras.ps1 - retro flair tools for xpharness (dot-sourced by harness.ps1)
#    Tool-Banner       : big ASCII-art text (built-in 5-row font, offline)
#    Tool-ImageToAscii : convert an image file to ASCII art (pure PS2 + GDI+)
#  Both print directly to the console and return a short status to the model,
#  so the art renders perfectly and doesn't get re-emitted through markdown.
# =====================================================================

# 5-row block font. Lowercase is upper-cased; unknown chars become '?'.
$BannerFont = @{
    'A' = @(' ## ','#  #','####','#  #','#  #')
    'B' = @('### ','#  #','### ','#  #','### ')
    'C' = @(' ###','#   ','#   ','#   ',' ###')
    'D' = @('### ','#  #','#  #','#  #','### ')
    'E' = @('####','#   ','### ','#   ','####')
    'F' = @('####','#   ','### ','#   ','#   ')
    'G' = @(' ###','#   ','# ##','#  #',' ###')
    'H' = @('#  #','#  #','####','#  #','#  #')
    'I' = @('###',' # ',' # ',' # ','###')
    'J' = @('  ##','   #','   #','#  #',' ## ')
    'K' = @('#  #','# # ','##  ','# # ','#  #')
    'L' = @('#   ','#   ','#   ','#   ','####')
    'M' = @('#   #','## ##','# # #','#   #','#   #')
    'N' = @('#  #','## #','# ##','#  #','#  #')
    'O' = @(' ## ','#  #','#  #','#  #',' ## ')
    'P' = @('### ','#  #','### ','#   ','#   ')
    'Q' = @(' ## ','#  #','#  #',' ## ','  ##')
    'R' = @('### ','#  #','### ','# # ','#  #')
    'S' = @(' ###','#   ',' ## ','   #','### ')
    'T' = @('#####','  #  ','  #  ','  #  ','  #  ')
    'U' = @('#  #','#  #','#  #','#  #',' ## ')
    'V' = @('#  #','#  #','#  #',' ## ','  # ')
    'W' = @('#   #','#   #','# # #','## ##','#   #')
    'X' = @('#  #',' ## ','  # ',' ## ','#  #')
    'Y' = @('#  #',' ## ','  # ','  # ','  # ')
    'Z' = @('####','  # ',' #  ','#   ','####')
    '0' = @(' ## ','#  #','# ##','##  #',' ## ')
    '1' = @(' # ','## ',' # ',' # ','###')
    '2' = @(' ## ','#  #','  # ',' #  ','####')
    '3' = @('### ','   #',' ## ','   #','### ')
    '4' = @('#  #','#  #','####','   #','   #')
    '5' = @('####','#   ','### ','   #','### ')
    '6' = @(' ###','#   ','### ','#  #',' ## ')
    '7' = @('####','   #','  # ',' #  ',' #  ')
    '8' = @(' ## ','#  #',' ## ','#  #',' ## ')
    '9' = @(' ## ','#  #',' ###','   #','### ')
    ' ' = @('  ','  ','  ','  ','  ')
    '!' = @('#','#','#',' ','#')
    '.' = @(' ',' ',' ',' ','#')
    ',' = @(' ',' ',' ',' #','# ')
    '-' = @('    ','    ','####','    ','    ')
    ':' = @(' ','#',' ','#',' ')
    '?' = @('### ','   #',' ## ','    ',' #  ')
}

function Make-Banner($text) {
    $rows = @('', '', '', '', '')
    foreach ($ch in ([string]$text).ToUpper().ToCharArray()) {
        $g = $BannerFont[[string]$ch]
        if (-not $g) { $g = $BannerFont['?'] }
        $w = 0; foreach ($ln in $g) { if ($ln.Length -gt $w) { $w = $ln.Length } }
        for ($r = 0; $r -lt 5; $r++) {
            $line = $g[$r]
            if ($line.Length -lt $w) { $line = $line + (" " * ($w - $line.Length)) }
            $rows[$r] = $rows[$r] + $line + " "
        }
    }
    return ($rows -join "`r`n")
}

# Clippy homage - a paperclip with eyes, shown at startup.
$ClippyArt = @'
 __
/  \
|  |
@  @
|| ||
|| ||
|\_/|
\___/
'@

function Tool-Banner($toolInput) {
    $text = [string]$toolInput["text"]
    if (-not $text) { return "ERROR: text required" }
    $col = "Cyan"; if ($BannerColor) { $col = $BannerColor }
    Write-Host ""
    Write-Host (Make-Banner $text) -ForegroundColor $col
    return "(banner displayed for '$text')"
}

function Tool-ImageToAscii($toolInput) {
    $path = [string]$toolInput["path"]
    if (-not (Test-Path $path)) { return "ERROR: image not found: $path" }
    $width = 80; if ($toolInput["width"]) { $width = [int]$toolInput["width"] }
    if ($width -lt 8) { $width = 8 }
    if ($width -gt 200) { $width = 200 }
    $invert = ($toolInput["invert"] -eq $true)
    try {
        [void][Reflection.Assembly]::LoadWithPartialName("System.Drawing")
        $img = New-Object System.Drawing.Bitmap($path)
        $ramp = " .:-=+*#%@"
        # console chars are ~2x taller than wide, so squash height by ~0.5
        $h = [int]($width * ($img.Height / $img.Width) * 0.5)
        if ($h -lt 1) { $h = 1 }
        $small = New-Object System.Drawing.Bitmap($img, (New-Object System.Drawing.Size($width, $h)))
        $sb = New-Object System.Text.StringBuilder
        for ($y = 0; $y -lt $h; $y++) {
            for ($x = 0; $x -lt $width; $x++) {
                $px = $small.GetPixel($x, $y)
                $lum = (0.299 * $px.R + 0.587 * $px.G + 0.114 * $px.B) / 255.0
                $idx = [int]($lum * ($ramp.Length - 1))
                if ($invert) { $idx = ($ramp.Length - 1) - $idx }
                [void]$sb.Append($ramp[$idx])
            }
            [void]$sb.Append("`r`n")
        }
        $small.Dispose(); $img.Dispose()
        Write-Host ""
        Write-Host $sb.ToString() -ForegroundColor Gray
        return "(rendered $path as ${width}x${h} ASCII)"
    } catch {
        return "ERROR rendering image: $($_.Exception.Message)"
    }
}
