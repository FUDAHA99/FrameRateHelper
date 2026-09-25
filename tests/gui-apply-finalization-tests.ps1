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
# 日志里有没有「请不要重复点击」。勾选形态（系统项/电源项/缓存项/检测项/组合）、确认框的回答
# （确认/取消/确认期间改勾选）、失败点（引擎/本地收尾/界面收尾）和引擎是否带回备份都参数化——只造一种形态时，把置位挪进 if ($r.Backup) 或本地收尾块都能保持绿。
$applyClickHandlers = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    "$($node.Member)" -eq 'Add_Click' -and "$($node.Expression)" -eq '$ui.ApplyBtn' -and
    $node.Arguments -and $node.Arguments.Count -eq 1 -and
    $node.Arguments[0] -is [Management.Automation.Language.ScriptBlockExpressionAst]
}, $true))
Assert-True ($applyClickHandlers.Count -eq 1) 'Apply click handler missing or duplicated'

# 非 0 退出码场景（S6–S12）的返回值不手写：真实 Invoke-ElevatedEngineAction 起真 powershell.exe
# 子进程跑替身引擎，替身里是引擎原样的 Get-ApplyExitCode / Write-IpcResult / Write-BytesAtomic；
# GUI 侧走生产的结果文件读取、身份核对、退出码核对、Data 判空与 EngineExitCode 附加。
# 手写对象只能证明「测试作者以为的形状」，引擎一改退出码语义或 GUI 一改 Data 处理，桩就漂了。
# S8、S10、S11（备份写失败 / 部分子项已写入）连 Data 本身也不手写：子进程里跑引擎真实的 Invoke-Apply，
# 只桩掉系统写入与备份落盘这些叶子（复核 B5/B6：手写的 UnrecordedNames 替引擎作答，
# 引擎把「部分写入」项滤掉、或备份失败后直接 throw，测试照绿）。
$enginePath = Join-Path $root 'scripts\delta-booster.ps1'
$tokens = $null
$errors = $null
$engineAst = [Management.Automation.Language.Parser]::ParseFile($enginePath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('engine PowerShell AST parse failed: ' + (($errors | ForEach-Object Message) -join '; '))
function Get-AFFunctionText($SourceAst, [string]$Name) {
  $found = @($SourceAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true))
  Assert-True ($found.Count -eq 1) "function missing or duplicated: $Name"
  $found[0].Extent.Text
}
# 改名取出：新名字与下方点击路径的桩并存。函数头必须恰好是「function 名字」后接空白或 '('，否则改名会落空。
function Get-AFRenamedFunctionText($SourceAst, [string]$Name, [string]$NewName) {
  $text = Get-AFFunctionText $SourceAst $Name
  $header = "function $Name"
  Assert-True ($text.StartsWith($header, [StringComparison]::Ordinal) -and $text.Length -gt $header.Length -and
    ($text[$header.Length] -eq [char]'(' -or [char]::IsWhiteSpace($text[$header.Length]))) "$Name definition header changed"
  "function $NewName" + $text.Substring($header.Length)
}
# 引擎顶层入口分发（$didDispatch 语句 + if ($didDispatch) 块）也原样取出，在替身子进程里真跑：
# 结果文件里有没有 Data、失败时 Error 写什么、退出码怎么落，都是这段胶水说了算。
# 替身尾部自己复刻它，等于替生产作答——把 $dispatchData 改成只在 exit 0 时带 Data，旧替身照绿（攻击复核 A5）。
$engineDispatchFlag = @($engineAst.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$didDispatch' })
$engineDispatchBlock = @($engineAst.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses.Count -eq 1 -and
  $_.Clauses[0].Item1.Extent.Text -eq '$didDispatch' })
Assert-True ($engineDispatchFlag.Count -eq 1 -and $engineDispatchBlock.Count -eq 1) 'engine top-level action dispatch missing or duplicated'
$afReal = @{
  # 改名后与下方的点击路径桩并存：桩只在 S6–S12 把 Apply 转交给它。
  Transport = (@(
    (Get-AFRenamedFunctionText $ast 'Invoke-ElevatedEngineAction' 'Invoke-AFRealElevatedEngineAction'),
    (Get-AFFunctionText $ast 'Write-ProtectedEngineRequest'),
    (Get-AFFunctionText $ast 'Remove-ProtectedEngineExchangeFile'),
    (Get-AFFunctionText $ast 'ConvertTo-NativeFileArgument'),
    (Get-AFFunctionText $ast 'ConvertTo-EngineDiagnosticSummary'),
    (Get-AFFunctionText $engineAst 'Write-BytesAtomic')
  ) -join "`r`n`r`n")
  RowShape = (Get-AFFunctionText $engineAst 'Set-ApplyResultChangeState')
  # 真 Set-BusyState（攻击复核 B7）：桩成 { $script:Busy = $On } 时，生产函数把标志写错名字，
  # 闸门、忙碌记录和 Update-TuningUi 读到的永远是 False，测试却量的是桩。
  BusyState = (Get-AFRenamedFunctionText $ast 'Set-BusyState' 'Invoke-AFRealSetBusyState')
  EngineDispatch = ($engineDispatchFlag[0].Extent.Text + "`r`n" + $engineDispatchBlock[0].Extent.Text)
  EngineChild = (@(
    (Get-AFFunctionText $engineAst 'Write-BytesAtomic'),
    (Get-AFFunctionText $engineAst 'Get-ApplyExitCode'),
    (Get-AFFunctionText $engineAst 'Write-IpcResult'),
    (Get-AFFunctionText $engineAst 'Set-ApplyResultChangeState'),
    (Get-AFRenamedFunctionText $engineAst 'Invoke-Apply' 'Invoke-AFRealApply')
  ) -join "`r`n`r`n")
}

# 处理器里的 [Windows.Threading.DispatcherPriority]::Render 需要这个程序集；只加载，不建窗口。
Add-Type -AssemblyName WindowsBase

& {
  param([string]$FunctionText, [string]$HandlerText, [hashtable]$Real)
  Invoke-Expression $FunctionText
  $applyHandler = & ([scriptblock]::Create($HandlerText))
  Assert-True ($applyHandler -is [scriptblock]) 'Apply click handler body did not materialise as a scriptblock'

  $script:Busy = $false
  $script:TargetExe = 'C:\Games\fixture\game.exe'
  $script:TuningConfigGeneration = 0
  $script:ApplySelectionSnapshot = @()
  # 方案下拉框：默认没有（索引 -1）；S8 选中内置方案，让「选了方案」这一形态也走一遍收尾失败通道。
  $script:PresetList = @([pscustomobject]@{ Id = 'main'; Name = 'fixture main preset'; Builtin = $true })
  $script:AFPresetIndex = -1
  # 失败注入点是封闭集合：none | engine | local | tail | tail-script，同一时刻只有一处抛。
  $script:AFFailAt = 'none'; $script:AFWithBackup = $true
  $script:AFLog = @(); $script:AFDialogs = @(); $script:AFApplyCalls = 0
  $script:AFApplyRequests = @(); $script:AFLocalIds = @(); $script:AFBusyAtWork = @(); $script:AFBusyCalls = @(); $script:AFReenter = 'off'
  $script:AFDecline = $null; $script:AFOnConfirm = $null; $script:AFTuningActive = $false
  $script:AFRebootAsked = @(); $script:AFRebootStarted = 0; $script:AFRebootAnswer = $false
  $script:AFScenario = $null; $script:AFReply = $null; $script:AFRealEngineError = $null
  $fixtureBackup = 'C:\ProgramData\DeltaForceBooster\backup\fixture-backup.json'

  # 真 Write-Log 写 WPF 并落盘、真 Invoke-ElevatedEngineAction 起提权子进程、真 Invoke-LocalNoBackupItems
  # 删缓存目录——全部桩掉，全程纯内存。Set-BusyState 跑生产原文：它遍历的控件在夹具的 $ui 里大多不存在
  # （按 if ($ui[$n]) 跳过），存在的几个带 IsEnabled；chip 表为空，Update-TuningUi 桩掉（它刷的是实验页）。
  function Write-Log([string]$Msg) { $script:AFLog += ,"$Msg" }
  Invoke-Expression $Real.BusyState
  $script:SymptomChips = @{}; $script:ActiveSymptomIds = @(); $script:UpdateInfo = $null
  function Update-TuningUi { }
  # 调用记录只为让失败消息分清「没调 Set-BusyState」与「调了但没置位」，不参与判定。
  function Set-BusyState([bool]$On) { $script:AFBusyCalls += ,"$On"; Invoke-AFRealSetBusyState $On }
  function Test-TuningExperimentActive { [bool]$script:AFTuningActive }
  function Get-OptItems([string]$Exe) {
    # reg 三项（exit 2 需要一成一败；S8 需要「第三项在备份失败后不再执行」）；cache 与 check 都只能走本地 medium 执行器；
    # power-ultimate 用真实 Id（处理器按 Id 走「电源计划风险确认」分支，引擎里它是默认勾选的常见项）；
    # 高风险项只进 RiskyPanel，本测试里它永远不勾：勾上会撞到一个已报告、尚未修的产品缺陷（确认高风险项后
    # $ids 并入了 RiskyPanel 的项，再与只采 ItemPanel 的复采快照比对，必然以「勾选已变化」中止）。
    # 未勾选的高风险行仍在，任何忽略 IsChecked 的读取都会把它带进确认框（复核 B8）。Reboot 同真实目录的标注。
    @([pscustomobject]@{ Id='fixture-sys';    Name='fixture system item';     Kind='reg';   Tier='safe';  Reboot=$true;  Warn=$null; Note='' },
      [pscustomobject]@{ Id='fixture-sys2';   Name='fixture system item 2';   Kind='reg';   Tier='safe';  Reboot=$false; Warn=$null; Note='' },
      [pscustomobject]@{ Id='fixture-sys3';   Name='fixture system item 3';   Kind='reg';   Tier='safe';  Reboot=$false; Warn=$null; Note='' },
      [pscustomobject]@{ Id='power-ultimate'; Name='fixture power plan item'; Kind='power'; Tier='safe';  Reboot=$false; Warn=$null; Note='' },
      [pscustomobject]@{ Id='fixture-cache';  Name='fixture cache item';      Kind='cache'; Tier='safe';  Reboot=$false; Warn=$null; Note='' },
      [pscustomobject]@{ Id='fixture-check';  Name='fixture check item';      Kind='check'; Tier='safe';  Reboot=$false; Warn=$null; Note='' },
      [pscustomobject]@{ Id='fixture-risky';  Name='fixture high-risk item';  Kind='reg';   Tier='risky'; Reboot=$false; Warn='fixture warning'; Note='' })
  }
  function Show-ConfirmDialog([string]$ChipText, [string]$EnText, [string]$Message,
                              [string]$OkText = 'ok', [switch]$InfoOnly, [string]$Banner, [switch]$DefaultCancel) {
    $script:AFDialogs += ,([pscustomobject]@{ Chip = "$ChipText"; En = "$EnText"; Message = "$Message" })
    # S13：模态确认框自己跑消息泵，期间用户可以回主窗口改勾选；也可以在指定的确认框上点「取消」。
    # 其余场景一律回答「确认」。
    if ($ChipText -ceq '确认执行' -and $script:AFOnConfirm) { & $script:AFOnConfirm }
    return (-not ($script:AFDecline -and "$ChipText" -ceq $script:AFDecline))
  }
  # 重启提醒：用户的回答由场景决定（默认「稍后重启」）；真正的重启只计数，绝不执行。
  function Show-RebootDialog($Names) { $script:AFRebootAsked += ,(@($Names) -join '|'); [bool]$script:AFRebootAnswer }
  function Start-ConfirmedSystemReboot { $script:AFRebootStarted++ }
  function Invoke-ElevatedEngineAction {
    param([string]$Action, [string[]]$ItemIds, [string]$GamePath, [bool]$AllowRisky = $false,
          [string]$BackupFile, [switch]$ListRestoreItems, [string[]]$RestoreItemIds,
          [string]$ResidueKind, [string]$ResidueId, [string]$ResultId)
    if ($Action -ne 'Apply') {
      # 批次返回后处理器还有一次提权往返（Restore -ListRestoreItems 同步活动优化集合），真实传输层等它时
      # 同样以 Background 优先级泵消息：这段时间放开忙碌锁，排队的「执行优化 / 还原设置」点击照样嵌套执行。
      $script:AFBusyAtWork += ,"catalog:$($script:Busy)"
      return @()
    }
    $script:AFApplyCalls++
    # 忙碌态与请求在任何失败注入之前记下（独立复核 W2 / F4）：提权往返期间 Busy 必须已置位，
    # 高 IL 引擎只收系统项、原样拿到游戏路径、没有高风险确认就不带 AllowRisky。
    $script:AFBusyAtWork += ,"engine:$($script:Busy)"
    $script:AFApplyRequests += ,([pscustomobject]@{ ItemIds = [string[]]@($ItemIds); GamePath = "$GamePath"; AllowRisky = [bool]$AllowRisky })
    if ($script:AFReenter -eq 'armed') {
      # 真实传输层等引擎退出时以 Background 优先级泵消息，排队中的第二次「执行优化」点击会在这里
      # 重入同一个处理器。只重入一次；忙碌闸门必须把它挡回去。
      $script:AFReenter = 'fired'
      $null = & $applyHandler
    }
    if ($script:AFFailAt -eq 'engine') { throw [InvalidOperationException]::new('fixture engine refused the batch') }
    if ($script:AFScenario) {
      # S6–S12：Apply 交给真实的 Invoke-ElevatedEngineAction（改名为 Invoke-AFRealElevatedEngineAction），
      # 处理器拿到的 $r 就是生产结果整形的产物；抛出的原文留给断言消息，便于区分变异与替身故障。
      try {
        $script:AFReply = Invoke-AFRealElevatedEngineAction -Action $Action -ItemIds $ItemIds -GamePath $GamePath `
                            -AllowRisky $AllowRisky
      } catch { $script:AFRealEngineError = $_.Exception.Message; throw }
      return $script:AFReply
    }
    # 收到几个 id 就回几行：路由错了，「共 N 项」汇总也会跟着错，不再是恒定的一行。
    # Reboot 按引擎规则（成功、有改动、目录标了 Reboot）：S0 因此会走到重启提醒。
    $catalogById = @{}
    foreach ($catalogItem in @(Get-OptItems $GamePath)) { $catalogById["$($catalogItem.Id)"] = $catalogItem }
    [pscustomobject]@{
      Results = @(@($ItemIds) | ForEach-Object { [pscustomobject]@{ Id = "$_"; Name = "$($catalogById["$_"].Name)"; Ok = $true
                                                   Changed = $true; Skipped = $false; Attention = $false
                                                   Reboot = [bool]$catalogById["$_"].Reboot; Msg = '' } })
      Backup = $(if ($script:AFWithBackup) { $fixtureBackup } else { $null })
      BackupError = $null; UnrecordedNames = @(); EngineExitCode = 0
    }
  }
  function Invoke-LocalNoBackupItems([object[]]$Items) {
    $script:AFBusyAtWork += ,"local:$($script:Busy)"
    $script:AFLocalIds += @(@($Items) | ForEach-Object { "$($_.Id)" })
    if ($script:AFFailAt -eq 'local') { throw [IO.IOException]::new('fixture cache cleanup exploded') }
    @($Items | ForEach-Object { [pscustomobject]@{ Id=$_.Id; Name=$_.Name; Ok=$true; Changed=$true
                                                   Skipped=$false; Attention=$false; Reboot=$false; Msg='' } })
  }
  function Update-ItemList {
    if ($script:AFFailAt -eq 'tail') { throw [IO.IOException]::new('fixture tail refresh exploded') }
    # 生产界面收尾的失败多是脚本 / WPF 异常而不是 IO：S11 用普通 throw（RuntimeException）。
    if ($script:AFFailAt -eq 'tail-script') { throw 'fixture tail script error' }
  }
  function Update-ApplyProgress($Progress) { }
  function Set-LogBadge($N) { }
  function Show-HealthDialog($List) { }
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
  function Get-AFLogChannel {
    if ((Get-AFLogIndex '执行收尾失败：') -ge 0) { 'finalization' } elseif ((Get-AFLogIndex '执行失败：') -ge 0) { 'preflight' } else { 'none' }
  }
  # 弹窗正文里「· 项名」逐行列出的名字（确认执行 / 备份写入失败都这样列）。
  function Get-AFDialogBullets([string]$Message) {
    @("$Message" -split "`n" | Where-Object { $_.StartsWith('· ', [StringComparison]::Ordinal) } |
      ForEach-Object { $_.Substring(2).TrimEnd("`r") })
  }
  function Get-AFDialogTitles { (@($script:AFDialogs | ForEach-Object { "$($_.En)" }) -join '|') }
  # 确认框消息泵期间改勾选：按 Tag 找行（夹具的勾选表与真实界面一样含未勾选行）。
  function Set-AFRowChecked([string]$Tag, [bool]$On) {
    $rows = @(@($ui.ItemPanel.Children) | Where-Object { "$($_.Child.Children[0].Tag)" -ceq $Tag })
    Assert-True ($rows.Count -eq 1) "fixture has no item-panel row for $Tag"
    $rows[0].Child.Children[0].IsChecked = $On
  }
  function Invoke-AFApplyClick([string]$Scenario, [string]$FailAt, [string[]]$Tags, [bool]$WithBackup, [switch]$ClickAgainDuringBatch,
                               [string]$Decline, [scriptblock]$DuringConfirm, [string]$NoWorkBecause, [switch]$TuningActive,
                               [switch]$RebootNow) {
    $script:AFLog = @(); $script:AFDialogs = @(); $script:AFApplyCalls = 0
    $script:AFApplyRequests = @(); $script:AFLocalIds = @(); $script:AFBusyAtWork = @(); $script:AFBusyCalls = @()
    $script:AFRebootAsked = @(); $script:AFRebootStarted = 0; $script:AFRebootAnswer = [bool]$RebootNow
    $script:AFReply = $null; $script:AFRealEngineError = $null
    $script:AFDecline = $Decline; $script:AFOnConfirm = $DuringConfirm; $script:AFTuningActive = [bool]$TuningActive
    $script:AFReenter = $(if ($ClickAgainDuringBatch) { 'armed' } else { 'off' })
    $script:AFFailAt = $FailAt; $script:AFWithBackup = $WithBackup
    # 勾选表照真实界面搭：目录里每个非高风险项一行、高风险项进 RiskyPanel，勾不勾由场景决定。
    # 只放已勾选行时，「初次读取不看 IsChecked」把整张表都送去执行也照绿（攻击复核 B8）。
    $catalog = @(Get-OptItems $script:TargetExe)
    foreach ($tag in @($Tags)) {
      Assert-True (@($catalog | Where-Object { $_.Id -ceq $tag }).Count -eq 1) "[$Scenario] fixture selects an item that is not in the catalog: $tag"
    }
    $node = { param($tag, [bool]$checked) [pscustomobject]@{ Child = [pscustomobject]@{ Children = @([pscustomobject]@{ IsChecked = $checked; Tag = $tag }) } } }
    $ui = @{
      ItemPanel     = [pscustomobject]@{ IsEnabled = $true
                        Children = @($catalog | Where-Object { $_.Tier -ne 'risky' } | ForEach-Object { & $node $_.Id (@($Tags) -contains $_.Id) }) }
      RiskyPanel    = [pscustomobject]@{ IsEnabled = $true
                        Children = @($catalog | Where-Object { $_.Tier -eq 'risky' } | ForEach-Object { & $node $_.Id (@($Tags) -contains $_.Id) }) }
      PresetBox     = $(if ($script:AFPresetIndex -ge 0) { [pscustomobject]@{ SelectedIndex = $script:AFPresetIndex; IsEnabled = $true } } else { $null })
      ProgressPanel = [pscustomobject]@{ Visibility = 'Collapsed' }
      ProgFill      = [pscustomobject]@{ Width = 0 }
      ProgText      = [pscustomobject]@{ Text = '' }
      ProgCount     = [pscustomobject]@{ Text = '' }
    }
    $dispatcher = New-Object psobject
    # 与真 Dispatcher 一样同步执行传入的 action；丢弃它会让「经 Dispatcher.Invoke 执行、在置位前抛出」
    # 的代码在测试里永远不跑（攻击复核 A6）。
    $dispatcher | Add-Member -MemberType ScriptMethod -Name Invoke -Value { param($Action, $Priority) if ($Action) { $Action.Invoke() } } -Force
    $window = [pscustomobject]@{ Dispatcher = $dispatcher }
    try { & $applyHandler }
    finally { $script:AFDecline = $null; $script:AFOnConfirm = $null; $script:AFTuningActive = $false }
    # 唯一的同意框必须逐项列出本次勾选（攻击复核 B2/B8）：列表空着、或把未勾选的行也列进去，
    # 用户是在没看到/看错清单的情况下同意写系统。
    $confirmDialogs = @($script:AFDialogs | Where-Object { $_.Chip -ceq '确认执行' })
    if ($confirmDialogs.Count -gt 0) {
      $expectedNames = @($catalog | Where-Object { @($Tags) -contains $_.Id } | ForEach-Object { "$($_.Name)" })
      $listedNames = @(Get-AFDialogBullets $confirmDialogs[0].Message)
      $announced = $(if ($confirmDialogs[0].Message -match '将执行以下 (\d+) 项优化') { [int]$Matches[1] } else { -1 })
      Assert-True ($expectedNames.Count -gt 0 -and $announced -eq $expectedNames.Count -and
        (@($listedNames | Sort-Object) -join '|') -ceq (@($expectedNames | Sort-Object) -join '|')) `
        ("[$Scenario] the CONFIRM APPLY dialog announced $announced items and listed [$($listedNames -join '|')]; " +
         "expected exactly the $($expectedNames.Count) checked items [$($expectedNames -join '|')]")
    }
    if ($NoWorkBecause) {
      # 同意闸门（S13）：提权批次、本地执行器、目录同步一个都不能跑，「开始执行」也不该出现。
      Assert-True ($script:AFApplyCalls -eq 0 -and @($script:AFLocalIds).Count -eq 0 -and @($script:AFBusyAtWork).Count -eq 0 -and
        (Get-AFLogIndex '开始执行') -lt 0) `
        ("[$Scenario] Apply ran work after $NoWorkBecause (engine calls: $($script:AFApplyCalls); local: $(@($script:AFLocalIds) -join ','); " +
         "busy records: $(@($script:AFBusyAtWork) -join ', '); dialogs [$(Get-AFDialogTitles)])")
      Assert-True (-not $script:Busy) "[$Scenario] Apply handler left the busy state set after $NoWorkBecause"
      return
    }
    # 闸门探针先于忙碌记录判定：闸门失守时嵌套的第二轮会在自己的 finally 里提前放开忙碌锁，
    # 外层随后的记录也会变成 False——那是后果，根因是闸门没挡住，消息要指向根因。
    if ($ClickAgainDuringBatch) {
      Assert-True ($script:AFReenter -eq 'fired') "[$Scenario] busy-gate probe never clicked Apply again during the batch"
      Assert-True ($script:AFApplyCalls -eq 1 -and (Get-AFLogCount '正在执行优化/还原，请等本轮结束。') -eq 1 -and
        @($script:AFDialogs | Where-Object { $_.Chip -ceq '确认执行' }).Count -eq 1) `
        ("[$Scenario] a second Apply click during the running batch was not refused by the busy gate " +
         "(engine calls: $($script:AFApplyCalls); confirm dialogs: $(@($script:AFDialogs | Where-Object { $_.Chip -ceq '确认执行' }).Count))")
    }
    # 忙碌锁（独立复核 W2）：只查结束后 Busy=false 时，删掉确认后的 Set-BusyState $true 照样全绿，
    # 而提权往返期间按钮、勾选表和「还原设置」都还能点。每个场景都至少到达引擎或本地执行器之一（锚点）。
    # 记录覆盖处理器里全部三段工作：提权批次（engine）、本地执行器（local）、批次后的目录同步（catalog）。
    $busyWork = @($script:AFBusyAtWork)
    Assert-True ($busyWork.Count -ge 1) "[$Scenario] Apply fixture never reached the engine or local work (dialogs [$(Get-AFDialogTitles)])"
    Assert-True (@($busyWork | Where-Object { -not "$_".EndsWith(':True') }).Count -eq 0) `
      "[$Scenario] Apply ran engine/local/catalog work while not busy: $($busyWork -join ', ') (Set-BusyState calls: $($script:AFBusyCalls -join ','))"
    Assert-True (-not $script:Busy) "[$Scenario] Apply handler left the busy state set"
    # 电源项会在「确认执行」之前多弹一次风险确认，所以只要求确认框恰好出现一次，不钉它的位置。
    Assert-True (@($script:AFDialogs | Where-Object { $_.Chip -ceq '确认执行' }).Count -eq 1) `
      "[$Scenario] Apply fixture did not reach the confirmation dialog exactly once"
    Assert-True ($RebootNow -or $script:AFRebootStarted -eq 0) `
      "[$Scenario] a reboot was started although the user chose 'reboot later' (reboot prompts: [$($script:AFRebootAsked -join ' / ')])"
  }
  function Get-AFLastDialog { $script:AFDialogs[$script:AFDialogs.Count - 1] }
  # 路由断言（独立复核 F4）：高 IL 引擎只收系统项（cache/check 都不行）、原样拿到游戏路径、没有高风险
  # 确认就不带 AllowRisky；cache/check 只走本地（medium）执行器。按集合比较（排序后逐项 -ceq），
  # 不钉顺序；期望集合非空（锚点），两边都退化成空集也对不上。
  function Assert-AFRouting([string]$Scenario, [string[]]$ExpectedElevated, [string[]]$ExpectedLocal) {
    $expElevated = @($ExpectedElevated | Where-Object { $_ })
    $expLocal = @($ExpectedLocal | Where-Object { $_ })
    Assert-True (($expElevated.Count + $expLocal.Count) -gt 0) "[$Scenario] routing expectation is vacuous"
    $requests = @($script:AFApplyRequests)
    if ($expElevated.Count -gt 0) {
      Assert-True ($requests.Count -eq 1) "[$Scenario] expected exactly one elevated Apply request, got $($requests.Count)"
      $req = $requests[0]
      Assert-True (@($req.ItemIds).Count -eq $expElevated.Count -and
        (@($req.ItemIds | Sort-Object) -join '|') -ceq (@($expElevated | Sort-Object) -join '|')) `
        "[$Scenario] elevated engine received [$(@($req.ItemIds) -join ',')], expected only system items [$($expElevated -join ',')]"
      Assert-True ($req.GamePath -ceq $script:TargetExe) "[$Scenario] elevated engine did not receive the selected game path: $($req.GamePath)"
      Assert-True ($req.AllowRisky -eq $false) "[$Scenario] elevated engine got AllowRisky without a high-risk confirmation"
    } else {
      Assert-True ($requests.Count -eq 0) "[$Scenario] no system item selected but the elevated engine was called"
    }
    $localIds = @($script:AFLocalIds)
    Assert-True ($localIds.Count -eq $expLocal.Count -and
      (@($localIds | Sort-Object) -join '|') -ceq (@($expLocal | Sort-Object) -join '|')) `
      "[$Scenario] local no-backup runner received [$($localIds -join ',')], expected [$($expLocal -join ',')]"
  }

  # S0：全部成功——证明桩齐全。少一个桩时异常会被产品自己的 catch 吞成弹窗，这里会直接红。
  # 三种 Kind 都勾上：系统项进引擎，cache 与 check 都只能进本地执行器。
  Invoke-AFApplyClick 'S0' 'none' @('fixture-sys', 'fixture-cache', 'fixture-check') $true
  Assert-True ($script:AFApplyCalls -eq 1 -and $script:AFDialogs.Count -eq 1) `
    ('[S0] successful Apply fixture raised a failure dialog: ' + (Get-AFLastDialog).Chip + ' ' + (Get-AFLastDialog).Message)
  Assert-AFRouting 'S0' @('fixture-sys') @('fixture-cache', 'fixture-check')
  # 锚点：成功路径确实走到了批次后的目录同步往返，上面「catalog 也必须在忙碌锁内」的检查不是空转。
  Assert-True (@($script:AFBusyAtWork | Where-Object { "$_".StartsWith('catalog:') }).Count -eq 1) `
    "[S0] the post-batch catalog round-trip (Restore -ListRestoreItems) was not observed exactly once: $($script:AFBusyAtWork -join ', ')"
  Assert-True ((Get-AFLogIndex '执行完成：共 3 项 — 3 成功') -ge 0) '[S0] successful Apply fixture did not complete all three items exactly once'
  Assert-True ((Get-AFLogCount '备份已保存：') -eq 1) '[S0] successful Apply logged the backup path zero times or twice'
  # 重启同意（攻击复核 B4）：唯一需重启的成功项弹一次提醒，用户选「稍后」就不能重启，并留下日志。
  Assert-True (@($script:AFRebootAsked).Count -eq 1 -and $script:AFRebootAsked[0] -ceq 'fixture system item' -and
    $script:AFRebootStarted -eq 0 -and (Get-AFLogIndex '你选择了稍后重启') -ge 0) `
    "[S0] the reboot prompt was not shown once for the one successful item that needs a reboot, or 'reboot later' was not honoured (prompts: [$($script:AFRebootAsked -join ' / ')]; reboots started: $($script:AFRebootStarted))"
  # S0b：同一成功路径，用户选「立即重启」——恰好发起一次重启。
  Invoke-AFApplyClick 'S0b' 'none' @('fixture-sys') $true -RebootNow
  Assert-AFRouting 'S0b' @('fixture-sys') @()
  Assert-True (@($script:AFRebootAsked).Count -eq 1 -and $script:AFRebootStarted -eq 1 -and (Get-AFLogIndex '你选择了稍后重启') -lt 0) `
    "[S0b] the user chose 'reboot now' but the reboot was not started exactly once (prompts: [$($script:AFRebootAsked -join ' / ')]; reboots started: $($script:AFRebootStarted))"

  # S1：系统批次已返回（带备份），随后本地缓存收尾炸掉——必须走「收尾失败」通道。
  Invoke-AFApplyClick 'S1' 'local' @('fixture-sys', 'fixture-cache') $true
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) '[S1] post-admin fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行收尾未完成' -and $d.En -ceq 'APPLY FINALIZATION FAILED') `
    "[S1] real Apply path failed after the admin batch returned but was not reported as a finalization failure (dialog: $($d.En); log channel: $(Get-AFLogChannel))"
  Assert-True ($d.Message.Contains('请不要重复点击「执行优化」') -and $d.Message.Contains('fixture cache cleanup exploded')) `
    '[S1] post-admin dialog lost the do-not-repeat warning or the original error'
  $failIdx = Get-AFLogIndex '执行收尾失败：fixture cache cleanup exploded'
  Assert-True ($failIdx -ge 0) '[S1] post-admin log did not record the finalization failure'
  Assert-True ((Get-AFLogIndex '系统批次可能已执行，请不要重复点击「执行优化」') -gt $failIdx) `
    '[S1] post-admin log did not warn against repeating a possibly completed batch'
  Assert-True ((Get-AFLogIndex '执行失败：') -lt 0) '[S1] post-admin failure was also reported as a preflight failure'
  Assert-True ((Get-AFLogCount '备份已保存：') -eq 1 -and
    (Get-AFLogIndex "备份已保存：$fixtureBackup") -ge 0 -and (Get-AFLogIndex "备份已保存：$fixtureBackup") -lt $failIdx) `
    '[S1] backup path was not logged exactly once, before local check/cache finalization failed'
  Assert-True ((Get-AFLogIndex '异常类型：System.IO.IOException') -ge 0) `
    '[S1] post-admin log did not carry the original exception type (a missing fixture stub also lands here)'
  Assert-True ((Get-AFLogIndex 'ScriptStackTrace：') -ge 0) '[S1] post-admin log did not carry ScriptStackTrace'
  Assert-AFRouting 'S1' @('fixture-sys') @('fixture-cache')

  # S2：提权引擎调用本身失败——标记必须仍为假，原文透传的前置失败通道。
  Invoke-AFApplyClick 'S2' 'engine' @('fixture-sys', 'fixture-cache') $true
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) '[S2] preflight fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行未完成' -and $d.En -ceq 'APPLY NOT COMPLETED') `
    '[S2] a failure of the elevated engine call itself was misreported as a completed admin batch'
  Assert-True ($d.Message -ceq 'fixture engine refused the batch') '[S2] preflight dialog did not pass the raw error through'
  Assert-True ((Get-AFLogIndex '系统批次可能已执行') -lt 0) '[S2] preflight failure warned about a batch that never ran'
  Assert-True ((Get-AFLogIndex '备份已保存：') -lt 0) '[S2] preflight failure invented a backup log line'
  Assert-True ((Get-AFLogIndex '执行失败：fixture engine refused the batch') -ge 0) '[S2] preflight failure lost the raw error in the log'
  Assert-True ((Get-AFLogIndex '异常类型：System.InvalidOperationException') -ge 0) '[S2] preflight log did not carry the exception type'
  Assert-AFRouting 'S2' @('fixture-sys') @()

  # S3：只勾系统项（没有本地收尾），失败发生在之后的界面刷新——仍是收尾失败。
  # 同时在批次进行中再点一次「执行优化」：忙碌闸门必须拒绝，不能嵌套起第二个提权批次。
  Invoke-AFApplyClick 'S3' 'tail' @('fixture-sys') $true -ClickAgainDuringBatch
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) '[S3] tail fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行收尾未完成' -and $d.En -ceq 'APPLY FINALIZATION FAILED') `
    "[S3] an elevated-only batch that failed after the engine returned was not reported as a finalization failure (dialog: $($d.En); log channel: $(Get-AFLogChannel))"
  Assert-True ((Get-AFLogIndex '执行收尾失败：fixture tail refresh exploded') -ge 0 -and
    (Get-AFLogIndex '系统批次可能已执行，请不要重复点击「执行优化」') -ge 0 -and (Get-AFLogIndex '执行失败：') -lt 0) `
    '[S3] elevated-only tail failure lost the do-not-repeat warning'
  Assert-AFRouting 'S3' @('fixture-sys') @()

  # S4：只勾缓存项，全程没有提权批次——绝不能报「系统批次可能已执行」。
  Invoke-AFApplyClick 'S4' 'local' @('fixture-cache') $true
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 0) '[S4] local-only fixture unexpectedly invoked the elevated engine'
  Assert-True ($d.Chip -ceq '执行未完成' -and $d.En -ceq 'APPLY NOT COMPLETED' -and $d.Message -ceq 'fixture cache cleanup exploded') `
    '[S4] a run that never elevated was reported as a possibly completed admin batch'
  Assert-True ((Get-AFLogIndex '系统批次可能已执行') -lt 0 -and (Get-AFLogIndex '备份已保存：') -lt 0) `
    '[S4] local-only failure warned about a batch that never ran or invented a backup'
  Assert-AFRouting 'S4' @() @('fixture-cache')

  # S5：引擎成功返回但没带回备份路径（备份整体写失败时就是这样）——批次仍然执行过。
  Invoke-AFApplyClick 'S5' 'local' @('fixture-sys', 'fixture-cache') $false
  $d = Get-AFLastDialog
  Assert-True ($script:AFApplyCalls -eq 1) '[S5] backup-less fixture never reached the elevated engine call'
  Assert-True ($d.Chip -ceq '执行收尾未完成' -and $d.En -ceq 'APPLY FINALIZATION FAILED') `
    "[S5] a backup-less admin batch that returned was not marked as completed (dialog: $($d.En); log channel: $(Get-AFLogChannel))"
  Assert-True ((Get-AFLogIndex '系统批次可能已执行，请不要重复点击「执行优化」') -ge 0 -and (Get-AFLogIndex '备份已保存：') -lt 0) `
    '[S5] backup-less batch lost the do-not-repeat warning or invented a backup line'
  Assert-AFRouting 'S5' @('fixture-sys') @('fixture-cache')

  # S13（同意闸门）：此前每个确认框替身都回答「确认」，勾选也从不在确认期间变化。把「确认执行」取消分支的
  # return、电源风险确认（默认按钮就是取消）取消分支的 return、或确认后重新采样勾选的中止分支删掉，
  # 全部照样绿——那意味着用户点了取消、或已取消勾选的项目，照样写进系统。
  Invoke-AFApplyClick 'S13-cancel' 'none' @('fixture-sys', 'fixture-cache') $true -Decline '确认执行' `
    -NoWorkBecause 'the user cancelled the CONFIRM APPLY dialog'
  Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY') `
    "[S13-cancel] a cancelled Apply showed something other than its confirmation dialog: [$(Get-AFDialogTitles)]"
  Invoke-AFApplyClick 'S13-power' 'none' @('fixture-sys', 'power-ultimate', 'fixture-cache') $true -Decline '电源计划优化风险确认' `
    -NoWorkBecause 'the user cancelled the POWER PLAN RISK confirmation'
  Assert-True ((Get-AFDialogTitles) -ceq 'POWER PLAN RISK' -and
    (Get-AFLogIndex '已取消电源计划风险确认，本次 3 项优化均未执行。') -ge 0) `
    "[S13-power] cancelling the power-plan risk confirmation did not stop the whole run before the Apply confirmation: [$(Get-AFDialogTitles)]"
  Invoke-AFApplyClick 'S13-uncheck' 'none' @('fixture-sys', 'fixture-cache') $true `
    -NoWorkBecause 'the selection changed (one item unchecked) during the confirmation' `
    -DuringConfirm { Set-AFRowChecked 'fixture-cache' $false }
  Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY|SELECTION CHANGED' -and
    (Get-AFLogIndex '确认过程中勾选发生了变化，本次执行已中止。') -ge 0) `
    "[S13-uncheck] a selection change during the confirmation did not abort with the SELECTION CHANGED notice: [$(Get-AFDialogTitles)]"
  # 攻击复核 B1：数量不变、集合变了（取消一项、勾上另一项）。只比数量的重新核对会放行，
  # 于是执行的是确认前那份旧勾选——包括用户刚取消的那一项。
  Invoke-AFApplyClick 'S13-swap' 'none' @('fixture-sys', 'fixture-cache') $true `
    -NoWorkBecause 'the selection was swapped (same count) during the confirmation' `
    -DuringConfirm { Set-AFRowChecked 'fixture-cache' $false; Set-AFRowChecked 'fixture-sys2' $true }
  Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY|SELECTION CHANGED') `
    "[S13-swap] a swapped selection did not abort with the SELECTION CHANGED notice: [$(Get-AFDialogTitles)]"
  # 攻击复核 B3：自动调优实验进行中，普通 Apply 必须在任何确认或系统写入之前拒绝（按钮禁用之外的第二道防线）。
  Invoke-AFApplyClick 'S13-tuning' 'none' @('fixture-sys', 'fixture-cache') $true -TuningActive `
    -NoWorkBecause 'Apply was clicked during an active auto-tuning experiment'
  $d = Get-AFLastDialog
  Assert-True ((Get-AFDialogTitles) -ceq 'APPLY NOT COMPLETED' -and $d.Message.Contains('自动调优实验期间已锁定配置') -and
    (Get-AFLogIndex '执行失败：自动调优实验期间已锁定配置') -ge 0) `
    "[S13-tuning] Apply during an active auto-tuning experiment was not refused with the experiment-lock message before any confirmation: [$(Get-AFDialogTitles)]"

  # S6–S11：批次**已经返回、带着 Data**，但引擎退出码不是 0（delta-booster.ps1 Get-ApplyExitCode：
  # 2 = 有项目失败，3 = 备份写入失败）。「已返回」不等于「全部成功」：把置位改成只在
  # EngineExitCode=0、无 BackupError、全部 Ok 或有改动时才成立，S0–S5 全都照样绿
  # （独立复核 R2 extra-apply 变异）。这里起真子进程，只桩掉受保护目录 / ACL 校验
  # （它们由 engine-security 与 engine-request-transport 覆盖）。
  $afRoot = Join-Path ([IO.Path]::GetTempPath()) ('dfb-apply-exit-fixture-' + [guid]::NewGuid().ToString('N'))
  $afExchange = Join-Path $afRoot 'session'
  $afChildSeen = Join-Path $afRoot 'scripts\af-invoke-apply.json'
  $afEngineResult = Join-Path $afRoot 'scripts\af-engine-result.json'
  $afSystemWrites = Join-Path $afRoot 'scripts\af-system-writes.txt'
  $afBackupDir = Join-Path $afRoot 'scripts\backup'
  $pendingBackup = Join-Path $afBackupDir 'backup-fixture.pending.json'
  $completeBackup = Join-Path $afBackupDir 'backup-fixture.json'
  # 「命令未识别」来自替身缺桩（引擎或传输层新增了依赖），不是产品回归：单独报，不许冒充任何一种杀死。
  $afMissingCommand = '识别为 cmdlet|is not recognized as the name of a cmdlet'
  [void][IO.Directory]::CreateDirectory((Join-Path $afRoot 'scripts'))
  [void][IO.Directory]::CreateDirectory($afExchange)
  try {
    Invoke-Expression $Real.Transport
    Invoke-Expression $Real.RowShape
    function Test-ProtectedProgramRoot { $true }
    function Get-ProtectedEngineExchangeRoot { $afExchange }
    function Set-ProtectedFileAcl([string]$Path) { }
    function Test-ProtectedFileAcl([string]$Path) { $true }
    function Test-PathHasReparsePoint([string]$Path) { $false }
    $isAdminGui = $true
    $script:EngineHostSessionValidated = $true
    $script:RootDir = $afRoot
    $script:OriginalUserLocalAppData = Join-Path $afRoot 'user-local'
    $script:OriginalUserSid = 'S-1-5-21-111111111-222222222-333333333-1001'
    $script:ProtectedUserStateRoot = Join-Path $afRoot 'user-state'
    # 替身引擎：读真实请求文件，按引擎尾部分发的顺序由生产 Get-ApplyExitCode 推出退出码、
    # 生产 Write-IpcResult 原子发布结果，再以该退出码退出（S9 模拟外壳改写进程退出码）。
    # 发布的结果文件另抄一份给父进程：传输层读完就删，失败消息要能说清是引擎发布错了还是传输层读错了。
    # 真实 Invoke-Apply（S8/S10/S11）只桩叶子：系统写入（Invoke-ApplyOp 记一笔「已写入」）与备份落盘
    # （Write-BackupDocumentAtomic 真写到临时备份目录；文档里一出现场景标记的那个子操作的 prepared 记录，
    # 这次及之后的落盘都失败——按语义触发而不是按「第几次写入」，引擎多一次或少一次原子写不会挪动故障点）；
    # 写前日志、逐操作容错、备份失败即停、部分备份抢救、UnrecordedNames、Reboot 标注都是生产原文。
    $childEngine = @(
      'param([string]$RequestFile)',
      '$ErrorActionPreference = ''Stop''',
      'function Get-ValidatedEngineSessionRoot { Split-Path -Parent $RequestFile }',
      'function Set-ProtectedFileAcl([string]$Path) { }',
      'function Test-ProtectedFileAcl([string]$Path) { $true }',
      'function Test-PathHasReparsePoint([string]$Path) { $false }',
      $Real.EngineChild,
      '$afRealWriteIpcResult = ${function:Write-IpcResult}',
      'function Write-IpcResult {',
      '  & $afRealWriteIpcResult @args',
      '  if (Test-Path -LiteralPath $script:EngineResultFile) { [IO.File]::Copy($script:EngineResultFile, (Join-Path $PSScriptRoot ''af-engine-result.json''), $true) }',
      '}',
      '$request = [IO.File]::ReadAllText($RequestFile) | ConvertFrom-Json',
      '$spec = [IO.File]::ReadAllText((Join-Path $PSScriptRoot ''af-scenario.json'')) | ConvertFrom-Json',
      '$script:EngineResultFile = Join-Path (Get-ValidatedEngineSessionRoot) (''engine-result-{0}.json'' -f $request.ResultId)',
      '$script:BackupDir = Join-Path $PSScriptRoot ''backup''',
      '$afFailPrepared = @($spec.Real.Items | ForEach-Object { $afItem = $_; @($afItem.Ops) | Where-Object { $_.PrepareFails } | ForEach-Object { "$($afItem.Id)/$($_.Name)" } })',
      'function Enter-EngineMutex { ''af-fixture-mutex'' }',
      'function Exit-EngineMutex($Mutex) { }',
      'function Find-GamePath { $null }',
      'function Get-ActiveScheme { $null }',
      'function Test-ToolPowerScheme($Scheme) { $false }',
      'function Test-Admin { $true }',
      'function Initialize-ProtectedStore { [void][IO.Directory]::CreateDirectory($script:BackupDir) }',
      'function New-BackupDocument([DateTime]$When, [string]$ApplyId) {',
      '  [pscustomobject]@{ BackupId = ''fixture''; ApplyId = $ApplyId; State = ''pending''; Items = @(); Ops = @() }',
      '}',
      'function Get-BackupOpFields([string]$Kind, [int]$SchemaVersion) { @(''Path'') }',
      'function Assert-BackupOperation($Op, [int]$SchemaVersion, [string]$AllowedLocalAppData) { }',
      'function New-BackupItemRecord($Item) { [pscustomobject]@{ ItemId = "$($Item.Id)"; OpIds = @() } }',
      'function Write-BackupDocumentAtomic([string]$Path, $Document) {',
      '  if (@($Document.Ops | Where-Object { $afFailPrepared -contains "$($_.Path)" }).Count -gt 0) { throw "$($spec.Real.BackupWriteError)" }',
      '  [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 6))',
      '}',
      'function Invoke-ApplyOp($Op, $ItemId, [scriptblock]$PrepareBackup, [scriptblock]$MarkApplied) {',
      '  $token = & $PrepareBackup @{ Kind = ''reg''; Path = "$ItemId/$($Op.Name)" }',
      '  if ($Op.WriteError) { throw "$($Op.WriteError)" }',
      '  [IO.File]::AppendAllText((Join-Path $PSScriptRoot ''af-system-writes.txt''), "$ItemId/$($Op.Name)`r`n")',
      '  & $MarkApplied $token',
      '  $null',
      '}',
      'function Get-OptItems([string]$Exe) {',
      '  @($spec.Real.Items | ForEach-Object { [pscustomobject]@{ Id = "$($_.Id)"; Name = "$($_.Name)"; Kind = ''reg''; Tier = ''safe''',
      '    Admin = $true; Default = $true; Reboot = [bool]$_.Reboot; Ops = @($_.Ops) } })',
      '}',
      'if ($null -ne $spec.ProcessExitCode) {',
      '  # 仅 S9：模拟外壳改写进程退出码。引擎自己的 exit 改写不了，这一场景保留手写尾部。',
      '  $cliExitCode = Get-ApplyExitCode $spec.Data',
      '  Write-IpcResult "$($request.ResultId)" "$($request.Action)" $spec.Data $cliExitCode $null',
      '  exit ([int]$spec.ProcessExitCode)',
      '}',
      '# 其余场景跑引擎真实的顶层入口分发：只把 Invoke-Apply 与用户上下文换成替身，',
      '# Data 是否写进结果文件、Error 与退出码怎么落，全由生产代码决定。',
      'function Set-TargetUserContext($Sid, $LocalAppData) { }',
      'function Invoke-Apply([string[]]$ItemIds, [string]$GamePath, [bool]$AllowRisky, [scriptblock]$Progress) {',
      '  # 记下生产分发真正交给 Invoke-Apply 的参数：父进程核对请求文件里的项目 / 路径 / AllowRisky 原样到达引擎。',
      '  $seen = [pscustomobject]@{ ItemIds = @($ItemIds); GamePath = "$GamePath"; AllowRisky = $AllowRisky }',
      '  [IO.File]::WriteAllText((Join-Path $PSScriptRoot ''af-invoke-apply.json''), ($seen | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))',
      '  # S12：批次在任何系统写入前就抛出（真实 Invoke-Apply 的备份目录预检），Data 由生产分发的 catch 留空。',
      '  if ($spec.Throw) { throw "$($spec.Throw)" }',
      '  if ($spec.Real) { return (Invoke-AFRealApply $ItemIds $GamePath $AllowRisky $Progress) }',
      '  $spec.Data',
      '}',
      '$ResultId = "$($request.ResultId)"; $Apply = $request.Action -eq ''Apply''',
      '$Items = [string[]]@($request.ItemIds); $GamePath = $request.GamePath; $Risky = [bool]$request.AllowRisky',
      '$UserSid = $request.UserSid; $UserLocalAppData = $request.UserLocalAppData',
      $Real.EngineDispatch,
      'throw ''fixture: engine dispatch fell through without exiting'''
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $afRoot 'scripts\delta-booster.ps1'), $childEngine, (New-Object Text.UTF8Encoding($true)))

    function New-AFEngineRow([string]$Id, [string]$Name, [bool]$Ok, [bool]$Changed, [string]$Msg, [switch]$NeedsReboot) {
      # 引擎 Invoke-Apply 的行只有 Id/Name/Ok/Skipped/Msg；Changed 由生产 Set-ApplyResultChangeState 补
      # （Ok 但没改动会被改判为 Skipped），Reboot 在批次末尾统一 Add-Member，规则同引擎：
      # 目录里标了 Reboot 的项，且 Ok、Changed、非 Attention 才为真（真实目录里多数系统项都标了 Reboot）。
      $row = [pscustomobject]@{ Id = $Id; Name = $Name; Ok = $Ok; Skipped = $false; Msg = $Msg }
      [void](Set-ApplyResultChangeState $row $Changed)
      $row | Add-Member -NotePropertyName Reboot -NotePropertyValue ([bool]($NeedsReboot -and $row.Ok -and $row.Changed))
      $row
    }
    function Write-AFEngineScenario {
      foreach ($leftover in @($afChildSeen, $afEngineResult, $afSystemWrites)) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force }
      }
      if (Test-Path -LiteralPath $afBackupDir) { Remove-Item -LiteralPath $afBackupDir -Recurse -Force }
      [IO.File]::WriteAllText((Join-Path $afRoot 'scripts\af-scenario.json'),
        ($script:AFScenario | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    }
    function Set-AFEngineScenario([object[]]$Rows, $Backup, $BackupError, [string[]]$Unrecorded, $ProcessExitCode) {
      $script:AFScenario = [pscustomobject]@{
        Data = [pscustomobject]@{
          ApplyId = [guid]::NewGuid().ToString('D'); Results = @($Rows); Backup = $Backup
          BackupError = $BackupError; UnrecordedNames = @($Unrecorded | Where-Object { $_ })
        }
        ProcessExitCode = $ProcessExitCode; Throw = $null; Real = $null
      }
      Write-AFEngineScenario
    }
    function Set-AFEngineThrowScenario([string]$Message) {
      $script:AFScenario = [pscustomobject]@{ Data = $null; ProcessExitCode = $null; Throw = $Message; Real = $null }
      Write-AFEngineScenario
    }
    # 真实 Invoke-Apply 场景：只描述目录（每项的子操作、哪个子操作的系统写入失败）和第几次备份落盘开始失败。
    # -PrepareFails：持久化这个子操作的 prepared 备份记录时磁盘写满（此后所有落盘都失败）；WriteError：备份已记下，系统写入被拒。
    function New-AFRealOp([string]$Name, [string]$WriteError, [switch]$PrepareFails) {
      [pscustomobject]@{ Name = $Name; WriteError = $WriteError; PrepareFails = [bool]$PrepareFails }
    }
    function New-AFRealItem([string]$Id, [string]$Name, [object[]]$Ops) { [pscustomobject]@{ Id = $Id; Name = $Name; Reboot = $false; Ops = @($Ops) } }
    function Set-AFEngineRealScenario([object[]]$Items, [string]$BackupWriteError) {
      $script:AFScenario = [pscustomobject]@{
        Data = $null; ProcessExitCode = $null; Throw = $null
        Real = [pscustomobject]@{ Items = @($Items); BackupWriteError = $BackupWriteError }
      }
      Write-AFEngineScenario
    }
    function Get-AFEngineResult {
      if (-not (Test-Path -LiteralPath $afEngineResult)) { return $null }
      [IO.File]::ReadAllText($afEngineResult) | ConvertFrom-Json
    }
    function Get-AFSystemWrites {
      if (-not (Test-Path -LiteralPath $afSystemWrites)) { return @() }
      @([IO.File]::ReadAllLines($afSystemWrites) | Where-Object { $_ })
    }
    # 引擎 → 传输链路逐段定位（复核：原先 ~25 个变异共用一句「没报成收尾失败」，缺桩、子进程崩溃、
    # 传输层误抛、分发丢 Data、处理器丢标记都长一个样）。每段只在前一段成立时才检查，消息指向第一处断点。
    function Assert-AFEnginePublished([string]$Label) {
      $published = Get-AFEngineResult
      # 缺桩先判：传输层（父进程）缺桩时子进程根本起不来；引擎里缺桩则落在分发的 Error，或被逐项 catch 成某一行的 Msg。
      $rowMessages = $(if ($null -ne $published -and $null -ne $published.Data) { @($published.Data.Results | ForEach-Object { "$($_.Msg)" }) -join ' ' })
      $stubProblem = "$($script:AFRealEngineError) $(if ($null -ne $published) { "$($published.Error)" }) $rowMessages"
      Assert-True (-not ($stubProblem -match $afMissingCommand)) `
        "$($Label): fixture problem, not a product regression: the engine child or the real transport called a command this test has no stub for: $($stubProblem.Trim())"
      Assert-True ($null -ne $published) `
        "$($Label): engine child never published a result file (crashed or blocked before Write-IpcResult; real transport error: $($script:AFRealEngineError))"
      $published
    }
    function Assert-AFFinalizationAfterBatch([string]$Label, [int]$ExpectedExit, [string]$FailText) {
      Assert-True ($script:AFApplyCalls -eq 1) "$($Label): fixture never reached the elevated engine call"
      $published = Assert-AFEnginePublished $Label
      if ($null -ne $script:AFScenario.Real -and $null -eq $published.Data) {
        # 真实 Invoke-Apply 场景（复核 B5）：系统已经写过，引擎却把整批 Data 丢了（Invoke-Apply 抛出，而不是交回
        # BackupError / UnrecordedNames）。于是走前置失败通道：没有「请不要重复点击」、没有备份失败弹窗、没有待回退项名。
        $writes = @(Get-AFSystemWrites)
        Assert-True ($writes.Count -eq 0) `
          ("$($Label): the real engine lost the batch Data after $($writes.Count) system write(s) [$($writes -join ',')] " +
           "(Invoke-Apply threw instead of returning BackupError / UnrecordedNames); engine exit $([int]$published.ExitCode), error '$($published.Error)'")
      }
      $hasData = $null -ne $published.Data
      Assert-True ($hasData -and [int]$published.ExitCode -eq $ExpectedExit) `
        ("$($Label): the real engine dispatch published exit $([int]$published.ExitCode) $(if ($hasData) { 'with' } else { 'without' }) Data " +
         "(expected exit $ExpectedExit with Data; engine error: '$($published.Error)')")
      Assert-True ($null -eq $script:AFRealEngineError -and $null -ne $script:AFReply) `
        "$($Label): the real transport threw on an engine result that carried Data (engine exit $([int]$published.ExitCode)): $($script:AFRealEngineError)"
      $d = Get-AFLastDialog
      Assert-True ($d.Chip -ceq '执行收尾未完成' -and $d.En -ceq 'APPLY FINALIZATION FAILED') `
        ("$Label returned Data from the admin batch but was not reported as a finalization failure " +
         "(dialog: $($d.En); log channel: $(Get-AFLogChannel); transport returned engine exit $($script:AFReply.EngineExitCode))")
      Assert-True ($d.Message.Contains('请不要重复点击「执行优化」') -and $d.Message.Contains($FailText)) `
        "$Label finalization dialog lost the do-not-repeat warning or the original error"
      $idx = Get-AFLogIndex "执行收尾失败：$FailText"
      Assert-True ($idx -ge 0 -and (Get-AFLogIndex '系统批次可能已执行，请不要重复点击「执行优化」') -gt $idx -and
        (Get-AFLogIndex '执行失败：') -lt 0) "$Label log lost the finalization failure or the do-not-repeat warning"
      # 非空锚点：确认处理器面对的真是生产整形出的非 0 退出码，而不是退回了上面的 exit-0 手写桩。
      Assert-True ($null -ne $script:AFReply -and [int]$script:AFReply.EngineExitCode -eq $ExpectedExit) `
        "$Label did not come back through the real result shaping as engine exit $ExpectedExit"
      $idx
    }
    # 传输链路核对：GUI 请求 → 真 Invoke-ElevatedEngineAction 写的请求文件 → 引擎真实分发 → Invoke-Apply。
    # 子进程替身若无视收到的 ItemIds，传输层丢项、分发层改 AllowRisky 都看不见（攻击复核遗留项）。
    function Assert-AFEngineChildSaw([string]$Scenario, [string[]]$ExpectedElevated) {
      Assert-True (Test-Path -LiteralPath $afChildSeen) "[$Scenario] engine child never reached Invoke-Apply through the real dispatch"
      $seen = [IO.File]::ReadAllText($afChildSeen) | ConvertFrom-Json
      $seenIds = @($seen.ItemIds)
      Assert-True ($seenIds.Count -eq @($ExpectedElevated).Count -and
        (@($seenIds | Sort-Object) -join '|') -ceq (@($ExpectedElevated | Sort-Object) -join '|') -and
        "$($seen.GamePath)" -ceq $script:TargetExe -and $seen.AllowRisky -eq $false) `
        ("[$Scenario] engine Invoke-Apply received ItemIds [$($seenIds -join ',')], GamePath '$($seen.GamePath)', " +
         "AllowRisky $($seen.AllowRisky) through the real request file; expected [$($ExpectedElevated -join ',')], " +
         "'$($script:TargetExe)', False")
    }

    # S6：exit 2——一项真改动成功（且需重启才完全生效，真实目录里多数系统项如此）、一项失败，
    # 带完整备份；随后本地缓存收尾炸掉。S0–S5 与其余场景都没有 Reboot 行，「有待重启项就不置位」只有这里会红。
    Set-AFEngineScenario @(
        (New-AFEngineRow 'fixture-sys'  'fixture system item'   $true  $true  '已写入' -NeedsReboot),
        (New-AFEngineRow 'fixture-sys2' 'fixture system item 2' $false $false '失败：fixture op：拒绝访问。' -NeedsReboot)
      ) $fixtureBackup $null @() $null
    Invoke-AFApplyClick 'S6' 'local' @('fixture-sys', 'fixture-sys2', 'fixture-cache') $true
    $failIdx = Assert-AFFinalizationAfterBatch '[S6] exit-2 partial batch' 2 'fixture cache cleanup exploded'
    Assert-True ((Get-AFLogCount '备份已保存：') -eq 1 -and (Get-AFLogIndex "备份已保存：$fixtureBackup") -ge 0 -and
      (Get-AFLogIndex "备份已保存：$fixtureBackup") -lt $failIdx) `
      '[S6] exit-2 partial batch did not log its backup exactly once before finalization failed'
    Assert-True (((@($script:AFReply.Results | Where-Object { $_.Reboot -eq $true }) | ForEach-Object { "$($_.Id)" }) -join ',') -ceq 'fixture-sys') `
      '[S6] exit-2 partial fixture lost its shape (expected exactly the successful changed row to need a reboot)'
    Assert-AFRouting 'S6' @('fixture-sys', 'fixture-sys2') @('fixture-cache')
    Assert-AFEngineChildSaw 'S6' @('fixture-sys', 'fixture-sys2')

    # S7：exit 2 且没有任何实际改动——一项已达标（引擎改判为跳过），电源计划项在写备份前就失败，
    # 所以也没有备份；只勾系统项，失败发生在界面刷新。「有改动 / 有备份才算已返回」在这里会红。
    # 勾了电源项，处理器先弹「电源计划风险确认」：其余场景都不走这个分支，按电源勾选分流的置位只有这里会红。
    Set-AFEngineScenario @(
        (New-AFEngineRow 'fixture-sys'    'fixture system item'     $true  $false '当前已是目标状态，无需切换'),
        (New-AFEngineRow 'power-ultimate' 'fixture power plan item' $false $false '失败：无法确定当前活动电源计划' -NeedsReboot)
      ) $null $null @() $null
    Invoke-AFApplyClick 'S7' 'tail' @('fixture-sys', 'power-ultimate') $true
    $failIdx = Assert-AFFinalizationAfterBatch '[S7] exit-2 no-change batch' 2 'fixture tail refresh exploded'
    Assert-True ($script:AFDialogs[0].En -ceq 'POWER PLAN RISK' -and $script:AFDialogs[0].Message.Contains('· fixture power plan item')) `
      '[S7] exit-2 no-change batch with a power item did not go through the power-plan risk confirmation first'
    $summaryIdx = Get-AFLogIndex '执行完成：共 2 项 — 1 成功、1 失败、0 跳过'
    Assert-True ($summaryIdx -ge 0 -and $summaryIdx -lt $failIdx -and
      (Get-AFLogIndex '[失败] fixture power plan item — 失败：无法确定当前活动电源计划') -ge 0) `
      '[S7] exit-2 no-change batch did not surface its mixed engine results before the tail failure'
    Assert-True ((Get-AFLogIndex '备份已保存：') -lt 0 -and
      @($script:AFReply.Results | Where-Object { $_.Changed }).Count -eq 0 -and
      @($script:AFReply.Results | Where-Object { $_.Reboot }).Count -eq 0) `
      '[S7] exit-2 no-change fixture invented a backup line, a changed row or a reboot row'
    Assert-AFRouting 'S7' @('fixture-sys', 'power-ultimate') @()
    Assert-AFEngineChildSaw 'S7' @('fixture-sys', 'power-ultimate')

    # S8：exit 3，**真实 Invoke-Apply**（攻击复核 B5/B6）——第一项写入并记账；第二项第一个子操作已写入，
    # 第二个子操作写 prepared 备份时落盘失败（系统已被部分改动：Ok=false、Changed=true）；第三项必须不再执行。
    # 引擎交回抢救出的 .pending.json 与「已生效但备份可能没记全」的项名，两项都必须在「备份写入失败」弹窗里
    # 逐项列出——用户只能凭它手动回退。随后界面刷新炸掉，仍必须走收尾失败通道。
    # 这一轮用户在方案下拉框里选中了内置方案（其余场景都没有方案），按方案分流的置位在这里会红。
    Set-AFEngineRealScenario @(
        (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1'))),
        (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2' -PrepareFails))),
        (New-AFRealItem 'fixture-sys3' 'fixture system item 3' @((New-AFRealOp 'op1')))
      ) 'fixture disk full'
    $script:AFPresetIndex = 0
    try { Invoke-AFApplyClick 'S8' 'tail' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') $true }
    finally { $script:AFPresetIndex = -1 }
    $failIdx = Assert-AFFinalizationAfterBatch '[S8] exit-3 backup-failure batch' 3 'fixture tail refresh exploded'
    Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY|BACKUP WRITE FAILED|APPLY FINALIZATION FAILED') `
      "[S8] exit-3 batch did not show the backup-write-failed dialog between the confirmation and the finalization dialog: [$(Get-AFDialogTitles)]"
    # 逐段定位，先引擎后界面：行形状 → 系统写入 → 引擎 UnrecordedNames → 弹窗列表 → 弹窗里的抢救备份。
    # 形状锚点：真实引擎在备份失败处停手，一行成功记账、一行部分写入；系统写入恰好发生在这两项的已记账子操作上。
    $s8Rows = @($script:AFReply.Results)
    Assert-True ((@($s8Rows | ForEach-Object { "$($_.Id)" }) -join ',') -ceq 'fixture-sys,fixture-sys2' -and
      $s8Rows[0].Ok -eq $true -and $s8Rows[0].Changed -eq $true -and $s8Rows[1].Ok -eq $false -and $s8Rows[1].Changed -eq $true -and
      "$($s8Rows[1].Msg)".StartsWith('部分子项写入失败（其余已写入）', [StringComparison]::Ordinal)) `
      ("[S8] the real engine's rows are not 'fixture-sys written and recorded, fixture-sys2 partially written, then stop at the " +
       "backup failure' (expected fixture-sys:Ok=True:Changed=True, fixture-sys2:Ok=False:Changed=True with the partial-write message): " +
       "rows [$(@($s8Rows | ForEach-Object { "$($_.Id):Ok=$($_.Ok):Changed=$($_.Changed)" }) -join ', ')]")
    Assert-True ((@(Get-AFSystemWrites) -join ',') -ceq 'fixture-sys/op1,fixture-sys2/op1') `
      "[S8] system writes were [$(@(Get-AFSystemWrites) -join ',')], expected exactly fixture-sys/op1,fixture-sys2/op1"
    # 引擎侧（复核 B6）：部分写入项（Ok=false、Changed=true）恰恰是回滚记录最不全的那一项，必须在 UnrecordedNames 里。
    $engineLost = @($script:AFReply.UnrecordedNames | ForEach-Object { "$_" })
    Assert-True ((@($engineLost | Sort-Object) -join '|') -ceq 'fixture system item|fixture system item 2') `
      ("[S8] the real engine's UnrecordedNames [$($engineLost -join '|')] do not name every item it changed without a complete " +
       "backup record; expected [fixture system item|fixture system item 2] (fixture system item 2 is the partially written one)")
    # 界面侧：弹窗逐项列出引擎交回的项名（上面已锚定为非空的两项）——用户只能凭它手动回退。
    $lostListed = @(Get-AFDialogBullets $script:AFDialogs[1].Message)
    Assert-True ((@($lostListed | Sort-Object) -join '|') -ceq (@($engineLost | Sort-Object) -join '|')) `
      "[S8] the BACKUP WRITE FAILED dialog listed [$($lostListed -join '|')] but the engine reported UnrecordedNames [$($engineLost -join '|')]"
    Assert-True ($script:AFDialogs[1].Message.Contains('backup-fixture.pending.json')) `
      "[S8] the BACKUP WRITE FAILED dialog did not name the salvaged partial backup (engine Backup: '$($script:AFReply.Backup)')"
    $backupErrorIdx = Get-AFLogIndex '！！严重：备份文件写入失败（fixture disk full）'
    Assert-True ($backupErrorIdx -ge 0 -and $backupErrorIdx -lt $failIdx) '[S8] exit-3 batch lost the backup-failure log line'
    Assert-True ((Get-AFLogCount '备份已保存：') -eq 1 -and (Get-AFLogIndex "备份已保存：$pendingBackup") -ge 0 -and
      (Get-AFLogIndex "备份已保存：$pendingBackup") -lt $failIdx) `
      '[S8] exit-3 batch did not log the salvaged backup exactly once before finalization failed'
    Assert-AFRouting 'S8' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') @()
    Assert-AFEngineChildSaw 'S8' @('fixture-sys', 'fixture-sys2', 'fixture-sys3')

    # S9：exit 3 发生在收尾写 complete 状态时（Results 全 Ok、两项都已生效），外壳又把进程退出码
    # 改写成 1——生产以结果文件为准并标 EngineExitCodeMismatch。随后本地缓存收尾炸掉。
    Set-AFEngineScenario @(
        (New-AFEngineRow 'fixture-sys'  'fixture system item'   $true $true '已写入'),
        (New-AFEngineRow 'fixture-sys2' 'fixture system item 2' $true $true '已写入')
      ) $pendingBackup 'fixture complete-state rename denied' @('fixture system item', 'fixture system item 2') 1
    Invoke-AFApplyClick 'S9' 'local' @('fixture-sys', 'fixture-sys2', 'fixture-cache') $true
    $failIdx = Assert-AFFinalizationAfterBatch '[S9] exit-3 all-ok batch with a rewritten process exit code' 3 'fixture cache cleanup exploded'
    Assert-True ($script:AFReply.EngineExitCodeMismatch -eq $true -and
      (Get-AFLogIndex '管理员引擎退出码(1)与结果文件(3)不一致') -ge 0) `
      '[S9] rewritten process exit code did not go through the production result-file-wins path'
    Assert-True ((Get-AFLogCount '备份已保存：') -eq 1 -and (Get-AFLogIndex "备份已保存：$pendingBackup") -ge 0 -and
      (Get-AFLogIndex "备份已保存：$pendingBackup") -lt $failIdx) `
      '[S9] exit-3 all-ok batch did not log the salvaged backup exactly once before finalization failed'
    Assert-AFRouting 'S9' @('fixture-sys', 'fixture-sys2') @('fixture-cache')

    # S10（攻击复核 A1–A4），**真实 Invoke-Apply**：exit 2 且**没有任何一行 Ok**。唯一的系统项第一个子操作已写入，
    # 第二个子操作的系统写入被拒（Ok=false、Changed=true、「部分子项写入失败（其余已写入）」），备份完整落盘；
    # 随后本地缓存收尾炸掉。系统已被改动，重复点击会叠加执行。S6–S9 每个回复都有 Ok 行且首行都是 Ok，
    # 「至少一行 Ok / 首行 Ok 才算已返回」或传输层「没有 Ok 行就当失败抛出」只有这里会红。
    Set-AFEngineRealScenario @(
        (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2' 'fixture op：拒绝访问。')))
      ) $null
    Invoke-AFApplyClick 'S10' 'local' @('fixture-sys', 'fixture-cache') $true
    $failIdx = Assert-AFFinalizationAfterBatch '[S10] exit-2 zero-ok partial-write batch' 2 'fixture cache cleanup exploded'
    Assert-True (@($script:AFReply.Results).Count -eq 1 -and @($script:AFReply.Results | Where-Object Ok).Count -eq 0 -and
      @($script:AFReply.Results | Where-Object { $_.Changed -eq $true }).Count -eq 1 -and -not $script:AFReply.BackupError -and
      (@(Get-AFSystemWrites) -join ',') -ceq 'fixture-sys/op1') `
      ("[S10] exit-2 zero-ok fixture lost its shape (expected exactly one row: not Ok, Changed; no BackupError; one system write): " +
       "rows [$(@($script:AFReply.Results | ForEach-Object { "$($_.Id):Ok=$($_.Ok):Changed=$($_.Changed)" }) -join ', ')], " +
       "writes [$(@(Get-AFSystemWrites) -join ',')]")
    Assert-True ((Get-AFLogCount '备份已保存：') -eq 1 -and (Get-AFLogIndex "备份已保存：$completeBackup") -ge 0 -and
      (Get-AFLogIndex "备份已保存：$completeBackup") -lt $failIdx) `
      '[S10] exit-2 zero-ok batch did not log its completed backup exactly once before finalization failed'
    Assert-AFRouting 'S10' @('fixture-sys') @('fixture-cache')
    Assert-AFEngineChildSaw 'S10' @('fixture-sys')

    # S11（攻击复核 A7、A8），**真实 Invoke-Apply**：exit 3 且什么都没改成——第一项第一个子操作写 prepared 备份就落盘失败，
    # 引擎停手不做第二项（Results 只有 1 行），交回只含 prepared 记录的 .pending.json，UnrecordedNames 为空。
    # 界面收尾抛的是普通脚本错误（RuntimeException）而不是 IOException：生产里 WPF / 界面代码的失败
    # 几乎都是这类，S1–S10 注入的全是 IOException，按异常类型分流的变异只有这里会红。
    Set-AFEngineRealScenario @(
        (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1' -PrepareFails))),
        (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1')))
      ) 'fixture disk full'
    Invoke-AFApplyClick 'S11' 'tail-script' @('fixture-sys', 'fixture-sys2') $true
    $failIdx = Assert-AFFinalizationAfterBatch '[S11] exit-3 nothing-recorded batch' 3 'fixture tail script error'
    Assert-True (@($script:AFReply.Results).Count -eq 1 -and @($script:AFReply.UnrecordedNames).Count -eq 0 -and
      @($script:AFReply.Results | Where-Object Ok).Count -eq 0 -and "$($script:AFReply.BackupError)" -ceq 'fixture disk full' -and
      @(Get-AFSystemWrites).Count -eq 0) `
      ("[S11] exit-3 nothing-recorded fixture lost its shape (one failed row, BackupError, no unrecorded names, no system write): " +
       "rows $(@($script:AFReply.Results).Count), unrecorded [$(@($script:AFReply.UnrecordedNames) -join '|')], writes [$(@(Get-AFSystemWrites) -join ',')]")
    Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY|BACKUP WRITE FAILED|APPLY FINALIZATION FAILED' -and
      $script:AFDialogs[1].Message.Contains('（无）') -and @(Get-AFDialogBullets $script:AFDialogs[1].Message).Count -eq 0) `
      "[S11] exit-3 nothing-recorded batch did not show the backup-write-failed dialog (listing no item) before finalization: [$(Get-AFDialogTitles)]"
    Assert-True ((Get-AFLogIndex '异常类型：System.Management.Automation.RuntimeException') -gt $failIdx) `
      '[S11] exit-3 nothing-recorded tail failure was not the non-IO script error the fixture intends'
    Assert-AFRouting 'S11' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S11' @('fixture-sys', 'fixture-sys2')

    # S12（反向锚点）：提权批次**没有带回 Data**。真实 Invoke-Apply 在任何系统写入之前做备份目录预检，
    # 失败即抛「备份目录不可写…未做任何修改」；生产分发的 catch 让 Data 留空、Error 写原文、退出码记 3。
    # 真实传输层据此抛出引擎原文，处理器必须走前置失败通道：原文透传、不置「已返回」、不警告「系统批次
    # 可能已执行」，也不能再去清缓存（系统批次先行，失败即停）。S2 只用手写 throw 证明这一侧。
    # 三段各自定位：引擎分发丢掉 Error、传输层把无 Data 的回包补成空批次交给处理器（于是置位、弹「请不要
    # 重复点击」）、传输层把原文换成笼统的「执行失败（退出码 N）」。
    $noDataError = '备份目录不可写（C:\ProgramData\DeltaForceBooster\backup），已中止执行，未做任何修改。原因：fixture access denied'
    Set-AFEngineThrowScenario $noDataError
    Invoke-AFApplyClick 'S12' 'none' @('fixture-sys', 'fixture-cache') $true
    Assert-True ($script:AFApplyCalls -eq 1) '[S12] no-data fixture never reached the elevated engine call'
    $published = Assert-AFEnginePublished '[S12] no-data batch'
    $publishedError = "$($published.Error)"
    Assert-True ($null -eq $published.Data -and [int]$published.ExitCode -eq 3 -and $publishedError -ceq $noDataError) `
      ("[S12] the real engine dispatch did not publish the Invoke-Apply failure as exit 3 without Data carrying the original error text " +
       "(published exit $([int]$published.ExitCode), Data $(if ($null -ne $published.Data) { 'present' } else { 'absent' }), " +
       "error text $(if ($publishedError -ceq $noDataError) { 'intact' } elseif ($publishedError) { 'changed' } else { 'empty' }))")
    Assert-True ($null -eq $script:AFReply -and $null -ne $script:AFRealEngineError) `
      '[S12] the real transport turned a no-Data exit-3 engine result into a batch reply instead of throwing'
    Assert-True ("$($script:AFRealEngineError)" -ceq $noDataError) `
      "[S12] the real transport replaced the engine's own error text with: $($script:AFRealEngineError)"
    $d = Get-AFLastDialog
    Assert-True ($d.Chip -ceq '执行未完成' -and $d.En -ceq 'APPLY NOT COMPLETED' -and $d.Message -ceq $noDataError) `
      ("[S12] an admin batch that returned no Data was not reported as a preflight failure carrying the engine's own error " +
       "(dialog: $($d.En); log channel: $(Get-AFLogChannel))")
    Assert-True ((Get-AFLogIndex "执行失败：$noDataError") -ge 0 -and (Get-AFLogIndex '系统批次可能已执行') -lt 0 -and
      (Get-AFLogIndex '备份已保存：') -lt 0) `
      '[S12] no-data batch lost the raw engine error in the log, warned about a batch that never ran, or invented a backup'
    Assert-AFRouting 'S12' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S12' @('fixture-sys')
  } finally {
    $script:AFScenario = $null
    if (Test-Path -LiteralPath $afRoot) { Remove-Item -LiteralPath $afRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }
} $failureHelpers[0].Extent.Text $applyClickHandlers[0].Arguments[0].Extent.Text $afReal

'GUI apply finalization tests passed.'
