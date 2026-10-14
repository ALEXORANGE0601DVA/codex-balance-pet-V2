<#
  pet-host.ps1 — 由 Codex 插件启动的常驻 MCP 服务

  职责很单一：
    · Codex 一开始跑，就把桌宠拉起来（已经开着就不重复开）
    · 桌宠自己带着守护逻辑：Codex 进程消失 15 秒后自动关闭
    · 顺带提供 pet 工具，可以在对话里控制它（start/stop/restart/status）

  进程用 WMI 创建，脱离 Codex 的进程树，避免某个会话结束时被一起收走。
#>
param(
  # 桌宠本体路径。留空则自动解析：
  #   1) 本脚本同目录（部署后 pet-host.ps1 与 balance-pet.ps1 同在 %USERPROFILE%\.codex\pets\balance-pet）
  #   2) 插件目录里的这份启动链负责拉起常驻副本 %USERPROFILE%\.codex\pets\balance-pet\balance-pet.ps1
  #   3) 仓库布局：../pet/balance-pet.ps1
  [string]$PetScript
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not $PetScript) {
  foreach ($candidate in @(
      (Join-Path $PSScriptRoot 'balance-pet.ps1'),
      (Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }) 'pets\balance-pet\balance-pet.ps1'),
      (Join-Path (Split-Path $PSScriptRoot -Parent) 'pet\balance-pet.ps1')
    )) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { $PetScript = $candidate; break }
  }
}

# 无控制台启动器（和桌宠放在一起，插件目录里也有一份）
$launcherCandidates = @(
  (Join-Path $PSScriptRoot 'winless-launch.ps1'),
  (Join-Path (Split-Path $PetScript -Parent) 'winless-launch.ps1')
)
foreach ($launcher in $launcherCandidates) {
  if (Test-Path -LiteralPath $launcher) { . $launcher; break }
}

function Get-PetStatusPath {
  return (Join-Path ([System.IO.Path]::GetTempPath()) 'balance-pet-status.json')
}

function Get-PetProcess {
  $file = Get-PetStatusPath
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try {
    $status = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if (-not $status.pid) { return $null }
    $process = Get-Process -Id ([int]$status.pid)
    if ($process -and $process.ProcessName -eq 'pwsh') { return $process }
  } catch { }
  return $null
}

function Resolve-Pwsh {
  $candidates = @()
  if ($env:CODEX_MCP_NODE_PATH) {
    $candidates += (Join-Path (Split-Path $env:CODEX_MCP_NODE_PATH -Parent) 'pwsh.exe')
  }
  if ($env:USERPROFILE) {
    $candidates += (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
  }
  $candidates += (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Start-Pet {
  if (Get-PetProcess) { return 'already running' }
  if (-not (Test-Path -LiteralPath $PetScript)) { return ('missing pet script: ' + $PetScript) }
  $pwsh = Resolve-Pwsh
  $commandLine = '"' + $pwsh + '" -NoProfile -File "' + $PetScript + '"'

  # 首选：CreateProcess + CREATE_NO_WINDOW，进程不分配控制台，任务栏不会多窗口
  if (Get-Command Start-HiddenProcess -ErrorAction SilentlyContinue) {
    $petProcessId = Start-HiddenProcess -CommandLine $commandLine -WorkingDirectory (Split-Path $PetScript -Parent)
    if ($petProcessId -gt 0) { return ('started (pid ' + $petProcessId + ', no console window)') }
  }

  # 退路：不新开控制台，复用当前这个（隐藏的）控制台
  Start-Process -FilePath $pwsh -ArgumentList ('-NoProfile -File "' + $PetScript + '"') -NoNewWindow
  return 'started (fallback)'
}

function Stop-Pet {
  $process = Get-PetProcess
  if (-not $process) { return 'not running' }
  Stop-Process -Id $process.Id -Force
  return 'stopped'
}

function Get-PetSummary {
  $process = Get-PetProcess
  if (-not $process) { return '桌宠当前没有运行' }
  $file = Get-PetStatusPath
  $status = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  return ('桌宠运行中：pid={0}，余额={1}，位置={2}，更新于 {3}' -f $status.pid, $status.balance, $status.location, $status.updated_at)
}

# Codex 一起来就把桌宠拉起来
$startResult = Start-Pet
[Console]::Error.WriteLine('[balance-pet] ' + $startResult)

$petTool = @{
  name        = 'pet'
  description = '控制桌面余额桌宠：start 启动、stop 关闭、restart 重启、status 查看状态。'
  inputSchema = @{
    type       = 'object'
    properties = @{
      action = @{
        type        = 'string'
        enum        = @('start', 'stop', 'restart', 'status')
        description = '要执行的操作'
      }
    }
    required   = @('action')
  }
}

$writer = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object System.Text.UTF8Encoding($false)))
$writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)

function Send-Message {
  param($Message)
  $writer.WriteLine(($Message | ConvertTo-Json -Depth 10 -Compress))
}

function Reply-Text {
  param($Id, [string]$Text, [bool]$IsError = $false)
  $result = @{ content = @(@{ type = 'text'; text = $Text }) }
  if ($IsError) { $result.isError = $true }
  Send-Message @{ jsonrpc = '2.0'; id = $Id; result = $result }
}

while ($true) {
  $line = $reader.ReadLine()
  if ($null -eq $line) { break }
  if (-not $line.Trim()) { continue }

  try { $message = $line | ConvertFrom-Json } catch { continue }
  if ($null -eq $message.id) { continue }
  $id = $message.id

  switch ($message.method) {
    'initialize' {
      $wanted = $message.params.protocolVersion
      $protocol = if ($wanted) { $wanted } else { '2025-06-18' }
      Send-Message @{
        jsonrpc = '2.0'
        id      = $id
        result  = @{
          protocolVersion = $protocol
          capabilities    = @{ tools = @{ listChanged = $false } }
          serverInfo      = @{ name = 'balance-pet'; version = '1.0.0' }
        }
      }
    }
    'tools/list' {
      Send-Message @{ jsonrpc = '2.0'; id = $id; result = @{ tools = @($petTool) } }
    }
    'tools/call' {
      $action = $message.params.arguments.action
      switch ($action) {
        'start'   { Reply-Text -Id $id -Text (Start-Pet) }
        'stop'    { Reply-Text -Id $id -Text (Stop-Pet) }
        'restart' { $null = Stop-Pet; Start-Sleep -Milliseconds 800; Reply-Text -Id $id -Text ('restart -> ' + (Start-Pet)) }
        'status'  { Reply-Text -Id $id -Text (Get-PetSummary) }
        default   { Reply-Text -Id $id -Text ('未知操作：' + $action) -IsError $true }
      }
    }
    'ping' {
      Send-Message @{ jsonrpc = '2.0'; id = $id; result = @{} }
    }
    default {
      Send-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = ('Method not found: ' + $message.method) } }
    }
  }
}

# stdin 关闭 = Codex 关掉了这个服务；桌宠由它自己的守护逻辑收尾
exit 0
