<#
  extract-stickers.ps1 — 从离线保存的网页里提取图片素材

  用途：知乎/论坛这类页面把图片放 CDN 上，离线 HTML 里保留的是链接。
  本脚本提取内容图链接、下载到本地（带 Referer 绕过防盗链），
  再生成一张对照图，方便一眼看清都是些什么图。

  用法：
    pwsh -NoProfile -File extract-stickers.ps1 -Html "页面.html" -OutDir "素材\某某表情包" -Limit 40
    pwsh -NoProfile -File extract-stickers.ps1 -Html "页面.html" -OutDir "..." -NoDownload   # 只看清单
#>
param(
  [Parameter(Mandatory = $true)][string]$Html,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [int]$Limit = 0,
  [int]$ExtraCount = 8,
  [switch]$NoDownload
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $Html)) { throw "找不到网页文件：$Html" }
$content = Get-Content -LiteralPath $Html -Raw

# 正文图：知乎的懒加载属性是 data-original（可能带 ?source=... 查询串），
# 头像之类在 <meta itemprop=image> 里，所以只认图片扩展名 + 正文容器
$candidates = @()
foreach ($pattern in @(
    'class="origin_image[^"]*"[^>]*data-original="(https?://[^"]+)"',
    'data-original="(https?://[^"]+)"',
    '"originalUrl":"(https?://[^"]+)"'
  )) {
  foreach ($match in [regex]::Matches($content, $pattern)) {
    $candidates += $match.Groups[1].Value
  }
}
$candidates = $candidates | Where-Object { $_ -match '\.(png|jpg|jpeg|gif|webp)(\?|$)' -and $_ -match 'zhimg\.com|zhihu\.com' }

# 同一张图可能有多个 CDN 尺寸变体，按 v2-<hash> 去重，优先保留原图（不带 /50/ 前缀）
$normalized = [ordered]@{}
foreach ($url in $candidates) {
  $clean = $url -replace '\?.*$', ''
  $key = [regex]::Match($clean, 'v2-[0-9a-f]{32}').Value
  if (-not $key) { $key = $clean }
  $isThumb = $clean -match 'zhimg\.com/50/'
  if (-not $normalized.Contains($key)) {
    $normalized[$key] = $clean
  } elseif ($isThumb -and ($normalized[$key] -match 'zhimg\.com/50/')) {
    $normalized[$key] = $clean
  }
}
$unique = @($normalized.Values)
Write-Host ("提取到内容图链接：" + $unique.Count)

if ($Limit -gt 0) { $unique = $unique | Select-Object -First $Limit }
$unique | ForEach-Object { Write-Host ("  " + $_) }

if ($NoDownload) { exit 0 }

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
$results = @()
$index = 0

foreach ($url in $unique) {
  $index++
  $extension = [System.IO.Path]::GetExtension(($url -replace '\?.*$', ''))
  if (-not $extension) { $extension = '.jpg' }
  $target = Join-Path $OutDir ('raw-{0:d3}{1}' -f $index, $extension)
  try {
    Invoke-WebRequest -Uri $url -OutFile $target -TimeoutSec 30 -UseBasicParsing -Headers @{
      'User-Agent' = $userAgent
      'Referer'    = 'https://www.zhihu.com/'
    }
    $bitmap = [System.Drawing.Bitmap]::FromFile($target)
    $results += [pscustomobject]@{
      index  = $index
      file   = $target
      width  = $bitmap.Width
      height = $bitmap.Height
      kb     = [math]::Round((Get-Item -LiteralPath $target).Length / 1KB)
      url    = $url
    }
    $bitmap.Dispose()
  } catch {
    Write-Host ("skip {0:d3} {1}" -f $index, $_.Exception.Message)
  }
}

Write-Host ("下载成功：" + @($results).Count)
$results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutDir 'list.json') -Encoding utf8

if (@($results).Count -eq 0) { exit 0 }

# 对照图：每张等比缩放进 260x260 的格子，一眼看清内容
$cell = 260
$cols = 6
$rows = [Math]::Ceiling(@($results).Count / $cols)
$sheet = New-Object System.Drawing.Bitmap(($cell * $cols), ($cell * $rows), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.InterpolationMode = 'HighQualityBicubic'
$bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 245, 248))
$g.FillRectangle($bg, 0, 0, $sheet.Width, $sheet.Height)
$font = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
$labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 190, 40, 40))

for ($i = 0; $i -lt @($results).Count; $i++) {
  $item = $results[$i]
  $cellX = ($i % $cols) * $cell
  $cellY = [Math]::Floor($i / $cols) * $cell
  $bitmap = [System.Drawing.Bitmap]::FromFile($item.file)
  $scale = [Math]::Min(($cell - 16) / $bitmap.Width, ($cell - 32) / $bitmap.Height)
  $drawW = [int]($bitmap.Width * $scale)
  $drawH = [int]($bitmap.Height * $scale)
  $g.DrawImage($bitmap, ($cellX + [int](($cell - $drawW) / 2)), ($cellY + 24 + [int](($cell - 32 - $drawH) / 2)), $drawW, $drawH)
  $g.DrawString(('#{0:d3} {1}x{2}' -f $item.index, $item.width, $item.height), $font, $labelBrush, [float]($cellX + 6), [float]($cellY + 4))
  $bitmap.Dispose()
}
$g.Dispose()
$sheetPath = Join-Path $OutDir 'contact-sheet.png'
$sheet.Save($sheetPath, [System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()
Write-Host ("对照图：" + $sheetPath)
