# Task activity is independent from token rates and from the balance app-server.
# Only lifecycle IDs/types and read-only SQLite statuses leave these readers.

function Initialize-TaskActivity {
  param([string]$SessionsDirectory, [string]$CodexDirectory, [string]$NodePath, [scriptblock]$StoreReader, [scriptblock]$RuntimeReader)
  if (-not $CodexDirectory) {
    if ($env:CODEX_HOME) { $CodexDirectory = $env:CODEX_HOME }
    else { $CodexDirectory = Join-Path $env:USERPROFILE '.codex' }
  }
  if (-not $SessionsDirectory) { $SessionsDirectory = Join-Path $CodexDirectory 'sessions' }
  if (-not $NodePath) {
    $candidates = @($env:CODEX_MCP_NODE_PATH)
    if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe') }
    $candidates += @(Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    $NodePath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
  }
  $previous = Get-Variable -Name TaskActivity -Scope Script -ErrorAction SilentlyContinue
  if ($previous -and $previous.Value -and $previous.Value.StoreProcess) {
    try { if (-not $previous.Value.StoreProcess.HasExited) { $previous.Value.StoreProcess.Kill() }; $previous.Value.StoreProcess.Dispose() } catch { }
  }
  $script:TaskActivity = @{
    SessionsDir=$SessionsDirectory; CodexHome=$CodexDirectory; NodePath=$NodePath
    StoreHelper=(Join-Path $PSScriptRoot 'task-activity-store.mjs'); StoreReader=$StoreReader; RuntimeReader=$RuntimeReader
    Files=@{}; StoreRows=@{}; StoreAvailable=$false; LastStoreAt=[datetime]::MinValue
    StoreProcess=$null; StoreOutput=$null; StoreError=$null; StoreStartedAt=[datetime]::MinValue
    Runtime=$null; LastRuntimeAt=[datetime]::MinValue
    Result=[pscustomobject]@{ IsBusy=$false; ActiveCount=0; Phase='unverified'; TaskId=$null }
  }
}

function Get-TaskRuntime {
  $state = $script:TaskActivity
  if ($state.RuntimeReader) { return (& $state.RuntimeReader) }
  # Exclude the CLI bin process used by balance account/rateLimits/read. A GUI
  # lifetime is corroboration for persistent history, not proof of a live turn.
  $processes = @(Get-Process -Name Codex -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and $_.Path -notmatch '(?i)[\\/]bin[\\/][^\\/]+[\\/]codex\.exe$' } catch { $false }
  })
  if (-not $processes.Count) { return [pscustomobject]@{ Running=$false; StartedAt=$null } }
  $started = @($processes | ForEach-Object { try { $_.StartTime.ToUniversalTime() } catch { } } | Sort-Object | Select-Object -First 1)
  return [pscustomobject]@{ Running=$true; StartedAt=$(if ($started.Count) { $started[0] } else { $null }) }
}

function Set-TaskStoreSnapshot {
  param($Snapshot)
  $state=$script:TaskActivity
  $state.StoreAvailable = $Snapshot -and $Snapshot.available -eq $true
  if (-not $state.StoreAvailable) { return }
  $rows=@{}
  foreach ($row in @($Snapshot.threads)) { if ($row.thread_id) { $rows[[string]$row.thread_id]=$row } }
  $state.StoreRows=$rows
}

function Update-TaskStore {
  $state=$script:TaskActivity; $now=[datetime]::UtcNow
  if ($state.StoreReader) {
    try { Set-TaskStoreSnapshot -Snapshot (& $state.StoreReader) } catch { $state.StoreAvailable=$false }
    $state.LastStoreAt=$now
    return
  }
  if ($state.StoreProcess) {
    $finished=$false
    try { $finished=$state.StoreProcess.HasExited -and $state.StoreOutput.IsCompleted } catch { $finished=$true }
    if ($finished) {
      try {
        $json=$state.StoreOutput.GetAwaiter().GetResult()
        Set-TaskStoreSnapshot -Snapshot ($json | ConvertFrom-Json -ErrorAction Stop)
      } catch { $state.StoreAvailable=$false }
      try { $state.StoreProcess.Dispose() } catch { }
      $state.StoreProcess=$null; $state.StoreOutput=$null; $state.StoreError=$null
    } elseif (($now-$state.StoreStartedAt).TotalSeconds -gt 3) {
      try { $state.StoreProcess.Kill(); $state.StoreProcess.Dispose() } catch { }
      $state.StoreProcess=$null; $state.StoreAvailable=$false
    }
  }
  if ($state.StoreProcess -or ($now-$state.LastStoreAt).TotalSeconds -lt 2) { return }
  $state.LastStoreAt=$now
  if (-not $state.NodePath -or -not (Test-Path -LiteralPath $state.StoreHelper)) { $state.StoreAvailable=$false; return }
  try {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$state.NodePath
    if ($start.PSObject.Properties['ArgumentList']) { $start.ArgumentList.Add($state.StoreHelper); $start.ArgumentList.Add($state.CodexHome) }
    else { $start.Arguments='"' + $state.StoreHelper.Replace('"','\"') + '" "' + $state.CodexHome.TrimEnd('\').Replace('"','\"') + '"' }
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    if (-not $process.Start()) { $process.Dispose(); $state.StoreAvailable=$false; return }
    $state.StoreProcess=$process; $state.StoreStartedAt=$now
    $state.StoreOutput=$process.StandardOutput.ReadToEndAsync()
    $state.StoreError=$process.StandardError.ReadToEndAsync()
  } catch { $state.StoreAvailable=$false }
}

function New-TaskRolloutState {
  param([System.IO.FileInfo]$File)
  return @{
    File=$File.FullName; Offset=[long]0; Carry=''; Decoder=([Text.Encoding]::UTF8.GetDecoder())
    ThreadId=$null; ParentThreadId=$null; IsSubagent=$false; MetaKnown=$false
    TurnId=$null; RootTurnId=$null; StartedAt=$null; Active=$false; LiveStart=$false; Phase='unverified'
    Initial=$true; LengthAtRead=[long]0; ModifiedAt=[datetime]::MinValue; Backlog=$false
  }
}

function Read-TaskEvent {
  param([hashtable]$FileState, [string]$Line, [bool]$Historical)
  if ($Line -notlike '*"session_meta"*' -and $Line -notlike '*"event_msg"*' -and $Line -notlike '*"response_item"*') { return }
  try { $record=$Line | ConvertFrom-Json -ErrorAction Stop } catch { return }
  $payload=$record.payload
  if ($record.type -eq 'session_meta') {
    $FileState.ThreadId=[string]$(if ($payload.id) { $payload.id } else { $payload.session_id })
    $FileState.ParentThreadId=[string]$payload.parent_thread_id
    if (-not $FileState.ParentThreadId -and $payload.source.subagent.thread_spawn.parent_thread_id) { $FileState.ParentThreadId=[string]$payload.source.subagent.thread_spawn.parent_thread_id }
    $FileState.IsSubagent=[bool]($FileState.ParentThreadId -or ($payload.source -isnot [string] -and $payload.source.PSObject.Properties['subagent']))
    $FileState.MetaKnown=$true
    return
  }
  if ($record.type -eq 'event_msg') {
    if ($payload.type -eq 'task_started') {
      $FileState.TurnId=[string]$payload.turn_id
      $FileState.RootTurnId=[string]$payload.root_turn_id
      try { $FileState.StartedAt=[DateTimeOffset]::Parse([string]$(if ($payload.started_at) { $payload.started_at } else { $record.timestamp })).UtcDateTime } catch { $FileState.StartedAt=$null }
      $FileState.Active=$true; $FileState.LiveStart=(-not $Historical); $FileState.Phase='thinking'
    } elseif ($payload.type -in @('task_complete','turn_aborted','task_aborted')) {
      # A replayed completion for an older turn cannot close a newer live turn.
      if (-not $payload.turn_id -or -not $FileState.TurnId -or $payload.turn_id -eq $FileState.TurnId -or
          ($payload.root_turn_id -and $payload.root_turn_id -eq $FileState.RootTurnId)) {
        $FileState.Active=$false; $FileState.LiveStart=$false
        $FileState.Phase=$(if ($payload.type -eq 'task_complete') { 'completed' } else { 'interrupted' })
      }
    } elseif ($payload.type -eq 'item_completed' -and $FileState.Active) {
      if ($payload.item.type -in @('Reasoning','reasoning')) { $FileState.Phase='thinking' }
    }
    return
  }
  if ($record.type -eq 'response_item' -and $FileState.Active) {
    if ($payload.type -in @('function_call','custom_tool_call')) { $FileState.Phase='working' }
    elseif ($payload.type -in @('function_call_output','custom_tool_call_output','reasoning')) { $FileState.Phase='thinking' }
    elseif ($payload.type -in @('message','agent_message') -and $payload.role -eq 'assistant' -and $payload.channel -eq 'final') {
      $FileState.Active=$false; $FileState.LiveStart=$false; $FileState.Phase='completed'
    }
  }
}

function Read-TaskRolloutDelta {
  param([System.IO.FileInfo]$File)
  $state=$script:TaskActivity
  $fileState=$state.Files[$File.FullName]
  if (-not $fileState -or $File.Length -lt $fileState.Offset) { $fileState=New-TaskRolloutState -File $File; $state.Files[$File.FullName]=$fileState }
  if ($File.Length -eq $fileState.Offset) { return }
  $stream=$null
  try {
    $stream=[IO.File]::Open($File.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    [void]$stream.Seek($fileState.Offset,[IO.SeekOrigin]::Begin)
    $count=[int][Math]::Min([long]2097152,$stream.Length-$fileState.Offset)
    if ($count -le 0) { return }
    $bytes=New-Object byte[] $count
    $read=$stream.Read($bytes,0,$count)
    $fileState.Offset=$stream.Position
    $fileState.Backlog=$stream.Position -lt $stream.Length
    $chars=New-Object char[] ([Text.Encoding]::UTF8.GetMaxCharCount($read))
    $decoded=$fileState.Decoder.GetChars($bytes,0,$read,$chars,0,$false)
    $chunk=[string]::new($chars,0,$decoded)
    $lines=($fileState.Carry+$chunk) -split "`n"
    $fileState.Carry=$lines[-1]
    for ($i=0;$i -lt $lines.Count-1;$i++) { Read-TaskEvent -FileState $fileState -Line $lines[$i].TrimEnd("`r") -Historical $fileState.Initial }
    if (-not $fileState.Backlog) { $fileState.Initial=$false }
    $fileState.LengthAtRead=$stream.Length; $fileState.ModifiedAt=$File.LastWriteTimeUtc
  } catch { } finally { if ($stream) { $stream.Dispose() } }
}

function Update-TaskActivity {
  $existing=Get-Variable -Name TaskActivity -Scope Script -ErrorAction SilentlyContinue
  if (-not $existing -or -not $existing.Value) { Initialize-TaskActivity }
  $state=$script:TaskActivity; $now=[datetime]::UtcNow
  Update-TaskStore
  if (-not $state.Runtime -or ($now-$state.LastRuntimeAt).TotalSeconds -ge 5 -or $state.RuntimeReader) {
    try { $state.Runtime=Get-TaskRuntime } catch { $state.Runtime=[pscustomobject]@{ Running=$false; StartedAt=$null } }
    $state.LastRuntimeAt=$now
  }
  try {
    foreach ($file in @(Get-ChildItem -LiteralPath $state.SessionsDir -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
      Read-TaskRolloutDelta -File $file
    }
  } catch { }
  $byThread=@{}
  foreach ($fileState in $state.Files.Values) {
    if ($fileState.MetaKnown -and $fileState.ThreadId -and (-not $byThread.ContainsKey($fileState.ThreadId) -or $fileState.ModifiedAt -gt $byThread[$fileState.ThreadId].ModifiedAt)) { $byThread[$fileState.ThreadId]=$fileState }
  }
  $active=@{}; $phase='idle'; $unverified=$false
  if ($state.Runtime.Running) {
    foreach ($threadId in @($byThread.Keys + $state.StoreRows.Keys | Select-Object -Unique)) {
      $local=$byThread[$threadId]; $row=$state.StoreRows[$threadId]
      if ($row -and $row.archived) { continue }
      $running=$false; $known=$false
      if ($state.StoreAvailable -and $row) {
        $known=$true
        $running=$row.status -eq 'inProgress'
        # An old persisted inProgress turn from an earlier desktop lifetime is
        # unverified, rather than an eternal busy indicator after a restart.
        if ($running -and $state.Runtime.StartedAt -and $row.started_at) {
          $started=[DateTimeOffset]::FromUnixTimeSeconds([long]$row.started_at).UtcDateTime
          if ($started -lt ([datetime]$state.Runtime.StartedAt).ToUniversalTime()) { $running=$false; $known=$false; $unverified=$true }
        }
        if ($local -and $local.TurnId -eq $row.turn_id -and -not $local.Active) { $running=$false }
      }
      if ($local -and $local.Active -and $local.LiveStart -and
          (-not $known -or -not $row -or $local.TurnId -ne $row.turn_id)) { $running=$true }
      if (-not $running) {
        if ($local -and $local.Active -and -not $known) { $unverified=$true }
        continue
      }
      $isSubagent=($local -and $local.IsSubagent) -or ($row -and $row.is_subagent)
      $rootId=$threadId
      if ($isSubagent) {
        $parent=$(if ($local -and $local.ParentThreadId) { $local.ParentThreadId } elseif ($row) { [string]$row.parent_thread_id } else { '' })
        $seen=@{}
        while ($parent -and -not $seen.ContainsKey($parent)) {
          $seen[$parent]=$true; $rootId=$parent
          $ancestor=$byThread[$parent]; $ancestorRow=$state.StoreRows[$parent]
          $parent=$(if ($ancestor -and $ancestor.ParentThreadId) { $ancestor.ParentThreadId } elseif ($ancestorRow -and $ancestorRow.parent_thread_id) { [string]$ancestorRow.parent_thread_id } else { '' })
        }
      }
      $taskPhase=$(if ($local -and $local.Active) { $local.Phase } else { 'working' })
      $taskId=$(if ($local -and $local.TurnId) { $local.TurnId } elseif ($row) { [string]$row.turn_id } else { $null })
      if (-not $active.ContainsKey($rootId) -or $taskPhase -eq 'working') { $active[$rootId]=@{ Phase=$taskPhase; TaskId=$taskId } }
    }
  }
  if ($active.Count) {
    $phase=$(if (@($active.Values | Where-Object { $_.Phase -eq 'working' }).Count) { 'working' } else { 'thinking' })
  } elseif (-not $state.StoreAvailable -or $unverified) { $phase='unverified' }
  $taskId=$null
  if ($active.Count -eq 1) { $taskId=@($active.Values)[0].TaskId }
  $state.Result=[pscustomobject]@{ IsBusy=($active.Count -gt 0); ActiveCount=$active.Count; Phase=$phase; TaskId=$taskId }
  return $state.Result
}
