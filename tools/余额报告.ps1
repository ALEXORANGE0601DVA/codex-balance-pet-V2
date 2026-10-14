<#
  余额报告.ps1 — 把桌宠记录的余额日志汇总成表格 + 曲线图

  日志由桌宠自动追加（pet\data\balance-log.csv），
  默认每 30 分钟一行，正常退出时补一行；字段：timestamp,balance,currency,source,window

  用法：
    pwsh -NoProfile -File 余额报告.ps1                 # 全部记录
    pwsh -NoProfile -File 余额报告.ps1 -Days 1         # 只看最近 1 天
#>
param(
  [string]$LogFile = (Join-Path $PSScriptRoot '..\pet\data\balance-log.csv'),
  [string]$OutDir  = (Join-Path $PSScriptRoot '..\docs\reports'),
  [int]$Days = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $LogFile)) {
  Write-Host ('没有找到余额日志：' + $LogFile)
  Write-Host '桌宠运行后会自动生成（每 30 分钟记录一次）。'
  exit 1
}

$rows = @(Import-Csv -LiteralPath $LogFile |
  Where-Object { $_.balance -as [double] } |
  ForEach-Object {
    [pscustomobject]@{
      t       = [datetime]::Parse($_.timestamp)
      balance = [double]$_.balance
      source  = $_.source
    }
  } | Sort-Object t)

if ($rows.Count -lt 2) {
  Write-Host ('记录太少（' + $rows.Count + ' 条），至少两条才能算消耗。')
  exit 0
}

if ($Days -gt 0) {
  $cut = (Get-Date).AddDays(-$Days)
  $rows = @($rows | Where-Object { $_.t -ge $cut })
  if ($rows.Count -lt 2) { Write-Host '该时间范围内记录不足。'; exit 0 }
}

$first = $rows[0]
$last = $rows[-1]
$spent = [Math]::Round($first.balance - $last.balance, 2)
$hours = [Math]::Round(($last.t - $first.t).TotalHours, 2)
$rate = if ($hours -gt 0) { [Math]::Round($spent / $hours, 2) } else { 0 }

# 逐段累加消耗，按“起点所在小时”分桶
$segments = @()
for ($i = 1; $i -lt $rows.Count; $i++) {
  $delta = $rows[$i - 1].balance - $rows[$i].balance
  $segments += [pscustomobject]@{
    hour  = (Get-Date -Date $rows[$i - 1].t -Format 'MM-dd HH时')
    delta = [Math]::Round($delta, 3)
    order = (Get-Date -Date $rows[$i - 1].t -Format 'yyyyMMddHH')
  }
}
$byHour = $segments | Group-Object hour, order | ForEach-Object {
  [pscustomobject]@{
    hour  = $_.Group[0].hour
    spend = [Math]::Round(($_.Group | Measure-Object -Property delta -Sum).Sum, 2)
  }
} | Sort-Object hour

Write-Host ''
Write-Host ('记录区间：{0:yyyy-MM-dd HH:mm} → {1:yyyy-MM-dd HH:mm}（{2} 小时 / {3} 条）' -f $first.t, $last.t, $hours, $rows.Count)
Write-Host ('余额：{0:N2} → {1:N2}，共消耗 ¥{2:N2}' -f $first.balance, $last.balance, $spent)
Write-Host ('平均消耗：¥{0:N2} / 小时' -f $rate)
if ($rate -gt 0) { Write-Host ('按这个速度，剩余 ¥{0:N2} 大约还能用 {1:N1} 小时' -f $last.balance, ($last.balance / $rate)) }
Write-Host ''
Write-Host '逐小时消耗：'
$byHour | ForEach-Object { '  {0}   ¥{1,6:N2}' -f $_.hour, $_.spend }

#region 画图

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$canvasW = 1000
$canvasH = 560
$bitmap = New-Object System.Drawing.Bitmap($canvasW, $canvasH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bitmap)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.Clear([System.Drawing.Color]::FromArgb(255, 250, 251, 253))

$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$fontLabel = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$ink       = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 40, 46, 70))
$muted     = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 130, 138, 160))
$linePen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 77, 107, 254), 3)
$dotBrush  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 77, 107, 254))
$gridPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 226, 230, 240), 1)
$barBrush  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 146, 74))

$g.DrawString('余额消耗记录', $fontTitle, $ink, [float]24, [float]16)
$subtitle = ('{0:MM-dd HH:mm} → {1:MM-dd HH:mm}　共消耗 ¥{2:N2}　平均 ¥{3:N2}/小时　当前 ¥{4:N2}' -f $first.t, $last.t, $spent, $rate, $last.balance)
$g.DrawString($subtitle, $fontLabel, $muted, [float]26, [float]46)

# 上半：余额曲线
$plotX = 70.0; $plotY = 84.0; $plotW = $canvasW - 110.0; $plotH = 250.0
$maxBalance = ($rows | Measure-Object -Property balance -Maximum).Maximum
$minBalance = ($rows | Measure-Object -Property balance -Minimum).Minimum
$top = [Math]::Ceiling($maxBalance * 1.1)
$bottom = [Math]::Max(0, [Math]::Floor($minBalance * 0.9))
if ($top -le $bottom) { $top = $bottom + 1 }
$totalMinutes = [Math]::Max(1, ($last.t - $first.t).TotalMinutes)

$g.DrawRectangle($gridPen, [float]$plotX, [float]$plotY, [float]$plotW, [float]$plotH)
for ($i = 0; $i -le 4; $i++) {
  $value = $bottom + (($top - $bottom) * $i / 4.0)
  $y = $plotY + $plotH - ($plotH * ($value - $bottom) / ($top - $bottom))
  $g.DrawLine($gridPen, [float]$plotX, [float]$y, [float]($plotX + $plotW), [float]$y)
  $g.DrawString(('¥{0:N2}' -f $value), $fontSmall, $muted, [float]20, [float]($y - 8))
}

$points = New-Object System.Collections.ArrayList
foreach ($row in $rows) {
  $x = $plotX + ($plotW * (($row.t - $first.t).TotalMinutes / $totalMinutes))
  $y = $plotY + $plotH - ($plotH * ($row.balance - $bottom) / ($top - $bottom))
  $null = $points.Add((New-Object System.Drawing.PointF([float]$x, [float]$y)))
}
if ($points.Count -gt 1) { $g.DrawLines($linePen, [System.Drawing.PointF[]]$points.ToArray()) }
foreach ($p in $points) { $g.FillEllipse($dotBrush, ($p.X - 3), ($p.Y - 3), 6, 6) }
$g.DrawString(('{0:HH:mm}' -f $first.t), $fontSmall, $muted, [float]$plotX, [float]($plotY + $plotH + 6))
$g.DrawString(('{0:HH:mm}' -f $last.t), $fontSmall, $muted, [float]($plotX + $plotW - 34), [float]($plotY + $plotH + 6))

# 下半：逐小时消耗柱状
$barTop = 400.0; $barH = 110.0; $barAreaX = 70.0; $barAreaW = $canvasW - 130.0
$g.DrawString('逐小时消耗', $fontLabel, $ink, [float]24, [float]($barTop - 24))
$maxSpend = 0.0
foreach ($item in $byHour) { if ($item.spend -gt $maxSpend) { $maxSpend = $item.spend } }
if ($maxSpend -le 0) { $maxSpend = 1 }
$barCount = [Math]::Max(1, @($byHour).Count)
$barSlot = $barAreaW / $barCount
$barW = [Math]::Max(6, [Math]::Min(46, $barSlot * 0.6))
$i = 0
foreach ($item in $byHour) {
  $h = $barH * ($item.spend / $maxSpend)
  $x = $barAreaX + ($i * $barSlot) + (($barSlot - $barW) / 2)
  $g.FillRectangle($barBrush, [float]$x, [float]($barTop + $barH - $h), [float]$barW, [float]$h)
  $g.DrawString($item.hour, $fontSmall, $muted, [float]($x - 6), [float]($barTop + $barH + 6))
  $g.DrawString(('¥{0:N2}' -f $item.spend), $fontSmall, $ink, [float]($x - 6), [float]($barTop + $barH - $h - 16))
  $i++
}
$g.Dispose()

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$chartPath = Join-Path $OutDir ('余额报告-' + $stamp + '.png')
$bitmap.Save($chartPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
Write-Host ''
Write-Host ('图表：' + $chartPath)

#endregion
