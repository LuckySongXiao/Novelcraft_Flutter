param(
  [string]$IcoPath = 'F:\30_Novelcraft_Flutter\novelcraft_en\icon.ico',
  [string]$ProjRoot = 'F:\30_Novelcraft_Flutter\Flutter版代码\novelcraft'
)

Add-Type -AssemblyName System.Drawing

$ico = [System.Drawing.Icon]::ExtractAssociatedIcon($IcoPath)
if (-not $ico) {
  # Fallback: use Icon constructor
  $ico = New-Object System.Drawing.Icon($IcoPath)
}

function Save-Png($bitmap, $outPath, $size) {
  $resized = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($resized)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $g.DrawImage($bitmap, 0, 0, $size, $size)
  $g.Dispose()
  $dir = Split-Path $outPath -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $resized.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $resized.Dispose()
  Write-Host ("Wrote {0}x{0} -> {1}" -f $size, $outPath)
}

$srcBmp = $ico.ToBitmap()

# --- Windows: already done by direct copy above ---
# --- Web ---
$webTargets = @(
  @{ S = 192; P = "$ProjRoot\web\icons\Icon-192.png" },
  @{ S = 512; P = "$ProjRoot\web\icons\Icon-512.png" },
  @{ S = 192; P = "$ProjRoot\web\icons\Icon-maskable-192.png" },
  @{ S = 512; P = "$ProjRoot\web\icons\Icon-maskable-512.png" }
)
foreach ($t in $webTargets) { Save-Png $srcBmp $t.P $t.S }
# favicon: 32x32 png is enough for most browsers; but also try ico copy if desired
Save-Png $srcBmp "$ProjRoot\web\favicon.png" 32
Copy-Item -Force $IcoPath "$ProjRoot\web\favicon.ico"
Write-Host ("Wrote favicon.ico -> {0}\web\favicon.ico" -f $ProjRoot)

# --- Android (ic_launcher only, adaptive icon unchanged) ---
# mdpi=48, hdpi=72, xhdpi=96, xxhdpi=144, xxxhdpi=192
$androidDpis = @(
  @{ D = 'mdpi';    S = 48  },
  @{ D = 'hdpi';    S = 72  },
  @{ D = 'xhdpi';   S = 96  },
  @{ D = 'xxhdpi';  S = 144 },
  @{ D = 'xxxhdpi'; S = 192 }
)
foreach ($a in $androidDpis) {
  $p = "$ProjRoot\android\app\src\main\res\mipmap-$($a.D)\ic_launcher.png"
  Save-Png $srcBmp $p $a.S
}

# --- iOS AppIcon.appiconset ---
$iosSizes = @(20,29,40,60,76,83.5,1024)
$iosScales = @(1,2,3)
$iosDir = "$ProjRoot\ios\Runner\Assets.xcassets\AppIcon.appiconset"
foreach ($sz in $iosSizes) {
  foreach ($sc in $iosScales) {
    if ($sz -eq 76 -and $sc -eq 3) { continue }         # no 76@3x
    if ($sz -eq 83.5 -and $sc -ne 2) { continue }       # only 83.5@2x (iPad Pro 12.9)
    if ($sz -eq 1024 -and $sc -ne 1) { continue }       # only 1024@1x (Marketing)
    $px = [int]([math]::Round($sz * $sc))
    $suffix = if ($sc -eq 1) { "@1x" } else { "@${sc}x" }
    # For 83.5 we keep the name "83.5"
    $szName = if ($sz -eq [int]$sz) { [int]$sz } else { $sz }
    $name = "Icon-App-${szName}x${szName}${suffix}.png"
    Save-Png $srcBmp (Join-Path $iosDir $name) $px
  }
}

# --- macOS AppIcon.appiconset (old Flutter template naming: app_icon_16 / 32 / ... 1024) ---
$macosTargets = @(16,32,64,128,256,512,1024)
# Flutter macOS actually uses app_icon_16.png, app_icon_32.png, app_icon_64.png, app_icon_128.png, app_icon_256.png, app_icon_512.png, and 1024. Also need @2x variants for some? Contents.json decides. Let's just write the 8 commonly present ones.
$macDir = "$ProjRoot\macos\Runner\Assets.xcassets\AppIcon.appiconset"
foreach ($s in $macosTargets) {
  Save-Png $srcBmp (Join-Path $macDir "app_icon_${s}.png") $s
  # optional @2x half-size naming some templates use: produce double-resolution with name app_icon_S@2x where pixel = S*2
  Save-Png $srcBmp (Join-Path $macDir "app_icon_${s}@2x.png") ($s * 2)
}

$srcBmp.Dispose()
$ico.Dispose()
Write-Host "--- All platform icons deployed ---"
