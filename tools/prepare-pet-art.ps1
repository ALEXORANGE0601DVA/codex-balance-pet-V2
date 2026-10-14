<#
  prepare-pet-art.ps1 — 把网上下载的立绘处理成桌宠可用的素材

  做三件事：
    1. 只保留与主体相连的不透明像素（去掉画师水印、签名、旁边漂浮的杂物）
    2. 按 alpha 裁掉透明边
    3. 等比缩放并底部居中放进 320x400 画布

  用法：
    pwsh -NoProfile -File prepare-pet-art.ps1 -Source <图片路径> [-Name base]
#>
param(
  [Parameter(Mandatory = $true)][string]$Source,
  [string]$Name = 'base',
  [int]$CanvasW = 320,
  [int]$CanvasH = 400,
  [int]$Padding = 6,
  [switch]$RemoveBackground,
  [int]$Tolerance = 30,
  [string]$AssetDir = (Join-Path $PSScriptRoot '..\pet\assets'),
  [string]$PreviewDir = (Join-Path $PSScriptRoot '..\docs\preview')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$artCode = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class ArtTool {
    static byte[] ReadPixels(Bitmap bmp, out int stride, out BitmapData data) {
        data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        stride = Math.Abs(data.Stride);
        byte[] buffer = new byte[stride * bmp.Height];
        Marshal.Copy(data.Scan0, buffer, 0, buffer.Length);
        return buffer;
    }

    // 只保留包含图像中心的最大不透明连通块，其余（水印、签名、漂浮杂物）直接置为透明
    public static int KeepLargestComponent(Bitmap bmp, int alphaThreshold) {
        int w = bmp.Width, h = bmp.Height;
        BitmapData data;
        int stride;
        byte[] buffer = ReadPixels(bmp, out stride, out data);
        try {
            bool[] opaque = new bool[w * h];
            for (int y = 0; y < h; y++) {
                int row = y * stride;
                int mrow = y * w;
                for (int x = 0; x < w; x++) {
                    if (buffer[row + x * 4 + 3] > alphaThreshold) opaque[mrow + x] = true;
                }
            }

            int seed = -1;
            int cx = w / 2, cy = h / 2;
            int maxR = Math.Max(w, h);
            for (int r = 0; r < maxR && seed < 0; r++) {
                for (int dy = -r; dy <= r && seed < 0; dy++) {
                    for (int dx = -r; dx <= r && seed < 0; dx++) {
                        int x = cx + dx, y = cy + dy;
                        if (x >= 0 && y >= 0 && x < w && y < h && opaque[y * w + x]) seed = y * w + x;
                    }
                }
            }
            if (seed < 0) return 0;

            bool[] keep = new bool[w * h];
            int[] stack = new int[w * h];
            int sp = 0;
            stack[sp++] = seed;
            keep[seed] = true;
            while (sp > 0) {
                int cur = stack[--sp];
                int x = cur % w, y = cur / w;
                if (x > 0) { int n = cur - 1; if (opaque[n] && !keep[n]) { keep[n] = true; stack[sp++] = n; } }
                if (x < w - 1) { int n = cur + 1; if (opaque[n] && !keep[n]) { keep[n] = true; stack[sp++] = n; } }
                if (y > 0) { int n = cur - w; if (opaque[n] && !keep[n]) { keep[n] = true; stack[sp++] = n; } }
                if (y < h - 1) { int n = cur + w; if (opaque[n] && !keep[n]) { keep[n] = true; stack[sp++] = n; } }
            }

            int removed = 0;
            for (int y = 0; y < h; y++) {
                int row = y * stride;
                int mrow = y * w;
                for (int x = 0; x < w; x++) {
                    int i = mrow + x;
                    if (opaque[i] && !keep[i]) {
                        int p = row + x * 4;
                        buffer[p] = 0; buffer[p + 1] = 0; buffer[p + 2] = 0; buffer[p + 3] = 0;
                        removed++;
                    }
                }
            }
            Marshal.Copy(buffer, 0, data.Scan0, buffer.Length);
            return removed;
        } finally {
            bmp.UnlockBits(data);
        }
    }

    public static int[] AlphaBounds(Bitmap bmp, int threshold) {
        int w = bmp.Width, h = bmp.Height;
        BitmapData data;
        int stride;
        byte[] buffer = ReadPixels(bmp, out stride, out data);
        try {
            int minX = w, minY = h, maxX = -1, maxY = -1;
            for (int y = 0; y < h; y++) {
                int row = y * stride;
                for (int x = 0; x < w; x++) {
                    if (buffer[row + x * 4 + 3] > threshold) {
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }
            if (maxX < 0) return new int[] { 0, 0, 0, 0 };
            return new int[] { minX, minY, maxX - minX + 1, maxY - minY + 1 };
        } finally {
            bmp.UnlockBits(data);
        }
    }

    // 从四边向内做容差洪水填充，把纯色背景（表情包通常是白底）抠成透明
    public static int RemoveBackground(Bitmap bmp, int tolerance) {
        int w = bmp.Width, h = bmp.Height;
        BitmapData data;
        int stride;
        byte[] buffer = ReadPixels(bmp, out stride, out data);
        try {
            // 参考色：四角 + 四边中点的平均
            long sumB = 0, sumG = 0, sumR = 0;
            int[] sx = { 0, w - 1, 0, w - 1, w / 2, w / 2, 0, w - 1 };
            int[] sy = { 0, 0, h - 1, h - 1, 0, h - 1, h / 2, h / 2 };
            for (int i = 0; i < sx.Length; i++) {
                int p = sy[i] * stride + sx[i] * 4;
                sumB += buffer[p]; sumG += buffer[p + 1]; sumR += buffer[p + 2];
            }
            int refB = (int)(sumB / sx.Length), refG = (int)(sumG / sx.Length), refR = (int)(sumR / sx.Length);

            bool[] isBackground = new bool[w * h];
            int[] stack = new int[w * h];
            int sp = 0;
            for (int x = 0; x < w; x++) {
                if (!isBackground[x]) { isBackground[x] = true; stack[sp++] = x; }
                int bottom = (h - 1) * w + x;
                if (!isBackground[bottom]) { isBackground[bottom] = true; stack[sp++] = bottom; }
            }
            for (int y = 0; y < h; y++) {
                int left = y * w;
                if (!isBackground[left]) { isBackground[left] = true; stack[sp++] = left; }
                int right = y * w + w - 1;
                if (!isBackground[right]) { isBackground[right] = true; stack[sp++] = right; }
            }

            int removed = 0;
            while (sp > 0) {
                int cur = stack[--sp];
                int p = (cur / w) * stride + (cur % w) * 4;
                byte b = buffer[p], g = buffer[p + 1], r = buffer[p + 2];
                if (Math.Abs(b - refB) > tolerance || Math.Abs(g - refG) > tolerance || Math.Abs(r - refR) > tolerance) {
                    continue;   // 碰到角色了，停止扩散
                }
                buffer[p] = 0; buffer[p + 1] = 0; buffer[p + 2] = 0; buffer[p + 3] = 0;
                removed++;
                int x = cur % w, y = cur / w;
                if (x > 0) { int n = cur - 1; if (!isBackground[n]) { isBackground[n] = true; stack[sp++] = n; } }
                if (x < w - 1) { int n = cur + 1; if (!isBackground[n]) { isBackground[n] = true; stack[sp++] = n; } }
                if (y > 0) { int n = cur - w; if (!isBackground[n]) { isBackground[n] = true; stack[sp++] = n; } }
                if (y < h - 1) { int n = cur + w; if (!isBackground[n]) { isBackground[n] = true; stack[sp++] = n; } }
            }
            Marshal.Copy(buffer, 0, data.Scan0, buffer.Length);
            return removed;
        } finally {
            bmp.UnlockBits(data);
        }
    }
}
'@

Add-Type -TypeDefinition $artCode -Language CSharp -ReferencedAssemblies @(
  [System.Drawing.Bitmap].Assembly.Location,
  [System.Drawing.Rectangle].Assembly.Location
)

# 统一转成 32 位 ARGB：JPEG 没有 alpha 通道，直接处理会把写入的透明通道丢掉
$loaded = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $Source).Path)
$bitmap = New-Object System.Drawing.Bitmap($loaded.Width, $loaded.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$copyGraphics = [System.Drawing.Graphics]::FromImage($bitmap)
$copyGraphics.DrawImageUnscaled($loaded, 0, 0)
$copyGraphics.Dispose()
Write-Host ("source: {0} ({1}x{2}, 原格式 {3})" -f (Split-Path $Source -Leaf), $loaded.Width, $loaded.Height, $loaded.PixelFormat)
$loaded.Dispose()

if ($RemoveBackground) {
  $bgRemoved = [ArtTool]::RemoveBackground($bitmap, $Tolerance)
  Write-Host ("removed background pixels: " + $bgRemoved)
}

$removed = [ArtTool]::KeepLargestComponent($bitmap, 8)
Write-Host ("removed detached pixels: " + $removed)

$bounds = [ArtTool]::AlphaBounds($bitmap, 8)
Write-Host ("subject bounds: x={0} y={1} w={2} h={3}" -f $bounds[0], $bounds[1], $bounds[2], $bounds[3])
if ($bounds[2] -le 0) { throw '图片里没有找到不透明主体' }

$maxW = $CanvasW - $Padding * 2
$maxH = $CanvasH - $Padding
$scale = [Math]::Min($maxW / $bounds[2], $maxH / $bounds[3])
$drawW = [int][Math]::Round($bounds[2] * $scale)
$drawH = [int][Math]::Round($bounds[3] * $scale)
$drawX = [int][Math]::Round(($CanvasW - $drawW) / 2)
$drawY = $CanvasH - $Padding - $drawH

$canvas = New-Object System.Drawing.Bitmap($CanvasW, $CanvasH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.InterpolationMode = 'HighQualityBicubic'
$g.PixelOffsetMode = 'HighQuality'
$g.Clear([System.Drawing.Color]::Transparent)
$sourceRect = New-Object System.Drawing.Rectangle($bounds[0], $bounds[1], $bounds[2], $bounds[3])
$destRect = New-Object System.Drawing.Rectangle($drawX, $drawY, $drawW, $drawH)
$g.DrawImage($bitmap, $destRect, $sourceRect, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$bitmap.Dispose()

$assetDir = $AssetDir
if (-not (Test-Path -LiteralPath $assetDir)) { New-Item -ItemType Directory -Force -Path $assetDir | Out-Null }
$target = Join-Path $assetDir ("pet-" + $Name + ".png")
$canvas.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host ("saved: " + $target + "  (drawn at " + $drawX + "," + $drawY + " " + $drawW + "x" + $drawH + ")")

# 预览：棋盘底 + 放大 2 倍
$previewDir = $PreviewDir
if (-not (Test-Path -LiteralPath $previewDir)) { New-Item -ItemType Directory -Force -Path $previewDir | Out-Null }
$sheet = New-Object System.Drawing.Bitmap(($CanvasW * 2), ($CanvasH * 2), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$sg = [System.Drawing.Graphics]::FromImage($sheet)
$sg.InterpolationMode = 'NearestNeighbor'
$light = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 240, 240, 244))
$dark = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 212, 212, 220))
for ($y = 0; $y -lt $sheet.Height; $y += 14) {
  for ($x = 0; $x -lt $sheet.Width; $x += 14) {
    $brush = if ((($x / 14) + ($y / 14)) % 2 -eq 0) { $light } else { $dark }
    $sg.FillRectangle($brush, $x, $y, 14, 14)
  }
}
$sg.DrawImage($canvas, 0, 0, $CanvasW * 2, $CanvasH * 2)
$sg.Dispose()
$previewPath = Join-Path $previewDir ("asset-" + $Name + ".png")
$sheet.Save($previewPath, [System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()
$canvas.Dispose()
Write-Host ("preview: " + $previewPath)
