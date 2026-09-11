#requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
$rulesPath = Join-Path $root 'scripts\tuning-experiment.ps1'
$enginePath = Join-Path $root 'scripts\delta-booster.ps1'

function Assert-True([bool]$Condition,[string]$Message) {
  if(-not $Condition){throw "ASSERT FAILED: $Message"}
}
function Assert-Throws([scriptblock]$Action,[string]$Message) {
  try{& $Action;throw "ASSERT FAILED: $Message"}catch{if($_.Exception.Message -like 'ASSERT FAILED:*'){throw}}
}

$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($guiPath,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI PowerShell AST parse failed: ' + (($errors|ForEach-Object Message) -join '; '))
$raw=Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
$guiVersionMatch=[regex]::Match($raw,'(?m)^\$script:GuiVersion\s*=\s*''([^'']+)''\s*$')
Assert-True $guiVersionMatch.Success 'GUI version declaration not found'
$xamlMatch=[regex]::Match($raw,"(?s)\$xaml = @'\r?\n(.*?)\r?\n'@")
Assert-True $xamlMatch.Success 'main XAML here-string not found'
Add-Type -AssemblyName PresentationFramework
[void][Windows.Markup.XamlReader]::Parse($xamlMatch.Groups[1].Value)

foreach($needle in @(
  'x:Name="TabTuneBtn"','x:Name="TunePage"','x:Name="TuneCreateBtn"','x:Name="TuneNextBtn"','x:Name="TuneStopBtn"',
  "Invoke-ElevatedEngineAction -Action Restore -BackupFile",'Test-TuningExperimentActive','active-experiment.json',
  "'DeltaForceClient-Win64-Shipping.exe','DeltaForce.exe'",'scripts\tuning-experiment.ps1',
  "elseif(`$GroupId -eq 'final'){@(`$state.candidates).Count}", "'final' `$false", '-SafetyOnly',
  "`$Process.StartTime.ToUniversalTime() -lt [DateTime]::Parse", "groupRestartAfter=[DateTime]::UtcNow.ToString('o')"
)) { Assert-True $raw.Contains($needle) "GUI missing required tuning integration: $needle" }

# 本分支删掉了调优遥测。这里反过来钉住它不会悄悄回来 —— 上游后续版本合并时
# 最容易原样带回的就是这几个名字。
foreach($gone in 'Send-TuningTelemetryEvent','New-TuningTelemetryEventPayload','Send-TuningTelemetryPayload',
  'Start-TuningTelemetryOutboxFlush','New-TuningTelemetryPayload','ConvertTo-TuningWireVariantId',
  'Add-DfbTuningOutboxEvent','Invoke-DfbTuningOutboxFlush','Send-DfbTelemetryEvent'){
  Assert-True (-not $raw.Contains($gone)) "tuning telemetry came back into the GUI: $gone"
}

$applyFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-TuningApplyCandidate'},$true)|Select-Object -First 1)
Assert-True ($applyFunction.Count -eq 1) 'tuning apply function not found'
$applyText=$applyFunction[0].Extent.Text
Assert-True (([regex]::Matches($applyText,'Set-PendingTuningCommit -Kind variant')).Count -eq 1) 'variant commit barrier is entered more than once across B1/B2/retry'
Assert-True $applyText.Contains("if(`$ResumePhase -eq 'group_capture_b1')") 'variant commit barrier is not limited to the first committed B1 apply'
Assert-True $applyText.Contains('$expectedBoundary=[int](@($state.runs).Count+1)') 'first B1 apply does not persist the exact run-membership boundary'

# Run / first-B1 apply 使用同一个持久 commit 屏障：业务结果先在 experiment state 中
# 原子落盘，之后才允许推进实验阶段。
$pendingFunctions=@{}
foreach($functionName in 'Set-PendingTuningCommit','Resume-PendingTuningCommit','Complete-TuningVariantApplyDisposition',
  'Test-PendingTuningRunConsumed','Test-PendingTuningRunCompleted','Invoke-TuningPerformanceCapture','Invoke-NextTuningStep','Load-ActiveTuningExperiment'){
  $fn=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true)|Select-Object -First 1)
  Assert-True ($fn.Count -eq 1) "pending tuning function not found: $functionName"
  $pendingFunctions[$functionName]=$fn[0]
}
$setPendingText=$pendingFunctions['Set-PendingTuningCommit'].Extent.Text
$resumePendingText=$pendingFunctions['Resume-PendingTuningCommit'].Extent.Text
$captureText=$pendingFunctions['Invoke-TuningPerformanceCapture'].Extent.Text
$nextText=$pendingFunctions['Invoke-NextTuningStep'].Extent.Text
$loadText=$pendingFunctions['Load-ActiveTuningExperiment'].Extent.Text

$pendingAssignOffset=$setPendingText.IndexOf('$state.pendingTuningCommit=',[StringComparison]::Ordinal)
$pendingSaveOffset=$setPendingText.IndexOf('Save-TuningExperiment',[StringComparison]::Ordinal)
Assert-True ($pendingAssignOffset -ge 0 -and $pendingSaveOffset -gt $pendingAssignOffset) 'pending commit is not atomically saved with the state transition it guards'
foreach($field in 'schemaVersion','kind','sourcePhase','candidateIndex','entityId','resumePhase','outcome','unsafeFailure','reason'){
  Assert-True ($setPendingText -match ("(?m)\b"+[regex]::Escape($field)+"\s*=")) "pending commit omitted strict field: $field"
}

$pendingAdvanceOffset=$resumePendingText.IndexOf('Advance-TuningAfterValidRun',[StringComparison]::Ordinal)
$pendingVariantOffset=$resumePendingText.IndexOf('Complete-TuningVariantApplyDisposition',[StringComparison]::Ordinal)
$pendingClearOffset=$resumePendingText.IndexOf('$state.pendingTuningCommit=$null',[StringComparison]::Ordinal)
Assert-True ($pendingAdvanceOffset -ge 0 -and $pendingVariantOffset -ge 0) 'resume no longer replays both run and variant dispositions'
Assert-True ($pendingClearOffset -gt $pendingAdvanceOffset -and $pendingClearOffset -gt $pendingVariantOffset) 'pending marker is cleared before the state transition it guards'
Assert-True ($resumePendingText.Contains('"$($pending.sourcePhase)"') -and $resumePendingText.Contains('([int]$pending.candidateIndex)')) 'pending run does not replay its persisted source phase/index'

$captureAddOffset=$captureText.IndexOf('Add-TuningRun',[StringComparison]::Ordinal)
$capturePendingOffset=$captureText.IndexOf('Set-PendingTuningCommit -Kind run',[StringComparison]::Ordinal)
Assert-True ($captureAddOffset -ge 0 -and $capturePendingOffset -gt $captureAddOffset) 'captured run is not added before its pending commit marker is persisted'
Assert-True (-not $captureText.Contains('Advance-TuningAfterValidRun')) 'capture advances before the pending commit barrier'

$nextResumeOffset=$nextText.IndexOf('Resume-PendingTuningCommit',[StringComparison]::Ordinal)
$nextCaptureOffset=$nextText.IndexOf('Invoke-TuningPerformanceCapture',[StringComparison]::Ordinal)
Assert-True ($nextResumeOffset -ge 0 -and $nextResumeOffset -lt $nextCaptureOffset) 'Next does not resume the durable pending commit before new capture/apply work'
Assert-True (-not $nextText.Contains('Advance-TuningAfterValidRun')) 'Next bypasses Resume-PendingTuningCommit and advances a fresh run directly'
$loadResumeOffset=$loadText.IndexOf('Resume-PendingTuningCommit',[StringComparison]::Ordinal)
$loadDecisionOffset=$loadText.IndexOf('if("$($state.status)"',[StringComparison]::Ordinal)
Assert-True ($loadResumeOffset -ge 0 -and $loadDecisionOffset -gt $loadResumeOffset) 'restart does not resume pending commit before terminal/apply decisions'
$advanceFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Advance-TuningAfterValidRun'},$true)|Select-Object -First 1)
Assert-True ($advanceFunction.Count -eq 1) 'Advance-TuningAfterValidRun not found'
$advanceText=$advanceFunction[0].Extent.Text
Assert-True ($advanceText.Contains('$resumeSafetyRollback=') -and $advanceText.Contains('$state.finalComparison') -and
  $advanceText.Contains("status='rolled_back';result='rolled_back'")) 'final rollback restart can recompute an empty currentBest as no_gain'
Assert-True ($advanceText.Contains("`$state.stopReason=`$(if(`$autoRollback){'safety_threshold'}")) 'resumed safety rollback does not retain safety_threshold'

# 所有终态都必须走同一持久化边界：先盖 completedAt 并保存活动态，再清理活动指针。
# 禁止任一失败/取消分支自行 Save -Terminal。
$terminalFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-GuiTuningExperimentTerminal'},$true)|Select-Object -First 1)
Assert-True ($terminalFunction.Count -eq 1) 'central tuning terminal function not found'
$terminalText=$terminalFunction[0].Extent.Text
Assert-True $terminalText.Contains('Save-TuningExperiment -Terminal') 'central terminal function does not persist terminal state/clear the pointer'
$activeSaveOffset=$terminalText.IndexOf('Save-TuningExperiment',[StringComparison]::Ordinal)
$terminalSaveOffset=$terminalText.IndexOf('Save-TuningExperiment -Terminal',[StringComparison]::Ordinal)
$completedAtOffset=$terminalText.IndexOf('$state.completedAt',[StringComparison]::Ordinal)
Assert-True ($completedAtOffset -ge 0 -and $activeSaveOffset -gt $completedAtOffset) 'completedAt is stamped after the active-state save'
Assert-True ($terminalSaveOffset -gt $activeSaveOffset) 'active pointer is cleared before the terminal state is saved'

$terminalSaves=@($ast.FindAll({
  param($n)
  $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Save-TuningExperiment' -and
    @($n.CommandElements|Where-Object{$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Terminal'}).Count -eq 1
},$true))
Assert-True ($terminalSaves.Count -eq 1) 'Save-TuningExperiment -Terminal escaped the central terminal function'
Assert-True ($terminalSaves[0].Extent.StartOffset -ge $terminalFunction[0].Extent.StartOffset -and
  $terminalSaves[0].Extent.EndOffset -le $terminalFunction[0].Extent.EndOffset) 'terminal save is outside Complete-GuiTuningExperimentTerminal'

$terminalCalls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Complete-GuiTuningExperimentTerminal'},$true))
Assert-True ($terminalCalls.Count -ge 12) 'one or more GUI terminal branches bypass the central terminal function'
foreach($functionName in 'Complete-TuningVariantApplyDisposition','Complete-TuningCandidate','Invoke-TuningFinalRollback',
  'Advance-TuningAfterValidRun','Invoke-NextTuningStep','Stop-GuiTuningExperiment','Load-ActiveTuningExperiment'){
  $fn=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true)|Select-Object -First 1)
  Assert-True ($fn.Count -eq 1 -and $fn[0].Extent.Text.Contains('Complete-GuiTuningExperimentTerminal')) "$functionName has a terminal path that is not centralized"
}

. $rulesPath
. $enginePath

# 行为级验证收口顺序：终态必须先盖 completedAt 并保存活动态，再清理活动指针。
# 上游在这中间还夹了一次 completion 事件的持久入队；本分支删掉遥测后那一步没了，
# 但「两次 Save 的先后」这条不变式仍然是崩溃恢复的依据。
& {
  param([string]$FunctionText)
  $previousActive=$script:ActiveTuningExperiment
  try{
    $script:ActiveTuningExperiment=[pscustomobject]@{status='failed';completedAt='';pendingTuningCommit=$null}
    $script:TerminalTrace=New-Object 'System.Collections.Generic.List[string]'
    function Save-TuningExperiment {
      param([switch]$Terminal)
      if($Terminal){
        Assert-True ([bool]$script:ActiveTuningExperiment.completedAt) 'terminal closure did not stamp completedAt before the terminal save'
      }
      [void]$script:TerminalTrace.Add($(if($Terminal){'save-terminal'}else{'save-active'}))
    }
    function Update-TuningUi {[void]$script:TerminalTrace.Add('ui')}
    Invoke-Expression $FunctionText

    Complete-GuiTuningExperimentTerminal $false
    Assert-True (($script:TerminalTrace -join ',') -eq 'save-active,save-terminal,ui') 'terminal closure persistence/cleanup order changed'
    Assert-True ([bool]$script:ActiveTuningExperiment.completedAt) 'terminal closure did not stamp completedAt'
  }finally{
    $script:ActiveTuningExperiment=$previousActive
    Remove-Variable TerminalTrace -Scope Script -ErrorAction SilentlyContinue
  }
} $terminalText

# State file Replace 成功而 active pointer 后续写失败时，Set catch 必须从磁盘读回 pending，
# 不能删除刚保存的 run 后让用户在重启后重复采样。
$saveFunction=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-TuningExperiment'},$true)|Select-Object -First 1)
Assert-True ($saveFunction.Count -eq 1) 'Save-TuningExperiment not found for pointer crash test'
& {
  param([string]$SaveText,[string]$SetText)
  $previousActive=$script:ActiveTuningExperiment;$previousPath=$script:ActiveTuningStatePath
  try{
    $script:PointerCommitHarness=[pscustomobject]@{Persisted=$null;Pointer='';PointerWrites=0;FailPointer=$true}
    function Assert-TuningGuiState($State){$true}
    function Write-TuningStateAtomic([string]$Path,$State){
      $script:PointerCommitHarness.Persisted=$State|ConvertTo-Json -Depth 20|ConvertFrom-Json
      $Path
    }
    function Read-TuningState([string]$Path){$script:PointerCommitHarness.Persisted|ConvertTo-Json -Depth 20|ConvertFrom-Json}
    function Read-TuningPointerStrict {$script:PointerCommitHarness.Pointer}
    function Write-TuningPointerAtomic([string]$ExperimentId){
      $script:PointerCommitHarness.PointerWrites++
      if($script:PointerCommitHarness.FailPointer){throw 'simulated pointer write failure'}
      $script:PointerCommitHarness.Pointer=$ExperimentId
    }
    function Initialize-TuningGuiStateFields($State){$State}
    function Clear-TuningPointer {}
    Invoke-Expression $SaveText
    Invoke-Expression $SetText

    $runId='run_'+[guid]::NewGuid().ToString('N');$experimentId='exp_'+[guid]::NewGuid().ToString('N')
    $script:ActiveTuningStatePath='C:\fixture\experiment.json'
    $script:ActiveTuningExperiment=[pscustomobject]@{
      experimentId=$experimentId;runs=@([pscustomobject]@{runId=$runId});pendingTuningCommit=$null
    }
    Assert-Throws {
      Set-PendingTuningCommit -Kind run -SourcePhase baseline -CandidateIndex -1 -EntityId $runId|Out-Null
    } 'pointer failure after state Replace did not propagate'
    Assert-True ($script:ActiveTuningExperiment.pendingTuningCommit -and
      @($script:ActiveTuningExperiment.runs|Where-Object runId -eq $runId).Count -eq 1) 'pointer failure rolled back a durably saved pending run'
    Assert-True ($script:PointerCommitHarness.PointerWrites -eq 1) 'pointer failure fixture did not reach the post-state pointer write'

    # Once the pointer already names this experiment, ordinary state saves must not rewrite it.
    $script:PointerCommitHarness.Pointer=$experimentId
    $writesBefore=$script:PointerCommitHarness.PointerWrites
    Save-TuningExperiment
    Assert-True ($script:PointerCommitHarness.PointerWrites -eq $writesBefore) 'active experiment save rewrote an already-correct pointer'
  }finally{
    $script:ActiveTuningExperiment=$previousActive;$script:ActiveTuningStatePath=$previousPath
    Remove-Variable PointerCommitHarness -Scope Script -ErrorAction SilentlyContinue
  }
} $saveFunction[0].Extent.Text $setPendingText

# 行为级故障注入：把 experiment state 当成进程重启后唯一可信输入。依次覆盖
# run 保存前、Advance 前、Advance 已保存但 pending 清理前退出；
# 最终业务顺序必须仍然只有 B1、A、B2。
#
# 本分支删掉了调优遥测 outbox，所以这里不再有「独立持久介质」这一方。
# pendingTuningCommit 本身仍是崩溃恢复的提交点：它承载的是状态机推进
# （Advance-TuningAfterValidRun / Complete-TuningVariantApplyDisposition），
# 原来搭在上面的 exact payload 只是搭便车的乘客。
& {
  param([string]$SetText,[string]$ResumeText,[string]$ConsumedText,[string]$CompletedText,[string]$AdvanceText)
  $previousActive=$script:ActiveTuningExperiment
  $previousGuiVersion=$script:GuiVersion
  try{
    $h=[pscustomobject]@{
      PersistedJson='';FailClearOnce=$false
      Trace=(New-Object 'System.Collections.Generic.List[string]')
    }
    $script:PendingCommitHarness=$h

    function Save-TuningExperiment {
      param([switch]$Terminal)
      if($script:PendingCommitHarness.FailClearOnce -and -not $script:ActiveTuningExperiment.pendingTuningCommit){
        $script:PendingCommitHarness.FailClearOnce=$false
        throw 'simulated crash after Advance save, before pending clear save'
      }
      $script:PendingCommitHarness.PersistedJson=$script:ActiveTuningExperiment|ConvertTo-Json -Compress -Depth 30
      [void]$script:PendingCommitHarness.Trace.Add('save')
    }
    function Restart-PendingCommitHarness {
      $script:ActiveTuningExperiment=$script:PendingCommitHarness.PersistedJson|ConvertFrom-Json
    }
    function Update-TuningUi {}
    function Compare-CurrentTuningCandidate($Candidate,[bool]$FinalAttempt){
      $Candidate.status='complete'
      $script:ActiveTuningExperiment.phase='group_control_pre'
      Save-TuningExperiment
    }

    Invoke-Expression $SetText
    Invoke-Expression $ConsumedText
    Invoke-Expression $CompletedText
    Invoke-Expression $ResumeText
    Invoke-Expression $AdvanceText

    function New-HarnessRun([string]$Id,[int]$SequenceNo,[string]$VariantId){
      [pscustomobject][ordered]@{runId=$Id;validity='valid';sequenceNo=$SequenceNo;variantId=$VariantId}
    }
    function Add-HarnessPendingRun($Run,[string]$SourcePhase){
      $state=$script:ActiveTuningExperiment
      $state.runs=@($state.runs)+@($Run)
      Set-PendingTuningCommit -Kind run -SourcePhase $SourcePhase -CandidateIndex 0 `
        -EntityId "$($Run.runId)"|Out-Null
    }

    $experimentId='exp_'+[guid]::NewGuid().ToString('N')
    $candidate=[pscustomobject]@{
      variantId='background_low_risk';controlRunIds=@();candidateRunIds=@();status='pending'
    }
    $script:ActiveTuningExperiment=[pscustomobject]@{
      experimentId=$experimentId;phase='group_capture_b1';candidateIndex=0;candidates=@($candidate)
      runs=@();initialBaselineRunIds=@();finalRunIds=@();pendingTuningCommit=$null;lastMessage=''
    }
    Save-TuningExperiment

    # Crash before the run+pending state save: an in-memory run disappears and no Advance occurs.
    $unsaved=New-HarnessRun ('run_'+[guid]::NewGuid().ToString('N')) 1 'background_low_risk'
    $script:ActiveTuningExperiment.runs=@($unsaved)
    Restart-PendingCommitHarness
    Assert-True (-not @($script:ActiveTuningExperiment.runs).Count -and -not (Resume-PendingTuningCommit)) 'run survived a crash before its atomic state save'
    Assert-True ($script:ActiveTuningExperiment.phase -eq 'group_capture_b1') 'pre-save crash advanced a run'

    # State save succeeds, then the process exits immediately before Advance. A restart must advance
    # the same local run exactly once instead of recording another B1.
    $b1=New-HarnessRun ('run_'+[guid]::NewGuid().ToString('N')) 1 'background_low_risk'
    Add-HarnessPendingRun $b1 'group_capture_b1'
    function Advance-TuningAfterValidRun {param($Run,[string]$SourcePhase,[int]$SourceCandidateIndex);throw 'simulated crash before Advance'}
    Assert-Throws {Resume-PendingTuningCommit|Out-Null} 'simulated pre-Advance crash was not reached'
    Assert-True ($script:ActiveTuningExperiment.phase -eq 'group_capture_b1' -and
      -not @($script:ActiveTuningExperiment.candidates[0].candidateRunIds).Count -and
      $script:ActiveTuningExperiment.pendingTuningCommit) 'pre-Advance crash did not preserve the exact pending B1 state'
    Restart-PendingCommitHarness
    $script:GuiVersion='99.0.0' # 重启/升级不得改变已保存的业务推进结果
    Invoke-Expression $AdvanceText
    [void](Resume-PendingTuningCommit)
    Assert-True ($script:ActiveTuningExperiment.phase -eq 'group_rollback_a' -and
      (@($script:ActiveTuningExperiment.candidates[0].candidateRunIds) -join ',') -eq "$($b1.runId)") 'B1 recovery did not advance exactly once'

    # A commits normally.
    $script:ActiveTuningExperiment.phase='group_capture_a'
    $a=New-HarnessRun ('run_'+[guid]::NewGuid().ToString('N')) 2 'baseline'
    Add-HarnessPendingRun $a 'group_capture_a'
    [void](Resume-PendingTuningCommit)
    Assert-True ($script:ActiveTuningExperiment.phase -eq 'group_apply_b2' -and
      (@($script:ActiveTuningExperiment.candidates[0].controlRunIds) -join ',') -eq "$($a.runId)") 'A recovery/advance is not exact'

    # B2 reaches and saves Advance, then exits before clearing pending. Restart must recognize the
    # consumed run reference, skip Advance, and only clear the durable marker.
    $script:ActiveTuningExperiment.phase='group_capture_b2'
    $b2=New-HarnessRun ('run_'+[guid]::NewGuid().ToString('N')) 3 'background_low_risk'
    Add-HarnessPendingRun $b2 'group_capture_b2'
    $h.FailClearOnce=$true
    Assert-Throws {Resume-PendingTuningCommit|Out-Null} 'simulated post-Advance crash was not reached'
    Restart-PendingCommitHarness
    Assert-True ($script:ActiveTuningExperiment.pendingTuningCommit -and
      @($script:ActiveTuningExperiment.candidates[0].candidateRunIds) -contains "$($b2.runId)") 'post-Advance durable state did not retain its pending marker/reference'
    [void](Resume-PendingTuningCommit)

    Assert-True ((@($script:ActiveTuningExperiment.candidates[0].candidateRunIds) -join ',') -eq "$($b1.runId),$($b2.runId)") 'restart duplicated or lost B1/B2 membership'
    Assert-True ((@($script:ActiveTuningExperiment.candidates[0].controlRunIds) -join ',') -eq "$($a.runId)") 'restart duplicated or lost A membership'
    Assert-True ((@($script:ActiveTuningExperiment.runs|ForEach-Object{"$($_.runId)"}) -join ',') -eq "$($b1.runId),$($a.runId),$($b2.runId)") 'restart did not preserve exact B1,A,B2 run order'
    Assert-True (-not $script:ActiveTuningExperiment.pendingTuningCommit) 'recovery left an uncleared pending commit'
  }finally{
    $script:ActiveTuningExperiment=$previousActive;$script:GuiVersion=$previousGuiVersion
    Remove-Variable PendingCommitHarness -Scope Script -ErrorAction SilentlyContinue
  }
} $setPendingText $resumePendingText $pendingFunctions['Test-PendingTuningRunConsumed'].Extent.Text `
  $pendingFunctions['Test-PendingTuningRunCompleted'].Extent.Text `
  $advanceText
# 最后一份安全回滚备份已 Restore+Save 后、终态保存前退出：此时 currentBest 已经是
# baseline/空集合，但 finalComparison 的 rollback intent 仍必须胜出，恢复为 rolled_back。
& {
  param([string]$ResumeText,[string]$ConsumedText,[string]$CompletedText,[string]$AdvanceText)
  $previousActive=$script:ActiveTuningExperiment
  try{
    $script:SafetyRollbackHarness=[pscustomobject]@{RollbackCalls=0;TerminalCalls=0;TerminalAutoRollback=$false}
    function Save-TuningExperiment {param([switch]$Terminal)}
    function Update-TuningUi {}
    function Get-TuningRunsByIds($State,[object[]]$Ids){
      $wanted=@($Ids|ForEach-Object{"$_"});@($State.runs|Where-Object{$wanted -contains "$($_.runId)"})
    }
    function Invoke-TuningFinalRollback {
      $script:SafetyRollbackHarness.RollbackCalls++
      Assert-True (-not @($script:ActiveTuningExperiment.activeBackups).Count -and
        -not @($script:ActiveTuningExperiment.currentBestGroups).Count) 'last restored backup was not durably reflected before recovery'
    }
    function Complete-GuiTuningExperimentTerminal([bool]$AutoRollback){
      $script:SafetyRollbackHarness.TerminalCalls++
      $script:SafetyRollbackHarness.TerminalAutoRollback=$AutoRollback
    }
    Invoke-Expression $ConsumedText
    Invoke-Expression $CompletedText
    Invoke-Expression $AdvanceText
    Invoke-Expression $ResumeText

    $runs=@(1..3|ForEach-Object{[pscustomobject]@{runId=('run_'+[guid]::NewGuid().ToString('N'));validity='valid';variantId='display_path'}})
    $pending=[pscustomobject]@{
      schemaVersion=1;kind='run';sourcePhase='final_capture';candidateIndex=3
      entityId="$($runs[-1].runId)";resumePhase='';outcome='';unsafeFailure=$false;reason=''
    }
    $script:ActiveTuningExperiment=[pscustomobject]@{
      phase='rolling_back';status='final_validation';result='';stopReason='';completedAt='';lastMessage=''
      candidateIndex=3;candidates=@([pscustomobject]@{},[pscustomobject]@{},[pscustomobject]@{})
      runs=$runs;initialBaselineRunIds=@();finalRunIds=@($runs|ForEach-Object{$_.runId})
      currentBestGroups=@();currentBestVariantId='baseline';activeBackups=@()
      finalComparison=[pscustomobject]@{result='rollback';reason='safety limit'}
      allowHigherPower=$false;maxTempIncreaseC=3.0;maxPowerIncreasePct=0.0
      pendingTuningCommit=$pending
    }
    [void](Resume-PendingTuningCommit)
    Assert-True ($script:ActiveTuningExperiment.status -eq 'rolled_back' -and
      $script:ActiveTuningExperiment.result -eq 'rolled_back' -and
      $script:ActiveTuningExperiment.stopReason -eq 'safety_threshold') 'post-restore restart flipped safety rollback into no_gain'
    Assert-True ($script:SafetyRollbackHarness.RollbackCalls -eq 1 -and
      $script:SafetyRollbackHarness.TerminalCalls -eq 1 -and $script:SafetyRollbackHarness.TerminalAutoRollback) 'post-restore restart lost autoRollback terminal intent'
    Assert-True (-not $script:ActiveTuningExperiment.pendingTuningCommit) 'post-restore restart left final pending commit uncleared'
  }finally{
    $script:ActiveTuningExperiment=$previousActive
    Remove-Variable SafetyRollbackHarness -Scope Script -ErrorAction SilentlyContinue
  }
} $resumePendingText $pendingFunctions['Test-PendingTuningRunConsumed'].Extent.Text `
  $pendingFunctions['Test-PendingTuningRunCompleted'].Extent.Text $advanceText

$library=@(Get-TuningCandidateLibrary)
Assert-True ($library.Count -eq 3) 'candidate library must contain exactly G1/G2/G3'
Assert-True ((@($library.GroupId) -join ',') -eq 'G1,G2,G3') 'candidate order/group ids changed'
Assert-True (@($library|Where-Object{$_.RiskLevel -ne 'low' -or $_.RequiresReboot -or $_.Source -ne 'rules'}).Count -eq 0) 'candidate metadata escaped rules/low/no-reboot boundary'
Assert-True (@($library|Where-Object{@($_.ItemIds|Where-Object{$_ -match 'spoof|risky'}).Count}).Count -eq 0) 'risky/spoof item entered candidate library'
$engineFixture=Join-Path ([IO.Path]::GetTempPath()) ('dfb-tuning-engine-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($engineFixture)
try{
  $gameFixture=Join-Path $engineFixture 'DeltaForceClient-Win64-Shipping.exe'
  [IO.File]::WriteAllBytes($gameFixture,[byte[]](0))
  $actual=@(Get-OptItems $gameFixture)
  foreach($candidate in $library){
    foreach($id in @($candidate.ItemIds)){
      $item=@($actual|Where-Object Id -eq $id)
      Assert-True ($item.Count -eq 1) "candidate item missing/duplicated in engine: $id"
      Assert-True ($item[0].Tier -eq 'safe' -and -not [bool]$item[0].Reboot) "candidate is risky/rebooting: $id"
      Assert-True ($item[0].Kind -notin 'cache','check','npi','power','sched') "candidate uses forbidden kind: $id/$($item[0].Kind)"
      Assert-True (@($item[0].Ops).Count -gt 0) "candidate has no restorable ops: $id"
      Assert-True (@($item[0].Ops|Where-Object{$_.Kind -notin 'reg','kvstr'}).Count -eq 0) "candidate op is outside reversible Beta set: $id"
    }
  }
}finally{if(Test-Path -LiteralPath $engineFixture){[IO.Directory]::Delete($engineFixture,$true)}}
