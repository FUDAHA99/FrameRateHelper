#requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI PowerShell AST parse failed: ' + (($errors | ForEach-Object Message) -join '; '))

$failureHelpers = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-ApplyFailureContext'
}, $true))
Assert-True ($failureHelpers.Count -eq 1) 'Apply failure context helper missing or duplicated'

# 行为测试只执行纯格式化 helper，不加载 WPF，也不访问系统设置。
& {
  param([string]$FunctionText)
  Invoke-Expression $FunctionText

  try { throw [InvalidOperationException]::new('original preflight error') }
  catch { $preflightError = $_ }
  $preflight = Get-ApplyFailureContext $preflightError $false $null
  Assert-True (-not $preflight.AdminBatchReturned) 'preflight failure was marked as a completed admin batch'
  Assert-True ($preflight.UserMessage -ceq 'original preflight error') 'preflight user message did not preserve the original error text'
  Assert-True ($preflight.ErrorMessage -ceq 'original preflight error') 'preflight diagnostic message changed the original error text'
  Assert-True ($preflight.ExceptionType -eq 'System.InvalidOperationException') 'preflight exception type was not captured'
  Assert-True (-not [string]::IsNullOrWhiteSpace($preflight.ScriptStackTrace)) 'preflight ScriptStackTrace was not captured'
  Assert-True (-not $preflight.BackupPath) 'preflight failure invented a backup path'

  try { throw [ArgumentException]::new('post-admin finalization error') }
  catch { $postError = $_ }
  $backup = 'C:\ProgramData\DeltaForceBooster\backup\backup-fixture.json'
  $post = Get-ApplyFailureContext $postError $true ([pscustomobject]@{ Backup = $backup })
  Assert-True $post.AdminBatchReturned 'post-admin failure lost its completed-batch marker'
  Assert-True ($post.BackupPath -ceq $backup) 'post-admin failure lost the returned backup path'
  Assert-True ($post.ExceptionType -eq 'System.ArgumentException') 'post-admin exception type was not captured'
  foreach ($phrase in '系统批次可能已经执行','请不要重复点击「执行优化」','优先点击「还原设置」','点击「重新检测」','post-admin finalization error') {
    Assert-True $post.UserMessage.Contains($phrase) "post-admin user message omitted: $phrase"
  }
} $failureHelpers[0].Extent.Text

# 真实点击路径：不再在源码文本里 IndexOf '$adminBatchReturned = $true'——那行被注释掉后
# IndexOf 照样命中注释（独立复核变异 05）。这里用 AST 取出真实的 ApplyBtn.Add_Click 处理器整块执行，
# 只桩掉提权引擎、本地缓存清理、WPF 与落盘日志，断言标记置位的可观察后果：用户看到哪个弹窗、
# 日志里有没有「请不要重复点击」。勾选形态（系统项/缓存项/两者）、失败点（引擎/本地收尾/界面收尾）
# 和引擎是否带回备份都参数化——只造一种形态时，把置位挪进 if ($r.Backup) 或本地收尾块都能保持绿。
$applyClickHandlers = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    "$($node.Member)" -eq 'Add_Click' -and "$($node.Expression)" -eq '$ui.ApplyBtn' -and
    $node.Arguments -and $node.Arguments.Count -eq 1 -and
    $node.Arguments[0] -is [Management.Automation.Language.ScriptBlockExpressionAst]
}, $true))
Assert-True ($applyClickHandlers.Count -eq 1) 'Apply click handler missing or duplicated'

# 处理器里的 [Windows.Threading.DispatcherPriority]::Render 需要这个程序集；只加载，不建窗口。
Add-Type -AssemblyName WindowsBase

& {
  param([string]$FunctionText, [string]$HandlerText)
  Invoke-Expression $FunctionText
  $applyHandler = & ([scriptblock]::Create($HandlerText))
  Assert-True ($applyHandler -is [scriptblock]) 'Apply click handler body did not materialise as a scriptblock'

  $script:Busy = $false
  $script:TargetExe = 'C:\Games\fixture\game.exe'
  $script:TuningConfigGeneration = 0
  $script:ApplySelectionSnapshot = @()
  # 失败注入点是封闭集合：none | engine | local | tail，同一时刻只有一处抛。
  $script:AFFailAt = 'none'; $script:AFWithBackup = $true
  $script:AFLog = @(); $script:AFDialogs = @(); $script:AFApplyCalls = 0
  $fixtureBackup = 'C:\ProgramData\DeltaForceBooster\backup\fixture-backup.json'

  # 真 Write-Log 写 WPF 并落盘、真 Set-BusyState 遍历几十个控件、真 Invoke-ElevatedEngineAction
  # 起提权子进程、真 Invoke-LocalNoBackupItems 删缓存目录——全部桩掉，全程纯内存。
  function Write-Log([string]$Msg) { $script:AFLog += ,"$Msg" }
  function Set-BusyState([bool]$On) { $script:Busy = $On }
  function Test-TuningExperimentActive { $false }
  function Get-OptItems([string]$Exe) {
    @([pscustomobject]@{ Id='fixture-sys';   Name='fixture system item'; Kind='reg';   Warn=$null; Note='' },
      [pscustomobject]@{ Id='fixture-cache'; Name='fixture cache item';  Kind='cache'; Warn=$null; Note='' })
  }
  function Show-ConfirmDialog([string]$ChipText, [string]$EnText, [string]$Message,
                              [string]$OkText = 'ok', [switch]$InfoOnly, [string]$Banner, [switch]$DefaultCancel) {
    $script:AFDialogs += ,([pscustomobject]@{ Chip = "$ChipText"; En = "$EnText"; Message = "$Message" })
    return $true
  }
  function Invoke-ElevatedEngineAction {
    param([string]$Action, [string[]]$ItemIds, [string]$GamePath, [bool]$AllowRisky = $false,
          [string]$BackupFile, [switch]$ListRestoreItems, [string[]]$RestoreItemIds,
          [string]$ResidueKind, [string]$ResidueId, [string]$ResultId)
    if ($Action -ne 'Apply') { return @() }
    $script:AFApplyCalls++
    if ($script:AFFailAt -eq 'engine') { throw [InvalidOperationException]::new('fixture engine refused the batch') }
    [pscustomobject]@{
      Results = @([pscustomobject]@{ Id='fixture-sys'; Name='fixture system item'; Ok=$true; Changed=$true
                                     Skipped=$false; Attention=$false; Reboot=$false; Msg='' })
      Backup = $(if ($script:AFWithBackup) { $fixtureBackup } else { $null })
      BackupError = $null; UnrecordedNames = @(); EngineExitCode = 0
    }
  }
  function Invoke-LocalNoBackupItems([object[]]$Items) {
    if ($script:AFFailAt -eq 'local') { throw [IO.IOException]::new('fixture cache cleanup exploded') }
    @($Items | ForEach-Object { [pscustomobject]@{ Id=$_.Id; Name=$_.Name; Ok=$true; Changed=$true
                                                   Skipped=$false; Attention=$false; Reboot=$false; Msg='' } })
  }
  function Update-ItemList { if ($script:AFFailAt -eq 'tail') { throw [IO.IOException]::new('fixture tail refresh exploded') } }
  function Update-ApplyProgress($Progress) { }
  function Set-LogBadge($N) { }
  function Show-HealthDialog($List) { }
  function Show-RebootDialog($Names) { $false }
  function Get-TelemetryOptimizationContext { [pscustomobject]@{ ItemIds = @(); ConfigTier = 'baseline' } }
  function Set-TelemetryOptimizationContext { param($ItemIds, $Scheme, [bool]$ItemsComplete, $FallbackTier) }
  function Update-TelemetryOptimizationContextFromCatalog {
    param($Catalog, $RequestedScheme, $RequestedItemIds, $KnownChangedItemIds, [switch]$MutationIncomplete)
  }
  function Get-AFLogIndex([string]$Fragment) {
    for ($i = 0; $i -lt $script:AFLog.Count; $i++) { if ($script:AFLog[$i].Contains($Fragment)) { return $i } }
    return -1
  }
  function Get-AFLogCount([string]$Fragment) { @($script:AFLog | Where-Object { $_.Contains($Fragment) }).Count }
  function Invoke-AFApplyClick([string]$FailAt, [string[]]$Tags, [bool]$WithBackup) {
    $script:AFLog = @(); $script:AFDialogs = @(); $script:AFApplyCalls = 0
    $script:AFFailAt = $FailAt; $script:AFWithBackup = $WithBackup
    $node = { param($tag) [pscustomobject]@{ Child = [pscustomobject]@{ Children = @([pscustomobject]@{ IsChecked = $true; Tag = $tag }) } } }
    $ui = @{
      ItemPanel     = [pscustomobject]@{ Children = @(@($Tags) | ForEach-Object { & $node $_ }) }
      RiskyPanel    = [pscustomobject]@{ Children = @() }
      ProgressPanel = [pscustomobject]@{ Visibility = 'Collapsed' }
      ProgFill      = [pscustomobject]@{ Width = 0 }
      ProgText      = [pscustomobject]@{ Text = '' }
      ProgCount     = [pscustomobject]@{ Text = '' }
    }
    $dispatcher = New-Object psobject
    $dispatcher | Add-Member -MemberType ScriptMethod -Name Invoke -Value { param($Action, $Priority) } -Force
    $window = [pscustomobject]@{ Dispatcher = $dispatcher }
    & $applyHandler
    Assert-True (-not $script:Busy) "Apply handler left the busy state set (fail point: $FailAt)"
    Assert-True ($script:AFDialogs.Count -ge 1 -and $script:AFDialogs[0].Chip -ceq '确认执行') `
      "Apply fixture did not reach the confirmation dialog (fail point: $FailAt)"
  }
  function Get-AFLastDialog { $script:AFDialogs[$script:AFDialogs.Count - 1] }

  # S0：全部成功——证明桩齐全。少一个桩时异常会被产品自己的 catch 吞成弹窗，这里会直接红。
  Invoke-AFApplyClick 'none' @('fixture-sys', 'fixture-cache') $true
  Assert-True ($script:AFApplyCalls -eq 1 -and $script:AFDialogs.Count -eq 1) `
    ('successful Apply fixture raised a failure dialog: ' + (Get-AFLastDialog).Chip + ' ' + (Get-AFLastDialog).Message)
  Assert-True ((Get-AFLogIndex '执行完成：共 2 项 — 2 成功') -ge 0) 'successful Apply fixture did not complete both items'
  Assert-True ((Get-AFLogCount '备份已保存：') -eq 1) 'successful Apply logged the backup path zero times or twice'

  # S1：系统批次已返回（带备份），随后本地缓存收尾炸掉——必须走「收尾失败」通道。
  Invoke-AFApplyClick 'local' @('fixture-sys', 'fixture-cache') $true
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) 'post-admin fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行收尾未完成' -and $d.En -ceq 'APPLY FINALIZATION FAILED') `
    'real Apply path failed after the admin batch returned but was not reported as a finalization failure'
  Assert-True ($d.Message.Contains('请不要重复点击「执行优化」') -and $d.Message.Contains('fixture cache cleanup exploded')) `
    'post-admin dialog lost the do-not-repeat warning or the original error'
  $failIdx = Get-AFLogIndex '执行收尾失败：fixture cache cleanup exploded'
  Assert-True ($failIdx -ge 0) 'post-admin log did not record the finalization failure'
  Assert-True ((Get-AFLogIndex '系统批次可能已执行，请不要重复点击「执行优化」') -gt $failIdx) `
    'post-admin log did not warn against repeating a possibly completed batch'
  Assert-True ((Get-AFLogIndex '执行失败：') -lt 0) 'post-admin failure was also reported as a preflight failure'
  Assert-True ((Get-AFLogCount '备份已保存：') -eq 1 -and
    (Get-AFLogIndex "备份已保存：$fixtureBackup") -ge 0 -and (Get-AFLogIndex "备份已保存：$fixtureBackup") -lt $failIdx) `
    'backup path was not logged exactly once, before local check/cache finalization failed'
  Assert-True ((Get-AFLogIndex '异常类型：System.IO.IOException') -ge 0) `
    'post-admin log did not carry the original exception type (a missing fixture stub also lands here)'
  Assert-True ((Get-AFLogIndex 'ScriptStackTrace：') -ge 0) 'post-admin log did not carry ScriptStackTrace'

  # S2：提权引擎调用本身失败——标记必须仍为假，原文透传的前置失败通道。
  Invoke-AFApplyClick 'engine' @('fixture-sys', 'fixture-cache') $true
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) 'preflight fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行未完成' -and $d.En -ceq 'APPLY NOT COMPLETED') `
    'a failure of the elevated engine call itself was misreported as a completed admin batch'
  Assert-True ($d.Message -ceq 'fixture engine refused the batch') 'preflight dialog did not pass the raw error through'
  Assert-True ((Get-AFLogIndex '系统批次可能已执行') -lt 0) 'preflight failure warned about a batch that never ran'
  Assert-True ((Get-AFLogIndex '备份已保存：') -lt 0) 'preflight failure invented a backup log line'
  Assert-True ((Get-AFLogIndex '执行失败：fixture engine refused the batch') -ge 0) 'preflight failure lost the raw error in the log'
  Assert-True ((Get-AFLogIndex '异常类型：System.InvalidOperationException') -ge 0) 'preflight log did not carry the exception type'

  # S3：只勾系统项（没有本地收尾），失败发生在之后的界面刷新——仍是收尾失败。
  Invoke-AFApplyClick 'tail' @('fixture-sys') $true
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) 'tail fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行收尾未完成' -and $d.En -ceq 'APPLY FINALIZATION FAILED') `
    'an elevated-only batch that failed after the engine returned was not reported as a finalization failure'
  Assert-True ((Get-AFLogIndex '执行收尾失败：fixture tail refresh exploded') -ge 0 -and
    (Get-AFLogIndex '系统批次可能已执行，请不要重复点击「执行优化」') -ge 0 -and (Get-AFLogIndex '执行失败：') -lt 0) `
    'elevated-only tail failure lost the do-not-repeat warning'

  # S4：只勾缓存项，全程没有提权批次——绝不能报「系统批次可能已执行」。
  Invoke-AFApplyClick 'local' @('fixture-cache') $true
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 0) 'local-only fixture unexpectedly invoked the elevated engine'
  Assert-True ($d.Chip -ceq '执行未完成' -and $d.En -ceq 'APPLY NOT COMPLETED' -and $d.Message -ceq 'fixture cache cleanup exploded') `
    'a run that never elevated was reported as a possibly completed admin batch'
  Assert-True ((Get-AFLogIndex '系统批次可能已执行') -lt 0 -and (Get-AFLogIndex '备份已保存：') -lt 0) `
    'local-only failure warned about a batch that never ran or invented a backup'

  # S5：引擎成功返回但没带回备份路径（备份整体写失败时就是这样）——批次仍然执行过。
  Invoke-AFApplyClick 'local' @('fixture-sys', 'fixture-cache') $false
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) 'backup-less fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行收尾未完成' -and $d.En -ceq 'APPLY FINALIZATION FAILED') `
    'a backup-less admin batch that returned was not marked as completed'
  Assert-True ((Get-AFLogIndex '系统批次可能已执行，请不要重复点击「执行优化」') -ge 0 -and (Get-AFLogIndex '备份已保存：') -lt 0) `
    'backup-less batch lost the do-not-repeat warning or invented a backup line'
} $failureHelpers[0].Extent.Text $applyClickHandlers[0].Arguments[0].Extent.Text

'GUI apply finalization tests passed.'
