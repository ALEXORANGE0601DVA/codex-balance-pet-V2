param([string]$ModulePath=(Join-Path $PSScriptRoot '..\pet\task-activity.ps1'))
$ErrorActionPreference='Stop'
. $ModulePath
function Assert-Equal($Actual,$Expected,[string]$Label) { if ($Actual -ne $Expected) { throw "$Label expected $Expected received $Actual" } }
function Json-Line($Object) { return ($Object | ConvertTo-Json -Depth 12 -Compress)+"`n" }
function Meta([string]$Id,[string]$Parent='') {
  $payload=@{id=$Id;source='vscode'}
  if ($Parent) { $payload.parent_thread_id=$Parent; $payload.source=@{subagent=@{thread_spawn=@{parent_thread_id=$Parent}}} }
  return Json-Line @{type='session_meta';payload=$payload}
}
function Event([string]$Type,[string]$Turn,[string]$Stamp) { return Json-Line @{type='event_msg';timestamp=$Stamp;payload=@{type=$Type;turn_id=$Turn;root_turn_id=$Turn;started_at=$Stamp}} }
function Row([string]$Thread,[string]$Turn,[string]$Status,[bool]$Child=$false,[string]$Parent='') {
  return [pscustomobject]@{thread_id=$Thread;turn_id=$Turn;status=$Status;started_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();archived=$false;is_subagent=$Child;parent_thread_id=$Parent}
}
function Write-Log([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
function Append-Log([string]$Path,[string]$Text) { [IO.File]::AppendAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
$fixture=Join-Path $PSScriptRoot ('task-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$main=Join-Path $fixture 'rollout-main.jsonl';$second=Join-Path $fixture 'rollout-second.jsonl';$child=Join-Path $fixture 'rollout-child.jsonl'
$script:mockRows=@();$script:storeAvailable=$true;$script:runtimeRunning=$true;$script:runtimeStarted=[datetime]::UtcNow.AddDays(-1)
$store={ [pscustomobject]@{available=$script:storeAvailable;threads=@($script:mockRows)} }
$runtime={ [pscustomobject]@{Running=$script:runtimeRunning;StartedAt=$script:runtimeStarted} }
$stamp=[datetime]::UtcNow.ToString('o')
try {
  Write-Log $main ((Meta 'main')+(Event 'task_started' 'old-orphan' $stamp))
  $script:mockRows=@((Row 'main' 'newer-completed' 'completed'))
  Initialize-TaskActivity -SessionsDirectory $fixture -CodexDirectory $fixture -StoreReader $store -RuntimeReader $runtime
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $false 'Latest DB completed turn rejects historical orphan started'
  Assert-Equal $result.ActiveCount 0 'No ghost task'

  $script:storeAvailable=$false
  Initialize-TaskActivity -SessionsDirectory $fixture -CodexDirectory $fixture -StoreReader $store -RuntimeReader $runtime
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $false 'Historical unmatched start without authority stays unverified'
  Assert-Equal $result.Phase 'unverified' 'Authority unavailable is explicit'
  $script:storeAvailable=$true

  $partial=Event 'task_started' 'live-turn' $stamp
  Append-Log $main $partial.Substring(0,[int]($partial.Length/2))
  $script:mockRows=@((Row 'main' 'newer-completed' 'completed'))
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $false 'Half line cannot start a task'
  Append-Log $main $partial.Substring([int]($partial.Length/2))
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $true 'New complete start activates immediately before DB catches up'
  Assert-Equal $result.ActiveCount 1 'One primary task'
  Assert-Equal $result.TaskId 'live-turn' 'Only opaque task identifier is returned'
  Append-Log $main (Event 'turn_aborted' 'other-turn' $stamp)
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $true 'Abort for a different turn does not stop current work'
  $script:mockRows=@((Row 'main' 'live-turn' 'inProgress'))
  Append-Log $main (Json-Line @{type='response_item';payload=@{type='function_call';name='fixture';arguments='dummy-secret'}})
  $result=Update-TaskActivity
  Assert-Equal $result.Phase 'working' 'Tool type affects phase without exposing arguments'
  Assert-Equal (($result | ConvertTo-Json -Compress).Contains('dummy-secret')) $false 'No tool content leaves result'

  Write-Log $second ((Meta 'second')+(Event 'task_started' 'second-turn' $stamp))
  Write-Log $child ((Meta 'child' 'main')+(Event 'task_started' 'child-turn' $stamp))
  $script:mockRows=@((Row 'main' 'live-turn' 'inProgress'),(Row 'second' 'second-turn' 'inProgress'),(Row 'child' 'child-turn' 'inProgress' $true 'main'))
  $result=Update-TaskActivity
  Assert-Equal $result.ActiveCount 2 'Multiple primary tasks are counted and child groups with parent'
  Assert-Equal $result.TaskId $null 'Multiple tasks return no arbitrary task identifier'
  Append-Log $second (Event 'task_complete' 'second-turn' $stamp)
  $script:mockRows=@((Row 'main' 'live-turn' 'inProgress'),(Row 'second' 'second-turn' 'completed'),(Row 'child' 'child-turn' 'inProgress' $true 'main'))
  $result=Update-TaskActivity
  Assert-Equal $result.ActiveCount 1 'Completion leaves one parent cluster'
  Append-Log $main (Event 'turn_aborted' 'live-turn' $stamp)
  $script:mockRows=@((Row 'main' 'live-turn' 'interrupted'),(Row 'second' 'second-turn' 'completed'),(Row 'child' 'child-turn' 'inProgress' $true 'main'))
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $true 'A real running child keeps its parent cluster busy'
  Append-Log $child (Event 'task_complete' 'child-turn' $stamp)
  $script:mockRows=@((Row 'main' 'live-turn' 'interrupted'),(Row 'second' 'second-turn' 'completed'),(Row 'child' 'child-turn' 'completed' $true 'main'))
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $false 'Completion and abort restore idle'

  $script:mockRows=@((Row 'main' 'persisted-before-restart' 'inProgress'))
  $script:mockRows[0].started_at=[DateTimeOffset]::UtcNow.AddHours(-3).ToUnixTimeSeconds()
  $script:runtimeStarted=[datetime]::UtcNow.AddHours(-1)
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $false 'Previous desktop lifetime cannot leave an eternal busy task'
  $script:runtimeRunning=$false
  $result=Update-TaskActivity
  Assert-Equal $result.IsBusy $false 'A balance helper alone is not a task runtime'
  'PASS: start/completion/abort, concurrent primary+child tasks, half line, orphan lifecycle reconciliation, runtime restart, safe output'
} finally {
  foreach ($file in @($main,$second,$child)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture }
}
