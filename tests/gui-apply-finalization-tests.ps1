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
  Assert-True (-not $post.BackupError -and @($post.UnrecordedNames).Count -eq 0) 'a batch whose backup stayed intact was given a backup error or unrecorded names'
  Assert-True (-not $preflight.BackupError -and @($preflight.UnrecordedNames).Count -eq 0) 'preflight failure invented a backup error or unrecorded names'
  # 备份写盘失败的批次（独立复核遗留 2）：收尾在正常路径的告警之前就抛了，catch 只能凭这两样补告警
  $failedBackup = Get-ApplyFailureContext $postError $true ([pscustomobject]@{
    Backup = $backup; BackupError = 'fixture disk full'; UnrecordedNames = @('item A', '', 'item B') })
  Assert-True ($failedBackup.BackupError -ceq 'fixture disk full' -and (@($failedBackup.UnrecordedNames) -join '|') -ceq 'item A|item B' -and
    $failedBackup.BackupPath -ceq $backup -and $failedBackup.BackupFailedAfterAllItems -eq $false) `
    "post-admin failure lost the batch's backup error or unrecorded names (error '$($failedBackup.BackupError)', names [$(@($failedBackup.UnrecordedNames) -join '|')])"
  # 备份在收尾时才失败（独立复核遗留 4）：每一项都已执行，catch 补告警时同样不能说「已中止」
  $failedAtEnd = Get-ApplyFailureContext $postError $true ([pscustomobject]@{
    Backup = $backup; BackupError = 'fixture rename denied'; UnrecordedNames = @('item A'); BackupFailedAfterAllItems = $true })
  Assert-True ($failedAtEnd.BackupFailedAfterAllItems -eq $true -and $post.BackupFailedAfterAllItems -eq $false -and
    $preflight.BackupFailedAfterAllItems -eq $false) `
    'post-admin failure did not carry whether the backup failed only after every item ran'
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
# 电源设置在注册表里的两个根（生产 Invoke-ApplyOp 拼隐藏项 Attributes 路径、Get-PowerSettingAc 读方案值都用它们）：
# 从引擎顶层赋值语句原样取出，不在替身里手抄。
$enginePowerRoots = @(foreach ($rootVar in '$script:PsRoot', '$script:PuRoot') {
  $assign = @($engineAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq $rootVar })
  Assert-True ($assign.Count -eq 1) "engine top-level assignment of $rootVar missing or duplicated"
  $assign[0].Extent.Text
})
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
  # 备份写入失败的告警（日志两句 + BACKUP WRITE FAILED 弹窗）：正常收尾与收尾失败的 catch 共用的生产原文。
  BackupAlarm = (Get-AFFunctionText $ast 'Show-ApplyBackupFailureAlarm')
  # 真 Update-ApplyProgress（复核 R3 msg）：处理器对引擎交回的每一行调它落「[失败] 项名 — 文案」实时日志。
  # 默认仍是空桩（S0–S13 的日志断言按此编写），S14–S31 打开它，核对界面没有改写引擎的结果文案。
  Progress = (Get-AFRenamedFunctionText $ast 'Update-ApplyProgress' 'Invoke-AFRealUpdateApplyProgress')
  EngineDispatch = ($engineDispatchFlag[0].Extent.Text + "`r`n" + $engineDispatchBlock[0].Extent.Text)
  # 复攻 R3 msg：子操作也跑生产原文 Invoke-ApplyOp（改名后由记录尝试的薄壳原样转调）。手写替身每个子操作恰好
  # 写一条备份、从不返回「无需修改」附注，于是「尝试数」「备份条目数」「已完成数」永远相等，
  # 拿 $journal.CurrentOpIndex 顶替尝试计数照样全绿。它依赖的比较、备份字段表和电源读取也用生产原文，
  # 只有碰真注册表 / powercfg 的最底层原语在子进程里换成内存假注册表。
  EngineChild = ((@(
    (Get-AFFunctionText $engineAst 'Write-BytesAtomic'),
    (Get-AFFunctionText $engineAst 'Get-ApplyExitCode'),
    (Get-AFFunctionText $engineAst 'Write-IpcResult'),
    (Get-AFFunctionText $engineAst 'Set-ApplyResultChangeState'),
    (Get-AFRenamedFunctionText $engineAst 'Invoke-Apply' 'Invoke-AFRealApply'),
    (Get-AFRenamedFunctionText $engineAst 'Invoke-ApplyOp' 'Invoke-AFRealApplyOp'),
    (Get-AFFunctionText $engineAst 'Test-ValueEqual'),
    (Get-AFFunctionText $engineAst 'Test-FixedTimeEqual'),
    (Get-AFFunctionText $engineAst 'Get-BackupOpFields'),
    (Get-AFFunctionText $engineAst 'Test-PowerSettingHidden'),
    (Get-AFFunctionText $engineAst 'Get-PowerSettingAc'),
    (Get-AFFunctionText $engineAst 'Get-PowerSettingAcExplicit')
  ) + @($enginePowerRoots)) -join "`r`n`r`n")
}

# 处理器里的 [Windows.Threading.DispatcherPriority]::Render 需要这个程序集；只加载，不建窗口。
Add-Type -AssemblyName WindowsBase

& {
  param([string]$FunctionText, [string]$HandlerText, [hashtable]$Real)
  Invoke-Expression $FunctionText
  Invoke-Expression $Real.BackupAlarm
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
  $script:AFRealProgress = $false; $script:AFProgressCalls = 0; $script:AFLastRealProgress = $false; $script:AFLastProgText = $null
  $fixtureBackup ='C:\ProgramData\DeltaForceBooster\backup\fixture-backup.json'

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
    # 高风险项只进 RiskyPanel，只有 S37 勾它（确认 / 取消高风险确认之后复采勾选不能误判「勾选已变化」）；
    # 其余场景里未勾选的高风险行仍在，任何忽略 IsChecked 的读取都会把它带进确认框（复核 B8）。Reboot 同真实目录的标注。
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
  Invoke-Expression $Real.Progress
  # 处理器按名字调 Update-ApplyProgress：-RealProgress 的场景把调用原样转给生产原文，并计数（锚点：
  # 每一行都真的经过了它，界面日志断言不是空转）。
  function Update-ApplyProgress($Progress) {
    if ($script:AFRealProgress) { $script:AFProgressCalls++; Invoke-AFRealUpdateApplyProgress $Progress }
  }
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
  # 确认框消息泵期间改勾选：按 Tag 找行（夹具的勾选表与真实界面一样含未勾选行；高风险项的行在 RiskyPanel）。
  function Set-AFRowChecked([string]$Tag, [bool]$On) {
    $rows = @(@($ui.ItemPanel.Children) + @($ui.RiskyPanel.Children) | Where-Object { "$($_.Child.Children[0].Tag)" -ceq $Tag })
    Assert-True ($rows.Count -eq 1) "fixture has no checklist row for $Tag"
    $rows[0].Child.Children[0].IsChecked = $On
  }
  function Invoke-AFApplyClick([string]$Scenario, [string]$FailAt, [string[]]$Tags, [bool]$WithBackup, [switch]$ClickAgainDuringBatch,
                               [string]$Decline, [scriptblock]$DuringConfirm, [string]$NoWorkBecause, [switch]$TuningActive,
                               [switch]$RebootNow, [switch]$RealProgress, [string[]]$ConfirmTags) {
    $script:AFLog = @(); $script:AFDialogs = @(); $script:AFApplyCalls = 0
    $script:AFRealProgress = [bool]$RealProgress; $script:AFProgressCalls = 0; $script:AFLastRealProgress = [bool]$RealProgress
    $script:AFLastProgText = $null
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
    finally {
      $script:AFDecline = $null; $script:AFOnConfirm = $null; $script:AFTuningActive = $false; $script:AFRealProgress = $false
      # 进度区最后停在的文字（处理器收尾写的完成度结论）：$ui 是本函数的局部表，返回后就拿不到了。
      $script:AFLastProgText = "$($ui.ProgText.Text)"
    }
    # 唯一的同意框必须逐项列出本次勾选（攻击复核 B2/B8）：列表空着、或把未勾选的行也列进去，
    # 用户是在没看到/看错清单的情况下同意写系统。-ConfirmTags：取消高风险确认后，同意框只列其余勾选项（S37）。
    $confirmDialogs = @($script:AFDialogs | Where-Object { $_.Chip -ceq '确认执行' })
    if ($confirmDialogs.Count -gt 0) {
      $listedTags = $(if ($PSBoundParameters.ContainsKey('ConfirmTags')) { @($ConfirmTags) } else { @($Tags) })
      $expectedNames = @($catalog | Where-Object { $listedTags -contains $_.Id } | ForEach-Object { "$($_.Name)" })
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
    # 本该执行的场景（确认期间没人改勾选）不许以「勾选已变化」中止：先于下面的「没到达引擎」判定，消息指向根因。
    Assert-True (@($script:AFDialogs | Where-Object { $_.En -ceq 'SELECTION CHANGED' }).Count -eq 0) `
      ("[$Scenario] Apply aborted with SELECTION CHANGED although the user did not change the selection during the confirmation " +
       "(dialogs [$(Get-AFDialogTitles)]; log: $($script:AFLog -join ' / '))")
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
  # -AllowRisky：用户刚通过了高风险二次确认（S37），引擎必须带 AllowRisky 收到请求。
  function Assert-AFRouting([string]$Scenario, [string[]]$ExpectedElevated, [string[]]$ExpectedLocal, [switch]$AllowRisky) {
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
      Assert-True ($req.AllowRisky -eq [bool]$AllowRisky) $(if ($AllowRisky) {
        "[$Scenario] the user confirmed the HIGH RISK ITEMS dialog but the elevated engine did not get AllowRisky"
      } else { "[$Scenario] elevated engine got AllowRisky without a high-risk confirmation" })
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

  # S37：勾了 RiskyPanel 里的高风险项。处理器先弹「高风险项确认」：确认后 $ids 并入高风险项，取消时 $riskyIds 清空、
  # 高风险行仍勾着。置忙后复采勾选曾直接拿这两个被改写过的清单去比两张勾选表，于是确认必定以「勾选已变化」中止
  # （用户什么都没改，却永远执行不了高风险项），取消也一样中止（其余勾选项同样执行不了）。复采要对照的是点击那一刻两张表各自的样子。
  # 锚点：HIGH RISK ITEMS 弹窗真的出现、列的正是勾上的那一个高风险项——处理器确实把 RiskyPanel 的勾选读成了已勾。
  function Assert-AFRiskyDialog([string]$Scenario) {
    $risky = @($script:AFDialogs | Where-Object { $_.Chip -ceq '高风险项确认' })
    Assert-True ($risky.Count -eq 1 -and $risky[0].En -ceq 'HIGH RISK ITEMS' -and
      (@(Get-AFDialogBullets $risky[0].Message) -join '|') -ceq 'fixture high-risk item' -and $risky[0].Message.Contains('fixture warning')) `
      "[$Scenario] fixture problem: the checked high-risk row did not produce exactly one HIGH RISK ITEMS dialog listing only it: [$(Get-AFDialogTitles)]"
  }
  Invoke-AFApplyClick 'S37-confirm' 'none' @('fixture-sys', 'fixture-risky', 'fixture-cache') $true
  Assert-AFRiskyDialog 'S37-confirm'
  Assert-True ((Get-AFDialogTitles) -ceq 'HIGH RISK ITEMS|CONFIRM APPLY' -and (Get-AFLogIndex '确认过程中勾选发生了变化') -lt 0) `
    ("[S37-confirm] the user confirmed the high-risk item and changed nothing, but Apply aborted or showed another notice: [$(Get-AFDialogTitles)]; " +
     "log: $($script:AFLog -join ' / ')")
  Assert-True ((Get-AFLogIndex '执行完成：共 3 项 — 3 成功') -ge 0) '[S37-confirm] the confirmed high-risk batch did not complete all three items'
  Assert-AFRouting 'S37-confirm' @('fixture-sys', 'fixture-risky') @('fixture-cache') -AllowRisky
  Invoke-AFApplyClick 'S37-risky-only' 'none' @('fixture-risky') $true
  Assert-AFRiskyDialog 'S37-risky-only'
  Assert-True ((Get-AFDialogTitles) -ceq 'HIGH RISK ITEMS|CONFIRM APPLY' -and (Get-AFLogIndex '执行完成：共 1 项 — 1 成功') -ge 0) `
    "[S37-risky-only] a confirmed Apply of only a high-risk item did not run to completion: [$(Get-AFDialogTitles)]; log: $($script:AFLog -join ' / ')"
  Assert-AFRouting 'S37-risky-only' @('fixture-risky') @() -AllowRisky
  Invoke-AFApplyClick 'S37-decline' 'none' @('fixture-sys', 'fixture-risky', 'fixture-cache') $true -Decline '高风险项确认' `
    -ConfirmTags @('fixture-sys', 'fixture-cache')
  Assert-AFRiskyDialog 'S37-decline'
  Assert-True ((Get-AFDialogTitles) -ceq 'HIGH RISK ITEMS|CONFIRM APPLY' -and (Get-AFLogIndex '已取消 1 个高风险项，本次不执行它们。') -ge 0 -and
    (Get-AFLogIndex '执行完成：共 2 项 — 2 成功') -ge 0) `
    ("[S37-decline] after the user declined only the high-risk item, the remaining selection did not run (or the high-risk item ran): " +
     "[$(Get-AFDialogTitles)]; log: $($script:AFLog -join ' / ')")
  Assert-AFRouting 'S37-decline' @('fixture-sys') @('fixture-cache')
  # 对照：复采仍然看两张表。确认期间取消已确认的高风险项、或勾上一个点击时没勾的高风险项，都必须中止——
  # 只比 ItemPanel、或干脆不再复采 RiskyPanel 的「修法」在这两条上红。
  Invoke-AFApplyClick 'S37-uncheck-risky' 'none' @('fixture-sys', 'fixture-risky') $true `
    -NoWorkBecause 'the confirmed high-risk item was unchecked during the Apply confirmation' `
    -DuringConfirm { Set-AFRowChecked 'fixture-risky' $false }
  Assert-AFRiskyDialog 'S37-uncheck-risky'
  Assert-True ((Get-AFDialogTitles) -ceq 'HIGH RISK ITEMS|CONFIRM APPLY|SELECTION CHANGED') `
    "[S37-uncheck-risky] unchecking the confirmed high-risk item during the confirmation did not abort with the SELECTION CHANGED notice: [$(Get-AFDialogTitles)]"
  Invoke-AFApplyClick 'S37-check-risky' 'none' @('fixture-sys') $true `
    -NoWorkBecause 'a high-risk item was checked during the Apply confirmation' `
    -DuringConfirm { Set-AFRowChecked 'fixture-risky' $true }
  Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY|SELECTION CHANGED') `
    "[S37-check-risky] checking a high-risk item during the confirmation did not abort with the SELECTION CHANGED notice: [$(Get-AFDialogTitles)]"

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
  $afOpAttempts = Join-Path $afRoot 'scripts\af-op-attempts.txt'
  $afOpsShapes = Join-Path $afRoot 'scripts\af-ops-shapes.txt'
  $afBackupFailureHits = Join-Path $afRoot 'scripts\af-backup-failures.txt'
  $afCliOutput = Join-Path $afRoot 'scripts\af-cli-output.txt'
  $afPowerProbes = Join-Path $afRoot 'scripts\af-power-probes.txt'
  $afBackupWrites = Join-Path $afRoot 'scripts\af-backup-writes.txt'
  $afBackupDir = Join-Path $afRoot 'scripts\backup'
  $pendingBackup = Join-Path $afBackupDir 'backup-fixture.pending.json'
  $completeBackup = Join-Path $afBackupDir 'backup-fixture.json'
  # S36：夹具先占住改名目标 backup-fixture.json 时写进去的内容（复攻五 V56）。
  $afRenameBlocker = 'af-rename-blocker'
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
    # 真实 Invoke-Apply（S8/S10/S11/S14–S31）连同真实 Invoke-ApplyOp 只桩叶子：注册表与 powercfg 原语换成内存假注册表
    # （Set-RegValue / Show-PowerSetting / Set-PowerSettingAc 每次系统写入记一笔，WriteError 在这一层被拒），
    # 备份落盘（Write-BackupDocumentAtomic 真写到临时备份目录；文档里一出现场景标记的那个子操作的 prepared 记录，
    # 这次及之后的落盘都失败——按语义触发而不是按「第几次写入」，引擎多一次或少一次原子写不会挪动故障点；
    # 每次按注入抛出都记一笔命中，父进程据此确认注入真的打在了预定的子操作上）；
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
      '# 场景里的子操作：reg 子操作写 HKLM:\SOFTWARE\AFFixture\<项Id> 下名为子操作名的 DWord；pcfg 子操作的 Sub 是项 Id、Setting 是子操作名。',
      '# 记账键统一是「项Id/子操作名」，与尝试记录、系统写入记录、注入点同一套名字。',
      '$afSpecOps = @(if ($spec.Real) { foreach ($afItem in @($spec.Real.Items)) { foreach ($afOp in @($afItem.Ops)) { [pscustomobject]@{ ItemId = "$($afItem.Id)"; Op = $afOp } } } })',
      '$afFailPrepared = @($afSpecOps | Where-Object { $_.Op.PrepareFails } | ForEach-Object { "$($_.ItemId)/$($_.Op.Name)" })',
      '$afFailApplied = @($afSpecOps | Where-Object { $_.Op.AppliedFails } | ForEach-Object { "$($_.ItemId)/$($_.Op.Name)" })',
      '$afDenied = @{}; foreach ($afSpecOp in $afSpecOps) { if ($afSpecOp.Op.WriteError) { $afDenied["$($afSpecOp.ItemId)/$($afSpecOp.Op.Name)"] = "$($afSpecOp.Op.WriteError)" } }',
      '# -OptionalUnsupportedPowerSetting 的子操作不在「本机支持的电源设置」里：生产 Invoke-ApplyOp 对 Optional 的它返回「跳过（本机 CPU 无此电源项）：…」附注。',
      '$afPowerSettings = @($afSpecOps | Where-Object { "$($_.Op.Kind)" -ceq ''pcfg'' -and -not $_.Op.Unsupported } | ForEach-Object { "$($_.ItemId)/$($_.Op.Name)" })',
      '# 内存假注册表（"路径|值名" -> Kind/Value）。-AtTarget 的子操作预置为目标值：生产 Invoke-ApplyOp 读到已达标，',
      '# 不写备份、不写系统，直接返回「无需修改：… 已是目标状态」；-HiddenPowerSetting 预置 Attributes=1（隐藏）。',
      '$script:AFReg = @{}',
      'foreach ($afSpecOp in $afSpecOps) {',
      '  if ("$($afSpecOp.Op.Kind)" -ceq ''pcfg'') {',
      '    if ($afSpecOp.Op.Hidden) { $script:AFReg["$script:PsRoot\$($afSpecOp.ItemId)\$($afSpecOp.Op.Name)|Attributes"] = @{ Kind = ''DWord''; Value = 1 } }',
      '    if ($afSpecOp.Op.AtTarget) { $script:AFReg["$script:PuRoot\af-fixture-scheme\$($afSpecOp.ItemId)\$($afSpecOp.Op.Name)|ACSettingIndex"] = @{ Kind = ''DWord''; Value = 1 } }',
      '  } elseif ($afSpecOp.Op.AtTarget) {',
      '    $script:AFReg["HKLM:\SOFTWARE\AFFixture\$($afSpecOp.ItemId)|$($afSpecOp.Op.Name)"] = @{ Kind = ''DWord''; Value = 1 }',
      '  }',
      '}',
      'function Add-AFRecord([string]$File, [string]$Line) { [IO.File]::AppendAllText((Join-Path $PSScriptRoot $File), "$Line`r`n") }',
      'function Get-AFRegKey([string]$Path, [string]$Name) { "$($Path.Substring($Path.LastIndexOf([char]92) + 1))/$Name" }',
      '# 生产的命令行渲染（入口分发里的 elseif ($Apply) 分支；命令行用户与照 SKILL.md 调用的 agent 读的就是它）用 Write-Output',
      '# 逐行打印结果。子进程收到的请求没有 -Json，这一段本来就在这里真跑，只是真实传输层读走 stdout 后不交给调用方。',
      '# 这层薄壳把每一行原样记一笔，再交给真正的 Write-Output；第一笔是哨兵，证明记录在生产分发之前已就位。',
      '# 一次 Write-Output 记一行：内容按 JSON 字符串记下（行内自带的换行被转义——系统 IO 错误的原文以 CRLF 结尾，见 S36），父进程读回时原样还原。',
      'function Write-Output { param([Parameter(Position = 0, ValueFromPipeline = $true)]$InputObject) process { Add-AFRecord ''af-cli-output.txt'' (ConvertTo-Json -InputObject "$InputObject" -Compress); Microsoft.PowerShell.Utility\Write-Output $InputObject } }',
      '$null = Write-Output ''af-cli-recorder-armed''',
      'function Enter-EngineMutex { ''af-fixture-mutex'' }',
      'function Exit-EngineMutex($Mutex) { }',
      'function Find-GamePath { $null }',
      'function Get-ActiveScheme { [pscustomobject]@{ Guid = ''af-fixture-scheme''; Name = ''fixture scheme'' } }',
      'function Test-ToolPowerScheme($Scheme) { $false }',
      'function Test-Admin { $true }',
      '# 最底层系统原语：真实实现直接开 HKLM 注册表键、调 powercfg。',
      'function Get-RegValueKind([string]$Path, [string]$Name) { $v = $script:AFReg["$Path|$Name"]; if ($v) { $v.Kind } else { $null } }',
      'function Get-RegValue([string]$Path, [string]$Name) { $v = $script:AFReg["$Path|$Name"]; if ($v) { $v.Value } else { $null } }',
      'function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Kind) {',
      '  $key = Get-AFRegKey $Path $Name',
      '  if ($afDenied.ContainsKey($key)) { throw $afDenied[$key] }',
      '  Add-AFRecord ''af-system-writes.txt'' $key',
      '  $script:AFReg["$Path|$Name"] = @{ Kind = "$Kind"; Value = $Value }',
      '}',
      '# 每次询问「本机是否支持该电源设置」记一笔「项Id/子操作名=True|False」：父进程据此锚定「不支持」分支真的被走到。',
      'function Test-PowerSetting([string]$Sub, [string]$Setting) { $afSupported = $afPowerSettings -ccontains "$Sub/$Setting"; Add-AFRecord ''af-power-probes.txt'' "$Sub/$Setting=$afSupported"; $afSupported }',
      'function Show-PowerSetting([string]$Sub, [string]$Setting) {',
      '  $old = Get-RegValue "$script:PsRoot\$Sub\$Setting" ''Attributes''',
      '  Add-AFRecord ''af-system-writes.txt'' "$Sub/$Setting(unhide)"',
      '  $script:AFReg["$script:PsRoot\$Sub\$Setting|Attributes"] = @{ Kind = ''DWord''; Value = ([int]$old -band (-bnot 1)) }',
      '  $old',
      '}',
      'function Set-PowerSettingAc([string]$Sub, [string]$Setting, [int]$Value, [string]$SchemeGuid) {',
      '  if ($afDenied.ContainsKey("$Sub/$Setting")) { throw $afDenied["$Sub/$Setting"] }',
      '  Add-AFRecord ''af-system-writes.txt'' "$Sub/$Setting"',
      '  $script:AFReg["$script:PuRoot\af-fixture-scheme\$Sub\$Setting|ACSettingIndex"] = @{ Kind = ''DWord''; Value = $Value }',
      '}',
      'function Initialize-ProtectedStore { [void][IO.Directory]::CreateDirectory($script:BackupDir) }',
      'function New-BackupDocument([DateTime]$When, [string]$ApplyId) {',
      '  [pscustomobject]@{ BackupId = ''fixture''; ApplyId = $ApplyId; State = ''pending''; Items = @(); Ops = @() }',
      '}',
      'function Assert-BackupOperation($Op, [int]$SchemaVersion, [string]$AllowedLocalAppData) { }',
      'function New-BackupItemRecord($Item) { [pscustomobject]@{ ItemId = "$($Item.Id)"; OpIds = @() } }',
      '# 上一次成功落盘时文档里撤销记录的摘要：收尾那一次写入不新增、不改动任何撤销记录，摘要与它相同。',
      '$script:AFLastOpsDigest = $null',
      'function Write-BackupDocumentAtomic([string]$Path, $Document) {',
      '  $afDigest = ConvertTo-Json -InputObject @($Document.Ops) -Depth 6 -Compress',
      '  # -CompleteFails（复攻四 N04/N25）：只有收尾那一次写失败（此前的 prepared / applied 都已真落盘）。按语义认这一次——',
      '  # 它是首次写入之后、不新增也不改动任何撤销记录的写入——而不是看文档的 State：生产收尾漏设 State 时注入照样打在',
      '  # 收尾写入上，不会因为注入落空而在 S29 冒充「退出码 0」（复攻五 V03；漏设 State 本身由 S17 / S21 核对改名后的文件）。',
      '  # 同样先抛、不写文件，盘上留下的仍是最后一次成功写入的 pending 文档。命中记一笔「complete:State=<这次要写的 State>」。',
      '  if ($spec.Real -and $spec.Real.CompleteFails -and $null -ne $script:AFLastOpsDigest -and $afDigest -ceq $script:AFLastOpsDigest) {',
      '    Add-AFRecord ''af-backup-failures.txt'' "complete:State=$($Document.State)"',
      '    throw "$($spec.Real.BackupWriteError)"',
      '  }',
      '  foreach ($afEntry in @($Document.Ops)) {',
      '    $afKey = $(if ("$($afEntry.Kind)" -ceq ''pcfg'') { "$($afEntry.Sub)/$($afEntry.Setting)" } else { Get-AFRegKey "$($afEntry.Path)" "$($afEntry.Name)" })',
      '    if ($afFailPrepared -ccontains $afKey -or ($afFailApplied -ccontains $afKey -and "$($afEntry.Status)" -ceq ''applied'')) {',
      '      Add-AFRecord ''af-backup-failures.txt'' $afKey',
      '      throw "$($spec.Real.BackupWriteError)"',
      '    }',
      '  }',
      '  [IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 6))',
      '  $script:AFLastOpsDigest = $afDigest',
      '  # 每次成功落盘记一笔「文件名|State|记录条数」：父进程据此锚定备份文件确实建过、收尾写入确实先于改名落盘。',
      '  Add-AFRecord ''af-backup-writes.txt'' "$([IO.Path]::GetFileName($Path))|$($Document.State)|$(@($Document.Ops).Count)"',
      '}',
      '# 生产 Invoke-Apply 按名字调 Invoke-ApplyOp：这层薄壳只记一笔尝试，再把同样四个参数原样交给生产原文。',
      'function Invoke-ApplyOp($Op, $ItemId, [scriptblock]$PrepareBackup, [scriptblock]$MarkApplied) {',
      '  Add-AFRecord ''af-op-attempts.txt'' "$ItemId/$(if ("$($Op.Kind)" -ceq ''pcfg'') { $Op.Setting } else { $Op.Name })"',
      '  Invoke-AFRealApplyOp $Op $ItemId $PrepareBackup $MarkApplied',
      '}',
      '# 目录与生产 Get-OptItems 同形：每项、每个子操作都是 hashtable。-ScalarOps 的项照生产 gpu-pstate-lock 的写法',
      '# Ops = $(if (...) { @(@{...}) }) 构造：子表达式把单元素数组展开成一个裸 Hashtable（.Count 是键数，不是 1）。',
      '# 子操作的 Label 同生产：reg 子操作有的带人话 Label（与值名 Name 不同，如 PowerThrottlingOff / 关闭电源节流），有的不带；',
      '# pcfg 子操作总带 Label（场景没给时退回子操作名）。Optional 只在场景要求时出现，同生产 power-tuning 的两个大小核调度项。',
      'function Get-OptItems([string]$Exe) {',
      '  @(foreach ($afItem in @($spec.Real.Items)) {',
      '    $afOps = @(foreach ($afOp in @($afItem.Ops)) {',
      '      if ("$($afOp.Kind)" -ceq ''pcfg'') {',
      '        $afH = @{ Kind = ''pcfg''; Sub = "$($afItem.Id)"; Setting = "$($afOp.Name)"; Value = 1; Label = $(if ($afOp.Label) { "$($afOp.Label)" } else { "$($afOp.Name)" }) }',
      '        if ($afOp.Optional) { $afH.Optional = $true }',
      '        $afH',
      '      } else {',
      '        $afH = @{ Kind = ''reg''; Path = "HKLM:\SOFTWARE\AFFixture\$($afItem.Id)"; Name = "$($afOp.Name)"; Value = 1; Kind2 = ''DWord'' }',
      '        if ($afOp.Label) { $afH.Label = "$($afOp.Label)" }',
      '        $afH',
      '      }',
      '    })',
      '    $afRow = @{ Id = "$($afItem.Id)"; Name = "$($afItem.Name)"; Kind = ''multi''; Tier = ''safe''; Admin = $true; Default = $true',
      '                Reboot = [bool]$afItem.Reboot; Ops = $afOps }',
      '    if ($afItem.ScalarOps) { $afRow.Ops = $(if ($afOps.Count -gt 0) { @($afOps) }) }',
      '    # -NoOps（复攻五 V09/V10/V52/V53）：照生产 fso-off / gpu-pref / game-priority 没有游戏路径时的写法，Ops = $null；',
      '    # -RequiresGame 同生产这三项的标注（生产据此选「未找到游戏路径」还是「本机不满足此项前提」）。',
      '    if ($afItem.NoOps) { $afRow.Ops = $null }',
      '    if ($afItem.RequiresGame) { $afRow.RequiresGame = $true }',
      '    Add-AFRecord ''af-ops-shapes.txt'' "$($afItem.Id)=$(if ($null -eq $afRow.Ops) { ''null'' } else { $afRow.Ops.GetType().Name })"',
      '    $afRow',
      '  })',
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
      foreach ($leftover in @($afChildSeen, $afEngineResult, $afSystemWrites, $afOpAttempts, $afOpsShapes, $afBackupFailureHits, $afCliOutput, $afPowerProbes,
                              $afBackupWrites)) {
        if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force }
      }
      if (Test-Path -LiteralPath $afBackupDir) { Remove-Item -LiteralPath $afBackupDir -Recurse -Force }
      [IO.File]::WriteAllText((Join-Path $afRoot 'scripts\af-scenario.json'),
        ($script:AFScenario | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    }
    # -AfterAllItems：手写 Data 的 BackupFailedAfterAllItems（同真实引擎：备份在收尾时才失败、每一项都已执行，S9）。
    function Set-AFEngineScenario([object[]]$Rows, $Backup, $BackupError, [string[]]$Unrecorded, $ProcessExitCode, [switch]$AfterAllItems) {
      $script:AFScenario = [pscustomobject]@{
        Data = [pscustomobject]@{
          ApplyId = [guid]::NewGuid().ToString('D'); Results = @($Rows); Backup = $Backup
          BackupError = $BackupError; UnrecordedNames = @($Unrecorded | Where-Object { $_ })
          BackupFailedAfterAllItems = [bool]$AfterAllItems
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
    # -AppliedFails：prepared 已落盘、系统写入已发生，标 applied 时磁盘写满（此后所有落盘都失败）。
    # -AtTarget：系统里已是目标值——生产 Invoke-ApplyOp 不写备份、不写系统，返回「无需修改：… 已是目标状态」附注。
    # -HiddenPowerSetting：隐藏的电源设置（pcfg）——生产 Invoke-ApplyOp 先备份并解除隐藏（Attributes），再备份并写值：
    # 一个子操作两条备份记录、两次系统写入。
    # -OptionalUnsupportedPowerSetting（复攻三 X05）：生产 power-tuning 的大小核调度项——Optional 的 pcfg 子操作，本机不支持时
    # 生产 Invoke-ApplyOp 不写备份、不写系统，返回「跳过（本机 CPU 无此电源项）：<Label>」附注（算尝试过、没失败）。
    # -Label（复攻三 X04）：子操作带与值名不同的人话 Label，同生产多数 reg 子操作；失败原因必须以它开头。
    function New-AFRealOp([string]$Name, [string]$WriteError, [switch]$PrepareFails, [switch]$AppliedFails, [switch]$AtTarget,
                          [switch]$HiddenPowerSetting, [switch]$OptionalUnsupportedPowerSetting, [string]$Label) {
      Assert-True (-not ($HiddenPowerSetting -and $OptionalUnsupportedPowerSetting)) "fixture problem: sub-operation $Name cannot be both hidden and unsupported"
      [pscustomobject]@{ Name = $Name; Kind = $(if ($HiddenPowerSetting -or $OptionalUnsupportedPowerSetting) { 'pcfg' } else { 'reg' }); WriteError = $WriteError
                         PrepareFails = [bool]$PrepareFails; AppliedFails = [bool]$AppliedFails; AtTarget = [bool]$AtTarget
                         Hidden = [bool]$HiddenPowerSetting; Optional = [bool]$OptionalUnsupportedPowerSetting
                         Unsupported = [bool]$OptionalUnsupportedPowerSetting; Label = $Label }
    }
    # -ScalarOps：子进程目录里这一项的 Ops 按生产 gpu-pstate-lock 的写法构造成一个裸 Hashtable（只允许一个子操作）。
    # -Reboot（复攻三 X03）：目录里标「需重启」，同生产多数系统项（hags、paging-exec、mpo-off、power-tuning…）。
    # -NoOps（复攻五）：这一项在本机没有可执行的子操作（子进程目录里 Ops = $null，同生产 fso-off / gpu-pref / game-priority
    # 没有游戏路径时）；-RequiresGame 同生产这三项的标注。生产通用 Ops 分支对它不尝试任何子操作，给出 Ok=False、Skipped=True 的行。
    function New-AFRealItem([string]$Id, [string]$Name, [object[]]$Ops, [switch]$ScalarOps, [switch]$Reboot, [switch]$NoOps, [switch]$RequiresGame) {
      Assert-True (-not $ScalarOps -or @($Ops).Count -eq 1) "fixture problem: -ScalarOps item $Id must have exactly one sub-operation"
      Assert-True (-not $NoOps -or (@($Ops).Count -eq 0 -and -not $ScalarOps)) "fixture problem: -NoOps item $Id cannot carry sub-operations"
      [pscustomobject]@{ Id = $Id; Name = $Name; Reboot = [bool]$Reboot; Ops = @($Ops); ScalarOps = [bool]$ScalarOps
                         NoOps = [bool]$NoOps; RequiresGame = [bool]$RequiresGame }
    }
    # -CompleteFails（复攻四 N04/N25）：所有子操作的备份都正常落盘，只有收尾写 complete 状态那一次失败（注入原文同 BackupWriteError）。
    # -RenameBlocked（复攻五 V56）：收尾的 complete 状态正常落盘，随后把 .pending.json 改名成 backup-fixture.json 时失败——
    # 夹具在批次开始前就在备份目录里放好一个同名文件，生产的 [IO.File]::Move 真的撞上「目标已存在」，不注入、不桩改名。
    function Set-AFEngineRealScenario([object[]]$Items, [string]$BackupWriteError, [switch]$CompleteFails, [switch]$RenameBlocked) {
      $script:AFScenario = [pscustomobject]@{
        Data = $null; ProcessExitCode = $null; Throw = $null
        Real = [pscustomobject]@{ Items = @($Items); BackupWriteError = $BackupWriteError; CompleteFails = [bool]$CompleteFails }
      }
      Write-AFEngineScenario
      if ($RenameBlocked) {
        [void][IO.Directory]::CreateDirectory($afBackupDir)
        [IO.File]::WriteAllText($completeBackup, $afRenameBlocker)
      }
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
      # 引擎报了备份写入失败（BackupError）就必须恰好告警一次（弹窗 + 严重告警日志），不论收尾在告警之前（S9、S38：本地执行器）
      # 还是之后（S8、S11：界面刷新）失败；告警排在「执行收尾失败」之前（同 S8 的顺序）。没报就一次都不许有。
      $alarmDialogs = @($script:AFDialogs | Where-Object { "$($_.En)" -ceq 'BACKUP WRITE FAILED' }).Count
      $severeIdx = @(for ($i = 0; $i -lt $script:AFLog.Count; $i++) { if ($script:AFLog[$i].StartsWith('！！严重：备份文件写入失败', [StringComparison]::Ordinal)) { $i } })
      if ($script:AFReply.BackupError) {
        Assert-True ($alarmDialogs -eq 1 -and $severeIdx.Count -eq 1 -and $severeIdx[0] -lt $idx) `
          ("$Label reported a backup-write failure ('$($script:AFReply.BackupError)') but the GUI raised the backup-failure alarm " +
           "$alarmDialogs time(s) as a dialog and $($severeIdx.Count) time(s) as a severe log line (at [$($severeIdx -join ',')], finalization failure at $idx); " +
           "expected exactly once, before the finalization failure, even when finalization fails before the alarm (dialogs [$(Get-AFDialogTitles)])")
      } else {
        Assert-True ($alarmDialogs -eq 0 -and $severeIdx.Count -eq 0) `
          "$Label had no backup-write failure but the GUI raised a backup-failure alarm (dialogs [$(Get-AFDialogTitles)]; severe log lines $($severeIdx.Count))"
      }
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

    # S14–S31（复核 R3「其余已写入」及其四轮复攻），**真实 Invoke-Apply + 真实 Invoke-ApplyOp**：多子项优化项的结果文案必须与实际执行情况一致。
    # 备份 prepared / applied 状态落不了盘时，子项循环立即停下，后面的子项根本没被尝试；旧判断只拿失败数比子项总数，
    # 第一个子项就因备份失败停手、什么都没写时，结果里也写「部分子项写入失败（其余已写入）」。
    # 期望文案里的两个数字对照实际：「未执行」= 目录里该项的子操作数 − 生产 Invoke-Apply 实际调用 Invoke-ApplyOp 的次数（尝试记录），
    # 「已完成」= 实际尝试的子操作数 − 其中被注入失败的子操作数；尝试记录与系统写入记录本身先按场景逐笔钉死。
    # 界面侧走生产 Update-ApplyProgress：逐项实时日志「[失败] 项名 — 文案」与汇总失败清单都必须原样带出引擎文案；
    # 汇总计数（日志与进度区）、备份失败弹窗逐项列出的项名、子进程里生产命令行渲染的逐行结果与汇总也逐字核对。
    # 复攻三起还核对：失败原因里撞上落盘失败那条的阶段词（prepared / applied）与标签（Label 优先）、界面日志与命令行的
    # 备份失败告警两句（严重告警、「以下已生效的改动…」名单）、逐行 Reboot 标注与重启提醒（弹窗、界面日志、命令行）。
    # 93713da 起还核对：部分备份抢救按「真正落过盘的撤销记录」决定（交回 / 删除 .pending.json、盘上记录逐条），
    # 以及界面日志、弹窗与命令行的「备份已保存 / 已抢救出部分备份」（跨项抢救见 S27）；落盘失败撞在最后一个子操作上的真部分失败文案（S26）。
    # 复攻四起还核对：真部分失败带两条原因时按尝试顺序全列（S28）；收尾写 complete 状态失败时真实引擎照样上报 BackupError、
    # 交回 .pending.json（S29，此前只有手写 Data 的 S9）；执行顺序与字母序相反时名单按引擎顺序（S30）；单子操作项撞上
    # 自己的落盘失败走「失败：…」（S31）；备份完好时 UnrecordedNames 为空；备份失败弹窗除抢救一句外逐段逐字；失败清单的抬头与条目。
    # 这十八个场景都不注入收尾失败，处理器走完整条收尾（备份失败弹窗、失败清单、界面刷新、重启提醒）。
    # 放在 S6–S12 之前：同时破坏 S8 文案的引擎变异先在这里、按本组的断言消息红。
    function Get-AFOpAttempts {
      if (-not (Test-Path -LiteralPath $afOpAttempts)) { return @() }
      @([IO.File]::ReadAllLines($afOpAttempts) | Where-Object { $_ })
    }
    # 子进程里备份落盘注入每抛一次记一笔「项Id/子操作名」：锚定注入真的打在预定的子操作上。
    function Get-AFBackupFailureHits {
      if (-not (Test-Path -LiteralPath $afBackupFailureHits)) { return @() }
      @([IO.File]::ReadAllLines($afBackupFailureHits) | Where-Object { $_ })
    }
    # 子进程目录里每项 Ops 的实际类型（Object[] / Hashtable）：锚定 -ScalarOps 真的造出了生产那种裸 Hashtable。
    function Get-AFOpsShapes {
      if (-not (Test-Path -LiteralPath $afOpsShapes)) { return @() }
      @([IO.File]::ReadAllLines($afOpsShapes) | Where-Object { $_ })
    }
    # 子进程里生产命令行渲染逐行打印的内容（第一行是记录器哨兵）：每次 Write-Output 一个元素，行内换行原样还原。
    function Get-AFCliOutput {
      if (-not (Test-Path -LiteralPath $afCliOutput)) { return @() }
      @([IO.File]::ReadAllLines($afCliOutput) | Where-Object { $_ } | ForEach-Object { [string](ConvertFrom-Json $_) } | Where-Object { $_ })
    }
    # 弹窗正文按空行（"`n`n"）分段。失败原因的原文可能自带换行（系统 IO 错误的原文以 CRLF 结尾，S36）：先把「失败原因：<原文>」
    # 里的原文换成占位符再去 CR、分段，最后换回原文，原文里的换行不会把段落切开；原文不在正文里时照常分段（核对随之红在原处）。
    function Get-AFDialogParagraphs([string]$Message, [string]$BackupError) {
      $placeholder = '<<af-backup-error>>'
      $masked = $(if ($BackupError) { $Message.Replace("失败原因：$BackupError", "失败原因：$placeholder") } else { $Message })
      @(($masked -replace "`r", '') -split "`n`n" | ForEach-Object { $_.Replace($placeholder, $BackupError) })
    }
    # 子进程里「本机是否支持该电源设置」的每次询问与回答（「项Id/子操作名=True|False」）。
    function Get-AFPowerProbes {
      if (-not (Test-Path -LiteralPath $afPowerProbes)) { return @() }
      @([IO.File]::ReadAllLines($afPowerProbes) | Where-Object { $_ })
    }
    # 子进程里每次成功的备份落盘（「文件名|State|记录条数」，按先后）。
    function Get-AFBackupWrites {
      if (-not (Test-Path -LiteralPath $afBackupWrites)) { return @() }
      @([IO.File]::ReadAllLines($afBackupWrites) | Where-Object { $_ })
    }
    # 「把文件改名到一个已存在的文件上」在这台机器、这个系统语言下的原文（复攻五 V56 / S36）：在本进程里照样撞一次
    # [IO.File]::Move，取最内层 .NET 异常的消息（不手写，随系统语言而变；外层 PowerShell 包装另说，生产用别的改名方式也照样带着它）。
    function Get-AFRenameCollisionMessage {
      $probeDir = Join-Path $afRoot 'rename-probe'
      [void][IO.Directory]::CreateDirectory($probeDir)
      $probeSource = Join-Path $probeDir 'probe.pending.json'
      $probeTarget = Join-Path $probeDir 'probe.json'
      [IO.File]::WriteAllText($probeSource, 'source'); [IO.File]::WriteAllText($probeTarget, 'target')
      try { [IO.File]::Move($probeSource, $probeTarget); '' }
      catch { $probeError = $_.Exception; while ($probeError.InnerException) { $probeError = $probeError.InnerException }; "$($probeError.Message)" }
      finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # 一行结果的全部字段（传输层前后逐字段对照用）。
    function Get-AFRowDigest($Row) {
      "Id=$($Row.Id);Name=$($Row.Name);Ok=$($Row.Ok);Skipped=$($Row.Skipped);Changed=$($Row.Changed);Attention=$($Row.Attention);Reboot=$($Row.Reboot);Msg=$($Row.Msg)"
    }
    # 一轮真实批次的共同锚点：到达引擎、引擎发布了带 Data 的结果且退出码符合、传输层把原样的行交给了处理器、
    # 行集合符合、尝试 / 系统写入记录与场景逐笔一致，生产 Update-ApplyProgress 对每一行都跑过（界面断言不空转）。
    function Assert-AFRealBatch([string]$Scenario, [int]$ExpectedExit, [string[]]$ExpectedRowIds,
                                [string[]]$ExpectedAttempts, [string[]]$ExpectedWrites) {
      Assert-True ($script:AFApplyCalls -eq 1) "[$Scenario] fixture problem: the elevated engine call was never reached"
      $published = Assert-AFEnginePublished "[$Scenario] real-engine batch"
      Assert-True ($null -ne $published.Data -and [int]$published.ExitCode -eq $ExpectedExit) `
        ("[$Scenario] the real engine published exit $([int]$published.ExitCode) $(if ($null -ne $published.Data) { 'with' } else { 'without' }) Data; " +
         "expected exit $ExpectedExit with Data (engine error: '$($published.Error)')")
      Assert-True ($null -eq $script:AFRealEngineError -and $null -ne $script:AFReply) `
        "[$Scenario] the real transport did not hand the engine's Data back to the Apply handler: $($script:AFRealEngineError)"
      $rowIds = @($published.Data.Results | ForEach-Object { "$($_.Id)" })
      Assert-True (($rowIds -join ',') -ceq (@($ExpectedRowIds) -join ',')) `
        "[$Scenario] the real engine returned rows [$($rowIds -join ',')], expected exactly [$(@($ExpectedRowIds) -join ',')]"
      # 传输层是生产原文（真 Invoke-ElevatedEngineAction），行在这里被改写是产品回归，不是夹具问题（复攻 R3 msg）。
      # 逐字段对照（复攻三）：只比 Id=Msg 时，传输层改掉 Changed / Reboot（处理器据此算活动优化集合、弹重启提醒）看不见。
      $handedRows = (@($script:AFReply.Results | ForEach-Object { Get-AFRowDigest $_ }) -join ' | ')
      $publishedRows = (@($published.Data.Results | ForEach-Object { Get-AFRowDigest $_ }) -join ' | ')
      Assert-True ($handedRows -ceq $publishedRows) `
        "[$Scenario] the real transport handed the Apply handler rows that differ from what the engine published (handler: $handedRows; engine: $publishedRows)"
      $attempts = @(Get-AFOpAttempts)
      Assert-True (($attempts -join ',') -ceq (@($ExpectedAttempts) -join ',')) `
        ("[$Scenario] sub-operations attempted were [$($attempts -join ',')], expected exactly [$(@($ExpectedAttempts) -join ',')] " +
         "(no sub-operation may be attempted after a backup-write failure)")
      $writes = @(Get-AFSystemWrites)
      Assert-True (($writes -join ',') -ceq (@($ExpectedWrites) -join ',')) `
        "[$Scenario] system writes were [$($writes -join ',')], expected exactly [$(@($ExpectedWrites) -join ',')]"
      # 夹具锚点：这一轮确实把处理器对 Update-ApplyProgress 的调用转给了生产原文（-RealProgress）。
      Assert-True ($script:AFLastRealProgress -and $rowIds.Count -gt 0) `
        "[$Scenario] fixture problem: the scenario did not route Update-ApplyProgress to the production function (-RealProgress) or has no rows"
      # 产品断言（复攻 R3 msg）：处理器对引擎交回的每一行恰好调一次 Update-ApplyProgress，逐项实时日志才会一行不少。
      Assert-True ($script:AFProgressCalls -eq $rowIds.Count) `
        "[$Scenario] the Apply handler ran the production Update-ApplyProgress $($script:AFProgressCalls) time(s) for $($rowIds.Count) engine result row(s); every row needs exactly one per-item log line"
      $published
    }
    # 被备份失败截断的那一项：数字对照实际 → Ok / Changed → 绝不说「其余已写入」→ 头部与两个数字 → 头部后按尝试顺序逐条列出失败子操作的原因。
    # 失败子操作可以不止一条（复攻 M01/M03/M04）：先有子操作被系统拒绝写入、之后才遇到备份落盘失败时，
    # 「已完成 = 尝试数 − 1」「只报最后一条错误」「尝试过两个以上就算部分完成」都与正确公式分得开。
    # 落盘失败恰好撞在最后一个子操作上时（S26，复攻二 / 三的 P5 形态）没有子操作被跳过（NotRun = 0），行走真部分失败 / 全部失败的文案：
    # 「部分子项写入失败（其余 Done 项已完成）：…」或「失败：…」（93713da）。已完成的子操作不一定写过系统（已达标、本机没有的可选电源项），
    # 所以「其余已写入」在这里同样不许出现。这两个分支的尾部同样逐条、按尝试顺序核对：真部分失败带两条原因见 S28（复攻四 N01–N03），
    # 单子操作项走「失败：…」见 S31 与 S11（复攻四 N24）。
    function Assert-AFCutShortRow([string]$Scenario, $Published, $Item, [int]$Done, [int]$NotRun, [bool]$Changed) {
      $id = "$($Item.Id)"
      $injected = "$($script:AFScenario.Real.BackupWriteError)"
      $specOps = @($Item.Ops)
      $attempted = @(Get-AFOpAttempts | Where-Object { $_.StartsWith("$id/", [StringComparison]::Ordinal) })
      # 尝试记录本身已由 Assert-AFRealBatch 按场景逐笔钉死；失败子操作 = 实际尝试过、且场景给它注入了失败的子操作（按尝试顺序）。
      $failedOps = @($specOps | Where-Object { ($_.PrepareFails -or $_.AppliedFails -or $_.WriteError) -and ($attempted -ccontains "$id/$($_.Name)") })
      $cutAt = $(if ($failedOps.Count -gt 0) { $failedOps[$failedOps.Count - 1] })
      $hits = @(Get-AFBackupFailureHits)
      # 夹具自检：场景确实是「最后一个被尝试的子操作撞上注入的落盘失败」，注入第一次命中的就是它，两个数字与尝试记录相符。
      Assert-True ($injected -and $NotRun -ge 0 -and $null -ne $cutAt -and ($cutAt.PrepareFails -or $cutAt.AppliedFails) -and
        $attempted.Count -gt 0 -and $attempted[$attempted.Count - 1] -ceq "$id/$($cutAt.Name)" -and
        $hits.Count -ge 1 -and $hits[0] -ceq "$id/$($cutAt.Name)" -and
        ($specOps.Count - $attempted.Count) -eq $NotRun -and ($attempted.Count - $failedOps.Count) -eq $Done) `
        ("[$Scenario] fixture problem: $id was meant to stop at the injected backup-write failure on its last attempted sub-operation " +
         "with $Done done and $NotRun not run, but $($attempted.Count) of its $($specOps.Count) sub-operations were attempted " +
         "[$($attempted -join ',')], $($failedOps.Count) of those were set to fail, and the injection fired on [$($hits -join ',')]")
      # 产品断言：引擎把注入的落盘错误原样交回为 BackupError（部分备份抢救、UnrecordedNames、界面弹窗都以它为准）。
      Assert-True ("$($Published.Data.BackupError)" -ceq $injected) `
        "[$Scenario] the real engine did not report the injected backup-write failure as its BackupError: expected '$injected', got '$($Published.Data.BackupError)'"
      $rows = @($Published.Data.Results | Where-Object { "$($_.Id)" -ceq $id })
      Assert-True ($rows.Count -eq 1) "[$Scenario] fixture problem: the engine published $($rows.Count) rows for $id"
      $row = $rows[0]
      Assert-True ($row.Ok -eq $false -and $row.Skipped -eq $false -and $row.Changed -eq $Changed -and "$($row.Name)" -ceq "$($Item.Name)") `
        ("[$Scenario] $id row is Ok=$($row.Ok) Skipped=$($row.Skipped) Changed=$($row.Changed) Name='$($row.Name)'; expected Ok=False Skipped=False " +
         "Changed=$Changed Name='$($Item.Name)' for an item whose sub-operations were cut short by a backup-write failure")
      $msg = "$($row.Msg)"
      # 这一项真正改过系统的子操作（系统写入记录按「项Id/子操作名」记，隐藏电源项的解除隐藏另记一笔「(unhide)」）。
      $itemWrittenOps = @(@(Get-AFSystemWrites) | Where-Object { $_.StartsWith("$id/", [StringComparison]::Ordinal) } |
        ForEach-Object { $_ -replace '\(unhide\)$', '' } | Select-Object -Unique)
      Assert-True (-not $msg.Contains('其余已写入')) $(if ($NotRun -gt 0) {
          "[$Scenario] $id message claims the remaining sub-operations were written although $NotRun of them never ran: $msg"
        } else {
          "[$Scenario] $id message claims the remaining sub-operations were written although $($itemWrittenOps.Count) of its $Done completed sub-operation(s) changed the system: $msg"
        })
      $head = $(if ($NotRun -gt 0) {
                  if ($Done -gt 0) { "部分子项写入失败（$Done 项已完成，其后 $NotRun 项因备份无法落盘未执行）" }
                  else { "失败（备份无法落盘，其余 $NotRun 项未执行）" }
                } elseif ($Done -gt 0) { "部分子项写入失败（其余 $Done 项已完成）" }
                else { '失败' })
      Assert-True ($msg.StartsWith($head, [StringComparison]::Ordinal) -and
        ($msg.Length -eq $head.Length -or $msg[$head.Length] -ceq [char]'：')) `
        "[$Scenario] $id message head is wrong: expected '$head' ($Done done, $NotRun not run), got: $msg"
      # 头部之后按尝试顺序、以「；」分隔，每个失败子操作恰好一条「子操作标签：原因」，整段逐字比对：
      # - 标签是用户看得懂的 Label（生产子操作带 Label 时），没有才退回值名 Name（复攻三 X04）；
      # - 系统拒绝写入的原因逐字是注入的 WriteError；
      # - 撞上落盘失败的那条逐字是「备份 prepared 状态持久化失败：<注入原文>」或「备份 applied 状态持久化失败：<注入原文>」（复攻三 X01/X02）。
      #   阶段词是这一条里唯一说明「这个子操作的系统写入有没有发生」的信息：prepared = 还没写系统，applied = 已写系统、回滚记录不全；
      #   同一场景的系统写入记录（Assert-AFRealBatch 已逐笔钉死）与它必须一致，张冠李戴或合并成一句都要红。
      $detail = $(if ($msg.Length -gt $head.Length) { $msg.Substring($head.Length + 1) } else { '' })
      $expectEntries = @($failedOps | ForEach-Object {
        $shown = $(if ($_.Label) { "$($_.Label)" } else { "$($_.Name)" })
        if ($_.WriteError) { "$shown：$($_.WriteError)" }
        elseif ($_.PrepareFails) { "$shown：备份 prepared 状态持久化失败：$injected" }
        else { "$shown：备份 applied 状态持久化失败：$injected" }
      })
      $expectDesc = @($expectEntries | ForEach-Object { "'$_'" }) -join ' ; '
      Assert-True ($detail.Length -gt 0 -and $detail -ceq ($expectEntries -join '；')) `
        "[$Scenario] $id message lost the failing sub-operation's detail after the head (expected, in attempt order, exactly $($failedOps.Count) entr$(if ($failedOps.Count -eq 1) { 'y' } else { 'ies' }): $expectDesc): $msg"
      $row
    }
    # 备份落盘失败的批次：引擎交回的 UnrecordedNames（已改动、回滚记录可能不全的项名）逐字对上，
    # 处理器在确认框之后恰好弹一次「备份写入失败」。两者都是生产行为，不是夹具自检。
    # 名单一律按引擎顺序（执行顺序）逐字比较：S30 的执行顺序与字母序相反，引擎、界面日志、弹窗或命令行排过序再列都会在那里红；
    # 其余场景的引擎顺序恰好是字母序，单看它们分不出「按顺序」与「排过序」（复攻四 N30/N31）。
    # -BackupError：备份失败的原文不是夹具注入的（S36 改名失败，原文由系统给出、先由场景锚定），按它核对弹窗与告警。
    # -Titles：收尾失败的场景（S38）在备份失败弹窗之后还有 APPLY FINALIZATION FAILED。
    # -AfterAllItems：备份在收尾（写 complete 状态 S29 / 改名 S36）时才失败，每一项都已执行——引擎交回 BackupFailedAfterAllItems，
    # 严重告警（界面与命令行）与弹窗开头不许说「剩余优化项已中止执行 / 本轮执行已中止」（独立复核遗留 4）。
    function Assert-AFBackupFailureSurfaced([string]$Scenario, $Published, [string[]]$ExpectedUnrecorded, [string]$BackupError,
                                            [string]$Titles = 'CONFIRM APPLY|BACKUP WRITE FAILED', [switch]$AfterAllItems) {
      $engineLost = (@($Published.Data.UnrecordedNames | ForEach-Object { "$_" }) -join '|')
      $wantLost = (@($ExpectedUnrecorded | Where-Object { $_ }) -join '|')
      Assert-True ($engineLost -ceq $wantLost) `
        "[$Scenario] the real engine's UnrecordedNames were [$engineLost], expected exactly [$wantLost] (the items it changed before the backup-write failure)"
      Assert-True ($Published.Data.BackupFailedAfterAllItems -is [bool] -and $Published.Data.BackupFailedAfterAllItems -eq [bool]$AfterAllItems) `
        ("[$Scenario] the real engine published BackupFailedAfterAllItems [$($Published.Data.BackupFailedAfterAllItems)]; expected $([bool]$AfterAllItems) " +
         "($(if ($AfterAllItems) { 'every item ran, only the final backup save failed' } else { 'the backup failure stopped the run' }))")
      Assert-True ((Get-AFDialogTitles) -ceq $Titles) `
        "[$Scenario] the Apply handler did not show exactly the BACKUP WRITE FAILED dialog after the confirmation: dialogs [$(Get-AFDialogTitles)], expected [$Titles]"
      # 弹窗正文（复攻二）：「· 项名」逐行列出的就是用户手动回退的全部线索，按引擎顺序逐字核对；一个都没有时写「（无）」，
      # 并带上注入的落盘错误原文。只核对标题时，弹窗漏列、多列（把没动过系统的项也列进去）都看不见。
      $bwf = @($script:AFDialogs | Where-Object { "$($_.En)" -ceq 'BACKUP WRITE FAILED' })[0]
      $listed = @(Get-AFDialogBullets $bwf.Message)
      $injected = $(if ($BackupError) { $BackupError } else { "$($script:AFScenario.Real.BackupWriteError)" })
      Assert-True (($listed -join '|') -ceq $wantLost -and ($wantLost.Length -gt 0 -or $bwf.Message.Contains('（无）')) -and
        $bwf.Message.Contains("失败原因：$injected")) `
        ("[$Scenario] the BACKUP WRITE FAILED dialog listed [$($listed -join '|')] as changed without a complete backup record; " +
         "expected exactly [$wantLost]$(if ($wantLost.Length -eq 0) { " shown as '（无）'" }) and the reason '$injected'")
      # 弹窗其余部分（复攻四 N06）：按空行分段，除「已抢救出部分备份」一句（有无与原文由 Assert-AFSalvageSurfaced 逐字核对）外逐段逐字：
      # 开头一句必须说「本轮执行已中止」——截断项之后勾选的项目没有结果行、不进计数，界面上说它们没开始的只有这句与日志里的严重告警；
      # -AfterAllItems 时开头一句反过来必须说都已执行完、失败的是最后一步保存备份（每一项都有结果行，不能让用户以为后面的项没跑）。
      # 名单前的说明句（没有它，「· 项名」就看不出是「已生效、备份可能没记全」的项）、失败原因、结尾的手动回退指引，都不许丢、改写或换序。
      $paragraphs = @(Get-AFDialogParagraphs "$($bwf.Message)" $injected | Where-Object { -not $_.Contains('抢救') })
      $listParagraph = "以下改动已经生效、但可能没有完整的备份记录：`n" +
        $(if ($wantLost.Length -gt 0) { @($ExpectedUnrecorded | Where-Object { $_ } | ForEach-Object { "· $_" }) -join "`n" } else { '（无）' })
      $opening = $(if ($AfterAllItems) { '本轮的优化项都已执行完，但最后一步保存备份时写入失败。' } else { '备份文件写入失败，本轮执行已中止。' })
      $wantParagraphs = @($opening, $listParagraph, "失败原因：$injected",
        '其余项如需回退，请按上面的项名手动处理，或点「导出诊断报告」发给开发者。')
      Assert-True (($paragraphs -join ' || ') -ceq ($wantParagraphs -join ' || ')) `
        ("[$Scenario] the BACKUP WRITE FAILED dialog (salvage sentence aside) read [$(($paragraphs -join ' || ') -replace "`n", ' <LF> ')]; " +
         "expected paragraph by paragraph [$(($wantParagraphs -join ' || ') -replace "`n", ' <LF> ')] " +
         "$(if ($AfterAllItems) { '(every item ran: the opening sentence must not say the run was aborted)' } else { '(the opening sentence must say the run was aborted)' })")
      Assert-True ("$($bwf.Chip)" -ceq '备份写入失败') "[$Scenario] the BACKUP WRITE FAILED dialog's chip read '$($bwf.Chip)'; expected '备份写入失败'"
      # 日志与命令行（复攻三 X06–X09、X07）：弹窗点一下就没了，留下来的是界面日志（「导出诊断报告」带走的也是它）和命令行输出。
      # 两处各两句都逐字核对：
      # - 严重告警整句恰好一次，含「剩余优化项已中止执行」——截断项之后勾选的项目没有结果行、不进计数，除弹窗开头一句外只有它说它们没开始；
      #   -AfterAllItems 时整句改说「本轮的优化项都已执行完，失败的是最后一步保存备份」；
      # - 「以下已生效的改动可能没有完整的备份记录：…」列的必须恰好是引擎的 UnrecordedNames（按引擎顺序），没有就整句不出现。
      #   拿失败行顶替会让用户去手动回退一个根本没改过系统的项（S14），或漏掉真改过的成功项（S20）。
      $namesJoined = (@($ExpectedUnrecorded | Where-Object { $_ }) -join '、')
      $severeTail = $(if ($AfterAllItems) { '。本轮的优化项都已执行完，失败的是最后一步保存备份。' } else { '，剩余优化项已中止执行。' })
      $severeGui = "！！严重：备份文件写入失败（$injected）$severeTail"
      Assert-True (@($script:AFLog | Where-Object { $_ -ceq $severeGui }).Count -eq 1) `
        "[$Scenario] the GUI's severe backup-failure log line was not exactly '$severeGui' once (GUI lines starting with ！！: $(@($script:AFLog | Where-Object { $_.StartsWith('！！', [StringComparison]::Ordinal) }) -join ' || '))"
      $lostGuiPrefix = '！！以下已生效的改动可能没有完整的备份记录：'
      $lostGui = @($script:AFLog | Where-Object { $_.StartsWith($lostGuiPrefix, [StringComparison]::Ordinal) })
      $wantLostGui = @(if ($namesJoined) { "$lostGuiPrefix$namesJoined" })
      Assert-True (($lostGui -join ' || ') -ceq ($wantLostGui -join ' || ')) `
        "[$Scenario] the GUI log's backup-failure line naming changes without a complete backup record was [$($lostGui -join ' || ')]; expected [$($wantLostGui -join ' || ')] (exactly the engine's UnrecordedNames)"
      $cli = @(Get-AFCliOutput)
      $severeCli = "！！严重警告：备份文件写入失败（$injected）$severeTail"
      Assert-True (@($cli | Where-Object { $_ -ceq $severeCli }).Count -eq 1) `
        "[$Scenario] the engine's CLI -Apply severe backup-failure line was not exactly '$severeCli' once (CLI lines starting with ！！: $(@($cli | Where-Object { $_.StartsWith('！！', [StringComparison]::Ordinal) }) -join ' || '))"
      $lostCliPrefix = '！！以下已生效的改动可能没有完整的备份记录，如需回退请按项名手动处理：'
      $lostCli = @($cli | Where-Object { $_.StartsWith($lostCliPrefix, [StringComparison]::Ordinal) })
      $wantLostCli = @(if ($namesJoined) { "$lostCliPrefix$namesJoined" })
      Assert-True (($lostCli -join ' || ') -ceq ($wantLostCli -join ' || ')) `
        "[$Scenario] the engine's CLI -Apply backup-failure line naming changes without a complete backup record was [$($lostCli -join ' || ')]; expected [$($wantLostCli -join ' || ')] (exactly the engine's UnrecordedNames)"
    }
    # 部分备份抢救（93713da）：备份落盘失败后，引擎只在至少一条撤销记录**真正落过盘**时才把 .pending.json 作为 Backup 交回；
    # 一条都没落盘（本轮第一次 prepared 写入就失败，或之前的子操作都已达标、没写过备份）就删掉这个空文件、Backup 为空。
    # 收尾写 complete 状态失败时（S29，复攻四 N04/N25）走的是另一处 catch：记录全都已落盘（applied），同样必须交回 .pending.json、上报 BackupError。
    # 交回与否决定四处说法：界面日志「备份已保存：…」、备份失败弹窗「已抢救出部分备份：…」一句、命令行「备份已保存：…」
    # 与「！！已抢救出的部分备份：…」——什么都没记下却这么说，用户会拿一个空文件去「还原设置」。
    # $ExpectedRecords 是抢救出的文件里应有的撤销记录（「项Id:Kind:值名或电源设置名=状态」，按落盘顺序），
    # 由场景按「哪些子操作的 prepared 写成功了、哪些又写成了 applied」逐条写明；为空表示不应交回任何备份。
    # 盘上的文件是子进程真实落盘的结果（夹具的落盘替身在注入失败时抛错、不写文件，同生产 Write-BytesAtomic）。
    # 收尾 complete 已写、改名失败（S36）时 -BackupError 给出由场景锚定过的系统原文，其余同注入的落盘失败。
    function Assert-AFSalvageSurfaced([string]$Scenario, $Published, [string[]]$ExpectedRecords, [string]$BackupError) {
      $want = @($ExpectedRecords | Where-Object { $_ })
      $salvaged = $want.Count -gt 0
      $injected = $(if ($BackupError) { $BackupError } else { "$($script:AFScenario.Real.BackupWriteError)" })
      Assert-True ($injected -and "$($Published.Data.BackupError)" -ceq $injected) `
        "[$Scenario] fixture problem: the salvage check only applies to a batch stopped by the injected backup-write failure (engine BackupError '$($Published.Data.BackupError)')"
      $engineBackup = "$($Published.Data.Backup)"
      $onDisk = @(if (Test-Path -LiteralPath $afBackupDir) { Get-ChildItem -LiteralPath $afBackupDir -Force | ForEach-Object { $_.Name } })
      if ($salvaged) {
        Assert-True ($engineBackup -ceq $pendingBackup) `
          "[$Scenario] the real engine did not hand back the salvaged partial backup although $($want.Count) undo record(s) reached the disk (expected Backup '$pendingBackup', got '$engineBackup')"
        $doc = $(if (Test-Path -LiteralPath $pendingBackup) { [IO.File]::ReadAllText($pendingBackup) | ConvertFrom-Json })
        $records = @(if ($doc) { @($doc.Ops) | ForEach-Object {
          "$($_.ItemId):$($_.Kind):$(if ("$($_.Kind)" -ceq 'pcfg') { "$($_.Setting)" } else { "$($_.Name)" })=$($_.Status)" } })
        Assert-True (($onDisk -join ',') -ceq [IO.Path]::GetFileName($pendingBackup) -and ($records -join ',') -ceq ($want -join ',')) `
          ("[$Scenario] the salvaged backup on disk does not hold exactly the undo records that were persisted before the failure: " +
           "backup directory [$($onDisk -join ',')], records [$($records -join ',')], expected [$($want -join ',')]")
      } else {
        Assert-True ($engineBackup -ceq '') `
          "[$Scenario] the real engine handed back a backup file although no undo record reached the disk (expected no Backup, got '$engineBackup')"
        Assert-True ($onDisk.Count -eq 0) `
          "[$Scenario] the real engine left the empty .pending.json in the backup directory although no undo record reached the disk (backup directory: [$($onDisk -join ',')])"
      }
      Assert-True ("$($script:AFReply.Backup)" -ceq $engineBackup) `
        "[$Scenario] the real transport handed the Apply handler Backup '$($script:AFReply.Backup)' but the engine published '$engineBackup'"
      # 界面：日志（严重告警在场，证明处理器走到了备份失败的收尾）与弹窗。
      Assert-True (@($script:AFLog | Where-Object { $_.StartsWith("！！严重：备份文件写入失败（$injected）", [StringComparison]::Ordinal) }).Count -eq 1) `
        "[$Scenario] the GUI log has no severe backup-failure line, so the Apply handler never reached its backup-failure finalization"
      $savedGui = @($script:AFLog | Where-Object { $_.Contains('备份已保存') })
      $wantSavedGui = @(if ($salvaged) { "备份已保存：$pendingBackup" })
      Assert-True (($savedGui -join ' || ') -ceq ($wantSavedGui -join ' || ')) `
        "[$Scenario] the GUI log's backup-saved lines were [$($savedGui -join ' || ')]; expected [$($wantSavedGui -join ' || ')]"
      $bwf = @($script:AFDialogs | Where-Object { "$($_.En)" -ceq 'BACKUP WRITE FAILED' })
      Assert-True ($bwf.Count -eq 1) "[$Scenario] the Apply handler showed the BACKUP WRITE FAILED dialog $($bwf.Count) time(s); expected once"
      $salvageGui = @("$($bwf[0].Message)" -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Contains('抢救') })
      $wantSalvageGui = @(if ($salvaged) { "已抢救出部分备份：$([IO.Path]::GetFileName($pendingBackup))，「还原设置」可还原其中已记录的部分。" })
      Assert-True (($salvageGui -join ' || ') -ceq ($wantSalvageGui -join ' || ')) `
        "[$Scenario] the BACKUP WRITE FAILED dialog's salvaged-backup sentence was [$($salvageGui -join ' || ')]; expected [$($wantSalvageGui -join ' || ')]"
      # 抢救一句在弹窗里的位置（复攻五 V07）：Assert-AFBackupFailureSurfaced 的逐段核对把含「抢救」的段落滤掉了，上面只核对它的有无与原文。
      # 整篇按空行分段：它必须紧跟「失败原因：…」，紧接着就是结尾的「其余项如需回退…」，结尾排在最后——「其余项」说的正是
      # 抢救备份还原不了的那部分，抢救一句挪到结尾之后，「其余项」就没有了所指。
      if ($salvaged) {
        $allParagraphs = @(Get-AFDialogParagraphs "$($bwf[0].Message)" $injected)
        $salvageAt = @(for ($i = 0; $i -lt $allParagraphs.Count; $i++) { if ($allParagraphs[$i].Contains('抢救')) { $i } })
        $reasonAt = [array]::IndexOf($allParagraphs, "失败原因：$injected")
        $closingAt = [array]::IndexOf($allParagraphs, '其余项如需回退，请按上面的项名手动处理，或点「导出诊断报告」发给开发者。')
        Assert-True ($salvageAt.Count -eq 1 -and $reasonAt -ge 0 -and $salvageAt[0] -eq $reasonAt + 1 -and
          $closingAt -eq $salvageAt[0] + 1 -and $closingAt -eq $allParagraphs.Count - 1) `
          ("[$Scenario] the BACKUP WRITE FAILED dialog put the salvaged-backup sentence at paragraph [$($salvageAt -join ',')] of $($allParagraphs.Count) " +
           "(reason at $reasonAt, closing guidance at $closingAt); expected it right after the reason and right before the closing guidance, which comes last")
      }
      # 命令行：记录器已在生产分发之前就位，且备份失败那一段确实打印了（严重警告在场），没有抢救句才说明问题。
      $cli = @(Get-AFCliOutput)
      Assert-True ($cli.Count -gt 0 -and $cli[0] -ceq 'af-cli-recorder-armed') `
        "[$Scenario] fixture problem: the engine child's Write-Output recorder was not armed before the real dispatch (recorded $($cli.Count) line(s))"
      Assert-True (@($cli | Where-Object { $_.StartsWith("！！严重警告：备份文件写入失败（$injected）", [StringComparison]::Ordinal) }).Count -eq 1) `
        "[$Scenario] the engine's CLI -Apply output has no severe backup-failure line, so its backup-failure block never ran"
      $savedCli = @($cli | Where-Object { $_.Contains('备份已保存') -or $_.Contains('抢救') })
      $wantSavedCli = @(if ($salvaged) { "备份已保存：$pendingBackup（用 -Restore 可一键还原）"; "！！已抢救出的部分备份：$pendingBackup（-Restore 可还原其中已记录的部分）" })
      Assert-True (($savedCli -join ' || ') -ceq ($wantSavedCli -join ' || ')) `
        "[$Scenario] the engine's CLI -Apply backup-saved / salvaged lines were [$($savedCli -join ' || ')]; expected [$($wantSavedCli -join ' || ')]"
    }
    # 备份完好的批次怎么收尾（复攻五 V01–V06、V54）。此前备份完好的真实批次（S17、S21）完全不看 Backup 与备份目录，
    # S10 只看界面日志里「备份已保存：…backup-fixture.json」这一行字——盘上有没有这个文件、.pending.json 删没删都不看；
    # 也没有一个真实批次「一条撤销记录都没写」（每个子操作都已达标）。
    # 有记录（$ExpectedRecords 非空，按落盘顺序）：Backup 是改名后的 backup-fixture.json；备份目录里恰好只有它（.pending.json 留着，
    # 还原时会被当成「一次未完成的执行」再列一遍）；它的 State 是 complete；撤销记录逐条是本轮写下的那些（系统写入被拒的停在 prepared）。
    # 没有记录：不交回 Backup，备份目录为空（空的 .pending.json 删掉，既不留着也不改名成一份空的完整备份）——否则界面与命令行
    # 会对一个空文件说「备份已保存…可一键还原」，正是 93713da 在备份失败一侧去掉的那句。界面日志与命令行的「备份已保存」照此逐字核对。
    function Assert-AFCompleteBackupSurfaced([string]$Scenario, $Published, [string[]]$ExpectedRecords) {
      $want = @($ExpectedRecords | Where-Object { $_ })
      $hits = @(Get-AFBackupFailureHits)
      Assert-True (-not $Published.Data.BackupError -and $hits.Count -eq 0) `
        "[$Scenario] fixture problem: the complete-backup check only applies to a batch whose backup stayed intact (engine BackupError '$($Published.Data.BackupError)'; injected failures [$($hits -join ',')])"
      # 夹具锚点：引擎确实建过这份 .pending.json（首次落盘、零条记录），下面「目录为空 / 只剩改名后的文件」才不是空转。
      $pendingName = [IO.Path]::GetFileName($pendingBackup)
      $completeName = [IO.Path]::GetFileName($completeBackup)
      $writes = @(Get-AFBackupWrites)
      Assert-True ($writes.Count -gt 0 -and $writes[0] -ceq "$pendingName|pending|0") `
        "[$Scenario] fixture problem: the engine's first backup write was not the empty $pendingName (backup writes: [$($writes -join ',')]), so the backup-directory check would prove nothing"
      $engineBackup = "$($Published.Data.Backup)"
      $onDisk = @(if (Test-Path -LiteralPath $afBackupDir) { Get-ChildItem -LiteralPath $afBackupDir -Force | ForEach-Object { $_.Name } })
      if ($want.Count -gt 0) {
        Assert-True ($engineBackup -ceq $completeBackup) `
          "[$Scenario] the real engine handed back Backup '$engineBackup' for an intact batch that recorded $($want.Count) undo record(s); expected the renamed complete backup '$completeBackup'"
        Assert-True (($onDisk -join ',') -ceq $completeName) `
          "[$Scenario] the intact batch left the backup directory as [$($onDisk -join ',')]; expected exactly [$completeName] (the $pendingName renamed to it, nothing left behind)"
        $doc = [IO.File]::ReadAllText($completeBackup) | ConvertFrom-Json
        Assert-True ("$($doc.State)" -ceq 'complete') `
          "[$Scenario] the intact batch's renamed backup $completeName says State '$($doc.State)'; expected 'complete'"
        $records = @(@($doc.Ops) | ForEach-Object {
          "$($_.ItemId):$($_.Kind):$(if ("$($_.Kind)" -ceq 'pcfg') { "$($_.Setting)" } else { "$($_.Name)" })=$($_.Status)" })
        Assert-True (($records -join ',') -ceq ($want -join ',')) `
          "[$Scenario] the intact batch's renamed backup $completeName holds the undo records [$($records -join ',')]; expected [$($want -join ',')] (every record this batch wrote, in write order)"
      } else {
        Assert-True ($engineBackup -ceq '') `
          "[$Scenario] the real engine handed back Backup '$engineBackup' for an intact batch that recorded no undo record (every sub-operation was already at target); expected none"
        Assert-True ($onDisk.Count -eq 0) `
          "[$Scenario] the intact batch that recorded no undo record left [$($onDisk -join ',')] in the backup directory; expected it empty (the empty $pendingName deleted, neither kept nor renamed)"
      }
      Assert-True ("$($script:AFReply.Backup)" -ceq $engineBackup) `
        "[$Scenario] the real transport handed the Apply handler Backup '$($script:AFReply.Backup)' but the engine published '$engineBackup'"
      $savedGui = @($script:AFLog | Where-Object { $_.Contains('备份已保存') -or $_.Contains('抢救') })
      $wantSavedGui = @(if ($want.Count -gt 0) { "备份已保存：$completeBackup" })
      Assert-True (($savedGui -join ' || ') -ceq ($wantSavedGui -join ' || ')) `
        "[$Scenario] the GUI log's backup-saved lines for an intact batch were [$($savedGui -join ' || ')]; expected [$($wantSavedGui -join ' || ')]"
      $cli = @(Get-AFCliOutput)
      Assert-True ($cli.Count -gt 0 -and $cli[0] -ceq 'af-cli-recorder-armed') `
        "[$Scenario] fixture problem: the engine child's Write-Output recorder was not armed before the real dispatch (recorded $($cli.Count) line(s))"
      $savedCli = @($cli | Where-Object { $_.Contains('备份已保存') -or $_.Contains('抢救') })
      $wantSavedCli = @(if ($want.Count -gt 0) { "备份已保存：$completeBackup（用 -Restore 可一键还原）" })
      Assert-True (($savedCli -join ' || ') -ceq ($wantSavedCli -join ' || ')) `
        "[$Scenario] the engine's CLI -Apply backup-saved lines for an intact batch were [$($savedCli -join ' || ')]; expected [$($wantSavedCli -join ' || ')]"
    }
    # 备份完好的批次（S17、S21）：界面日志与命令行都不能出现任何「！！」级别的备份告警。
    # 引擎交回的 UnrecordedNames 也必须为空（复攻四 N05）：界面与命令行只在 BackupError 时才显示它，但引擎 Data 与
    # 照 SKILL.md 调用的 -Apply -Json 原样带着它——备份完好时还列项名，等于告诉调用方「这些改动可能没有完整备份」。
    # 这两个批次都有改动过系统的行（下面的夹具锚点），不加 BackupError 守卫地列名单在这里必然非空。
    function Assert-AFNoBackupFailureSurfaced([string]$Scenario, $Published) {
      $changedRows = @($Published.Data.Results | Where-Object { $_.Changed -eq $true })
      Assert-True ($changedRows.Count -gt 0) `
        "[$Scenario] fixture problem: the intact batch has no row that changed the system, so an empty UnrecordedNames would prove nothing"
      $engineLost = @($Published.Data.UnrecordedNames | ForEach-Object { "$_" })
      Assert-True ($engineLost.Count -eq 0) `
        "[$Scenario] the real engine reported UnrecordedNames [$($engineLost -join '|')] for a batch whose backup was intact; expected none"
      $cli = @(Get-AFCliOutput)
      Assert-True ($cli.Count -gt 0 -and $cli[0] -ceq 'af-cli-recorder-armed') `
        "[$Scenario] fixture problem: the engine child's Write-Output recorder was not armed before the real dispatch (recorded $($cli.Count) line(s))"
      $guiAlarm = @($script:AFLog | Where-Object { $_.StartsWith('！！', [StringComparison]::Ordinal) })
      Assert-True ($guiAlarm.Count -eq 0) `
        "[$Scenario] the GUI log carried backup-failure lines for a batch whose backup was intact: $($guiAlarm -join ' || ')"
      $cliAlarm = @($cli | Where-Object { $_.StartsWith('！！', [StringComparison]::Ordinal) })
      Assert-True ($cliAlarm.Count -eq 0) `
        "[$Scenario] the engine's CLI -Apply output carried backup-failure lines for a batch whose backup was intact: $($cliAlarm -join ' || ')"
    }
    # 重启标注如何产生与呈现（复攻三 X03）：引擎只给「成功（Ok）、确有改动（Changed）、非体检、目录标了 Reboot」的行标 Reboot=True——
    # 被备份失败截断的行 Ok=False，哪怕它改过系统（Changed=True）、哪怕目录标了需重启，也绝不能被当成「成功项」弹重启提醒。
    # 逐行核对引擎标注；界面的重启弹窗（恰好一次、名单按引擎顺序，或一次都不弹）、界面日志与命令行的「成功项需重启」句都逐字核对。
    function Assert-AFRebootSurfaced([string]$Scenario, $Published, [string[]]$ExpectedRebootIds) {
      $wantIds = @($ExpectedRebootIds | Where-Object { $_ })
      $rebootItems = @(@($script:AFScenario.Real.Items) | Where-Object { $_.Reboot } | ForEach-Object { "$($_.Id)" })
      $rows = @($Published.Data.Results)
      $rowsOfRebootItems = @($rows | Where-Object { $rebootItems -ccontains "$($_.Id)" })
      Assert-True ($rowsOfRebootItems.Count -gt 0 -and @($wantIds | Where-Object { $rebootItems -cnotcontains $_ }).Count -eq 0) `
        "[$Scenario] fixture problem: the reboot expectation [$($wantIds -join ',')] needs rows of catalog items marked Reboot (marked: [$($rebootItems -join ',')]; rows: [$(@($rows | ForEach-Object { "$($_.Id)" }) -join ',')])"
      foreach ($row in $rows) {
        $want = [bool]($wantIds -ccontains "$($row.Id)")
        Assert-True ($row.Reboot -is [bool] -and $row.Reboot -eq $want) `
          ("[$Scenario] the real engine flagged $($row.Id) Reboot=$($row.Reboot) (Ok=$($row.Ok) Changed=$($row.Changed), catalog Reboot=$($rebootItems -ccontains "$($row.Id)")); " +
           "expected Reboot=$($want) because only a successful row that changed the system needs a reboot")
      }
      $names = @($rows | Where-Object { $wantIds -ccontains "$($_.Id)" } | ForEach-Object { "$($_.Name)" })
      $asked = @($script:AFRebootAsked)
      Assert-True ($(if ($names.Count -gt 0) { $asked.Count -eq 1 -and $asked[0] -ceq ($names -join '|') } else { $asked.Count -eq 0 })) `
        ("[$Scenario] the GUI's reboot prompt was shown $($asked.Count) time(s) for [$($asked -join ' / ')]; " +
         "expected $(if ($names.Count -gt 0) { "once for [$($names -join '|')]" } else { 'none' }) (only the rows the engine flagged Reboot)")
      $guiReboot = @($script:AFLog | Where-Object { $_.Contains('个成功项需重启电脑后完全生效') })
      $wantGui = @(if ($names.Count -gt 0) { "以下 $($names.Count) 个成功项需重启电脑后完全生效：$($names -join '、')。" })
      Assert-True (($guiReboot -join ' || ') -ceq ($wantGui -join ' || ')) `
        "[$Scenario] the GUI log's reboot line was [$($guiReboot -join ' || ')]; expected [$($wantGui -join ' || ')]"
      $cliReboot = @(Get-AFCliOutput | Where-Object { $_.Contains('个成功项需重启电脑后完全生效') })
      $wantCli = @(if ($names.Count -gt 0) { "提示：以下 $($names.Count) 个成功项需重启电脑后完全生效——$($names -join '、')。" })
      Assert-True (($cliReboot -join ' || ') -ceq ($wantCli -join ' || ')) `
        "[$Scenario] the engine's CLI -Apply reboot hint was [$($cliReboot -join ' || ')]; expected [$($wantCli -join ' || ')]"
    }
    # 汇总如何呈现（复攻二 G12）：被截断的行 Ok=False、Changed 可真可假。界面日志的「执行完成：共 N 项 — X 成功、Y 失败、Z 跳过。」、
    # 进度区最后的完成度文字（带失败项名）、子进程里生产命令行渲染的同一句汇总，都按场景写明的计数逐字核对。
    # 失败项名按引擎结果顺序（$FailedNames 照场景写明的顺序）：S30 的失败项按顺序不是字母序，排过序再列会在那里红。
    function Assert-AFSummarySurfaced([string]$Scenario, [int]$Ok, [int]$Fail, [int]$Skip, [string[]]$FailedNames) {
      $rowCount = @($script:AFReply.Results).Count
      $failNames = @($FailedNames | Where-Object { $_ })
      $unmatched = @($failNames | Where-Object { $n = $_; @($script:AFReply.Results | Where-Object { "$($_.Name)" -ceq $n }).Count -ne 1 })
      Assert-True ($rowCount -gt 0 -and ($Ok + $Fail + $Skip) -eq $rowCount -and $failNames.Count -eq $Fail -and $unmatched.Count -eq 0) `
        "[$Scenario] fixture problem: the summary expectation ($Ok ok / $Fail failed [$($failNames -join '、')] / $Skip skipped) does not add up to the $rowCount rows the handler received"
      $line = "执行完成：共 $rowCount 项 — $Ok 成功、$Fail 失败、$Skip 跳过。"
      Assert-True (@($script:AFLog | Where-Object { $_ -ceq $line }).Count -eq 1) `
        "[$Scenario] the GUI's completion summary in the log was not exactly '$line' once (summary lines: $(@($script:AFLog | Where-Object { $_.StartsWith('执行完成：', [StringComparison]::Ordinal) }) -join ' || '))"
      $prog = "执行完成：$Ok 成功 / $Fail 失败 / $Skip 跳过$(if ($Fail -gt 0) { " —— 失败：$($failNames -join '、')" })"
      Assert-True ("$($script:AFLastProgText)" -ceq $prog) `
        "[$Scenario] the GUI's progress text after the run was '$($script:AFLastProgText)'; expected '$prog'"
      # 日志里的失败清单（复攻四 N07）：抬头「以下 N 项失败，…」的 N 是失败行数、恰好一次，紧跟着恰好是这 N 行「  [失败] 项名 — 文案」，
      # 按引擎结果顺序，之后不再有「  [失败] 」行；没有失败行时抬头与清单都不出现（S29）。
      $failHeader = "以下 $Fail 项失败，请把日志原文反馈或运行 scripts\diagnose.ps1 排查："
      $headerAt = @(for ($i = 0; $i -lt $script:AFLog.Count; $i++) {
        if ($script:AFLog[$i].StartsWith('以下 ', [StringComparison]::Ordinal) -and $script:AFLog[$i].Contains(' 项失败，')) { $i } })
      $headerLines = @($headerAt | ForEach-Object { $script:AFLog[$_] })
      $listedAll = @($script:AFLog | Where-Object { $_.StartsWith('  [失败] ', [StringComparison]::Ordinal) })
      if ($Fail -gt 0) {
        Assert-True ($headerAt.Count -eq 1 -and $headerLines[0] -ceq $failHeader) `
          "[$Scenario] the GUI's failure-list header was [$($headerLines -join ' || ')]; expected exactly '$failHeader' once"
        $wantBlock = @(foreach ($n in $failNames) {
          "  [失败] $n — $(@($script:AFReply.Results | Where-Object { "$($_.Name)" -ceq $n })[0].Msg)" })
        $block = @($script:AFLog | Select-Object -Skip ($headerAt[0] + 1) -First $Fail)
        Assert-True (($block -join ' || ') -ceq ($wantBlock -join ' || ') -and $listedAll.Count -eq $Fail) `
          ("[$Scenario] the GUI's failure list under the header was [$($block -join ' || ')] ($($listedAll.Count) '  [失败] ' line(s) in the log); " +
           "expected exactly [$($wantBlock -join ' || ')] in engine order")
      } else {
        Assert-True ($headerAt.Count -eq 0 -and $listedAll.Count -eq 0) `
          "[$Scenario] the GUI logged a failure list although no row failed: [$(@($headerLines + $listedAll) -join ' || ')]"
      }
      $cli = @(Get-AFCliOutput)
      Assert-True (@($cli | Where-Object { $_ -ceq $line }).Count -eq 1) `
        "[$Scenario] the engine's CLI -Apply summary was not exactly '$line' once (CLI summary lines: $(@($cli | Where-Object { $_.StartsWith('执行完成：', [StringComparison]::Ordinal) }) -join ' || '))"
      # 逐行结果的先后（复攻四之后补）：界面逐项实时日志「[标签] 项名 — 文案」与命令行逐行结果「  [标签] 项名 — 文案」各自按出现顺序，
      # 必须恰好是引擎结果行的顺序（每行恰好一次、逐字已由 Assert-AFRowSurfaced 核对）。S30 的引擎顺序不是字母序，按项名排过序再列会在那里红。
      $rows = @($script:AFReply.Results)
      $rowNames = @($rows | ForEach-Object { "$($_.Name)" })
      $wantLive = @($rows | ForEach-Object {
        "$(if ($_.Attention) { '[提示]' } elseif ($_.Ok) { '[成功]' } elseif ($_.Skipped) { '[跳过]' } else { '[失败]' }) $($_.Name) — $($_.Msg)" })
      $liveOrder = @($script:AFLog | Where-Object { $wantLive -ccontains $_ } | ForEach-Object { $rowNames[[array]::IndexOf($wantLive, $_)] })
      Assert-True (($liveOrder -join '|') -ceq ($rowNames -join '|')) `
        "[$Scenario] the GUI's per-item log listed the rows in the order [$($liveOrder -join '|')]; expected the engine's row order [$($rowNames -join '|')]"
      $wantCliRows = @($wantLive | ForEach-Object { "  $_" })
      $cliOrder = @($cli | Where-Object { $wantCliRows -ccontains $_ } | ForEach-Object { $rowNames[[array]::IndexOf($wantCliRows, $_)] })
      Assert-True (($cliOrder -join '|') -ceq ($rowNames -join '|')) `
        "[$Scenario] the engine's CLI -Apply listed the rows in the order [$($cliOrder -join '|')]; expected the engine's row order [$($rowNames -join '|')]"
    }
    # 界面如何呈现这一行：处理器经生产 Update-ApplyProgress 落一条实时日志，失败行另在汇总的失败清单里再列一次。
    # 两处都必须逐字是引擎文案（整行 -ceq），界面侧截断或改写都会在这里红。
    # 标签（复攻五 V52/V53）：体检 [提示]、Ok [成功]、Ok=False 且 Skipped（通用 Ops 分支「本机不满足此项前提 / 未找到游戏路径，已跳过」）[跳过]、
    # 其余 [失败]——此前只会写 [成功]/[失败]，对跳过行用不上。只有 [失败] 行进汇总的失败清单，其余各行一次都不许出现在里面（复攻五 V09）。
    function Assert-AFRowSurfaced([string]$Scenario, $Row) {
      $near = @($script:AFLog | Where-Object { $_.Contains("$($Row.Name) — ") }) -join ' || '
      $tag = $(if ($Row.Attention) { '[提示]' } elseif ($Row.Ok) { '[成功]' } elseif ($Row.Skipped) { '[跳过]' } else { '[失败]' })
      $live = "$tag $($Row.Name) — $($Row.Msg)"
      Assert-True (@($script:AFLog | Where-Object { $_ -ceq $live }).Count -eq 1) `
        "[$Scenario] the GUI's per-item progress log did not show the engine's row for $($Row.Id) verbatim exactly once (expected '$live'; log: $near)"
      $listed = "  [失败] $($Row.Name) — $($Row.Msg)"
      $listedCount = @($script:AFLog | Where-Object { $_ -ceq $listed }).Count
      if ($tag -ceq '[失败]') {
        Assert-True ($listedCount -eq 1) `
          "[$Scenario] the GUI's failure list did not repeat the engine's message for $($Row.Id) verbatim exactly once (expected '$listed'; log: $near)"
      } else {
        Assert-True ($listedCount -eq 0) `
          "[$Scenario] the GUI's failure list listed $($Row.Id) $listedCount time(s) although its row is $tag, not a failure (Ok=$($Row.Ok) Skipped=$($Row.Skipped) Attention=$($Row.Attention); log: $near)"
      }
      # 命令行呈现（复攻二 L01）：同一行经引擎入口分发里生产的 elseif ($Apply) 分支打印（真实结果对象，未经 IPC），
      # 也必须逐字带出引擎文案——截断到第一个「：」会把每条子操作原因连同备份落盘错误一起丢掉。
      $cli = @(Get-AFCliOutput)
      Assert-True ($cli.Count -gt 0 -and $cli[0] -ceq 'af-cli-recorder-armed') `
        "[$Scenario] fixture problem: the engine child's Write-Output recorder was not armed before the real dispatch (recorded $($cli.Count) line(s))"
      $cliLine = "  $tag $($Row.Name) — $($Row.Msg)"
      Assert-True (@($cli | Where-Object { $_ -ceq $cliLine }).Count -eq 1) `
        "[$Scenario] the engine's CLI -Apply output did not show the row for $($Row.Id) verbatim exactly once (expected '$cliLine'; CLI lines: $(@($cli | Where-Object { $_.Contains("$($Row.Name) — ") }) -join ' || '))"
    }

    # S14：第一项的第一个子操作写 prepared 备份就落盘失败，其后还有两个子操作；第二项整项都不该开始。
    # 什么都没写（Changed=False），文案必须是「失败（备份无法落盘，其余 2 项未执行）：op1：…」。
    # 复攻三起，S14–S31 里被截断的项在目录里都标「需重启」（同生产多数系统项）：Reboot 只给成功项，这些行一律 Reboot=False、不弹重启提醒。
    # 93713da：本轮第一次 prepared 写入就失败，盘上的 .pending.json 一条撤销记录都没有——不交回 Backup、删掉空文件，
    # 界面与命令行都不能说「备份已保存」「已抢救出部分备份」。文案断言在前：修复前的引擎先按「其余已写入」红。
    $s14Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1' -PrepareFails), (New-AFRealOp 'op2'), (New-AFRealOp 'op3')) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1')) -Reboot)
    )
    Set-AFEngineRealScenario $s14Items 'fixture disk full'
    Invoke-AFApplyClick 'S14' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S14' 3 @('fixture-sys') @('fixture-sys/op1') @()
    $row = Assert-AFCutShortRow 'S14' $pub $s14Items[0] 0 2 $false
    Assert-AFRowSurfaced 'S14' $row
    Assert-AFBackupFailureSurfaced 'S14' $pub @()
    Assert-AFSalvageSurfaced 'S14' $pub @()
    Assert-AFSummarySurfaced 'S14' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S14' $pub @()
    Assert-AFRouting 'S14' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S14' @('fixture-sys', 'fixture-sys2')

    # S15：op1 写入并记账，op2 写 prepared 备份时落盘失败，op3 从未尝试——
    # 「部分子项写入失败（1 项已完成，其后 1 项因备份无法落盘未执行）：op2：…」。
    $s15Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2' -PrepareFails), (New-AFRealOp 'op3')) -Reboot)
    )
    Set-AFEngineRealScenario $s15Items 'fixture disk full'
    Invoke-AFApplyClick 'S15' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S15' 3 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op2') @('fixture-sys/op1')
    $row = Assert-AFCutShortRow 'S15' $pub $s15Items[0] 1 1 $true
    Assert-AFRowSurfaced 'S15' $row
    Assert-AFBackupFailureSurfaced 'S15' $pub @('fixture system item')
    # 93713da 的另一面：op1 的撤销记录已经落盘（prepared → applied），抢救出的 .pending.json 必须照常交回并如实告知。
    Assert-AFSalvageSurfaced 'S15' $pub @('fixture-sys:reg:op1=applied')
    Assert-AFSummarySurfaced 'S15' 0 1 0 @('fixture system item')
    # X03：这一行改过系统（Changed=True）、目录标了需重启，但它是失败项——不是「成功项需重启」。
    Assert-AFRebootSurfaced 'S15' $pub @()
    Assert-AFRouting 'S15' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S15' @('fixture-sys')

    # S16：标 applied 那一次落盘失败——op2 的系统写入已经发生、applied 状态却写不进备份，op3、op4 从未尝试。
    # op2 按失败计（回滚记录不完整，项名进 UnrecordedNames），所以是「1 项已完成，其后 2 项…未执行」，系统写入是 op1、op2 两笔。
    $s16Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2' -AppliedFails), (New-AFRealOp 'op3'), (New-AFRealOp 'op4')) -Reboot)
    )
    Set-AFEngineRealScenario $s16Items 'fixture disk full'
    Invoke-AFApplyClick 'S16' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S16' 3 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op2') @('fixture-sys/op1', 'fixture-sys/op2')
    $row = Assert-AFCutShortRow 'S16' $pub $s16Items[0] 1 2 $true
    Assert-AFRowSurfaced 'S16' $row
    Assert-AFBackupFailureSurfaced 'S16' $pub @('fixture system item')
    # op2 的 prepared 记录已落盘、applied 没写进去：盘上它停在 prepared——正是回滚这笔系统写入要用的那条。
    Assert-AFSalvageSurfaced 'S16' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys:reg:op2=prepared')
    Assert-AFSummarySurfaced 'S16' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S16' $pub @()
    Assert-AFRouting 'S16' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S16' @('fixture-sys')

    # S26（复攻二 / 三的 P5 形态，93713da）：落盘失败撞在**最后一个**子操作上——op1 已是目标值（生产 Invoke-ApplyOp 返回
    # 「无需修改」附注，不写备份、不写系统），op2 写 prepared 时落盘失败；没有子操作被跳过（未执行 0），14920d9 的「未执行」分支不适用。
    # 真部分失败的文案只能是「部分子项写入失败（其余 1 项已完成）：op2：备份 prepared 状态持久化失败：…」，绝不能说「其余已写入」：
    # 系统一笔没改（Changed=False、UnrecordedNames 为空、弹窗列「（无）」）。一条撤销记录也没落盘：不交回 Backup、删掉空的 .pending.json。
    # 放在 S17 之前：只修了抢救、没改真部分失败文案的引擎在这里按「其余已写入」红，而不是先撞上 S17 对照里的新文案。
    $s26Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1' -AtTarget), (New-AFRealOp 'op2' -PrepareFails)) -Reboot)
    )
    Set-AFEngineRealScenario $s26Items 'fixture disk full'
    Invoke-AFApplyClick 'S26' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S26' 3 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op2') @()
    $row = Assert-AFCutShortRow 'S26' $pub $s26Items[0] 1 0 $false
    Assert-AFRowSurfaced 'S26' $row
    Assert-AFBackupFailureSurfaced 'S26' $pub @()
    Assert-AFSalvageSurfaced 'S26' $pub @()
    Assert-AFSummarySurfaced 'S26' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S26' $pub @()
    Assert-AFRouting 'S26' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S26' @('fixture-sys')

    # S17（对照）：备份始终正常，每个子操作都尝试过。真部分失败是「部分子项写入失败（其余 N 项已完成）：…」（93713da 起
    # 不再说「其余已写入」：已完成的子项可能是已达标或本机没有的可选电源项，见 S26），这里 op1、op3 都写入了，N = 2；
    # 全部失败是「失败：…」，全部成功是「已写入」。「未执行」按失败数算、尝试数跨项累加之类的计数错误，
    # 会把这里的真部分失败 / 全成功误报成「因备份无法落盘未执行」。
    # 重启标注：真部分失败（改过系统）与全部失败两项标了需重启，都不是成功项；全成功的 fixture-sys3 目录没标，也不能被标。
    $s17Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1'), (New-AFRealOp 'op2' 'fixture op2 denied'), (New-AFRealOp 'op3')) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1' 'fixture op1 denied'), (New-AFRealOp 'op2' 'fixture op2 denied')) -Reboot),
      (New-AFRealItem 'fixture-sys3' 'fixture system item 3' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2')))
    )
    Set-AFEngineRealScenario $s17Items $null
    Invoke-AFApplyClick 'S17' 'none' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') $true -RealProgress
    $pub = Assert-AFRealBatch 'S17' 2 @('fixture-sys', 'fixture-sys2', 'fixture-sys3') `
      @('fixture-sys/op1', 'fixture-sys/op2', 'fixture-sys/op3', 'fixture-sys2/op1', 'fixture-sys2/op2', 'fixture-sys3/op1', 'fixture-sys3/op2') `
      @('fixture-sys/op1', 'fixture-sys/op3', 'fixture-sys3/op1', 'fixture-sys3/op2')
    Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY' -and -not $pub.Data.BackupError) `
      "[S17] a batch with an intact backup showed dialogs [$(Get-AFDialogTitles)] / engine BackupError '$($pub.Data.BackupError)'; expected only the confirmation and no BackupError"
    foreach ($want in @(
        [pscustomobject]@{ Id = 'fixture-sys';  Ok = $false; Changed = $true;  Msg = '部分子项写入失败（其余 2 项已完成）：op2：fixture op2 denied' },
        [pscustomobject]@{ Id = 'fixture-sys2'; Ok = $false; Changed = $false; Msg = '失败：op1：fixture op1 denied；op2：fixture op2 denied' },
        [pscustomobject]@{ Id = 'fixture-sys3'; Ok = $true;  Changed = $true;  Msg = '已写入' })) {
      $row = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq $want.Id })[0]
      Assert-True ($row.Ok -eq $want.Ok -and $row.Changed -eq $want.Changed -and $row.Skipped -eq $false -and "$($row.Msg)" -ceq $want.Msg) `
        ("[S17] $($want.Id) ran every sub-operation with the backup intact, so its row must be Ok=$($want.Ok) Changed=$($want.Changed) " +
         "'$($want.Msg)'; got Ok=$($row.Ok) Changed=$($row.Changed) Skipped=$($row.Skipped) '$($row.Msg)'")
      Assert-AFRowSurfaced 'S17' $row
    }
    Assert-AFSummarySurfaced 'S17' 1 2 0 @('fixture system item', 'fixture system item 2')
    Assert-AFNoBackupFailureSurfaced 'S17' $pub
    # 复攻五 V01–V03、V54：备份完好的批次写 complete、改名、交回 backup-fixture.json。系统写入被拒的子操作，prepared 记录先于写入落盘，停在 prepared。
    Assert-AFCompleteBackupSurfaced 'S17' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys:reg:op2=prepared', 'fixture-sys:reg:op3=applied',
      'fixture-sys2:reg:op1=prepared', 'fixture-sys2:reg:op2=prepared', 'fixture-sys3:reg:op1=applied', 'fixture-sys3:reg:op2=applied')
    Assert-AFRebootSurfaced 'S17' $pub @()
    Assert-AFRouting 'S17' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') @()
    Assert-AFEngineChildSaw 'S17' @('fixture-sys', 'fixture-sys2', 'fixture-sys3')

    # S18（复攻 M01/M03/M04）：同一项里先有子操作被系统拒绝写入，之后才遇到备份落盘失败。op1 的 prepared 备份已记下、
    # 系统写入被拒；op2 写 prepared 时落盘失败；op3 从未尝试。一个子操作都没完成：
    # 「失败（备份无法落盘，其余 1 项未执行）：op1：fixture op1 denied；op2：…fixture disk full」，两条原因按尝试顺序都在。
    # S14–S16 每个被截断的项只有一条失败，「已完成 = 尝试数 − 1」「只报最后一条错误」「尝试过两个以上就算部分完成」在那里都与正确公式重合。
    $s18Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1' 'fixture op1 denied'), (New-AFRealOp 'op2' -PrepareFails), (New-AFRealOp 'op3')) -Reboot)
    )
    Set-AFEngineRealScenario $s18Items 'fixture disk full'
    Invoke-AFApplyClick 'S18' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S18' 3 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op2') @()
    $row = Assert-AFCutShortRow 'S18' $pub $s18Items[0] 0 1 $false
    Assert-AFRowSurfaced 'S18' $row
    Assert-AFBackupFailureSurfaced 'S18' $pub @()
    # 系统一笔没改，但 op1 的 prepared 记录在系统写入被拒之前已经落盘：按「真正落过盘的记录」判断，照样交回这份备份。
    Assert-AFSalvageSurfaced 'S18' $pub @('fixture-sys:reg:op1=prepared')
    Assert-AFSummarySurfaced 'S18' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S18' $pub @()
    Assert-AFRouting 'S18' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S18' @('fixture-sys')

    # S19（复攻 M01/M02）：生产 Invoke-ApplyOp 遇到已是目标值的子操作直接返回「无需修改：…」附注，不写备份也不写系统——
    # 从这里起「实际尝试的子操作数」与「备份条目数」（$journal.CurrentOpIndex）分叉。op1 已达标、op2 写入、op3 被系统拒绝、
    # op4 写 prepared 时落盘失败、op5 从未尝试：已完成 2（op1、op2）、未执行 1——
    # 「部分子项写入失败（2 项已完成，其后 1 项因备份无法落盘未执行）：op3：fixture op3 denied；op4：…」。
    $s19Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1' -AtTarget), (New-AFRealOp 'op2'),
        (New-AFRealOp 'op3' 'fixture op3 denied'), (New-AFRealOp 'op4' -PrepareFails), (New-AFRealOp 'op5')) -Reboot)
    )
    Set-AFEngineRealScenario $s19Items 'fixture disk full'
    Invoke-AFApplyClick 'S19' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S19' 3 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op2', 'fixture-sys/op3', 'fixture-sys/op4') @('fixture-sys/op2')
    $row = Assert-AFCutShortRow 'S19' $pub $s19Items[0] 2 1 $true
    Assert-AFRowSurfaced 'S19' $row
    Assert-AFBackupFailureSurfaced 'S19' $pub @('fixture system item')
    Assert-AFSalvageSurfaced 'S19' $pub @('fixture-sys:reg:op2=applied', 'fixture-sys:reg:op3=prepared')
    Assert-AFSummarySurfaced 'S19' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S19' $pub @()
    Assert-AFRouting 'S19' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S19' @('fixture-sys')

    # S20（复攻 M02）：隐藏的电源设置一个子操作写两条备份（先备份并解除隐藏的 Attributes，再备份并写值）——备份条目数多于尝试数。
    # 第一项 op1 已达标、op2 写入，全部成功：文案带生产的附注「已写入（无需修改：op1 已是目标状态）」。
    # 第二项 op1 是隐藏电源设置（两次系统写入），op2 写 prepared 时落盘失败，op3 从未尝试：
    # 「部分子项写入失败（1 项已完成，其后 1 项因备份无法落盘未执行）：op2：…」。
    # 重启标注（复攻三 X03）：两项目录都标需重启——成功且改过系统的 fixture-sys 要弹一次提醒，截断的 fixture-sys2 不能进名单。
    $s20Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1' -AtTarget), (New-AFRealOp 'op2')) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1' -HiddenPowerSetting), (New-AFRealOp 'op2' -PrepareFails), (New-AFRealOp 'op3')) -Reboot)
    )
    Set-AFEngineRealScenario $s20Items 'fixture disk full'
    Invoke-AFApplyClick 'S20' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S20' 3 @('fixture-sys', 'fixture-sys2') `
      @('fixture-sys/op1', 'fixture-sys/op2', 'fixture-sys2/op1', 'fixture-sys2/op2') `
      @('fixture-sys/op2', 'fixture-sys2/op1(unhide)', 'fixture-sys2/op1')
    # 夹具锚点：抢救出的 pending 备份里，隐藏电源设置那一个子操作确实留下了两条已生效的记录（Attributes 与值本身）。
    $s20Salvaged = $(if (Test-Path -LiteralPath $pendingBackup) { [IO.File]::ReadAllText($pendingBackup) | ConvertFrom-Json })
    $s20Hidden = @($(if ($s20Salvaged) { @($s20Salvaged.Ops) | Where-Object { "$($_.ItemId)" -ceq 'fixture-sys2' -and "$($_.Status)" -ceq 'applied' } }))
    Assert-True ($s20Hidden.Count -eq 2 -and (@($s20Hidden | ForEach-Object { "$($_.Kind)" }) -join ',') -ceq 'reg,pcfg') `
      "[S20] fixture problem: the hidden power setting fixture-sys2/op1 did not leave two applied backup records (Attributes, then the value) in the salvaged backup: [$(@($s20Hidden | ForEach-Object { "$($_.Kind):$($_.Name)$($_.Setting)" }) -join ',')]"
    $s20Ok = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq 'fixture-sys' })[0]
    Assert-True ($s20Ok.Ok -eq $true -and $s20Ok.Changed -eq $true -and $s20Ok.Skipped -eq $false -and
      "$($s20Ok.Msg)" -ceq '已写入（无需修改：op1 已是目标状态）') `
      ("[S20] fixture-sys ran both sub-operations before the backup failure (op1 already at target, op2 written), so its row must be " +
       "Ok=True Changed=True '已写入（无需修改：op1 已是目标状态）'; got Ok=$($s20Ok.Ok) Changed=$($s20Ok.Changed) Skipped=$($s20Ok.Skipped) '$($s20Ok.Msg)'")
    Assert-AFRowSurfaced 'S20' $s20Ok
    $row = Assert-AFCutShortRow 'S20' $pub $s20Items[1] 1 1 $true
    Assert-AFRowSurfaced 'S20' $row
    Assert-AFBackupFailureSurfaced 'S20' $pub @('fixture system item', 'fixture system item 2')
    Assert-AFSalvageSurfaced 'S20' $pub @('fixture-sys:reg:op2=applied', 'fixture-sys2:reg:Attributes=applied', 'fixture-sys2:pcfg:op1=applied')
    Assert-AFSummarySurfaced 'S20' 1 1 0 @('fixture system item 2')
    Assert-AFRebootSurfaced 'S20' $pub @('fixture-sys')
    Assert-AFRouting 'S20' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S20' @('fixture-sys', 'fixture-sys2')

    # S21（对照，复攻 M02/M05）：备份始终正常，生产目录里另外两种形状。
    # fixture-sys 的两个子操作都已是目标值：生产 Invoke-ApplyOp 一条备份都不写，整项 Ok、Skipped、「无需修改：所有设置已是目标状态」。
    # fixture-sys2 / fixture-sys3 的 Ops 照生产 gpu-pstate-lock 的 $(if (…) { @(@{…}) }) 构造，是一个裸 Hashtable
    # （.Count 是键数 5，@(…).Count 才是 1）：写入成功是「已写入」，系统写入被拒是「失败：op1：…」。
    # 重启标注（复攻三 X03）：三项目录都标需重启——只有写入成功的 fixture-sys2 进名单；已达标（Ok、没改动）与写入被拒的都不进。
    $s21Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1' -AtTarget), (New-AFRealOp 'op2' -AtTarget)) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1')) -ScalarOps -Reboot),
      (New-AFRealItem 'fixture-sys3' 'fixture system item 3' @((New-AFRealOp 'op1' 'fixture op1 denied')) -ScalarOps -Reboot)
    )
    Set-AFEngineRealScenario $s21Items $null
    Invoke-AFApplyClick 'S21' 'none' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') $true -RealProgress
    $pub = Assert-AFRealBatch 'S21' 2 @('fixture-sys', 'fixture-sys2', 'fixture-sys3') `
      @('fixture-sys/op1', 'fixture-sys/op2', 'fixture-sys2/op1', 'fixture-sys3/op1') @('fixture-sys2/op1')
    Assert-True ((@(Get-AFOpsShapes) -join ',') -ceq 'fixture-sys=Object[],fixture-sys2=Hashtable,fixture-sys3=Hashtable') `
      "[S21] fixture problem: the engine child's catalog did not build the production Ops shapes (expected an array, then two bare Hashtables): [$(@(Get-AFOpsShapes) -join ',')]"
    Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY' -and -not $pub.Data.BackupError) `
      "[S21] a batch with an intact backup showed dialogs [$(Get-AFDialogTitles)] / engine BackupError '$($pub.Data.BackupError)'; expected only the confirmation and no BackupError"
    foreach ($want in @(
        [pscustomobject]@{ Id = 'fixture-sys';  Shape = 'two sub-operations already at target'; Ok = $true;  Skipped = $true;  Changed = $false; Msg = '无需修改：所有设置已是目标状态' },
        [pscustomobject]@{ Id = 'fixture-sys2'; Shape = 'bare-Hashtable Ops, written';           Ok = $true;  Skipped = $false; Changed = $true;  Msg = '已写入' },
        [pscustomobject]@{ Id = 'fixture-sys3'; Shape = 'bare-Hashtable Ops, write refused';     Ok = $false; Skipped = $false; Changed = $false; Msg = '失败：op1：fixture op1 denied' })) {
      $row = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq $want.Id })[0]
      Assert-True ($row.Ok -eq $want.Ok -and $row.Skipped -eq $want.Skipped -and $row.Changed -eq $want.Changed -and "$($row.Msg)" -ceq $want.Msg) `
        ("[S21] $($want.Id) ($($want.Shape)) ran every sub-operation with the backup intact, so its row must be Ok=$($want.Ok) " +
         "Skipped=$($want.Skipped) Changed=$($want.Changed) '$($want.Msg)'; got Ok=$($row.Ok) Skipped=$($row.Skipped) Changed=$($row.Changed) '$($row.Msg)'")
      Assert-AFRowSurfaced 'S21' $row
    }
    # 已达标整项是 Ok=True、Skipped=True：生产汇总按 Ok 计成功（跳过只数 Ok=False 的行）。
    Assert-AFSummarySurfaced 'S21' 2 1 0 @('fixture system item 3')
    Assert-AFNoBackupFailureSurfaced 'S21' $pub
    # 已达标的两个子操作不写备份；裸 Hashtable 的两项各一条（写入成功的 applied、被拒的停在 prepared）。
    Assert-AFCompleteBackupSurfaced 'S21' $pub @('fixture-sys2:reg:op1=applied', 'fixture-sys3:reg:op1=prepared')
    Assert-AFRebootSurfaced 'S21' $pub @('fixture-sys2')
    Assert-AFRouting 'S21' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') @()
    Assert-AFEngineChildSaw 'S21' @('fixture-sys', 'fixture-sys2', 'fixture-sys3')

    # S22（复攻二 A01/A02）：失败子操作多（4 条系统拒绝 + 最后 1 条备份落盘失败）、名字按尝试顺序排列时**不是**有序的。
    # 此前每个场景都把子操作按 op1..opN 命名（尝试顺序 = 排序顺序），截断的项最多两条失败：尾部按字母排序 / 去重，
    # 或只留前 2–3 条原因（恰好丢掉让循环停下的落盘错误），全都照绿。
    # 尝试顺序 zeta、beta（写入）、alpha、mid、delta、kappa（prepared 落盘失败），omega 从未尝试：已完成 1、未执行 1——
    # 「部分子项写入失败（1 项已完成，其后 1 项因备份无法落盘未执行）：zeta：…；alpha：…；mid：…；delta：…；kappa：…fixture disk full」。
    $s22Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'zeta' 'fixture zeta denied'), (New-AFRealOp 'beta'),
        (New-AFRealOp 'alpha' 'fixture alpha denied'), (New-AFRealOp 'mid' 'fixture mid denied'), (New-AFRealOp 'delta' 'fixture delta denied'),
        (New-AFRealOp 'kappa' -PrepareFails), (New-AFRealOp 'omega')) -Reboot)
    )
    # 夹具锚点：失败子操作按尝试顺序既不是升序也不是降序，而且至少 5 条、落盘失败排在最后。
    $s22Failed = @(@($s22Items[0].Ops) | Where-Object { $_.WriteError -or $_.PrepareFails } | ForEach-Object { "$($_.Name)" })
    Assert-True ($s22Failed.Count -ge 5 -and ($s22Failed -join ',') -cne (@($s22Failed | Sort-Object) -join ',') -and
      ($s22Failed -join ',') -cne (@($s22Failed | Sort-Object -Descending) -join ',') -and $s22Failed[$s22Failed.Count - 1] -ceq 'kappa') `
      "[S22] fixture problem: the failing sub-operations [$($s22Failed -join ',')] must be at least 5, in an unsorted attempt order, with the backup failure (kappa) last"
    Set-AFEngineRealScenario $s22Items 'fixture disk full'
    Invoke-AFApplyClick 'S22' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S22' 3 @('fixture-sys') `
      @('fixture-sys/zeta', 'fixture-sys/beta', 'fixture-sys/alpha', 'fixture-sys/mid', 'fixture-sys/delta', 'fixture-sys/kappa') @('fixture-sys/beta')
    $row = Assert-AFCutShortRow 'S22' $pub $s22Items[0] 1 1 $true
    Assert-AFRowSurfaced 'S22' $row
    Assert-AFBackupFailureSurfaced 'S22' $pub @('fixture system item')
    Assert-AFSalvageSurfaced 'S22' $pub @('fixture-sys:reg:zeta=prepared', 'fixture-sys:reg:beta=applied', 'fixture-sys:reg:alpha=prepared',
      'fixture-sys:reg:mid=prepared', 'fixture-sys:reg:delta=prepared')
    Assert-AFSummarySurfaced 'S22' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S22' $pub @()
    Assert-AFRouting 'S22' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S22' @('fixture-sys')

    # S23（复攻二 A03/A04）：「已完成」与「这一项改动了系统」脱钩——截断前完成的唯一子操作本来就已是目标值（无需修改，
    # 不写备份也不写系统），op2 写 prepared 时落盘失败，op3 从未尝试。已完成 1、未执行 1，但**系统一笔都没写**：
    # Changed=False、UnrecordedNames 为空、弹窗列「（无）」。此前凡是 done > 0 的截断项都真写过系统，
    # 于是「按有没有 applied 记录挑头部」「done > 0 就当改动过」都与正确实现重合。
    $s23Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1' -AtTarget), (New-AFRealOp 'op2' -PrepareFails), (New-AFRealOp 'op3')) -Reboot)
    )
    Set-AFEngineRealScenario $s23Items 'fixture disk full'
    Invoke-AFApplyClick 'S23' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S23' 3 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op2') @()
    $row = Assert-AFCutShortRow 'S23' $pub $s23Items[0] 1 1 $false
    Assert-AFRowSurfaced 'S23' $row
    Assert-AFBackupFailureSurfaced 'S23' $pub @()
    # 已达标的 op1 不写备份：一条撤销记录都没落盘，不交回 Backup（93713da）。
    Assert-AFSalvageSurfaced 'S23' $pub @()
    Assert-AFSummarySurfaced 'S23' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S23' $pub @()
    Assert-AFRouting 'S23' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S23' @('fixture-sys')

    # S24（复攻二 A03）：反方向脱钩——第一个子操作的系统写入已经发生，标 applied 时落盘失败（按失败计），op2、op3 从未尝试。
    # 已完成 0、未执行 2，但系统**确实被改了**：Changed=True、项名进 UnrecordedNames。
    # 「失败（备份无法落盘，其余 2 项未执行）：op1：备份 applied 状态持久化失败：fixture disk full」——绝不能是「0 项已完成」。
    $s24Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1' -AppliedFails), (New-AFRealOp 'op2'), (New-AFRealOp 'op3')) -Reboot)
    )
    Set-AFEngineRealScenario $s24Items 'fixture disk full'
    Invoke-AFApplyClick 'S24' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S24' 3 @('fixture-sys') @('fixture-sys/op1') @('fixture-sys/op1')
    $row = Assert-AFCutShortRow 'S24' $pub $s24Items[0] 0 2 $true
    Assert-AFRowSurfaced 'S24' $row
    Assert-AFBackupFailureSurfaced 'S24' $pub @('fixture system item')
    # 已完成 0，但 op1 的 prepared 记录已落盘、系统也已写入：这份 .pending.json 是回滚 op1 的唯一凭据，必须交回。
    Assert-AFSalvageSurfaced 'S24' $pub @('fixture-sys:reg:op1=prepared')
    Assert-AFSummarySurfaced 'S24' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S24' $pub @()
    Assert-AFRouting 'S24' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S24' @('fixture-sys')

    # S25（复攻三 X04/X05）：照生产 power-tuning 的形状——先是一个 Optional 的电源子操作，本机 CPU 不支持
    # （生产 Invoke-ApplyOp 返回「跳过（本机 CPU 无此电源项）：…」附注，不写备份也不写系统，算尝试过、没失败），
    # 其后的 reg 子操作都带与值名不同的人话 Label：valB 写入、valE 被系统拒绝、valC 写 prepared 时落盘失败、valD 从未尝试。
    # 已完成 = 尝试 4 − 失败 2 = 2（跳过的那个也算处理完了：已完成 + 失败 + 未执行 = 5 个子操作一个不少），未执行 1——
    # 「部分子项写入失败（2 项已完成，其后 1 项因备份无法落盘未执行）：fixture label E：fixture valE denied；fixture label C：备份 prepared 状态持久化失败：fixture disk full」。
    # 此前没有任何场景返回「跳过」附注（夹具的电源设置一律「本机支持」），reg 子操作也都不带 Label。
    $s25Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @(
        (New-AFRealOp 'optA' -OptionalUnsupportedPowerSetting -Label 'fixture optional power setting'),
        (New-AFRealOp 'valB' -Label 'fixture label B'), (New-AFRealOp 'valE' 'fixture valE denied' -Label 'fixture label E'),
        (New-AFRealOp 'valC' -PrepareFails -Label 'fixture label C'), (New-AFRealOp 'valD' -Label 'fixture label D')) -Reboot)
    )
    # 夹具锚点：每个 reg 子操作的 Label 都与值名不同（否则「Label 优先还是 Name 优先」在这里分不出来）。
    $s25RegOps = @(@($s25Items[0].Ops) | Where-Object { $_.Kind -ceq 'reg' })
    Assert-True ($s25RegOps.Count -eq 4 -and @($s25RegOps | Where-Object { -not $_.Label -or $_.Label -ceq $_.Name }).Count -eq 0) `
      "[S25] fixture problem: every reg sub-operation must carry a Label that differs from its value name"
    Set-AFEngineRealScenario $s25Items 'fixture disk full'
    Invoke-AFApplyClick 'S25' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S25' 3 @('fixture-sys') `
      @('fixture-sys/optA', 'fixture-sys/valB', 'fixture-sys/valE', 'fixture-sys/valC') @('fixture-sys/valB')
    # 夹具锚点：生产 Invoke-ApplyOp 确实问过「本机是否支持 optA」并得到「不支持」——走的是 Optional 跳过分支，而不是写入分支。
    Assert-True ((@(Get-AFPowerProbes) -join ',') -ceq 'fixture-sys/optA=False') `
      "[S25] fixture problem: the optional power setting was not probed exactly once as unsupported: [$(@(Get-AFPowerProbes) -join ',')]"
    $row = Assert-AFCutShortRow 'S25' $pub $s25Items[0] 2 1 $true
    Assert-AFRowSurfaced 'S25' $row
    Assert-AFBackupFailureSurfaced 'S25' $pub @('fixture system item')
    Assert-AFSalvageSurfaced 'S25' $pub @('fixture-sys:reg:valB=applied', 'fixture-sys:reg:valE=prepared')
    Assert-AFSummarySurfaced 'S25' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S25' $pub @()
    Assert-AFRouting 'S25' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S25' @('fixture-sys')

    # S27（93713da，跨项抢救）：第一项两个子操作都写入并记账（成功、需重启），第二项第一个子操作写 prepared 时落盘失败、op2 从未尝试。
    # 失败的这一项自己一条记录都没落盘，但前一项的两条早已在盘上：抢救按整轮真正落过盘的记录判断，必须交回 .pending.json，
    # 并列出成功项为「已生效、备份可能没记全」。S14 / S26 / S23 里失败项是本轮第一个写备份的，「按当前项是否落过盘」与正确实现在那里重合。
    $s27Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1'), (New-AFRealOp 'op2')) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1' -PrepareFails), (New-AFRealOp 'op2')) -Reboot)
    )
    Set-AFEngineRealScenario $s27Items 'fixture disk full'
    Invoke-AFApplyClick 'S27' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S27' 3 @('fixture-sys', 'fixture-sys2') @('fixture-sys/op1', 'fixture-sys/op2', 'fixture-sys2/op1') @('fixture-sys/op1', 'fixture-sys/op2')
    $s27Ok = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq 'fixture-sys' })[0]
    Assert-True ($s27Ok.Ok -eq $true -and $s27Ok.Changed -eq $true -and $s27Ok.Skipped -eq $false -and "$($s27Ok.Msg)" -ceq '已写入') `
      ("[S27] fixture-sys wrote and recorded both sub-operations before the next item's backup failure, so its row must be " +
       "Ok=True Changed=True '已写入'; got Ok=$($s27Ok.Ok) Changed=$($s27Ok.Changed) Skipped=$($s27Ok.Skipped) '$($s27Ok.Msg)'")
    Assert-AFRowSurfaced 'S27' $s27Ok
    $row = Assert-AFCutShortRow 'S27' $pub $s27Items[1] 0 1 $false
    Assert-AFRowSurfaced 'S27' $row
    Assert-AFBackupFailureSurfaced 'S27' $pub @('fixture system item')
    Assert-AFSalvageSurfaced 'S27' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys:reg:op2=applied')
    Assert-AFSummarySurfaced 'S27' 1 1 0 @('fixture system item 2')
    Assert-AFRebootSurfaced 'S27' $pub @('fixture-sys')
    Assert-AFRouting 'S27' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S27' @('fixture-sys', 'fixture-sys2')

    # S28（复攻四 N01–N03）：真部分失败（没有子操作被跳过、已完成 > 0）带**两条**原因。op1 写入；op3 的系统写入被拒；
    # 最后一个子操作 op2 写 prepared 时落盘失败。已完成 1、未执行 0——「部分子项写入失败（其余 1 项已完成）：op3：…；op2：…」，
    # 两条原因按尝试顺序（op3 在前、带阶段词 prepared 的 op2 在后，与字母序相反）。此前走这个分支的场景（S26、S17 的 fixture-sys、S8、S10）
    # 都只有一条原因：只留最后一条 / 第一条、排序去重都与正确实现重合；只留第一条还会把落盘失败那条连同阶段词一起丢掉。
    $s28Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1'), (New-AFRealOp 'op3' 'fixture op3 denied'), (New-AFRealOp 'op2' -PrepareFails)) -Reboot)
    )
    # 夹具锚点：两条失败按尝试顺序不是字母序，落盘失败排在最后。
    $s28Failed = @(@($s28Items[0].Ops) | Where-Object { $_.WriteError -or $_.PrepareFails } | ForEach-Object { "$($_.Name)" })
    Assert-True ($s28Failed.Count -eq 2 -and ($s28Failed -join ',') -cne (@($s28Failed | Sort-Object) -join ',') -and $s28Failed[1] -ceq 'op2') `
      "[S28] fixture problem: the two failing sub-operations [$($s28Failed -join ',')] must be in a non-alphabetical attempt order with the backup failure (op2) last"
    Set-AFEngineRealScenario $s28Items 'fixture disk full'
    Invoke-AFApplyClick 'S28' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S28' 3 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op3', 'fixture-sys/op2') @('fixture-sys/op1')
    $row = Assert-AFCutShortRow 'S28' $pub $s28Items[0] 1 0 $true
    Assert-AFRowSurfaced 'S28' $row
    Assert-AFBackupFailureSurfaced 'S28' $pub @('fixture system item')
    # op3 的 prepared 记录在系统写入被拒之前已落盘；op2 那条没写进去。
    Assert-AFSalvageSurfaced 'S28' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys:reg:op3=prepared')
    Assert-AFSummarySurfaced 'S28' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S28' $pub @()
    Assert-AFRouting 'S28' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S28' @('fixture-sys')

    # S29（复攻四 N04/N25）：每个子操作都写入并记账（备份逐条落盘），收尾把 complete 状态落盘时失败。生产在这一处 catch 里
    # 记下 BackupError（退出码 3），把仍是 pending、记录全为 applied 的 .pending.json 作为 Backup 交回（不改名为 .json），
    # 两项都列为「已生效、备份可能没记全」；两行本身都是成功（已写入），需重启的成功项照常提醒重启。
    # 此前这条路径只有 S9 覆盖，而 S9 的 Data 是手写的：真实引擎在这里不交回备份、或吞掉错误照报 exit 0，都照绿。
    # 每一项都已执行完（独立复核遗留 4）：引擎交回 BackupFailedAfterAllItems，界面严重告警、命令行严重警告与弹窗开头都说
    # 「本轮的优化项都已执行完」，不再说「剩余优化项已中止执行 / 本轮执行已中止」（Assert-AFBackupFailureSurfaced -AfterAllItems 逐字核对）；
    # 本批次没有失败行，只按「有没有失败行」改措辞的实现只在这里红。
    $s29Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1')) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2')))
    )
    Set-AFEngineRealScenario $s29Items 'fixture complete-state write denied' -CompleteFails
    Invoke-AFApplyClick 'S29' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S29' 3 @('fixture-sys', 'fixture-sys2') @('fixture-sys/op1', 'fixture-sys2/op1', 'fixture-sys2/op2') `
      @('fixture-sys/op1', 'fixture-sys2/op1', 'fixture-sys2/op2')
    # 夹具锚点：注入恰好打在收尾那一次写入上（不新增、不改动任何撤销记录的那一次；prepared / applied 写入一次都没失败）。
    $s29Hits = @(Get-AFBackupFailureHits)
    Assert-True ($s29Hits.Count -eq 1 -and $s29Hits[0].StartsWith('complete:', [StringComparison]::Ordinal)) `
      "[S29] fixture problem: the finalization write (the one that adds or changes no undo record) was not injected to fail exactly once: [$($s29Hits -join ',')]"
    # 产品断言（复攻五 V03 的另一面）：收尾那一次写入带的是 complete 状态（注入不再按 State 认收尾，漏设 State 不会让注入落空）。
    Assert-True ($s29Hits[0] -ceq 'complete:State=complete') `
      "[S29] the engine's finalization write carried $($s29Hits[0].Substring('complete:'.Length)); expected State=complete"
    foreach ($s29Id in @('fixture-sys', 'fixture-sys2')) {
      $s29Row = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq $s29Id })[0]
      Assert-True ($s29Row.Ok -eq $true -and $s29Row.Changed -eq $true -and $s29Row.Skipped -eq $false -and "$($s29Row.Msg)" -ceq '已写入') `
        ("[S29] $s29Id wrote and recorded every sub-operation before the complete-state write failed, so its row must be " +
         "Ok=True Changed=True '已写入'; got Ok=$($s29Row.Ok) Changed=$($s29Row.Changed) Skipped=$($s29Row.Skipped) '$($s29Row.Msg)'")
      Assert-AFRowSurfaced 'S29' $s29Row
    }
    Assert-AFBackupFailureSurfaced 'S29' $pub @('fixture system item', 'fixture system item 2') -AfterAllItems
    Assert-AFSalvageSurfaced 'S29' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys2:reg:op1=applied', 'fixture-sys2:reg:op2=applied')
    Assert-AFSummarySurfaced 'S29' 2 0 0 @()
    Assert-AFRebootSurfaced 'S29' $pub @('fixture-sys')
    Assert-AFRouting 'S29' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S29' @('fixture-sys', 'fixture-sys2')

    # S30（复攻四 N30/N31）：执行顺序与名字的字母序相反。此前每个场景的引擎顺序都恰好是字母序，「按引擎顺序」逐字核对的
    # UnrecordedNames、界面日志 / 弹窗 / 命令行名单、失败清单与进度区的失败项名、逐项日志与命令行逐行结果的先后都分不出「按顺序」还是「排过序」。
    # 目录顺序：fixture-sys3（两个子操作的系统写入都被拒：失败、没改动）、fixture-sys2（写入成功、需重启）、fixture-sys（op1 写入，
    # op2 写 prepared 时落盘失败，op3 从未尝试）。UnrecordedNames 是「item 2、item」，失败项是「item 3、item」，两者都与字母序相反。
    # fixture-sys3 的两个子操作按 op2、op1 的顺序尝试：全部失败「失败：…」的尾部也按尝试顺序列（S17 的 fixture-sys2 两条原因恰好是字母序）。
    $s30Items = @(
      (New-AFRealItem 'fixture-sys3' 'fixture system item 3' @((New-AFRealOp 'op2' 'fixture op2 denied'), (New-AFRealOp 'op1' 'fixture op1 denied'))),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1')) -Reboot),
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1'), (New-AFRealOp 'op2' -PrepareFails), (New-AFRealOp 'op3')) -Reboot)
    )
    $s30Lost = @('fixture system item 2', 'fixture system item')
    $s30Failed = @('fixture system item 3', 'fixture system item')
    $s30Sys3Ops = @(@($s30Items[0].Ops) | ForEach-Object { "$($_.Name)" })
    # 夹具锚点：两份期望名单、fixture-sys3 的尝试顺序都不是字母序（否则顺序断言又会空转）。
    Assert-True (($s30Lost -join '|') -cne (@($s30Lost | Sort-Object) -join '|') -and ($s30Failed -join '|') -cne (@($s30Failed | Sort-Object) -join '|') -and
      ($s30Sys3Ops -join '|') -cne (@($s30Sys3Ops | Sort-Object) -join '|')) `
      '[S30] fixture problem: the expected unrecorded and failed name lists and the attempt order of fixture-sys3 must all differ from their alphabetical order'
    Set-AFEngineRealScenario $s30Items 'fixture disk full'
    Invoke-AFApplyClick 'S30' 'none' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') $true -RealProgress
    $pub = Assert-AFRealBatch 'S30' 3 @('fixture-sys3', 'fixture-sys2', 'fixture-sys') `
      @('fixture-sys3/op2', 'fixture-sys3/op1', 'fixture-sys2/op1', 'fixture-sys/op1', 'fixture-sys/op2') @('fixture-sys2/op1', 'fixture-sys/op1')
    foreach ($want in @(
        [pscustomobject]@{ Id = 'fixture-sys3'; Ok = $false; Changed = $false; Msg = '失败：op2：fixture op2 denied；op1：fixture op1 denied' },
        [pscustomobject]@{ Id = 'fixture-sys2'; Ok = $true;  Changed = $true;  Msg = '已写入' })) {
      $row = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq $want.Id })[0]
      Assert-True ($row.Ok -eq $want.Ok -and $row.Changed -eq $want.Changed -and $row.Skipped -eq $false -and "$($row.Msg)" -ceq $want.Msg) `
        ("[S30] $($want.Id) ran every sub-operation before the backup failure, so its row must be Ok=$($want.Ok) Changed=$($want.Changed) " +
         "'$($want.Msg)'; got Ok=$($row.Ok) Changed=$($row.Changed) Skipped=$($row.Skipped) '$($row.Msg)'")
      Assert-AFRowSurfaced 'S30' $row
    }
    $row = Assert-AFCutShortRow 'S30' $pub $s30Items[2] 1 1 $true
    Assert-AFRowSurfaced 'S30' $row
    Assert-AFBackupFailureSurfaced 'S30' $pub $s30Lost
    Assert-AFSalvageSurfaced 'S30' $pub @('fixture-sys3:reg:op2=prepared', 'fixture-sys3:reg:op1=prepared', 'fixture-sys2:reg:op1=applied',
      'fixture-sys:reg:op1=applied')
    Assert-AFSummarySurfaced 'S30' 1 2 0 $s30Failed
    Assert-AFRebootSurfaced 'S30' $pub @('fixture-sys2')
    Assert-AFRouting 'S30' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') @()
    Assert-AFEngineChildSaw 'S30' @('fixture-sys', 'fixture-sys2', 'fixture-sys3')

    # S31（复攻四 N24）：生产里最常见的形状——只有一个子操作的项（照生产 gpu-pstate-lock 的裸 Hashtable Ops），它自己写 prepared 时落盘失败。
    # 没有子操作被跳过（未执行 0）、也没有完成的（已完成 0）：行走全部失败的文案「失败：op1：备份 prepared 状态持久化失败：…」，
    # 绝不能说「其余 0 项未执行」。后一项整项不开始；一条撤销记录都没落盘，不交回备份。此前同时走到全部失败分支与备份失败的只有 S11，
    # 而 S11 注入了收尾失败、从不看这一行的文案。
    $s31Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1' -PrepareFails)) -ScalarOps -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1')) -Reboot)
    )
    Set-AFEngineRealScenario $s31Items 'fixture disk full'
    Invoke-AFApplyClick 'S31' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S31' 3 @('fixture-sys') @('fixture-sys/op1') @()
    Assert-True ((@(Get-AFOpsShapes) -join ',') -ceq 'fixture-sys=Hashtable,fixture-sys2=Object[]') `
      "[S31] fixture problem: the engine child's catalog did not build a bare-Hashtable Ops for the single-op item: [$(@(Get-AFOpsShapes) -join ',')]"
    $row = Assert-AFCutShortRow 'S31' $pub $s31Items[0] 0 0 $false
    Assert-AFRowSurfaced 'S31' $row
    Assert-AFBackupFailureSurfaced 'S31' $pub @()
    Assert-AFSalvageSurfaced 'S31' $pub @()
    Assert-AFSummarySurfaced 'S31' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S31' $pub @()
    Assert-AFRouting 'S31' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S31' @('fixture-sys', 'fixture-sys2')

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
      "$($s8Rows[1].Msg)".StartsWith('部分子项写入失败（其余 1 项已完成）', [StringComparison]::Ordinal)) `
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
    Assert-AFSalvageSurfaced 'S8' $(Get-AFEngineResult) @('fixture-sys:reg:op1=applied', 'fixture-sys2:reg:op1=applied')
    Assert-AFRouting 'S8' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') @()
    Assert-AFEngineChildSaw 'S8' @('fixture-sys', 'fixture-sys2', 'fixture-sys3')

    # S9：exit 3 发生在收尾写 complete 状态时（Results 全 Ok、两项都已生效），外壳又把进程退出码
    # 改写成 1——生产以结果文件为准并标 EngineExitCodeMismatch。随后本地缓存收尾炸掉。
    Set-AFEngineScenario @(
        (New-AFEngineRow 'fixture-sys'  'fixture system item'   $true $true '已写入'),
        (New-AFEngineRow 'fixture-sys2' 'fixture system item 2' $true $true '已写入')
      ) $pendingBackup 'fixture complete-state rename denied' @('fixture system item', 'fixture system item 2') 1 -AfterAllItems
    Invoke-AFApplyClick 'S9' 'local' @('fixture-sys', 'fixture-sys2', 'fixture-cache') $true
    $failIdx = Assert-AFFinalizationAfterBatch '[S9] exit-3 all-ok batch with a rewritten process exit code' 3 'fixture cache cleanup exploded'
    # 告警是收尾失败的 catch 补出来的（遗留 2），措辞同样要跟引擎的 BackupFailedAfterAllItems 走（遗留 4）：每一项都已执行，不许说「已中止」。
    $s9Severe = '！！严重：备份文件写入失败（fixture complete-state rename denied）。本轮的优化项都已执行完，失败的是最后一步保存备份。'
    $s9Bwf = @($script:AFDialogs | Where-Object { "$($_.En)" -ceq 'BACKUP WRITE FAILED' })
    Assert-True (@($script:AFLog | Where-Object { $_ -ceq $s9Severe }).Count -eq 1 -and $s9Bwf.Count -eq 1 -and
      "$($s9Bwf[0].Message)".StartsWith("本轮的优化项都已执行完，但最后一步保存备份时写入失败。`n`n", [StringComparison]::Ordinal)) `
      ("[S9] every item ran before the complete-state backup write failed, but the alarm raised on the finalization-failure path still said the run was aborted " +
       "(severe lines: $(@($script:AFLog | Where-Object { $_.StartsWith('！！严重', [StringComparison]::Ordinal) }) -join ' || '); " +
       "dialog opening: $(if ($s9Bwf.Count -gt 0) { ("$($s9Bwf[0].Message)" -split "`n")[0] }))")
    Assert-True ($script:AFReply.EngineExitCodeMismatch -eq $true -and
      (Get-AFLogIndex '管理员引擎退出码(1)与结果文件(3)不一致') -ge 0) `
      '[S9] rewritten process exit code did not go through the production result-file-wins path'
    Assert-True ((Get-AFLogCount '备份已保存：') -eq 1 -and (Get-AFLogIndex "备份已保存：$pendingBackup") -ge 0 -and
      (Get-AFLogIndex "备份已保存：$pendingBackup") -lt $failIdx) `
      '[S9] exit-3 all-ok batch did not log the salvaged backup exactly once before finalization failed'
    Assert-AFRouting 'S9' @('fixture-sys', 'fixture-sys2') @('fixture-cache')

    # S38（独立复核遗留 2），**真实 Invoke-Apply**：exit 3 的批次已经返回，本地缓存收尾在备份失败告警之前就炸了。
    # 告警原来写在逐项日志、本地执行器、目录同步之后，异常一冲进 catch，「备份写入失败」弹窗与「以下已生效的改动…」名单
    # 都到不了用户眼前，只剩「执行收尾失败」与「备份已保存」——Get-ApplyFailureContext 原来也只带回 Backup。
    # 形状同 S8：fixture-sys 写入并记账；fixture-sys2 的 op1 写入并记账、op2 写 prepared 时落盘失败（部分写入）。
    $s38Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1'))),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2' -PrepareFails)))
    )
    Set-AFEngineRealScenario $s38Items 'fixture disk full'
    Invoke-AFApplyClick 'S38' 'local' @('fixture-sys', 'fixture-sys2', 'fixture-cache') $true -RealProgress
    $failIdx = Assert-AFFinalizationAfterBatch '[S38] exit-3 batch whose local finalization failed before the backup alarm' 3 'fixture cache cleanup exploded'
    # 锚点：失败点真的在告警之前——逐项日志（生产 Update-ApplyProgress，本场景接的是原文）与「执行完成」汇总都排在本地执行器之后，
    # 一行都没写出来；本地执行器确实收到了缓存项（由下面的路由断言核对）。
    Assert-True ($script:AFProgressCalls -eq 0 -and (Get-AFLogIndex '执行完成：') -lt 0) `
      ("[S38] fixture problem: the local finalization did not fail before the per-item log and the summary " +
       "(Update-ApplyProgress calls $($script:AFProgressCalls); log: $($script:AFLog -join ' / '))")
    $pub = Get-AFEngineResult
    Assert-AFBackupFailureSurfaced 'S38' $pub @('fixture system item', 'fixture system item 2') `
      -Titles 'CONFIRM APPLY|BACKUP WRITE FAILED|APPLY FINALIZATION FAILED'
    Assert-AFSalvageSurfaced 'S38' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys2:reg:op1=applied')
    Assert-AFRouting 'S38' @('fixture-sys', 'fixture-sys2') @('fixture-cache')
    Assert-AFEngineChildSaw 'S38' @('fixture-sys', 'fixture-sys2')

    # S10（攻击复核 A1–A4），**真实 Invoke-Apply**：exit 2 且**没有任何一行 Ok**。唯一的系统项第一个子操作已写入，
    # 第二个子操作的系统写入被拒（Ok=false、Changed=true、「部分子项写入失败（其余 1 项已完成）」），备份完整落盘；
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

    # S11（攻击复核 A7、A8），**真实 Invoke-Apply**：exit 3 且什么都没改成——第一项唯一的子操作写 prepared 备份就落盘失败，
    # 引擎停手不做第二项（Results 只有 1 行），盘上没有任何撤销记录、不交回备份文件，UnrecordedNames 为空。
    # 那一行没有被跳过的子操作，文案是全部失败的「失败：op1：备份 prepared 状态持久化失败：…」（复攻四 N24；完整呈现见 S31）。
    # 界面收尾抛的是普通脚本错误（RuntimeException）而不是 IOException：生产里 WPF / 界面代码的失败
    # 几乎都是这类，S1–S10 注入的全是 IOException，按异常类型分流的变异只有这里会红。
    $s11Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1' -PrepareFails))),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1')))
    )
    Set-AFEngineRealScenario $s11Items 'fixture disk full'
    Invoke-AFApplyClick 'S11' 'tail-script' @('fixture-sys', 'fixture-sys2') $true
    $failIdx = Assert-AFFinalizationAfterBatch '[S11] exit-3 nothing-recorded batch' 3 'fixture tail script error'
    Assert-True (@($script:AFReply.Results).Count -eq 1 -and @($script:AFReply.UnrecordedNames).Count -eq 0 -and
      @($script:AFReply.Results | Where-Object Ok).Count -eq 0 -and "$($script:AFReply.BackupError)" -ceq 'fixture disk full' -and
      @(Get-AFSystemWrites).Count -eq 0) `
      ("[S11] exit-3 nothing-recorded fixture lost its shape (one failed row, BackupError, no unrecorded names, no system write): " +
       "rows $(@($script:AFReply.Results).Count), unrecorded [$(@($script:AFReply.UnrecordedNames) -join '|')], writes [$(@(Get-AFSystemWrites) -join ',')]")
    $null = Assert-AFCutShortRow 'S11' (Get-AFEngineResult) $s11Items[0] 0 0 $false
    Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY|BACKUP WRITE FAILED|APPLY FINALIZATION FAILED' -and
      $script:AFDialogs[1].Message.Contains('（无）') -and @(Get-AFDialogBullets $script:AFDialogs[1].Message).Count -eq 0) `
      "[S11] exit-3 nothing-recorded batch did not show the backup-write-failed dialog (listing no item) before finalization: [$(Get-AFDialogTitles)]"
    # 93713da：一条撤销记录都没落盘——不交回 Backup、删掉空的 .pending.json，界面、弹窗与命令行都不提「备份已保存 / 已抢救」。
    Assert-AFSalvageSurfaced 'S11' $(Get-AFEngineResult) @()
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

    # ---------------- 复攻五（R3 msg 最终收尾）：放在全部原有场景之后，原有变异的命中位置与消息不变 ----------------
    # S32（复攻五 V01/V02/V54，以及全成功行的多条附注）：备份完好、有撤销记录的批次。收尾核对同 S17 / S21（Assert-AFCompleteBackupSurfaced）；
    # fixture-sys2 的两个已达标子操作夹着一个写入的 op3：全成功文案按尝试顺序带两条「无需修改」附注、以「；」分隔（此前最多一条，见 S20）。
    $s32Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1'), (New-AFRealOp 'op2')) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op2' -AtTarget), (New-AFRealOp 'op3'), (New-AFRealOp 'op1' -AtTarget)))
    )
    Set-AFEngineRealScenario $s32Items $null
    Invoke-AFApplyClick 'S32' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S32' 0 @('fixture-sys', 'fixture-sys2') `
      @('fixture-sys/op1', 'fixture-sys/op2', 'fixture-sys2/op2', 'fixture-sys2/op3', 'fixture-sys2/op1') @('fixture-sys/op1', 'fixture-sys/op2', 'fixture-sys2/op3')
    Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY' -and -not $pub.Data.BackupError) `
      "[S32] a batch with an intact backup showed dialogs [$(Get-AFDialogTitles)] / engine BackupError '$($pub.Data.BackupError)'; expected only the confirmation and no BackupError"
    foreach ($want in @(
        [pscustomobject]@{ Id = 'fixture-sys';  Msg = '已写入' },
        [pscustomobject]@{ Id = 'fixture-sys2'; Msg = '已写入（无需修改：op2 已是目标状态；无需修改：op1 已是目标状态）' })) {
      $row = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq $want.Id })[0]
      Assert-True ($row.Ok -eq $true -and $row.Changed -eq $true -and $row.Skipped -eq $false -and "$($row.Msg)" -ceq $want.Msg) `
        ("[S32] $($want.Id) ran every sub-operation with the backup intact, so its row must be Ok=True Changed=True '$($want.Msg)'; " +
         "got Ok=$($row.Ok) Changed=$($row.Changed) Skipped=$($row.Skipped) '$($row.Msg)'")
      Assert-AFRowSurfaced 'S32' $row
    }
    Assert-AFSummarySurfaced 'S32' 2 0 0 @()
    Assert-AFNoBackupFailureSurfaced 'S32' $pub
    Assert-AFCompleteBackupSurfaced 'S32' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys:reg:op2=applied', 'fixture-sys2:reg:op3=applied')
    Assert-AFRebootSurfaced 'S32' $pub @('fixture-sys')
    Assert-AFRouting 'S32' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S32' @('fixture-sys', 'fixture-sys2')

    # S33（复攻五 V04–V06）：备份完好、一条撤销记录都没写——每个子操作都已是目标值（用户重复点「执行优化」时最常见的形状）。
    # 不交回 Backup、删掉空的 .pending.json、不改名成一份空的完整备份；界面与命令行都不能说「备份已保存」，也不能有任何告警或弹窗。
    $s33Items = @(
      (New-AFRealItem 'fixture-sys' 'fixture system item' @((New-AFRealOp 'op1' -AtTarget), (New-AFRealOp 'op2' -AtTarget)) -Reboot)
    )
    Set-AFEngineRealScenario $s33Items $null
    Invoke-AFApplyClick 'S33' 'none' @('fixture-sys') $true -RealProgress
    $pub = Assert-AFRealBatch 'S33' 0 @('fixture-sys') @('fixture-sys/op1', 'fixture-sys/op2') @()
    $row = @($pub.Data.Results)[0]
    Assert-True ($row.Ok -eq $true -and $row.Skipped -eq $true -and $row.Changed -eq $false -and $row.Reboot -eq $false -and
      "$($row.Msg)" -ceq '无需修改：所有设置已是目标状态') `
      ("[S33] fixture-sys had every sub-operation already at target, so its row must be Ok=True Skipped=True Changed=False Reboot=False " +
       "'无需修改：所有设置已是目标状态'; got Ok=$($row.Ok) Skipped=$($row.Skipped) Changed=$($row.Changed) Reboot=$($row.Reboot) '$($row.Msg)'")
    Assert-AFRowSurfaced 'S33' $row
    Assert-AFSummarySurfaced 'S33' 1 0 0 @()
    Assert-True (-not $pub.Data.BackupError -and @($pub.Data.UnrecordedNames).Count -eq 0) `
      "[S33] the real engine reported BackupError '$($pub.Data.BackupError)' / UnrecordedNames [$(@($pub.Data.UnrecordedNames) -join '|')] for a batch that changed nothing; expected neither"
    $s33Alarms = @(@($script:AFLog) + @(Get-AFCliOutput) | Where-Object { $_.StartsWith('！！', [StringComparison]::Ordinal) })
    Assert-True ((Get-AFDialogTitles) -ceq 'CONFIRM APPLY' -and $s33Alarms.Count -eq 0) `
      "[S33] a batch that changed nothing showed dialogs [$(Get-AFDialogTitles)] / alarm lines [$($s33Alarms -join ' || ')]; expected only the confirmation and no alarm"
    Assert-AFCompleteBackupSurfaced 'S33' $pub @()
    Assert-AFRebootSurfaced 'S33' $pub @()
    Assert-AFRouting 'S33' @('fixture-sys') @()
    Assert-AFEngineChildSaw 'S33' @('fixture-sys')

    # S34（复攻五 V09/V10/V52/V53）：通用 Ops 分支里 Ok=False、Skipped=True 的行——项目在本机没有可执行的子操作（生产 Ops = $null）：
    # 「本机不满足此项前提，已跳过」，需要游戏路径的项（生产 fso-off / gpu-pref / game-priority，都是默认项）是「未找到游戏路径，已跳过…」。
    # 此前没有任何场景产生这种行。它们是跳过、不是失败：逐项日志与命令行标 [跳过]，汇总记进跳过、不进失败计数，
    # 不进失败清单与进度区的失败项名；引擎退出码也不因它们变成 2。两个跳过行夹着成功行，逐行先后照样核对。
    $s34Items = @(
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @() -NoOps -Reboot),
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1')) -Reboot),
      (New-AFRealItem 'fixture-sys3' 'fixture system item 3' @() -NoOps -RequiresGame)
    )
    Set-AFEngineRealScenario $s34Items $null
    Invoke-AFApplyClick 'S34' 'none' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') $true -RealProgress
    $pub = Assert-AFRealBatch 'S34' 0 @('fixture-sys2', 'fixture-sys', 'fixture-sys3') @('fixture-sys/op1') @('fixture-sys/op1')
    Assert-True ((@(Get-AFOpsShapes) -join ',') -ceq 'fixture-sys2=null,fixture-sys=Object[],fixture-sys3=null') `
      "[S34] fixture problem: the engine child's catalog did not build Ops = `$null for the two items without sub-operations: [$(@(Get-AFOpsShapes) -join ',')]"
    foreach ($want in @(
        [pscustomobject]@{ Id = 'fixture-sys2'; Ok = $false; Skipped = $true;  Changed = $false; Msg = '本机不满足此项前提，已跳过' },
        [pscustomobject]@{ Id = 'fixture-sys';  Ok = $true;  Skipped = $false; Changed = $true;  Msg = '已写入' },
        [pscustomobject]@{ Id = 'fixture-sys3'; Ok = $false; Skipped = $true;  Changed = $false; Msg = '未找到游戏路径，已跳过；请用 -GamePath 指定游戏 exe' })) {
      $row = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq $want.Id })[0]
      Assert-True ($row.Ok -eq $want.Ok -and $row.Skipped -eq $want.Skipped -and $row.Changed -eq $want.Changed -and "$($row.Msg)" -ceq $want.Msg) `
        ("[S34] $($want.Id) must be Ok=$($want.Ok) Skipped=$($want.Skipped) Changed=$($want.Changed) '$($want.Msg)'; " +
         "got Ok=$($row.Ok) Skipped=$($row.Skipped) Changed=$($row.Changed) '$($row.Msg)'")
      Assert-AFRowSurfaced 'S34' $row
    }
    Assert-AFSummarySurfaced 'S34' 1 0 2 @()
    Assert-AFNoBackupFailureSurfaced 'S34' $pub
    Assert-AFCompleteBackupSurfaced 'S34' $pub @('fixture-sys:reg:op1=applied')
    Assert-AFRebootSurfaced 'S34' $pub @('fixture-sys')
    Assert-AFRouting 'S34' @('fixture-sys', 'fixture-sys2', 'fixture-sys3') @()
    Assert-AFEngineChildSaw 'S34' @('fixture-sys', 'fixture-sys2', 'fixture-sys3')

    # S35（复攻五 V26）：只有一个子操作的项（生产最常见的形状，裸 Hashtable Ops），系统写入已发生、标 applied 时落盘失败。
    # 没有被跳过的子操作、也没有完成的：行走全部失败的「失败：op1：备份 applied 状态持久化失败：…」，但系统**确实被改了**——
    # Changed=True，项名进 UnrecordedNames（界面与命令行的「以下已生效…」名单、弹窗逐项）；op1 的 prepared 记录已落盘，交回 .pending.json。
    # 此前全部失败分支上的行都没改过系统（S17 / S30 的系统拒绝、S31 / S11 的 prepared 落盘失败），「全部失败 = 没改动」与正确实现在那里重合。
    $s35Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1' -AppliedFails)) -ScalarOps -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1')) -Reboot)
    )
    Set-AFEngineRealScenario $s35Items 'fixture disk full'
    Invoke-AFApplyClick 'S35' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S35' 3 @('fixture-sys') @('fixture-sys/op1') @('fixture-sys/op1')
    Assert-True ((@(Get-AFOpsShapes) -join ',') -ceq 'fixture-sys=Hashtable,fixture-sys2=Object[]') `
      "[S35] fixture problem: the engine child's catalog did not build a bare-Hashtable Ops for the single-op item: [$(@(Get-AFOpsShapes) -join ',')]"
    $row = Assert-AFCutShortRow 'S35' $pub $s35Items[0] 0 0 $true
    Assert-AFRowSurfaced 'S35' $row
    Assert-AFBackupFailureSurfaced 'S35' $pub @('fixture system item')
    Assert-AFSalvageSurfaced 'S35' $pub @('fixture-sys:reg:op1=prepared')
    Assert-AFSummarySurfaced 'S35' 0 1 0 @('fixture system item')
    Assert-AFRebootSurfaced 'S35' $pub @()
    Assert-AFRouting 'S35' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S35' @('fixture-sys', 'fixture-sys2')

    # S36（复攻五 V56）：收尾的另一半——complete 状态已经写进 .pending.json，改名（生产 [IO.File]::Move）失败：目标被占住
    # （生产里是杀毒 / 同步盘的占用锁；夹具在批次前放好同名文件，改名真的失败，不注入）。生产在同一个 catch 里处理：BackupError 是
    # 改名失败的原文、退出码 3、Data 照常交回，Backup 是仍在原名的 .pending.json（记录全为 applied），两项都列为「已生效、备份可能没记全」，
    # 界面弹备份失败弹窗。把改名挪出 try（「只有写入会失败」）时异常直接冲出 Invoke-Apply：系统已改、Data 丢失、退出码 1，
    # 界面走前置失败，不再提醒「请不要重复点击」，也拿不到需手动回退的项名。此前只有 S29 走这一处 catch，失败的是写入、不是改名。
    # 同 S29：每一项都已执行，严重告警与弹窗开头说「都已执行完」，不说「已中止」。
    $s36Collision = Get-AFRenameCollisionMessage
    Assert-True ($s36Collision.Length -gt 0) `
      '[S36] fixture problem: moving a file onto an existing file did not fail in this process, so there is no rename error to expect'
    $s36Items = @(
      (New-AFRealItem 'fixture-sys'  'fixture system item'   @((New-AFRealOp 'op1')) -Reboot),
      (New-AFRealItem 'fixture-sys2' 'fixture system item 2' @((New-AFRealOp 'op1'), (New-AFRealOp 'op2')))
    )
    Set-AFEngineRealScenario $s36Items $null -RenameBlocked
    Invoke-AFApplyClick 'S36' 'none' @('fixture-sys', 'fixture-sys2') $true -RealProgress
    $pub = Assert-AFRealBatch 'S36' 3 @('fixture-sys', 'fixture-sys2') @('fixture-sys/op1', 'fixture-sys2/op1', 'fixture-sys2/op2') `
      @('fixture-sys/op1', 'fixture-sys2/op1', 'fixture-sys2/op2')
    # 夹具锚点：改名目标一直被夹具的文件占着，没有任何落盘注入，complete 状态（三条记录）确实先于改名落了盘——失败的只能是改名。
    $s36Blocker = $(if (Test-Path -LiteralPath $completeBackup -PathType Leaf) { [IO.File]::ReadAllText($completeBackup) })
    $s36Writes = @(Get-AFBackupWrites)
    $s36LastWrite = $(if ($s36Writes.Count -gt 0) { $s36Writes[$s36Writes.Count - 1] })
    Assert-True ("$s36Blocker" -ceq $afRenameBlocker -and @(Get-AFBackupFailureHits).Count -eq 0 -and
      "$s36LastWrite" -ceq "$([IO.Path]::GetFileName($pendingBackup))|complete|3") `
      ("[S36] fixture problem: the rename target was not held by the fixture's file, a backup write was injected to fail, or the complete state " +
       "never reached the disk before the rename (target content '$s36Blocker', injected [$(@(Get-AFBackupFailureHits) -join ',')], last backup write '$s36LastWrite')")
    $s36Error = "$($pub.Data.BackupError)"
    Assert-True ($s36Error.Contains($s36Collision)) `
      "[S36] the real engine reported BackupError '$s36Error' after renaming the complete backup failed; expected the rename's own error ('$s36Collision')"
    foreach ($s36Id in @('fixture-sys', 'fixture-sys2')) {
      $s36Row = @($pub.Data.Results | Where-Object { "$($_.Id)" -ceq $s36Id })[0]
      Assert-True ($s36Row.Ok -eq $true -and $s36Row.Changed -eq $true -and $s36Row.Skipped -eq $false -and "$($s36Row.Msg)" -ceq '已写入') `
        ("[S36] $s36Id wrote and recorded every sub-operation before the rename failed, so its row must be Ok=True Changed=True '已写入'; " +
         "got Ok=$($s36Row.Ok) Changed=$($s36Row.Changed) Skipped=$($s36Row.Skipped) '$($s36Row.Msg)'")
      Assert-AFRowSurfaced 'S36' $s36Row
    }
    Assert-AFBackupFailureSurfaced 'S36' $pub @('fixture system item', 'fixture system item 2') -BackupError $s36Error -AfterAllItems
    # 夹具的占位文件已完成使命：移走它，下面的目录核对只看引擎留下了什么。
    Remove-Item -LiteralPath $completeBackup -Force
    Assert-AFSalvageSurfaced 'S36' $pub @('fixture-sys:reg:op1=applied', 'fixture-sys2:reg:op1=applied', 'fixture-sys2:reg:op2=applied') -BackupError $s36Error
    Assert-AFSummarySurfaced 'S36' 2 0 0 @()
    Assert-AFRebootSurfaced 'S36' $pub @('fixture-sys')
    Assert-AFRouting 'S36' @('fixture-sys', 'fixture-sys2') @()
    Assert-AFEngineChildSaw 'S36' @('fixture-sys', 'fixture-sys2')
  } finally {
    $script:AFScenario = $null
    if (Test-Path -LiteralPath $afRoot) { Remove-Item -LiteralPath $afRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }
} $failureHelpers[0].Extent.Text $applyClickHandlers[0].Arguments[0].Extent.Text $afReal

'GUI apply finalization tests passed.'
