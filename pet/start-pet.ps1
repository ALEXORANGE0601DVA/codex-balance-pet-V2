<#
  start-pet.ps1 — 手动启动桌宠（不产生任务栏窗口）
  双击 启动余额桌宠.cmd 时走的就是这个脚本。
#>
param(
  [string]$PetScript = (Join-Path $PSScriptRoot 'balance-pet.ps1')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winless-launch.ps1')

function Test-PetRunning {
  $statusFile = Join-Path ([System.IO.Path]::GetTempPath()) 'balance-pet-status.json'
  if (-not (Test-Path -LiteralPath $statusFile)) { return $false }
  try {
    $status = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
    if (-not $status.pid) { return $false }
    return [bool](Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue)
  } catch {
    return $false
  }
}

if (-not (Test-Path -LiteralPath $PetScript)) {
  Write-Host ('找不到桌宠脚本：' + $PetScript)
  exit 1
}

if (Test-PetRunning) {
  Write-Host '桌宠已经在运行了，不重复启动'
  exit 0
}

$pwsh = $null
$candidates = @(
  (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe'),
  (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
)
foreach ($candidate in $candidates) {
  if ($candidate -and (Test-Path -LiteralPath $candidate)) { $pwsh = $candidate; break }
}
if (-not $pwsh) { $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

$commandLine = '"' + $pwsh + '" -NoProfile -File "' + $PetScript + '"'
$newProcessId = Start-HiddenProcess -CommandLine $commandLine -WorkingDirectory (Split-Path $PetScript -Parent)
if ($newProcessId -gt 0) {
  Write-Host ('桌宠已启动（pid ' + $newProcessId + '，无命令行窗口）')
} else {
  Write-Host '启动失败'
  exit 1
}
