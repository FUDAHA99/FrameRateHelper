#requires -Version 5.1
using namespace System.Management.Automation.Language

# 本文件含中文，必须带 UTF-8 BOM —— PS 5.1 会把无 BOM 文件按系统 ANSI（这里是 GBK）读。
#
# 回归：「不再提醒此版本」对自动检查更新从来没生效（v1.0.0.0 起）。
#   用户在更新对话框勾「不再提醒此版本」→ Set-BoosterSkipVersion 在界面线程把 SkippedVersion
#   写进 $script:BoosterUserConfigDir（Initialize-ProtectedUserStateStore 设的受保护 per-SID 配置目录）。
#   自动检查 Start-UpdateCheck 却在后台 [PowerShell]::Create() runspace 里调 Test-BoosterUpdate，
#   那里 $script:BoosterUserConfigDir 是空的：提权时读配置抛错被吞、得到空记录；非提权时去读
#   LocalAppData。跳过记录等于不存在，勾过的版本每次启动（以及每 30 分钟的定时复查）照弹。
#   修法（14920d9）：runspace 一律带 -IncludeSkipped 只联网；结果回到界面线程的 DispatcherTimer tick，
#   用 Test-BoosterUpdateSkipped 过滤（读的就是勾选时写的那个文件）；强制更新永远不可跳过；
#   手动「检查更新」照旧不受跳过记录影响。
#   补修（780fb30）：自动弹窗的另一个入口 —— 执行优化/还原收尾时 Set-BusyState $false 补弹的
#   Show-DetectedUpdateDialog —— 也要看跳过记录（跳过判断放进 Show-DetectedUpdateDialog 本身）；
#   手动检查当面弹过的版本记进 UpdatePromptedVersion，忙碌结束时不再自动补弹；
#   勾了「不再提醒」却没存上时，日志如实写「没能保存」，不再说「已设置不再提醒」。
#   嵌套对话框（X 场景）：标题栏入口与手动检查直接调 Show-UpdateDialog，原来不挂 $script:UpdateDialogOpen，周期复查
#   检出更新的版本时会在它的模态帧里再建一个对话框、改写外层正在用的全局状态；现在由 Show-UpdateDialog 自己挂上、先存后还。
#
# 这里跑的是生产原文，不是复制品：
#   - Start-UpdateCheck / Start-ManualUpdateCheck / Show-DetectedUpdateDialog / Show-UpdateDialog /
#     Reset-UpdDialogButtons / Test-TuningExperimentActive / Initialize-ProtectedUserStateStore /
#     Set-BusyState / Update-TuningUi / Set-SymptomChipVisual 从 GUI 按 AST 原文抽出执行；
#     标题栏更新入口 $ui.UpdateBtn 的 Click 处理器原文挂到真 Button 上，由「用户点击」（RaiseEvent）触发；
#   - 受保护配置目录由 GUI 的 Initialize-ProtectedUserStateStore 原文设置（每个场景 = 一次全新的 GUI 启动，
#     都重跑它），之后才按 GUI 顶层的方式点源 scripts\updater.ps1，并核对点源没有改掉它（与生产同序）；
#     只桩掉要管理员权限建 ACL 的 New-ProtectedDirectory（在本次临时目录里建普通目录并记账）与 Write-BootLog；
#     它必须正好是引擎 scripts\delta-booster.ps1 的 Get-ProtectedUserStateRoot（原交互用户的 per-SID 根，
#     引擎原文照跑）下、引擎 Set-TargetUserContext 同名的配置子目录 —— 不能是全机共享的目录；
#   - $script:UpdaterPath 取 GUI 里的同一相对路径，后台 runspace 由抽出的函数自己创建、自己再点源一次（和生产一样）；
#     提权 GUI 的 runspace 读不到受保护配置目录，而本测试进程不提权：两个 runspace 里的 Test-BoosterUpdate
#     都必须带 -IncludeSkipped，这一条只能按 AST 核对（W10 / W11，认的是 AddScript 交出去的那个脚本块里的调用节点）；
#   - $script:GuiVersion / $script:DisplayVersion / 更新相关的顶层初始化语句 / UpdateBtn 的 XAML 初始可见性 /
#     主题资源字典都取自 GUI 源码；清单字段形状取自发版产物 build\update-manifest.json
#     （N 场景另外删掉 sha256/size 或换成白名单外的 setupUrl，走对话框「退回浏览器下载」那一支）；
#   - 真 DispatcherTimer tick，由本测试用 DispatcherFrame + PushFrame 泵 WPF 调度器驱动；
#     周期复查用的是 GUI 里 $script:UpdatePeriodicTimer.Add_Tick({...}) 的原文脚本块；
#     「执行一次优化/还原」= 生产 Set-BusyState $true 再 $false，它在收尾时 BeginInvoke 的补弹由同一个调度器真正派发；
#   - 清单经 [Net.WebRequest]::RegisterPrefix 在「updater 里的生产默认清单地址」上接管（AppDomain 级，
#     后台 runspace 同样看得到），不联网；每次检查都核对 runspace 真的取到了清单；
#   - Show-UpdateDialog 整段原文照跑（真 XAML、真控件、真处理器），对话框真的模态显示：`$script:UpdDlg.ShowDialog()`
#     这个调用表达式换成夹具函数，由它对生产建好的同一个窗口调用真正的 ShowDialog()（放在屏幕外、不抢焦点、
#     不进任务栏）—— Loaded / 渲染 / ContentRendered / Closing / Closed 与 DialogResult 都由 WPF 真实发生。
#     「用户」是同一调度器上的定时器：窗口真的渲染出来后才动手，只勾得到真正在屏幕上（IsVisible）且可用的
#     「不再提醒此版本」（UI 自动化 Toggle，与鼠标点击同一条切换路径），再点屏幕上可用的「稍后再说」（强制更新没有它，
#     点「前往下载」）或场景指定的按钮；按钮处理器、DialogResult、关窗与 ShowDialog() 的返回值都是生产原样，
#     之后的收尾语句（勾了就 Set-BoosterSkipVersion、按保存结果写日志并返回 $true）照跑。
#     「前往下载」经原用户 broker（Invoke-EngineHostUserAction，参数块取自 GUI 原文）打开网页：这里只记下网址；
#   - 原交互用户的 SID 故意与本测试进程的身份不同（提权 GUI 的 OTS 情形：进程身份是批准提权的另一个管理员），
#     按进程身份分区的回归与正确实现不会落在同一个目录。
# 只写 %TEMP% 下本次的临时目录；绝不写真实 LocalAppData / ProgramData（结尾有守卫）；绝不打开浏览器。
#
# 断言消息以 [场景.要点] 开头，可直接当变异测试的检索针；「FIXTURE PROBLEM」表示夹具自身没有成立。

$ErrorActionPreference = 'Stop'   # 与 GUI 顶层一致：GUI 同样是 Stop，产品代码在两边按同一偏好运行

$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
$enginePath = Join-Path $root 'scripts\delta-booster.ps1'
$shippedManifestPath = Join-Path $root 'build\update-manifest.json'
$script:TestRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('DeltaForceBooster-Tests\update-check-' + [guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($script:TestRoot)

$script:Assertions = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'

# 夹具没成立：后面的断言都没有意义，立即中止当前场景
function Assert-Fixture([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "FIXTURE PROBLEM: $Message" }
}
# 产品断言（致命）：后续步骤依赖它成立时用
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}
# 产品断言（记录后继续）：同一场景里互相独立的结果逐条都要看到
function Assert-Soft([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) {
    $script:Failures.Add("ASSERT: $Message")
    Write-Host "FAIL: $Message"
  }
}

function Invoke-Scenario([string]$Name, [scriptblock]$Body) {
  Write-Host "--- $Name"
  try { & $Body }
  catch {
    $script:Failures.Add("[$Name] $($_.Exception.Message)")
    Write-Host "FAIL [$Name]: $($_.Exception.Message)"
    # 场景半路中止时后台检查可能还在跑：等它收尾，免得下一场景被「上一轮还忙」误伤
    if ($script:UpdateCheckBusy -or $script:ManualCheckBusy) {
      [void](Wait-FixtureDispatcher { -not $script:UpdateCheckBusy -and -not $script:ManualCheckBusy } 30000)
    }
  }
}

# ---------- AST 工具 ----------

function Get-AncestorOfType([Ast]$Node, [type]$Type) {
  $p = $Node.Parent
  while ($p -and -not ($p -is $Type)) { $p = $p.Parent }
  $p
}

function Test-AstWithin([Ast]$Node, [Ast]$Ancestor) {
  $p = $Node.Parent
  while ($p) {
    if ([object]::ReferenceEquals($p, $Ancestor)) { return $true }
    $p = $p.Parent
  }
  $false
}

# $Node 位于 $Root 之内、且在「正常路径」上：从它到 $Root 之间没有 catch / trap、if / switch 分支、循环
# （try 的主体和 finally 都算正常路径）
function Test-OnNormalPath([Ast]$Node, [Ast]$Root) {
  $p = $Node.Parent
  while ($p -and -not [object]::ReferenceEquals($p, $Root)) {
    if ($p -is [CatchClauseAst] -or $p -is [TrapStatementAst] -or $p -is [IfStatementAst] -or
        $p -is [SwitchStatementAst] -or $p -is [LoopStatementAst]) { return $false }
    $p = $p.Parent
  }
  [bool]$p
}

# 启动路径：$Node 在 $Root 里，要么直接写在 $Root 这个脚本块里，要么在交给 UI 线程调度器排队执行的脚本块里
# （<…>.Dispatcher.BeginInvoke / Invoke / InvokeAsync({...})，可带 [action] 之类的转换）。
# 其他嵌套脚本块（定时器 tick、别的事件处理器）不是启动路径，返回 $null；
# 在启动路径上但处在 catch / trap、if / switch 分支或循环里返回 'branch'，否则返回 'normal'
function Get-StartupPathKind([Ast]$Node, [Ast]$Root) {
  $kind = 'normal'
  $p = $Node.Parent
  while ($p -and -not [object]::ReferenceEquals($p, $Root)) {
    if ($p -is [CatchClauseAst] -or $p -is [TrapStatementAst] -or $p -is [IfStatementAst] -or
        $p -is [SwitchStatementAst] -or $p -is [LoopStatementAst]) { $kind = 'branch' }
    if ($p -is [ScriptBlockExpressionAst]) {
      $q = $p.Parent
      while ($q -is [ConvertExpressionAst]) { $q = $q.Parent }
      $queued = $q -is [InvokeMemberExpressionAst] -and @('BeginInvoke', 'Invoke', 'InvokeAsync') -contains $q.Member.Extent.Text -and
        $q.Expression.Extent.Text -match 'Dispatcher$'
      if (-not $queued) { return $null }
    }
    $p = $p.Parent
  }
  if (-not $p) { return $null }
  $kind
}

# 只要「直接写在这个脚本块里」的调用：嵌套脚本块（例如处理器里再挂的定时器 tick）里的不算
function Get-DirectCommandCalls([ScriptBlockAst]$Block, [string]$Name) {
  # 命令名按 PowerShell 的解析规则大小写不敏感
  @($Block.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq $Name }, $true) |
    Where-Object { [object]::ReferenceEquals((Get-AncestorOfType $_ ([ScriptBlockAst])), $Block) })
}

# 函数里交给后台 runspace 的脚本块：<…>.AddScript({...})，或 AddScript($变量)（该变量在本函数里由脚本块直接赋值）
function Get-RunspaceScriptBlocks([FunctionDefinitionAst]$Fn) {
  foreach ($call in @($Fn.Body.FindAll({ param($n) $n -is [InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'AddScript' }, $true))) {
    foreach ($arg in @($call.Arguments)) {
      $e = $arg
      while ($e -is [ConvertExpressionAst]) { $e = $e.Child }
      if ($e -is [ScriptBlockExpressionAst]) { $e.ScriptBlock }
      elseif ($e -is [VariableExpressionAst]) {
        $vn = $e.VariablePath.UserPath
        @($Fn.Body.FindAll({ param($n) $n -is [AssignmentStatementAst] -and $n.Left -is [VariableExpressionAst] -and
          $n.Left.VariablePath.UserPath -eq $vn -and $n.Right -is [CommandExpressionAst] -and
          $n.Right.Expression -is [ScriptBlockExpressionAst] }, $true)) | ForEach-Object { $_.Right.Expression.ScriptBlock }
      }
    }
  }
}

# 参数名（或至少 3 个字符的无歧义前缀）是否指这个开关
function Test-NamesSwitch([string]$Name, [string]$Switch) {
  $Name.Length -ge 3 -and $Switch.StartsWith($Name, [StringComparison]::OrdinalIgnoreCase)
}
function Test-IsTrueLiteral($Ast) {
  $Ast -is [VariableExpressionAst] -and $Ast.VariablePath.UserPath -eq 'true'
}

# 命令调用是否打开了某个开关参数：-Name、-Name:$true，或参数名的无歧义前缀（至少 3 个字符）；
# 也认 splat（@p）：同一脚本块里 $p 只由哈希表字面量 @{ …; <开关> = $true } 赋值、除赋值与这次 splat 外不再被引用
# （认不出的写法一律判为没带：这是保守的钉子，宁可误报也不放过）
function Test-CommandPassesSwitch([CommandAst]$Cmd, [string]$Switch) {
  foreach ($e in $Cmd.CommandElements) {
    if ($e -is [CommandParameterAst] -and (Test-NamesSwitch $e.ParameterName $Switch)) {
      return ($null -eq $e.Argument -or (Test-IsTrueLiteral $e.Argument))
    }
  }
  $block = Get-AncestorOfType $Cmd ([ScriptBlockAst])
  foreach ($e in $Cmd.CommandElements) {
    if (-not ($e -is [VariableExpressionAst] -and $e.Splatted) -or -not $block) { continue }
    $vn = $e.VariablePath.UserPath
    $refs = @($block.FindAll({ param($n) $n -is [VariableExpressionAst] -and $n.VariablePath.UserPath -eq $vn }, $true))
    $assigns = @($block.FindAll({ param($n) $n -is [AssignmentStatementAst] -and $n.Left -is [VariableExpressionAst] -and
      $n.Left.VariablePath.UserPath -eq $vn }, $true))
    # 只有「赋值左边」和「这次 splat」两种引用
    if ($assigns.Count -lt 1 -or $refs.Count -ne $assigns.Count + 1) { continue }
    $allOn = $true
    foreach ($a in $assigns) {
      $ht = $(if ($a.Right -is [CommandExpressionAst]) { $a.Right.Expression })
      $on = $false
      if ($ht -is [HashtableAst]) {
        foreach ($kv in $ht.KeyValuePairs) {
          $v = $kv.Item2
          if ($v -is [PipelineAst] -and $v.PipelineElements.Count -eq 1 -and $v.PipelineElements[0] -is [CommandExpressionAst]) {
            $v = $v.PipelineElements[0].Expression
          }
          if ($kv.Item1 -is [StringConstantExpressionAst] -and (Test-NamesSwitch $kv.Item1.Value $Switch)) { $on = Test-IsTrueLiteral $v }
        }
      }
      if (-not $on) { $allOn = $false }
    }
    if ($allOn) { return $true }
  }
  $false
}

# ---------- 读 GUI 源码 ----------

$tokens = $null; $parseErrors = $null
$guiAst = [Parser]::ParseFile($guiPath, [ref]$tokens, [ref]$parseErrors)
Assert-Fixture ($parseErrors.Count -eq 0) ('GUI 解析失败：' + (($parseErrors | ForEach-Object Message) -join '; '))

function Get-GuiFunctionAst([string]$Name) {
  $found = @($guiAst.FindAll({ param($n) $n -is [FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
  Assert-Fixture ($found.Count -eq 1) "GUI 里 function $Name 应恰好定义一次（实际 $($found.Count) 次）：抽不出生产实际调用的那一份"
  $found[0]
}

function Get-GuiTopLevelAssignment([string]$LeftText) {
  $found = @($guiAst.EndBlock.Statements | Where-Object { $_ -is [AssignmentStatementAst] -and $_.Left.Extent.Text -eq $LeftText })
  Assert-Fixture ($found.Count -eq 1) "GUI 顶层对 $LeftText 的赋值应恰好一处（实际 $($found.Count) 处）"
  $found[0]
}

function Get-GuiTopLevelStringConstant([string]$LeftText) {
  $r = (Get-GuiTopLevelAssignment $LeftText).Right
  Assert-Fixture ($r -is [CommandExpressionAst] -and $r.Expression -is [StringConstantExpressionAst]) "GUI 顶层 $LeftText 不再是字符串常量，测试取不到生产值"
  $r.Expression.Value
}

# 某个控件事件处理器的脚本块：<$Target>.<$Member>({...}) 应恰好一处
function Get-GuiHandlerBody([string]$Target, [string]$Member) {
  $calls = @($guiAst.FindAll({ param($n) $n -is [InvokeMemberExpressionAst] -and
    $n.Expression.Extent.Text -eq $Target -and $n.Member.Extent.Text -eq $Member }, $true))
  Assert-Fixture ($calls.Count -eq 1 -and $calls[0].Arguments.Count -eq 1 -and $calls[0].Arguments[0] -is [ScriptBlockExpressionAst]) `
    "$Target.$Member({...}) 应恰好一处（实际 $($calls.Count) 处）"
  [pscustomobject]@{ Call = $calls[0]; Body = $calls[0].Arguments[0].ScriptBlock }
}

# 版本号：GUI 顶层的常量原值
$script:GuiVersion = Get-GuiTopLevelStringConstant '$script:GuiVersion'
$script:DisplayVersion = Get-GuiTopLevelStringConstant '$script:DisplayVersion'
Assert-Fixture ([bool]"$script:GuiVersion".Trim()) 'GUI 的 $script:GuiVersion 是空的'

# 更新模块路径：GUI 是 $script:UpdaterPath = Join-Path $script:RootDir '<相对路径>'；本测试按同一相对路径定位同一个真文件
$updPathRight = (Get-GuiTopLevelAssignment '$script:UpdaterPath').Right
$updJoin = @($updPathRight.FindAll({ param($n) $n -is [CommandAst] }, $true))
Assert-Fixture ($updJoin.Count -eq 1 -and $updJoin[0].GetCommandName() -eq 'Join-Path' -and $updJoin[0].CommandElements.Count -eq 3 -and
  $updJoin[0].CommandElements[1].Extent.Text -eq '$script:RootDir' -and $updJoin[0].CommandElements[2] -is [StringConstantExpressionAst]) `
  'GUI 的 $script:UpdaterPath 不再是 Join-Path $script:RootDir <常量>，测试无法定位生产加载的更新模块'
$script:UpdaterPath = Join-Path $root $updJoin[0].CommandElements[2].Value
Assert-Fixture (Test-Path -LiteralPath $script:UpdaterPath -PathType Leaf) "GUI 指向的更新模块不存在：$script:UpdaterPath"

# 更新与忙碌态相关的 GUI 顶层初始化语句（原文）；每个场景 =「一次全新的 GUI 启动」，都重跑它们
$script:GuiInitStatements = @(
  foreach ($lhs in '$script:Busy', '$script:UpdateInfo', '$script:UpdatePromptedVersion', '$script:UpdateDialogOpen',
                   '$script:ActiveSymptomIds', '$script:SymptomChips') {
    (Get-GuiTopLevelAssignment $lhs).Extent.Text
  })

# 主窗口 XAML：标题栏更新入口 UpdateBtn 的初始可见性；以及 GUI 共享的主题资源字典原文（更新对话框会合并它）
$xamlDoc = New-Object Xml.XmlDocument
$xamlDoc.LoadXml((Get-GuiTopLevelStringConstant '$xaml'))
$wpfNs = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
$xNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
$updBtnNodes = @($xamlDoc.GetElementsByTagName('Button', $wpfNs) | Where-Object { $_.GetAttribute('Name', $xNs) -ceq 'UpdateBtn' })
Assert-Fixture ($updBtnNodes.Count -eq 1) "主窗口 XAML 里 x:Name=UpdateBtn 的 Button 应恰好一个（实际 $($updBtnNodes.Count) 个）"
$script:XamlUpdateBtnVisibility = $(if ($updBtnNodes[0].HasAttribute('Visibility')) { $updBtnNodes[0].GetAttribute('Visibility') } else { 'Visible' })
Assert-Fixture ($script:XamlUpdateBtnVisibility -ceq 'Collapsed') `
  "XAML 里 UpdateBtn 初始是 $script:XamlUpdateBtnVisibility 而不是 Collapsed：本测试「入口保持隐藏」的断言以它为基线"
$script:ThemeResXamlText = Get-GuiTopLevelStringConstant '$script:ThemeResXaml'

# 生产函数
$startUpdateCheckAst = Get-GuiFunctionAst 'Start-UpdateCheck'
$manualCheckAst = Get-GuiFunctionAst 'Start-ManualUpdateCheck'
$showDetectedAst = Get-GuiFunctionAst 'Show-DetectedUpdateDialog'
$tuningActiveAst = Get-GuiFunctionAst 'Test-TuningExperimentActive'
$showUpdAst = Get-GuiFunctionAst 'Show-UpdateDialog'
$resetButtonsAst = Get-GuiFunctionAst 'Reset-UpdDialogButtons'
$protectedInitAst = Get-GuiFunctionAst 'Initialize-ProtectedUserStateStore'
$busyStateAst = Get-GuiFunctionAst 'Set-BusyState'
$tuningUiAst = Get-GuiFunctionAst 'Update-TuningUi'
$chipVisualAst = Get-GuiFunctionAst 'Set-SymptomChipVisual'
$brokerAst = Get-GuiFunctionAst 'Invoke-EngineHostUserAction'

# Start-UpdateCheck 里等结果的那个 DispatcherTimer tick
$updTickCalls = @($startUpdateCheckAst.FindAll({ param($n) $n -is [InvokeMemberExpressionAst] -and
  $n.Expression.Extent.Text -eq '$script:UpdateTimer' -and $n.Member.Extent.Text -eq 'Add_Tick' }, $true))
Assert-Fixture ($updTickCalls.Count -eq 1 -and $updTickCalls[0].Arguments.Count -eq 1 -and $updTickCalls[0].Arguments[0] -is [ScriptBlockExpressionAst]) `
  "Start-UpdateCheck 里 `$script:UpdateTimer.Add_Tick({...}) 应恰好一处（实际 $($updTickCalls.Count) 处）"
$updTick = $updTickCalls[0].Arguments[0].ScriptBlock

# ContentRendered 处理器与其中的周期复查定时器；标题栏「检查更新」按钮与更新入口的 Click 处理器
$crBody = (Get-GuiHandlerBody '$window' 'Add_ContentRendered').Body
$periodic = Get-GuiHandlerBody '$script:UpdatePeriodicTimer' 'Add_Tick'
$periodicTickBody = $periodic.Body
# 周期复查 tick 的原文脚本块：B/E/F 等场景的第二次检查就挂它到真 DispatcherTimer 上触发
$script:PeriodicTickBlock = $periodicTickBody.GetScriptBlock()
$manualClickBody = (Get-GuiHandlerBody '$ui.CheckUpdBtn' 'Add_Click').Body
# 标题栏更新入口 UpdateBtn 的 Click 处理器原文：挂到本测试的真 Button 上（与生产同一个事件、同一种挂法）
$script:UpdateBtnClickBlock = (Get-GuiHandlerBody '$ui.UpdateBtn' 'Add_Click').Body.GetScriptBlock()

# Show-UpdateDialog：参数名；函数体里（不在嵌套脚本块里）那一处 `$script:UpdDlg.ShowDialog()` 调用 —— 夹具只替换
# 这个调用表达式本身（换成「对同一个窗口真的 ShowDialog()，并让用户在上面操作」），所以语句写成 `| Out-Null`、
# `[void]…`、赋给变量还是放进 if 都照样能替换，返回值也原样交回
$showParams = @($(if ($showUpdAst.Parameters) { $showUpdAst.Parameters } elseif ($showUpdAst.Body.ParamBlock) { $showUpdAst.Body.ParamBlock.Parameters }))
Assert-Fixture ($showParams.Count -eq 1) "Show-UpdateDialog 应恰好一个参数（实际 $($showParams.Count) 个）"
$script:ShowUpdParamName = $showParams[0].Name.VariablePath.UserPath
$sdCalls = @($showUpdAst.Body.FindAll({ param($n) $n -is [InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'ShowDialog' -and
    $n.Expression.Extent.Text -eq '$script:UpdDlg' }, $true) |
  Where-Object { [object]::ReferenceEquals((Get-AncestorOfType $_ ([ScriptBlockAst])), $showUpdAst.Body) })
Assert-Fixture ($sdCalls.Count -eq 1) "Show-UpdateDialog 函数体里的 `$script:UpdDlg.ShowDialog() 调用应恰好一处（实际 $($sdCalls.Count) 处）"
$sdExpr = $sdCalls[0]
$showFnText = $showUpdAst.Extent.Text
$sdRel = $sdExpr.Extent.StartOffset - $showUpdAst.Extent.StartOffset
$script:FixtureShowUpdateDialogText = $showFnText.Substring(0, $sdRel) +
  "(Invoke-FixtureUserSeesUpdateDialog `$$($script:ShowUpdParamName))" +
  $showFnText.Substring($sdRel + ($sdExpr.Extent.EndOffset - $sdExpr.Extent.StartOffset))
$fxShowTokens = $null; $fxShowErrors = $null
$fxShowAst = [Parser]::ParseInput($script:FixtureShowUpdateDialogText, [ref]$fxShowTokens, [ref]$fxShowErrors)
Assert-Fixture ($fxShowErrors.Count -eq 0 -and
  @($fxShowAst.FindAll({ param($n) $n -is [InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'ShowDialog' -and
    $n.Expression.Extent.Text -eq '$script:UpdDlg' }, $true)).Count -eq 0 -and
  @($fxShowAst.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq 'Invoke-FixtureUserSeesUpdateDialog' }, $true)).Count -eq 1) `
  'Show-UpdateDialog 的 ShowDialog() 替换没有生效（替换后解析失败、仍有 ShowDialog()，或夹具调用不是恰好一处）'

# GUI 顶层：Initialize-ProtectedUserStateStore 的调用与更新模块的点源（都不在函数、事件处理器里）
$topInitCalls = @($guiAst.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq 'Initialize-ProtectedUserStateStore' }, $true) |
  Where-Object { [object]::ReferenceEquals((Get-AncestorOfType $_ ([ScriptBlockAst])), $guiAst) -and (Test-OnNormalPath $_ $guiAst) })
$topUpdaterLoads = @($guiAst.FindAll({ param($n) $n -is [CommandAst] -and $n.InvocationOperator -eq [TokenKind]::Dot -and
  $n.CommandElements[0].Extent.Text -eq '$script:UpdaterPath' }, $true) |
  Where-Object { [object]::ReferenceEquals((Get-AncestorOfType $_ ([ScriptBlockAst])), $guiAst) })

# ---------- 读引擎源码：原交互用户的 per-SID 受保护状态根 ----------

# 提权引擎自己的用户状态就落在 Get-ProtectedUserStateRoot <原交互用户 SID>（Set-TargetUserContext 再在下面拼配置子目录）；
# GUI 的「不再提醒」记录必须落在同一个 per-SID 配置目录里。两样都从引擎源码取，测试不自己拼目录布局
$engTokens = $null; $engErrors = $null
$engineAst = [Parser]::ParseFile($enginePath, [ref]$engTokens, [ref]$engErrors)
Assert-Fixture ($engErrors.Count -eq 0) ('引擎 scripts\delta-booster.ps1 解析失败：' + (($engErrors | ForEach-Object Message) -join '; '))
$engStateRootFn = @($engineAst.FindAll({ param($n) $n -is [FunctionDefinitionAst] -and $n.Name -eq 'Get-ProtectedUserStateRoot' }, $true))
Assert-Fixture ($engStateRootFn.Count -eq 1) "引擎里 function Get-ProtectedUserStateRoot 应恰好定义一次（实际 $($engStateRootFn.Count) 次）"
$engTargetCtxFn = @($engineAst.FindAll({ param($n) $n -is [FunctionDefinitionAst] -and $n.Name -eq 'Set-TargetUserContext' }, $true))
Assert-Fixture ($engTargetCtxFn.Count -eq 1) "引擎里 function Set-TargetUserContext 应恰好定义一次（实际 $($engTargetCtxFn.Count) 次）"
$engCfgAssign = @($engTargetCtxFn[0].FindAll({ param($n) $n -is [AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ConfigDir' }, $true))
$engCfgJoin = @($engCfgAssign | ForEach-Object { $_.Right.FindAll({ param($n) $n -is [CommandAst] }, $true) })
Assert-Fixture ($engCfgAssign.Count -eq 1 -and $engCfgJoin.Count -eq 1 -and $engCfgJoin[0].GetCommandName() -eq 'Join-Path' -and
  $engCfgJoin[0].CommandElements.Count -eq 3 -and $engCfgJoin[0].CommandElements[1].Extent.Text -eq '$script:UserDataRoot' -and
  $engCfgJoin[0].CommandElements[2] -is [StringConstantExpressionAst]) `
  '引擎 Set-TargetUserContext 里的 $script:ConfigDir 不再是 Join-Path $script:UserDataRoot <常量>：测试取不到引擎的用户配置子目录'
$script:EngineConfigLeaf = $engCfgJoin[0].CommandElements[2].Value

# ---------- WPF ----------

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Assert-Fixture ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA) `
  '测试线程不是 STA：WPF 控件与 DispatcherTimer 都要求 STA（请用 Windows PowerShell 5.1 直接运行本文件）'

# ---------- 生产接线（AST，只认节点不认注释） ----------

Invoke-Scenario 'W wiring' {
  # 启动时：ContentRendered 处理器在正常路径上调 Start-UpdateCheck（无参数，和夹具的调用方式一致）。
  # 直接调，或交给 UI 线程调度器排队（$window.Dispatcher.BeginInvoke([action]{ Start-UpdateCheck })）都算；
  # 定时器 tick 之类的其他嵌套脚本块不算（那是 W3 的周期复查）
  $crStart = @($crBody.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq 'Start-UpdateCheck' }, $true) |
    Where-Object { $null -ne (Get-StartupPathKind $_ $crBody) })
  Assert-Soft ($crStart.Count -ge 1) '[W2.content-rendered] ContentRendered 处理器里不再（直接或经调度器排队）调用 Start-UpdateCheck：启动时不检查更新'
  Assert-Soft (@($crStart | Where-Object { (Get-StartupPathKind $_ $crBody) -ceq 'normal' }).Count -ge 1) `
    '[W2.content-rendered-normal-path] ContentRendered 里对 Start-UpdateCheck 的调用只在 catch / if / 循环分支里：正常启动时不检查更新'
  Assert-Soft (@($crStart | Where-Object { $_.CommandElements.Count -ne 1 }).Count -eq 0) `
    '[W2.content-rendered-args] ContentRendered 里调用 Start-UpdateCheck 时带了参数，和本测试（无参调用）不再是同一条路径'

  # 运行中：周期复查 DispatcherTimer 的 tick 调 Start-UpdateCheck；定时器在 ContentRendered 的正常路径上建、挂、启
  $ptStart = @(Get-DirectCommandCalls $periodicTickBody 'Start-UpdateCheck')
  Assert-Soft ($ptStart.Count -ge 1 -and @($ptStart | Where-Object { $_.CommandElements.Count -ne 1 }).Count -eq 0) `
    '[W3.periodic-tick] $script:UpdatePeriodicTimer 的 tick 不再（无参）调用 Start-UpdateCheck：定时复查失效'
  Assert-Soft (@($ptStart | Where-Object { Test-OnNormalPath $_ $periodicTickBody }).Count -ge 1) `
    '[W3.periodic-tick-normal-path] 周期复查 tick 里对 Start-UpdateCheck 的调用只在 catch / if / 循环分支里'
  Assert-Soft (Test-AstWithin $periodic.Call $crBody) '[W3.periodic-in-content-rendered] 周期复查 tick 不是在 ContentRendered 处理器里挂上的'
  Assert-Soft (Test-OnNormalPath $periodic.Call $crBody) '[W3.periodic-normal-path] 周期复查 tick 只在 ContentRendered 的 catch / if / 循环分支里才挂上'
  $ptAssign = @($crBody.FindAll({ param($n) $n -is [AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:UpdatePeriodicTimer' }, $true))
  $ptTimerType = @($ptAssign | ForEach-Object { $_.Right.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq 'New-Object' }, $true) } |
    Where-Object { $_.CommandElements.Count -ge 2 -and $_.CommandElements[1] -is [StringConstantExpressionAst] -and
                   ($_.CommandElements[1].Value -as [type]) -eq [Windows.Threading.DispatcherTimer] })
  Assert-Soft ($ptAssign.Count -eq 1 -and $ptTimerType.Count -eq 1) '[W3.periodic-timer] $script:UpdatePeriodicTimer 不再是 ContentRendered 里 New-Object 出来的 DispatcherTimer'
  $ptStartCall = @($crBody.FindAll({ param($n) $n -is [InvokeMemberExpressionAst] -and
    $n.Expression.Extent.Text -eq '$script:UpdatePeriodicTimer' -and $n.Member.Extent.Text -eq 'Start' }, $true))
  Assert-Soft (@($ptStartCall | Where-Object { Test-OnNormalPath $_ $crBody }).Count -ge 1) `
    '[W3.periodic-started] ContentRendered 的正常路径上没有 $script:UpdatePeriodicTimer.Start()：定时复查从不触发'

  # 结果回到界面线程的 tick：跳过判断 Test-BoosterUpdateSkipped 在 tick 里（含其中的 Where-Object 等过滤块），
  # 并且写在弹窗、点亮入口、记下 $script:UpdateInfo 之前。形态不限（置空 / return / 并进筛选都行）
  $filters = @($updTick.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq 'Test-BoosterUpdateSkipped' }, $true))
  Assert-Soft ($filters.Count -ge 1) `
    '[W4.filter-missing] Start-UpdateCheck 的界面线程 tick 里没有调用 Test-BoosterUpdateSkipped：跳过判断不在读得到受保护配置目录的界面线程上'
  if ($filters.Count -ge 1) {
    $filterAt = ($filters | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Minimum).Minimum
    $dlgCalls = @(Get-DirectCommandCalls $updTick 'Show-DetectedUpdateDialog')
    Assert-Soft ($dlgCalls.Count -ge 1) '[W4.tick-dialog] Start-UpdateCheck 的 tick 不再调用 Show-DetectedUpdateDialog'
    Assert-Soft (@($dlgCalls | Where-Object { $_.Extent.StartOffset -lt $filterAt }).Count -eq 0) `
      '[W4.filter-after-dialog] 跳过判断写在 Show-DetectedUpdateDialog 之后：对话框先弹了才过滤'
    $visible = @($updTick.FindAll({ param($n) $n -is [AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$ui.UpdateBtn.Visibility' -and
      $n.Right -is [CommandExpressionAst] -and $n.Right.Expression -is [StringConstantExpressionAst] -and $n.Right.Expression.Value -ceq 'Visible' }, $true))
    Assert-Soft ($visible.Count -ge 1) '[W4.tick-visible] Start-UpdateCheck 的 tick 不再把 UpdateBtn 设为 Visible'
    Assert-Soft (@($visible | Where-Object { $_.Extent.StartOffset -lt $filterAt }).Count -eq 0) `
      '[W4.filter-after-visible] 跳过判断写在「UpdateBtn.Visibility = Visible」之后：标题栏入口先亮了才过滤'
    $infoSet = @($updTick.FindAll({ param($n) $n -is [AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:UpdateInfo' }, $true))
    Assert-Soft (@($infoSet | Where-Object { $_.Extent.StartOffset -lt $filterAt }).Count -eq 0) `
      '[W4.filter-after-updateinfo] 跳过判断写在 $script:UpdateInfo 赋值之后'
  }

  # 「不再提醒」落盘记的是哪个版本，不按实参写法比对：F1 / T / Q / N1 / N2 等场景按行为核对
  # （跳过记录必须等于对话框里给用户看的那个版本），$UpdInfo.Version、$script:UpdDlgInfo.Version 之类的等价写法都不影响

  # 后台 runspace 读不到受保护的 per-SID 配置目录（提权 GUI 里读配置会抛错），所以两个 runspace 里的
  # Test-BoosterUpdate 都必须带 -IncludeSkipped：runspace 只联网，跳过与否回到界面线程判断。本测试进程不提权，
  # 去掉它时 runspace 会悄悄退回读 LocalAppData、场景照样全绿 —— 这一条只能按 AddScript 交出去的脚本块里的调用节点核对
  foreach ($rs in @(
      [pscustomobject]@{ Tag = 'W10'; Fn = $startUpdateCheckAst; Name = 'Start-UpdateCheck（自动检查）' },
      [pscustomobject]@{ Tag = 'W11'; Fn = $manualCheckAst; Name = 'Start-ManualUpdateCheck（手动检查）' })) {
    $rsCalls = @(Get-RunspaceScriptBlocks $rs.Fn | ForEach-Object { $_.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq 'Test-BoosterUpdate' }, $true) })
    Assert-Soft ($rsCalls.Count -ge 1) "[$($rs.Tag).runspace-check] $($rs.Name) 交给后台 runspace（AddScript）的脚本块里没有调用 Test-BoosterUpdate"
    $rsBad = @($rsCalls | Where-Object { -not (Test-CommandPassesSwitch $_ 'IncludeSkipped') })
    Assert-Soft ($rsCalls.Count -ge 1 -and $rsBad.Count -eq 0) `
      ("[$($rs.Tag).runspace-include-skipped] $($rs.Name) 的后台 runspace 调 Test-BoosterUpdate 没带 -IncludeSkipped" +
       "（[$(@($rsBad | ForEach-Object { $_.Extent.Text }) -join ' / ')]）：runspace 自己去读跳过记录 —— 提权 GUI 里没有受保护配置目录，" +
       '读配置抛错（被吞时还好，不被吞时连带整个检查返回空）；本测试不提权，测不到这种回归')
  }

  # B/C 场景用 Reset-UpdDialogButtons 模拟「下载失败/取消后按钮复位」：生产的更新对话框里确实调用它
  Assert-Soft (@($showUpdAst.FindAll({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq 'Reset-UpdDialogButtons' }, $true)).Count -ge 1) `
    '[W9.reset-buttons-used] Show-UpdateDialog 里不再调用 Reset-UpdDialogButtons：B/C 场景对「下载失败后按钮复位」的建模已过时'

  # GUI 顶层点源的就是 $script:UpdaterPath（不在任何函数里）
  Assert-Soft ($topUpdaterLoads.Count -ge 1) '[W6.updater-load] GUI 顶层不再点源 $script:UpdaterPath：本测试点源更新模块的方式与生产不一致'

  # 受保护配置目录：GUI 顶层（正常路径、不在函数里）调用 Initialize-ProtectedUserStateStore —— S 场景跑的就是它
  Assert-Soft ($topInitCalls.Count -ge 1 -and @($topInitCalls | Where-Object { $_.CommandElements.Count -ne 1 }).Count -eq 0) `
    '[W7.init-called] GUI 顶层不再（无条件、无参地）调用 Initialize-ProtectedUserStateStore：受保护配置目录从不设置'

  # 手动「检查更新」：标题栏按钮的 Click 处理器在正常路径上（无参）调用 Start-ManualUpdateCheck —— M 场景跑的就是它
  Assert-Soft (@(Get-DirectCommandCalls $manualClickBody 'Start-ManualUpdateCheck' |
      Where-Object { $_.CommandElements.Count -eq 1 -and (Test-OnNormalPath $_ $manualClickBody) }).Count -ge 1) `
    '[W8.manual-click] 「检查更新」按钮的 Click 处理器不再（在正常路径上、无参地）调用 Start-ManualUpdateCheck'
}

# ---------- 受保护配置目录：GUI 的 Initialize-ProtectedUserStateStore 原文 ----------

# 生产里 $script:ProgramDataRoot 是引擎算出的 <CommonAppData>\DeltaForceBooster；本测试绝不写真实 ProgramData，
# 每次「GUI 启动」都换成本次临时目录下的一个全新根（测试值）。
# 原交互用户（启动器交给 GUI 的 $script:OriginalUserSid）故意不是本测试进程的身份：提权 GUI 的常见情形
# （OTS：标准用户输入另一管理员的凭据）里，进程身份是批准提权的那个管理员，「不再提醒」却必须记在原交互用户的
# per-SID 目录。两者相同时，按进程身份（WindowsIdentity.GetCurrent().User）分区的回归与正确实现落在同一个目录，测不出来。
# 这里用一个固定的、形状合法的域账户 SID（测试值，只当目录名用，不会去查这个账户）
$script:ProcessUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:OriginalUserSid = 'S-1-5-21-3623811015-3361044348-30300820-1013'
Assert-Fixture ((New-Object Security.Principal.SecurityIdentifier($script:OriginalUserSid)).IsAccountSid() -and
  $script:OriginalUserSid -cne $script:ProcessUserSid) "夹具的原交互用户 SID [$script:OriginalUserSid] 不是账户 SID，或恰好就是本进程身份"
$script:FxProtectedDirs = New-Object 'System.Collections.Generic.List[object]'
$script:FxBootLog = New-Object 'System.Collections.Generic.List[string]'
# 引擎的 New-ProtectedDirectory 要管理员权限并设严格 ACL；这里只在本次临时目录里建普通目录并记账
function New-ProtectedDirectory([string]$Path, [bool]$UsersRead) {
  $full = [IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($script:TestRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "FIXTURE PROBLEM: Initialize-ProtectedUserStateStore 要在测试临时目录之外建目录：$full"
  }
  [void][IO.Directory]::CreateDirectory($full)
  $script:FxProtectedDirs.Add([pscustomobject]@{ Path = $full; UsersRead = $UsersRead })
}
function Write-BootLog([string]$Line) { $script:FxBootLog.Add($Line) }
Invoke-Expression $protectedInitAst.Extent.Text
# 引擎原文：原交互用户的 per-SID 受保护状态根（读 $script:ProgramDataRoot，本测试里是本次临时目录下的根）
Invoke-Expression $engStateRootFn[0].Extent.Text

# 一次 GUI 启动里的受保护状态初始化：清空它设的变量 → 跑生产函数 → 核对配置目录；在任何读写跳过记录之前做
function Invoke-FixtureProtectedStateInit([string]$Name) {
  $script:ProgramDataRoot = Join-Path $script:TestRoot "$Name\ProgramData"
  foreach ($v in 'BoosterUserConfigDir', 'UserConfigDir', 'ConfigDir', 'ProfileDir', 'UserDataRoot', 'ProtectedUserStateRoot') {
    Set-Variable -Scope Script -Name $v -Value $null
  }
  $script:FxProtectedDirs.Clear()
  Initialize-ProtectedUserStateStore
  Assert-Fixture ($script:FxProtectedDirs.Count -ge 1) "Initialize-ProtectedUserStateStore（$Name）没有经过 New-ProtectedDirectory：桩没被调用"
  $cfg = "$script:BoosterUserConfigDir"
  # 致命：配置目录为空时再往下走，非提权的测试进程会让更新模块退回真实 LocalAppData
  Assert-True ([bool]$cfg.Trim()) ("[S1.init-sets-config-dir] GUI 的 Initialize-ProtectedUserStateStore 跑完后 `$script:BoosterUserConfigDir 是空的（$Name）：" +
    '提权 GUI 里 Set-BoosterSkipVersion 写不进、Test-BoosterUpdateSkipped 读不到，「不再提醒此版本」形同虚设')
  $full = [IO.Path]::GetFullPath($cfg)
  Assert-Fixture ($full.StartsWith($script:TestRoot + '\', [StringComparison]::OrdinalIgnoreCase)) "受保护配置目录落在测试临时目录之外：$full"
  Assert-True (@($script:FxProtectedDirs | Where-Object { $_.Path -eq $full -and -not $_.UsersRead }).Count -ge 1) `
    "[S1.config-dir-protected] `$script:BoosterUserConfigDir [$full] 不是 Initialize-ProtectedUserStateStore 建出的受保护（普通用户不可读）目录（$Name）"
  # 记录是「这个 Windows 用户」的：必须是引擎为原交互用户算出的 per-SID 根下的配置目录，
  # 不能是 users\ 或 ProgramData 根这类全机共享的受保护目录（否则用户 A 勾的「不再提醒」会替用户 B 做主）
  $perSidCfg = [IO.Path]::GetFullPath((Join-Path (Get-ProtectedUserStateRoot $script:OriginalUserSid) $script:EngineConfigLeaf))
  # 参照物自身得是 per-SID 的：ProgramData 根之下、路径里有一段恰好是原交互用户的 SID
  Assert-Fixture ($perSidCfg.StartsWith([IO.Path]::GetFullPath($script:ProgramDataRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
    @($perSidCfg.Substring($script:ProgramDataRoot.Length).Split('\') | Where-Object { $_ -ceq $script:OriginalUserSid }).Count -eq 1) `
    "引擎 Get-ProtectedUserStateRoot 给出的 [$perSidCfg] 不是 ProgramData 根下含原交互用户 SID 的目录：拿它当 per-SID 参照没有意义"
  Assert-True ($full.TrimEnd('\') -eq $perSidCfg.TrimEnd('\')) `
    ("[S1.per-sid-config-dir] `$script:BoosterUserConfigDir [$full] 不是原交互用户 $script:OriginalUserSid 的 per-SID 配置目录 [$perSidCfg]" +
     "（引擎 Get-ProtectedUserStateRoot 下的 $script:EngineConfigLeaf；本进程身份是 $script:ProcessUserSid）：" +
     "「不再提醒此版本」记到了别的账户名下或成了多个 Windows 用户共用的一份（$Name）")
}

# ---------- 加载生产代码 ----------

# 真实 LocalAppData 里的旧版配置目录（含跳过记录）：本测试（以及修好的产品）绝不能动它，也不能在里面新建任何东西
$script:RealLocalConfigDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'DeltaForceBooster\config'
$script:RealLocalUpdaterJson = Join-Path $script:RealLocalConfigDir 'updater.json'
function Get-RealLocalUpdaterState {
  if (-not (Test-Path -LiteralPath $script:RealLocalConfigDir -PathType Container)) { return 'no-config-dir' }
  $lines = @('config-dir') + @(Get-ChildItem -LiteralPath $script:RealLocalConfigDir -Recurse -Force -ErrorAction SilentlyContinue |
    Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
  if (Test-Path -LiteralPath $script:RealLocalUpdaterJson -PathType Leaf) {
    $lines += (Get-FileHash -LiteralPath $script:RealLocalUpdaterJson -Algorithm SHA256).Hash
  }
  $lines -join "`n"
}
$localUpdaterBefore = Get-RealLocalUpdaterState

try {
  # 生产顺序：GUI 先 Initialize-ProtectedUserStateStore，再点源更新模块（本测试照这个顺序建模）
  if ($topInitCalls.Count -ge 1 -and $topUpdaterLoads.Count -ge 1) {
    Assert-Fixture ($topInitCalls[0].Extent.StartOffset -lt $topUpdaterLoads[0].Extent.StartOffset) `
      'GUI 改成了先点源更新模块、后初始化受保护状态：本测试「先初始化再点源」的建模要跟着改'
  }
  $script:BoosterUserConfigDir = $null
  Invoke-Scenario 'S1 protected config dir (production Initialize-ProtectedUserStateStore)' { Invoke-FixtureProtectedStateInit 'boot' }
  $script:FxBootConfigDir = "$script:BoosterUserConfigDir"
  # GUI 顶层：if (Test-Path $script:UpdaterPath) { try { . $script:UpdaterPath } catch {} } —— 这里不吞错，加载失败直接报
  . $script:UpdaterPath
  foreach ($fn in 'Test-BoosterUpdate', 'Set-BoosterSkipVersion', 'Get-BoosterUpdateConfig', 'Get-BoosterUpdateConfigPath', 'Compare-BoosterVersion', 'Get-BoosterManifest') {
    Assert-Fixture ([bool](Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) "点源 $script:UpdaterPath 后没有 $fn"
  }
  Invoke-Scenario 'S2 updater load keeps the protected config dir' {
    if (-not $script:FxBootConfigDir) {
      # S1 失败时已经记了产品断言失败；S2 无从比较，只核对那条失败确实在
      Assert-Fixture ($script:Failures.Count -ge 1) 'S1 没有产出受保护配置目录，却没有任何失败记录'
      return
    }
    # 致命：被改空时再调 Get-BoosterUpdateConfigPath 会退回真实 LocalAppData
    Assert-True ("$script:BoosterUserConfigDir" -ceq $script:FxBootConfigDir) `
      ("[S2.updater-load-keeps-config-dir] 点源 scripts\updater.ps1 把 `$script:BoosterUserConfigDir 从 [$script:FxBootConfigDir] 改成了 [$script:BoosterUserConfigDir]：" +
       'GUI 与更新模块共用脚本作用域，提权 GUI 的「不再提醒此版本」从此存不下也读不到')
    $cfgPath = [IO.Path]::GetFullPath((Get-BoosterUpdateConfigPath))
    Assert-Soft ($cfgPath -eq (Join-Path ([IO.Path]::GetFullPath($script:FxBootConfigDir)) 'updater.json')) `
      "[S2.updater-config-path] 更新模块的配置文件 [$cfgPath] 不在受保护配置目录 [$script:FxBootConfigDir] 里"
  }
  Assert-Fixture ("$script:BoosterManifestUrl" -like 'https://*') "更新模块的默认清单地址不是 https：[$script:BoosterManifestUrl]"
  Assert-Fixture ((Compare-BoosterVersion '9.0.0.0' $script:GuiVersion) -gt 0) "GUI 版本 $script:GuiVersion 不低于夹具版本 9.x，测试版本号需要调整"

  # 假清单服务：在生产默认清单地址上接管 WebRequest.Create，数命中
  if (-not ('DfbUpdateCheckManifestCreator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

// 清单 fixture：WebRequest.RegisterPrefix 接管生产默认清单地址。Body 是本场景要下发的清单 JSON；
// CreateCount/ResponseCount 数真实的请求与响应（后台 runspace 与测试线程都会来，全部原子计数）。
public sealed class DfbUpdateCheckManifestCreator : IWebRequestCreate {
  private readonly object gate = new object();
  private string body = "";
  private string lastUri = "";
  private int createCount;
  private int responseCount;
  public string Body { get { lock (gate) { return body; } } set { lock (gate) { body = value ?? ""; } } }
  public string LastUri { get { lock (gate) { return lastUri; } } }
  public int CreateCount { get { return Thread.VolatileRead(ref createCount); } }
  public int ResponseCount { get { return Thread.VolatileRead(ref responseCount); } }
  public WebRequest Create(Uri uri) {
    Interlocked.Increment(ref createCount);
    lock (gate) { lastUri = uri.AbsoluteUri; }
    return new DfbUpdateCheckManifestRequest(this, uri);
  }
  public byte[] Respond() {
    Interlocked.Increment(ref responseCount);
    return Encoding.UTF8.GetBytes(Body);
  }
}

public sealed class DfbUpdateCheckManifestRequest : WebRequest {
  private readonly DfbUpdateCheckManifestCreator owner;
  private readonly Uri requestUri;
  private int timeout = 100000;
  public DfbUpdateCheckManifestRequest(DfbUpdateCheckManifestCreator owner, Uri requestUri) {
    this.owner = owner;
    this.requestUri = requestUri;
  }
  public override Uri RequestUri { get { return requestUri; } }
  public override int Timeout { get { return timeout; } set { timeout = value; } }
  public override WebResponse GetResponse() { return new DfbUpdateCheckManifestResponse(requestUri, owner.Respond()); }
}

public sealed class DfbUpdateCheckManifestResponse : WebResponse {
  private readonly Uri uri;
  private readonly byte[] data;
  public DfbUpdateCheckManifestResponse(Uri uri, byte[] data) { this.uri = uri; this.data = data; }
  public override Uri ResponseUri { get { return uri; } }
  public override long ContentLength { get { return data.LongLength; } set { } }
  public override string ContentType { get { return "application/json"; } set { } }
  public override Stream GetResponseStream() { return new MemoryStream(data, false); }
  public override void Close() { }
}
'@
  }
  $script:ManifestFake = New-Object DfbUpdateCheckManifestCreator
  Assert-Fixture ([Net.WebRequest]::RegisterPrefix($script:BoosterManifestUrl, $script:ManifestFake)) `
    "RegisterPrefix($script:BoosterManifestUrl) 失败：本进程里已有同一前缀"

  # 清单字段形状取自发版产物；每个场景只改 version / displayVersion / minimumSupportedVersion。
  # Shape：'inline' = 发版形状（内置更新可用）；'no-hash' = 删掉 sha256 与 size；'untrusted-url' = setupUrl 换成白名单外的域名。
  # 后两种让生产 Test-BoosterUpdate 判出 CanInline=False，对话框走「退回浏览器下载」那一支
  $script:ShippedManifestText = [IO.File]::ReadAllText($shippedManifestPath, [Text.Encoding]::UTF8)
  $shipped = $script:ShippedManifestText | ConvertFrom-Json
  foreach ($p in 'version', 'displayVersion', 'minimumSupportedVersion', 'setupUrl', 'sha256', 'size') {
    Assert-Fixture ($null -ne $shipped.PSObject.Properties[$p]) "build\update-manifest.json 缺少字段 $p"
  }
  function New-FixtureManifestJson([string]$Version, [string]$DisplayVersion, [string]$Minimum, [string]$Shape = 'inline') {
    $m = $script:ShippedManifestText | ConvertFrom-Json
    $m.version = $Version
    $m.displayVersion = $DisplayVersion
    $m.minimumSupportedVersion = $Minimum
    if ($Shape -ceq 'no-hash') {
      $m.PSObject.Properties.Remove('sha256')
      $m.PSObject.Properties.Remove('size')
    } elseif ($Shape -ceq 'untrusted-url') {
      $m.setupUrl = 'https://downloads.example.invalid/DeltaForceBooster-Setup.exe'
    } elseif ($Shape -cne 'inline') {
      throw "FIXTURE PROBLEM: 未知的清单形状 $Shape"
    }
    $m | ConvertTo-Json
  }

  # 本次运行独有的假版本号：机器上若有真实的旧跳过记录，也不可能恰好等于它们。
  # 末段故意有前缀/后缀关系的成对取值（1 / 10 / 19、5 / 51、8 / 81）：跳过判断必须逐字相等，不能是子串/前缀/正则匹配
  $seed = [guid]::NewGuid().ToByteArray()
  $script:VerMid1 = 100 + [int]$seed[0]
  $script:VerMid2 = 100 + [int]$seed[1]
  function New-FixtureVersion([int]$N) { "9.$($script:VerMid1).$($script:VerMid2).$N" }

  # ---------- UI 桩：只替换真正要画窗口/写日志框/弹提示框的部分 ----------

  $ui = @{ UpdateBtn = (New-Object Windows.Controls.Button); CheckUpdBtn = (New-Object Windows.Controls.Button) }
  $script:FxLog = New-Object 'System.Collections.Generic.List[string]'
  $script:FxDialogCalls = New-Object 'System.Collections.Generic.List[object]'
  $script:FxDialogProblems = New-Object 'System.Collections.Generic.List[string]'
  $script:FxConfirmCalls = New-Object 'System.Collections.Generic.List[string]'
  $script:FxUserTicksSkip = $false
  $script:FxProbeResetButtons = $false
  function Write-Log([string]$Msg) { $script:FxLog.Add($Msg) }
  # 手动检查的「已是最新 / 检查失败」提示框：只记下文案
  function Show-ConfirmDialog { $script:FxConfirmCalls.Add((@($args | ForEach-Object { "$_" }) -join ' | ')); $true }
  # 主窗口在本测试里不存在：更新对话框的 Owner 是 $null（生产是主窗口；没显示过的 Window 不能当 Owner）。
  # 主题资源字典用 GUI 的原文
  $window = $null
  $script:ThemeRes = [Windows.Markup.XamlReader]::Parse($script:ThemeResXamlText)

  # 原用户 broker：签名（param 块，含 Action 的 ValidateSet）取自 GUI 原文；只记下「前往下载」要打开的网址，绝不真开浏览器
  $script:FxOpenUrlCalls = New-Object 'System.Collections.Generic.List[string]'
  Assert-Fixture ($null -ne $brokerAst.Body.ParamBlock) 'GUI 的 Invoke-EngineHostUserAction 不再有 param(...) 块：broker 桩取不到生产签名'
  Invoke-Expression ("function Invoke-EngineHostUserAction {`n" + $brokerAst.Body.ParamBlock.Extent.Text + "`n" +
    '  if ($Action -cne ''OpenUrl'') { throw "更新对话框调用了意外的 broker 动作 $Action" }' + "`n" +
    '  $script:FxOpenUrlCalls.Add("$Payload")' + "`n}")

  # ---------- 更新对话框：真模态，用户在真正显示出来的窗口上操作 ----------
  # 替换 Show-UpdateDialog 里 `$script:UpdDlg.ShowDialog()` 那个调用：对生产建好、挂好处理器的同一个窗口调用真正的
  # ShowDialog()。只改摆放与激活（屏幕外、不抢焦点；生产是 CenterOwner），不碰内容与处理器。「用户」由同一调度器上的
  # 定时器扮演，等窗口真的渲染出来（ContentRendered）之后：
  #   - 记下「不再提醒此版本」的 Visibility / IsEnabled / IsVisible（真在屏幕上：自身与所有上级都可见）；
  #   - FxProbeResetButtons：调生产 Reset-UpdDialogButtons（下载失败/取消后的按钮复位），再看复选框还在不在屏幕上；
  #   - FxUserTicksSkip：只勾得到在屏幕上且可用的复选框，经 UI 自动化 Toggle（与鼠标点击同一条切换路径）；
  #   - 点关窗按钮：场景指定的 FxCloseWith，否则非强制更新点「稍后再说」、强制更新点「前往下载」（它没有「稍后再说」）。
  #     按钮必须在屏幕上且可用；由生产的按钮处理器设 DialogResult、关窗。
  # ShowDialog() 的返回值原样交回生产代码。在生产的调用链里（tick 的 catch {} 会吞异常），所以这里不抛：
  # 夹具自身的问题记到 FxDialogProblems，用户关不掉窗口之类的产品问题记到这次调用的 UserProblem，都由驱动方核对。
  # 「用户」只认屏幕上的那个窗口：观察与点击都按名字在本次真正 ShowDialog() 的窗口里找控件（FxDlgWindow），不经生产的
  # $script:UpdDlg / $script:UpdUi —— 两者平时是同一批对象；被嵌套的第二个对话框改写之后，用户点的仍是自己眼前那个窗口的按钮（X 场景）。
  # FxDuringDialog：窗口渲染出来、用户动手之前在模态帧里做一次的事（例如让周期复查的定时器触发）；FxHoldDialogUntil：用户等它成立再动手。
  # 在一个更新对话框的模态期间生产又要显示第二个：产品问题，记进 FxNestedDialogs（由 DLG.no-nested 与各场景报），不再真的显示它——
  # 夹具的「用户」一次只扮演一个窗口；外层窗口照常由用户操作，改写的后果照样看得见。
  Add-Type -AssemblyName UIAutomationProvider
  $script:FxCloseWith = ''
  $script:FxMainWindowCloses = 0
  $script:FxDialogDepth = 0
  $script:FxNestedDialogs = New-Object 'System.Collections.Generic.List[string]'
  $script:FxNestedReported = 0
  $script:FxDuringDialog = $null
  $script:FxHoldDialogUntil = $null
  function Invoke-FixtureUserSeesUpdateDialog($Info) {
    if ($script:FxDialogDepth -gt 0) {
      $script:FxNestedDialogs.Add("v$($Info.DisplayVersion) 在 v$($script:FxDlgCall.DisplayVersion) 的更新对话框模态期间被弹出")
      return $false
    }
    $call = [pscustomobject]@{
      Version = "$($Info.Version)"; DisplayVersion = "$($Info.DisplayVersion)"; Mandatory = [bool]$Info.Mandatory
      Rendered = $false; VerText = ''; UpdBtnVisibility = ''
      SkipVisibility = ''; SkipEnabled = $false; SkipOnScreen = $false
      ResetSkipVisibility = ''; ResetSkipOnScreen = $false
      UserTicked = $false; ClosedWith = ''; UserProblem = ''; Reported = $false
      ShowDialogResult = $null; DialogResultAfter = $null; Held = ''
    }
    $script:FxDialogCalls.Add($call)
    $dlg = $script:UpdDlg
    if (-not ($dlg -is [Windows.Window])) { $script:FxDialogProblems.Add('生产 Show-UpdateDialog 没有建出 $script:UpdDlg 窗口'); return $null }
    $script:FxDlgWindow = $dlg
    $dlg.WindowStartupLocation = [Windows.WindowStartupLocation]::Manual
    $dlg.Left = -32000
    $dlg.Top = -32000
    $dlg.ShowActivated = $false
    $script:FxDlgCall = $call
    $script:FxDlgRendered = $false
    $script:FxDlgActedAt = $null
    $script:FxDlgForced = $false
    $script:FxDlgDeadline = [DateTime]::UtcNow.AddSeconds(20)
    # 处理器按挂上的先后执行：生产（或变异后）挂在 ContentRendered 上的处理器都先于这一个跑完
    $dlg.Add_ContentRendered({ $script:FxDlgRendered = $true })
    # 强制更新点「前往下载」时生产会关主窗口（$window.Close()，即退出程序）。主窗口在本测试里不存在：模态期间给它一个
    # 只记账的替身 —— 处理器按 PowerShell 的动态作用域解析 $window，会先找到这里；Owner 在调用本函数之前已按生产设成 $null
    $window = New-Object psobject
    Add-Member -InputObject $window -MemberType ScriptMethod -Name Close -Value { $script:FxMainWindowCloses++ }
    $script:FxUserTimer = New-Object Windows.Threading.DispatcherTimer
    $script:FxUserTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    $script:FxUserTimer.Add_Tick({ Invoke-FixtureDialogUser })
    $script:FxUserTimer.Start()
    $res = $null
    $script:FxDialogDepth++
    try { $res = $dlg.ShowDialog() }
    catch { $script:FxDialogProblems.Add("真模态 ShowDialog() 抛出异常：$($_.Exception.Message)") }
    finally { $script:FxUserTimer.Stop(); $script:FxDialogDepth-- }
    # 嵌套的 Show-UpdateDialog 不一定走得到上面的深度检查：模态期间 $window 是本函数的替身，它在 `.Owner = $window` 就抛了
    # （被 tick 的 catch {} 吞掉）—— 但在那之前已经改写了 $script:UpdDlg / UpdDlgInfo，外层的按钮照样失灵。按改写本身认
    if (-not [object]::ReferenceEquals($script:UpdDlg, $dlg)) {
      $script:FxNestedDialogs.Add("v$($call.DisplayVersion) 的更新对话框模态期间生产又建了一个（`$script:UpdDlgInfo 成了 v$($script:UpdDlgInfo.DisplayVersion)）")
    }
    $call.ShowDialogResult = $res
    $call.DialogResultAfter = $dlg.DialogResult
    $res
  }

  # 用户的手（定时器 tick 里跑；不抛）
  function Invoke-FixtureDialogUser {
    $dlg = $script:FxDlgWindow
    $call = $script:FxDlgCall
    try {
      if ($null -eq $script:FxDlgActedAt) {
        if (-not ($script:FxDlgRendered -and $dlg.IsLoaded -and $dlg.IsVisible)) {
          if ([DateTime]::UtcNow -gt $script:FxDlgDeadline) { throw '更新对话框 20 秒内没有真正显示（渲染）出来' }
          return
        }
        $chk = $dlg.FindName('SkipChk')
        if (-not $call.Rendered) {
          $call.Rendered = $true
          $call.VerText = "$($dlg.FindName('VerText').Text)"
          $call.UpdBtnVisibility = "$($dlg.FindName('UpdBtn').Visibility)"
          if ($chk -is [Windows.Controls.CheckBox]) {
            $call.SkipVisibility = "$($chk.Visibility)"
            $call.SkipEnabled = [bool]$chk.IsEnabled
            $call.SkipOnScreen = [bool]$chk.IsVisible
          }
          if ($script:FxDuringDialog) {
            # 只对第一个渲染出来的对话框做一次
            $during = $script:FxDuringDialog
            $script:FxDuringDialog = $null
            $script:FxDlgHoldDeadline = [DateTime]::UtcNow.AddSeconds(40)
            $call.Held = 'holding'
            & $during
          }
        }
        if ($call.Held -ceq 'holding') {
          if ($script:FxHoldDialogUntil -and -not (& $script:FxHoldDialogUntil)) {
            if ([DateTime]::UtcNow -gt $script:FxDlgHoldDeadline) { throw '更新对话框开着时要等的事 40 秒内没有完成' }
            return
          }
          $call.Held = 'released'
        }
        $script:FxDlgActedAt = [DateTime]::UtcNow
        if ($chk -is [Windows.Controls.CheckBox]) {
          if ($script:FxProbeResetButtons) {
            Reset-UpdDialogButtons
            $call.ResetSkipVisibility = "$($chk.Visibility)"
            $call.ResetSkipOnScreen = [bool]$chk.IsVisible
          }
          if ($script:FxUserTicksSkip -and $chk.IsVisible -and $chk.IsEnabled) {
            $peer = New-Object Windows.Automation.Peers.CheckBoxAutomationPeer($chk)
            [void][Windows.Automation.Provider.IToggleProvider].GetMethod('Toggle').Invoke($peer, @())
            $call.UserTicked = ($chk.IsChecked -eq $true)
          }
        } else {
          # 对话框里压根没有「不再提醒此版本」是产品问题（用户无从跳过），不是夹具问题：
          # 记成「没有」，由各场景的 skip-offered / skip-hidden 断言按产品失败报出来
          $call.SkipVisibility = '(no SkipChk)'
          $call.ResetSkipVisibility = '(no SkipChk)'
        }
        $with = $(if ($script:FxCloseWith) { $script:FxCloseWith } elseif ($call.Mandatory) { 'GoBtn' } else { 'LaterBtn' })
        $btn = $dlg.FindName($with)
        if (-not ($btn -is [Windows.Controls.Button] -and $btn.IsVisible -and $btn.IsEnabled)) {
          $call.UserProblem = "对话框里的 $with 不在屏幕上或不可用，用户没法这样关窗"
          Close-FixtureDialogForcibly
          return
        }
        $call.ClosedWith = $with
        try { $btn.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        catch {
          $call.UserProblem = "点 $with 时生产的处理器抛出异常：$($_.Exception.Message)"
          Close-FixtureDialogForcibly
        }
        return
      }
      # 已经点过：生产的处理器应当已经关窗；10 秒还开着就是关不掉（产品问题），强行关；再关不掉只好退出所有调度帧
      $since = ([DateTime]::UtcNow - $script:FxDlgActedAt).TotalSeconds
      if (-not $script:FxDlgForced -and $since -gt 10) {
        $call.UserProblem = "点了 $($call.ClosedWith) 之后 10 秒对话框仍没关"
        Close-FixtureDialogForcibly
      } elseif ($script:FxDlgForced -and $since -gt 20) {
        $script:FxDialogProblems.Add('强行关窗也没能结束模态对话框，只好退出所有调度帧')
        $script:FxDlgActedAt = [DateTime]::UtcNow.AddDays(1)
        [Windows.Threading.Dispatcher]::ExitAllFrames()
      }
    } catch {
      $script:FxDialogProblems.Add("对话框用户夹具出错：$($_.Exception.Message)")
      if ($null -eq $script:FxDlgActedAt) { $script:FxDlgActedAt = [DateTime]::UtcNow }
      Close-FixtureDialogForcibly
    }
  }
  function Close-FixtureDialogForcibly {
    $script:FxDlgForced = $true
    $script:AllowMandatoryDialogClose = $true
    try { $script:FxDlgWindow.Close() } catch {}
  }
  function Get-FixtureDialogCall([int]$Index) {
    if ($Index -ge 0 -and $Index -lt $script:FxDialogCalls.Count) { $script:FxDialogCalls[$Index] } else { $null }
  }
  # 「不再提醒此版本」在用户眼里的样子（断言消息用）
  function Format-FixtureSkipState($Call) {
    if ($null -eq $Call) { return '没有弹窗' }
    "Visibility=[$($Call.SkipVisibility)] IsVisible=[$($Call.SkipOnScreen)] IsEnabled=[$($Call.SkipEnabled)] 勾上=[$($Call.UserTicked)]"
  }
  # 用户是怎么关窗的（断言消息用）
  function Format-FixtureClose($Call) {
    if ($null -eq $Call) { return '没有弹窗' }
    "点 $($Call.ClosedWith) 关窗，ShowDialog 返回 [$($Call.ShowDialogResult)]，DialogResult=[$($Call.DialogResultAfter)]"
  }

  # 生产函数原文
  Invoke-Expression $tuningActiveAst.Extent.Text
  Invoke-Expression $resetButtonsAst.Extent.Text
  Invoke-Expression $script:FixtureShowUpdateDialogText
  Invoke-Expression $showDetectedAst.Extent.Text
  Invoke-Expression $startUpdateCheckAst.Extent.Text
  Invoke-Expression $manualCheckAst.Extent.Text
  Invoke-Expression $chipVisualAst.Extent.Text
  Invoke-Expression $tuningUiAst.Extent.Text
  Invoke-Expression $busyStateAst.Extent.Text

  # 标题栏更新入口：先挂一个计数器（证明「用户点击」真的派发到了按钮的 Click 事件），再挂生产处理器原文
  $script:FxTitleClicks = 0
  $ui.UpdateBtn.Add_Click({ $script:FxTitleClicks++ })
  $ui.UpdateBtn.Add_Click($script:UpdateBtnClickBlock)

  # ---------- 驱动 ----------

  # 泵 WPF 调度器直到 $Done 成立（或超时）；DispatcherTimer 的 tick 就在这里被真正派发
  function Wait-FixtureDispatcher([scriptblock]$Done, [int]$TimeoutMs) {
    $script:FxPumpDone = $Done
    $script:FxPumpFrame = New-Object Windows.Threading.DispatcherFrame
    $script:FxPumpDeadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $script:FxPumpTimedOut = $false
    $fxPump = New-Object Windows.Threading.DispatcherTimer
    $fxPump.Interval = [TimeSpan]::FromMilliseconds(40)
    $fxPump.Add_Tick({
      if (& $script:FxPumpDone) { $script:FxPumpFrame.Continue = $false }
      elseif ([DateTime]::UtcNow -gt $script:FxPumpDeadline) { $script:FxPumpTimedOut = $true; $script:FxPumpFrame.Continue = $false }
    })
    $fxPump.Start()
    try { [Windows.Threading.Dispatcher]::PushFrame($script:FxPumpFrame) } finally { $fxPump.Stop() }
    -not $script:FxPumpTimedOut
  }

  # 把调度器里已经排着的工作跑完：排一个 ContextIdle（比 Normal / Background 都低）优先级的哨兵，
  # 哨兵跑到时，之前按任何常规优先级排进来的工作（例如 Set-BusyState 收尾 BeginInvoke 的补弹）都已经跑完了
  function Wait-FixtureDispatcherQueue {
    $script:FxSentinel = $false
    [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ContextIdle,
      [action]{ $script:FxSentinel = $true })
    Assert-Fixture (Wait-FixtureDispatcher { $script:FxSentinel } 10000) '调度器 10 秒内没有跑到哨兵：排队的工作没有机会执行'
  }

  # 生产 Set-BusyState。它在收尾时用 $window.Dispatcher.BeginInvoke 补弹 Show-DetectedUpdateDialog；本测试没有主窗口
  # （见上：更新对话框的 Owner 只能是 $null），所以只在调用期间给它一个局部 $window，其 Dispatcher 就是本线程（UI 线程）的
  # 调度器 —— 和主窗口的是同一个（WPF 一个线程一个调度器）。补弹真正执行时 $window 照旧是 $null，与对话框夹具一致
  function Invoke-FixtureSetBusyState([bool]$On) {
    $window = [pscustomobject]@{ Dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher }
    Set-BusyState $On
    Assert-Fixture ([bool]$script:Busy -eq $On) "生产 Set-BusyState `$$On 之后 `$script:Busy 是 [$script:Busy]"
    if ($On) {
      Assert-Fixture (-not $ui.UpdateBtn.IsEnabled) "生产 Set-BusyState `$true 没有禁用标题栏更新入口：本测试的「忙碌」不成立"
    } else {
      # 忙碌结束后入口必须恢复可点：亮着却点不动就是「亮着的死入口」—— 产品问题，按产品失败报，场景继续往下走
      Assert-Soft ([bool]$ui.UpdateBtn.IsEnabled) `
        "[Z.busy-end-entry-enabled] 执行优化/还原结束后标题栏更新入口仍是禁用的（Visibility=$($ui.UpdateBtn.Visibility)）：亮着却点不动"
    }
  }
  # 一次「执行优化 / 还原 / 导出报告」：生产 Set-BusyState $true …… Set-BusyState $false，再让收尾时排队的补弹跑完
  function Invoke-FixtureBusyCycle {
    Invoke-FixtureSetBusyState $true
    Invoke-FixtureSetBusyState $false
    Wait-FixtureDispatcherQueue
    Assert-FixtureDialogsHealthy 'busy cycle'
  }

  # 用户点标题栏更新入口：只点得到看得见、可用的入口（忙碌时 Set-BusyState 会禁用它）。点了返回 $true
  function Invoke-FixtureTitleBarClick {
    if ("$($ui.UpdateBtn.Visibility)" -cne 'Visible' -or -not $ui.UpdateBtn.IsEnabled) { return $false }
    $before = $script:FxTitleClicks
    $ui.UpdateBtn.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Assert-Fixture ($script:FxTitleClicks -eq $before + 1) '标题栏更新入口的 Click 事件没有派发到处理器'
    Assert-FixtureDialogsHealthy 'title-bar click'
    $true
  }

  # 每个场景 = 一次全新的 GUI 启动：生产的受保护状态初始化（全新 ProgramData 根）、GUI 顶层初始化语句原文重跑、按钮回到 XAML 初值
  function Initialize-FixtureScenario([string]$Name) {
    # 上一场景万一留下了排队的工作（例如补弹），先在上一场景的状态里跑完，免得串到本场景
    Wait-FixtureDispatcherQueue
    Invoke-FixtureProtectedStateInit $Name
    $fxCfg = [IO.Path]::GetFullPath((Get-BoosterUpdateConfigPath))
    Assert-Fixture ($fxCfg.StartsWith($script:TestRoot + '\', [StringComparison]::OrdinalIgnoreCase)) `
      "场景 $Name 的跳过记录会写到测试临时目录之外：$fxCfg"
    Assert-Fixture (-not (Test-Path -LiteralPath $fxCfg)) "场景 $Name 的配置目录不是全新的：$fxCfg 已存在"
    Reset-FixtureGuiSession
    Assert-Fixture (-not $script:UpdateCheckBusy -and -not $script:ManualCheckBusy) "场景 $Name 开始时上一轮更新检查还没结束"
  }
  function Reset-FixtureGuiSession {
    foreach ($fxInit in $script:GuiInitStatements) { Invoke-Expression $fxInit }
    $script:ManualCheckBusy = $null   # GUI 顶层不初始化它：新进程里就是未定义
    $ui.UpdateBtn.Visibility = $script:XamlUpdateBtnVisibility
    $ui.UpdateBtn.ToolTip = $null
    $ui.UpdateBtn.IsEnabled = $true
    $ui.CheckUpdBtn.IsEnabled = $true
    $script:FxDialogCalls.Clear()
    $script:FxDialogProblems.Clear()
    $script:FxConfirmCalls.Clear()
    $script:FxLog.Clear()
    $script:FxUserTicksSkip = $false
    $script:FxProbeResetButtons = $false
    $script:FxCloseWith = ''
    $script:FxOpenUrlCalls.Clear()
    $script:FxMainWindowCloses = 0
    $script:FxDialogDepth = 0
    $script:FxNestedDialogs.Clear()
    $script:FxNestedReported = 0
    $script:FxDuringDialog = $null
    $script:FxHoldDialogUntil = $null
    $script:ActiveTuningExperiment = $null
    Assert-Fixture (-not (Test-TuningExperimentActive)) 'Test-TuningExperimentActive 在没有实验时返回了真'
    Assert-Fixture ("$($ui.UpdateBtn.Visibility)" -ceq $script:XamlUpdateBtnVisibility -and $null -eq $script:UpdateInfo -and
      -not $script:UpdateDialogOpen -and -not $script:Busy -and $null -eq $script:UpdatePromptedVersion) 'GUI 会话状态没有回到初始值'
  }

  # 同一份清单在测试线程上用 -IncludeSkipped 走一遍生产 Test-BoosterUpdate：证明下发的清单本身是一个
  # 有效的 v$Version 更新（否则「没弹窗」可能只是清单坏了），并且内置更新可用与否正是本场景要走的那一支。要在写跳过记录之前做。
  function Invoke-FixtureManifestProbe([string]$Version, [bool]$Mandatory, [bool]$CanInline = $true) {
    $hits = $script:ManifestFake.CreateCount
    $probe = Test-BoosterUpdate -CurrentVersion $script:GuiVersion -IncludeSkipped
    Assert-Fixture ($script:ManifestFake.CreateCount -eq $hits + 1) '探针请求没有落到假清单上（RegisterPrefix 没有接管默认清单地址）'
    Assert-Fixture ($null -ne $probe -and -not ($probe -is [array]) -and "$($probe.Version)" -ceq $Version) `
      "假清单没有产出 v$Version 的更新（得到 [$($probe.Version)]）：夹具下发的清单本身不成立"
    Assert-Fixture ([bool]$probe.CanInline -eq $CanInline) `
      "v$Version 的清单判出 CanInline=$([bool]$probe.CanInline)（$($probe.InlineDeny)），本场景要的是 $CanInline：对话框走的不是要测的那一支"
    # 强制与否是生产 Test-BoosterUpdate 按 minimumSupportedVersion 算的：算错是产品问题，不是夹具问题
    Assert-True ([bool]$probe.Mandatory -eq $Mandatory) `
      ("[P.mandatory-calc] 生产 Test-BoosterUpdate 对 minimumSupportedVersion=[$($probe.MinimumSupportedVersion)]、当前 $script:GuiVersion 的清单" +
       "判出 Mandatory=$([bool]$probe.Mandatory)，应为 $Mandatory")
    $probe
  }

  # 驱动方核对：每次弹窗都真的模态显示、渲染出来过，用户真的在上面操作过（VerText 由生产写入），
  # ShowDialog() 是关窗后正常返回的（只会是 $true / $false），夹具的「用户」没有出错；
  # 用户没法用按钮关掉对话框（按钮不在屏幕上 / 不可用 / 点了不关 / 处理器抛异常）是产品问题，按产品失败报一次
  function Assert-FixtureDialogsHealthy([string]$Via) {
    Assert-Fixture ($script:FxDialogProblems.Count -eq 0) "更新对话框夹具出了问题（$Via）：$($script:FxDialogProblems -join '; ')"
    foreach ($c in $script:FxDialogCalls) {
      Assert-Fixture $c.Rendered "v$($c.DisplayVersion) 的更新对话框没有真正显示出来，用户没机会操作（$Via）"
      Assert-Fixture ($c.VerText.Contains($c.DisplayVersion)) "生产 Show-UpdateDialog 没有把 v$($c.DisplayVersion) 写进对话框（VerText=[$($c.VerText)]，$Via）"
      Assert-Fixture ($c.ShowDialogResult -is [bool]) "v$($c.DisplayVersion) 的真模态 ShowDialog() 没有正常返回（[$($c.ShowDialogResult)]，$Via）"
      if (-not $c.Reported) {
        $c.Reported = $true
        Assert-Soft (-not $c.UserProblem) "[DLG.user-can-close] v$($c.DisplayVersion) 的更新对话框：$($c.UserProblem)（$Via）"
      }
    }
    # 一个更新对话框还开着，生产又弹第二个（嵌套在它的模态帧里）：每次嵌套报一次
    while ($script:FxNestedReported -lt $script:FxNestedDialogs.Count) {
      Assert-Soft $false ("[DLG.no-nested] $($script:FxNestedDialogs[$script:FxNestedReported])：第二个对话框改写了外层正在用的 `$script:UpdDlg 等全局状态，" +
        "外层对话框的按钮从此操作的不是它自己（$Via）")
      $script:FxNestedReported++
    }
  }

  # 生产周期 tick 原文挂到真 DispatcherTimer 上，只触发一次；不等它（X 场景在更新对话框的模态帧里用它）
  function Start-FixturePeriodicTick {
    $script:FxPeriodicFired = 0
    $script:FxPeriodicTimer = New-Object Windows.Threading.DispatcherTimer
    $script:FxPeriodicTimer.Interval = [TimeSpan]::FromMilliseconds(30)
    # 先挂的先跑：先记一次并停表（只要一次），再跑生产 tick 原文
    $script:FxPeriodicTimer.Add_Tick({ $script:FxPeriodicFired++; $script:FxPeriodicTimer.Stop() })
    $script:FxPeriodicTimer.Add_Tick($script:PeriodicTickBlock)
    $script:FxPeriodicTimer.Start()
  }

  # 一次自动检查：startup = ContentRendered 的直接调用；periodic = 生产周期 tick 原文挂到真 DispatcherTimer 上触发
  function Invoke-FixtureUpdateCheck([string]$Via) {
    Assert-Fixture (-not $script:UpdateCheckBusy) "上一轮更新检查还没结束，无法开始新一轮（$Via）"
    $hits = $script:ManifestFake.CreateCount
    $served = $script:ManifestFake.ResponseCount
    if ($Via -eq 'startup') {
      Start-UpdateCheck
      Assert-Fixture ([bool]$script:UpdateCheckBusy) 'Start-UpdateCheck 返回后没有处于检查中：更新模块未加载或后台 runspace 没有启动'
    } else {
      Start-FixturePeriodicTick
      Assert-Fixture (Wait-FixtureDispatcher { $script:FxPeriodicFired -ge 1 } 10000) '周期复查定时器 10 秒内没有触发'
      Assert-Fixture ($script:FxPeriodicFired -eq 1) "周期复查定时器触发了 $script:FxPeriodicFired 次，应为 1 次"
      Assert-True ([bool]$script:UpdateCheckBusy) '[P.periodic-starts-check] 生产的周期复查 tick 触发后没有开始更新检查'
    }
    Assert-Fixture (Wait-FixtureDispatcher { -not $script:UpdateCheckBusy } 30000) `
      "30 秒内 UpdateCheckBusy 没有回到 false（$Via）：后台 runspace 或界面线程 tick 没有跑完"
    Assert-Fixture (-not $script:UpdateTimer.IsEnabled) "界面线程 tick 没有停下 `$script:UpdateTimer（$Via）"
    Assert-Fixture ($script:ManifestFake.CreateCount -eq $hits + 1) `
      "后台 runspace 没有取清单（$Via，命中 $($script:ManifestFake.CreateCount - $hits) 次，应为 1 次）"
    Assert-Fixture ($script:ManifestFake.ResponseCount -eq $served + 1) "后台 runspace 没有拿到清单内容（$Via）"
    Assert-Fixture ($script:ManifestFake.LastUri -ceq $script:BoosterManifestUrl) `
      "后台 runspace 取的不是生产默认清单地址：$($script:ManifestFake.LastUri)"
    Assert-FixtureDialogsHealthy $Via
  }

  # 一次手动检查：「检查更新」按钮处理器调的 Start-ManualUpdateCheck 原文
  function Invoke-FixtureManualCheck {
    Assert-Fixture (-not $script:ManualCheckBusy) '上一轮手动检查还没结束'
    $hits = $script:ManifestFake.CreateCount
    Start-ManualUpdateCheck
    Assert-Fixture ([bool]$script:ManualCheckBusy) 'Start-ManualUpdateCheck 返回后没有处于检查中：更新模块未加载或后台 runspace 没有启动'
    Assert-Fixture (Wait-FixtureDispatcher { -not $script:ManualCheckBusy } 30000) '30 秒内 ManualCheckBusy 没有回到 false：手动检查没有跑完'
    Assert-Fixture (-not $script:ManualCheckTimer.IsEnabled) '手动检查的界面线程 tick 没有停下'
    Assert-Fixture ($script:ManifestFake.CreateCount -ge $hits + 1) '手动检查的后台 runspace 没有取清单'
    Assert-Fixture ($script:ManifestFake.LastUri -ceq $script:BoosterManifestUrl) "手动检查取的不是生产默认清单地址：$($script:ManifestFake.LastUri)"
    Assert-FixtureDialogsHealthy 'manual'
  }

  function Get-FixtureLogCount([string]$Needle) { @($script:FxLog | Where-Object { $_.Contains($Needle) }).Count }
  function Get-FixtureSkipRecord { "$((Get-BoosterUpdateConfig).SkippedVersion)" }
  # 场景前提「跳过记录已经是 $Version」：用生产的 Set-BoosterSkipVersion 写、按读回的记录核对。
  # 它的返回值是产品行为（界面据此写如实日志），由 H0.save-reports-success / V.save-reports-failure 单独断言，
  # 不拿来当夹具前提 —— 否则「返回值丢了」这种产品回归会让十几个场景以 FIXTURE PROBLEM 中止、看不到产品针。
  # 读回不符同样是产品问题（写读不是同一份记录）：记一条产品失败，场景照常往下走，各场景自己的断言照样报
  function Set-FixtureSkipRecord([string]$Version) {
    [void](Set-BoosterSkipVersion $Version)
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $Version) `
      "[R.record-written] 用生产 Set-BoosterSkipVersion 写下 [$Version] 后读回的跳过记录是 [$(Get-FixtureSkipRecord)]：场景的前提（已跳过 / 已清空）没有成立"
  }
  function New-FixtureInfo([string]$Version, [bool]$Mandatory) {
    [pscustomobject]@{ Version = $Version; DisplayVersion = "$Version-display"; Mandatory = $Mandatory }
  }

  # ---------- H：Test-BoosterUpdateSkipped 本身 ----------

  Invoke-Scenario 'H Test-BoosterUpdateSkipped' {
    Assert-True ([bool](Get-Command Test-BoosterUpdateSkipped -CommandType Function -ErrorAction SilentlyContinue)) `
      '[H0.defined] scripts\updater.ps1 没有定义 Test-BoosterUpdateSkipped（界面线程过滤的唯一判定）'
    $x = New-FixtureVersion 91
    $x1 = New-FixtureVersion 92
    Initialize-FixtureScenario 'H'
    $info = New-FixtureInfo $x $false
    $h1 = $null; $h1Threw = $null
    try { $h1 = Test-BoosterUpdateSkipped $info } catch { $h1Threw = $_.Exception.Message }
    Assert-Soft ($null -eq $h1Threw -and $h1 -is [bool] -and -not $h1) "[H1.no-record] 没有任何跳过记录时 v$x 应判为未跳过（得到 [$h1]，异常 [$h1Threw]）"

    Assert-Soft ((Set-BoosterSkipVersion '') -eq $true) `
      '[H0.save-reports-success] 写入成功时 Set-BoosterSkipVersion 应返回 $true：界面靠它决定写「已设置不再提醒」还是「没能保存」'
    # 写入落点必须就是读取方读的那个文件；否则下面的「空记录」用例根本没有记录可读
    Assert-True (Test-Path -LiteralPath (Get-BoosterUpdateConfigPath) -PathType Leaf) `
      '[H0.record-file] Set-BoosterSkipVersion 写完后，Get-BoosterUpdateConfigPath 指向的配置文件并不存在：写入与读取不是同一个文件'
    $emptyInfo = [pscustomobject]@{ Version = ''; DisplayVersion = ''; Mandatory = $false }
    Assert-Soft (-not (Test-BoosterUpdateSkipped $emptyInfo)) '[H2.empty-record] 空的 SkippedVersion 与空版本号「相等」被判成已跳过'
    Assert-Soft (-not (Test-BoosterUpdateSkipped $info)) "[H2.empty-record-real] 空的 SkippedVersion 让 v$x 被判成已跳过"

    Set-FixtureSkipRecord $x
    Assert-True ((Get-FixtureSkipRecord) -ceq $x) "[H0.round-trip] Set-BoosterSkipVersion $x 之后，Get-BoosterUpdateConfig 读回的记录是 [$(Get-FixtureSkipRecord)]"
    $r = $null; $threw = $null
    try { $r = Test-BoosterUpdateSkipped $null } catch { $threw = $_.Exception.Message }
    Assert-Soft ($null -eq $threw -and $r -is [bool] -and -not $r) "[H3.null-info] Test-BoosterUpdateSkipped `$null 应返回 `$false（得到 [$r]，异常 [$threw]）"
    Assert-Soft (-not (Test-BoosterUpdateSkipped (New-FixtureInfo $x $true))) "[H4.mandatory] 强制更新 v$x 被「不再提醒」跳过了"
    $hit = Test-BoosterUpdateSkipped $info
    Assert-Soft ($hit -is [bool] -and $hit) "[H5.match] 跳过记录 v$x 与更新 v$x（显示版本 $x-display）不匹配（得到 [$hit]）"
    Assert-Soft (-not (Test-BoosterUpdateSkipped (New-FixtureInfo $x1 $false))) "[H6.other-version] 跳过 v$x 连更新的 v$x1 也挡了"

    # 逐字相等，不是子串 / 前缀 / 后缀 / 正则：跳过 v…1 不能连带挡掉 v…10、v…19、v1…1
    $p = New-FixtureVersion 1
    Set-FixtureSkipRecord $p
    $hp = Test-BoosterUpdateSkipped (New-FixtureInfo $p $false)
    Assert-Soft ($hp -is [bool] -and $hp) "[H7.match-short] 跳过记录 v$p 与更新 v$p 不匹配（得到 [$hp]）"
    foreach ($longer in (New-FixtureVersion 10), (New-FixtureVersion 19)) {
      Assert-Soft (-not (Test-BoosterUpdateSkipped (New-FixtureInfo $longer $false))) "[H7.prefix-version] 跳过 v$p 连以它开头的 v$longer 也挡了"
    }
    $suffixed = "1$p"
    Assert-Soft (-not (Test-BoosterUpdateSkipped (New-FixtureInfo $suffixed $false))) "[H8.suffix-version] 跳过 v$p 连以它结尾的 v$suffixed 也挡了"
  }

  # ---------- G：Test-BoosterUpdate 自己的跳过判断（file:// 清单） ----------

  Invoke-Scenario 'G Test-BoosterUpdate file-manifest' {
    $x = New-FixtureVersion 8
    $x1 = New-FixtureVersion 81
    Initialize-FixtureScenario 'G'
    $mf = Join-Path $script:TestRoot 'G\update-manifest.json'
    $url = ([Uri]$mf).AbsoluteUri
    $utf8 = New-Object Text.UTF8Encoding($false)
    $hits = $script:ManifestFake.CreateCount
    [IO.File]::WriteAllText($mf, (New-FixtureManifestJson $x "$x-display" $script:GuiVersion), $utf8)
    $r0 = Test-BoosterUpdate -CurrentVersion $script:GuiVersion -ManifestUrl $url -IncludeSkipped
    Assert-Fixture ($null -ne $r0 -and "$($r0.Version)" -ceq $x) "file:// 清单 $url 读不出 v$x 的更新：G 的夹具不成立"
    Assert-True (-not $r0.Mandatory) "[G0.min-equals-current] minimumSupportedVersion 等于当前版本 $script:GuiVersion 时不是强制更新，Test-BoosterUpdate 却判成 Mandatory=$($r0.Mandatory)"
    $rn = Test-BoosterUpdate -CurrentVersion $script:GuiVersion -ManifestUrl $url
    Assert-Soft ($null -ne $rn -and "$($rn.Version)" -ceq $x) "[G0.no-record] 还没有任何跳过记录时，Test-BoosterUpdate（不带 -IncludeSkipped）没有报出 v$x（得到 [$($rn.Version)]）"
    Set-FixtureSkipRecord $r0.Version

    $r1 = Test-BoosterUpdate -CurrentVersion $script:GuiVersion -ManifestUrl $url
    Assert-Soft ($null -eq $r1) "[G1.skip-honoured] 已跳过 v$x，Test-BoosterUpdate（不带 -IncludeSkipped）仍返回了 v$($r1.Version)"
    $r2 = Test-BoosterUpdate -CurrentVersion $script:GuiVersion -ManifestUrl $url -IncludeSkipped
    Assert-Soft ($null -ne $r2 -and "$($r2.Version)" -ceq $x) "[G2.include-skipped] -IncludeSkipped 没有无视跳过记录返回 v$x（得到 [$($r2.Version)]）"

    [IO.File]::WriteAllText($mf, (New-FixtureManifestJson $x "$x-display" $x), $utf8)
    $r3 = Test-BoosterUpdate -CurrentVersion $script:GuiVersion -ManifestUrl $url
    Assert-Soft ($null -ne $r3 -and "$($r3.Version)" -ceq $x -and $r3.Mandatory -eq $true) `
      "[G3.mandatory] v$x 低于 minimumSupportedVersion 时是强制更新，跳过记录不该挡住它（得到 [$($r3.Version)] Mandatory=[$($r3.Mandatory)]）"

    # v$x1 以 v$x 开头：跳过 v$x 不能连带挡掉它
    [IO.File]::WriteAllText($mf, (New-FixtureManifestJson $x1 "$x1-display" $script:GuiVersion), $utf8)
    $r4 = Test-BoosterUpdate -CurrentVersion $script:GuiVersion -ManifestUrl $url
    Assert-Soft ($null -ne $r4 -and "$($r4.Version)" -ceq $x1) "[G4.newer] 跳过 v$x 后，更新的 v$x1 没有被报出来（得到 [$($r4.Version)]）"
    Assert-Fixture ($script:ManifestFake.CreateCount -eq $hits) 'file:// 清单的请求落到了 https 假清单上'
  }

  # ---------- A / A2：已跳过 X、清单给 X → 什么都不该发生 ----------

  function Invoke-SkippedSameVersionScenario([string]$Tag, [int]$N, [bool]$DistinctDisplay) {
    $x = New-FixtureVersion $N
    $disp = $(if ($DistinctDisplay) { "$x-display" } else { $x })
    Initialize-FixtureScenario $Tag
    $script:ManifestFake.Body = New-FixtureManifestJson $x $disp $script:GuiVersion
    $probe = Invoke-FixtureManifestProbe $x $false
    # 用户在对话框里勾「不再提醒此版本」：生产收尾调的就是 Set-BoosterSkipVersion <更新对象>.Version（F1 按行为核对了记下的版本）
    Set-FixtureSkipRecord $probe.Version
    Assert-Soft (@(Get-ChildItem -LiteralPath $script:BoosterUserConfigDir -File).Count -ge 1) `
      "[$Tag.record-in-config-dir] Set-BoosterSkipVersion 写下的跳过记录不在受保护配置目录 [$script:BoosterUserConfigDir] 里"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) "[$Tag.record] Set-BoosterSkipVersion 写下的记录没有被 Get-BoosterUpdateConfig 读回（读到 [$(Get-FixtureSkipRecord)]）"

    Invoke-FixtureUpdateCheck 'startup'
    # 两道关：tick 的过滤让已跳过的版本既不点亮入口、不进 UpdateInfo、不记日志，也不弹窗；780fb30 起
    # Show-DetectedUpdateDialog 自己也看跳过记录，所以只拆掉 tick 过滤时弹窗仍被挡住，红的是 button / updateinfo / log
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) `
      "[$Tag.dialog] 已勾「不再提醒此版本」的 v$x 仍被自动检查弹出了更新对话框（Show-UpdateDialog 被调用 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[$Tag.button] 已跳过 v$x，标题栏更新入口却变成了 $($ui.UpdateBtn.Visibility)"
    Assert-Soft ($null -eq $script:UpdateInfo) "[$Tag.updateinfo] 已跳过 v$x，`$script:UpdateInfo 却被设成了 v$($script:UpdateInfo.Version)"
    Assert-Soft ((Get-FixtureLogCount '检测到新版本') -eq 0) "[$Tag.log] 已跳过 v$x，日志里仍出现「检测到新版本」"

    # 同一场景里的对照：清掉跳过记录，同一份清单再查一次就该弹 —— 上面的「安静」确实是跳过记录挡下的，不是后台没拿到更新
    Set-FixtureSkipRecord ''
    Invoke-FixtureUpdateCheck 'periodic'
    $d0 = Get-FixtureDialogCall 0
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) `
      "[$Tag.twin-dialog] 清掉跳过记录后，同一份清单的下一次检查应弹出 v$x（实际 $($script:FxDialogCalls.Count) 次）：前面的「没弹」不能归因于跳过记录"
  }

  Invoke-Scenario 'A skipped X, manifest X' { Invoke-SkippedSameVersionScenario 'A' 11 $true }
  # 发版产物的形状：displayVersion 与 version 逐字一致
  Invoke-Scenario 'A2 skipped X, manifest X (displayVersion == version)' { Invoke-SkippedSameVersionScenario 'A2' 21 $false }

  # ---------- B：对照组 —— 跳过的是别的版本，照常弹；「稍后再说」后周期复查不重复提醒 ----------

  Invoke-Scenario 'B control: skipped Y, manifest X' {
    $x = New-FixtureVersion 31
    $y = New-FixtureVersion 39
    Initialize-FixtureScenario 'B'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    Set-FixtureSkipRecord $y
    $script:FxProbeResetButtons = $true
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxProbeResetButtons = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) `
      "[B.dialog-once] 跳过的是 v$y，v$x 应自动弹一次更新对话框（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ($null -ne $d0 -and $d0.SkipOnScreen -and $d0.SkipEnabled) `
      "[B.skip-offered] 非强制更新 v$x 的对话框里「不再提醒此版本」应在屏幕上、可勾（实际 $(Format-FixtureSkipState $d0)）"
    Assert-Soft ($null -ne $d0 -and $d0.ResetSkipOnScreen) `
      "[B.reset-skip-offered] 下载失败/取消后 Reset-UpdDialogButtons 复位按钮，非强制更新的「不再提醒此版本」应仍在屏幕上（实际 Visibility=[$($d0.ResetSkipVisibility)] IsVisible=[$($d0.ResetSkipOnScreen)]）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[B.button] 发现 v$x 后标题栏更新入口应为 Visible（实际 $($ui.UpdateBtn.Visibility)）"
    Assert-Soft ("$($ui.UpdateBtn.ToolTip)".Contains("$x-display")) "[B.tooltip] 更新入口提示没有写显示版本 $x-display：[$($ui.UpdateBtn.ToolTip)]"
    Assert-Soft ($null -ne $script:UpdateInfo -and "$($script:UpdateInfo.Version)" -ceq $x) "[B.updateinfo] `$script:UpdateInfo 应为 v$x（实际 [$($script:UpdateInfo.Version)]）"
    Assert-Soft ((Get-FixtureLogCount '检测到新版本') -eq 1) "[B.log] 发现 v$x 应记一条「检测到新版本」（实际 $(Get-FixtureLogCount '检测到新版本') 条）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $y) "[B.record] 用户没勾「不再提醒」，跳过记录却从 $y 变成了 [$(Get-FixtureSkipRecord)]"

    # 用户选了「稍后再说」；30 分钟后的周期复查又见到同一个 v$x：不再弹、不再记「检测到新版本」，入口保持点亮
    Invoke-FixtureUpdateCheck 'periodic'
    Assert-Soft ($script:FxDialogCalls.Count -eq 1) "[B.periodic-no-second-dialog] 同一版本 v$x 本次运行只该自动弹一次，周期复查又弹了（累计 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ((Get-FixtureLogCount '检测到新版本') -eq 1) `
      "[B.periodic-log-once] 周期复查对已经提示过的 v$x 又记了「检测到新版本 … 正在显示更新详情」（共 $(Get-FixtureLogCount '检测到新版本') 条）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[B.periodic-button] 「稍后再说」之后标题栏入口应保持点亮（实际 $($ui.UpdateBtn.Visibility)）"
    Assert-Soft ($null -ne $script:UpdateInfo -and "$($script:UpdateInfo.Version)" -ceq $x) "[B.periodic-updateinfo] 周期复查后 `$script:UpdateInfo 应仍为 v$x"
  }

  # ---------- C：强制更新不可跳过 ----------

  Invoke-Scenario 'C skipped X, X mandatory' {
    $x = New-FixtureVersion 41
    Initialize-FixtureScenario 'C'
    # minimumSupportedVersion = X 高于当前版本 → 强制更新
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $x
    $probe = Invoke-FixtureManifestProbe $x $true
    Set-FixtureSkipRecord $probe.Version
    # 用户想再勾一次「不再提醒」：强制更新的对话框里根本不该给这个选项
    $script:FxUserTicksSkip = $true
    $script:FxProbeResetButtons = $true
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxUserTicksSkip = $false
    $script:FxProbeResetButtons = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x -and $d0.Mandatory) `
      "[C.dialog-mandatory] v$x 是强制更新，曾勾过「不再提醒」也必须弹出（实际弹了 $($script:FxDialogCalls.Count) 次）"
    # 「不提供」= 不在屏幕上（Collapsed 与 Hidden 只差布局占位，都算），用户也就勾不上
    Assert-Soft ($null -ne $d0 -and -not $d0.SkipOnScreen -and -not $d0.UserTicked) `
      "[C.skip-hidden] 强制更新 v$x 的对话框里仍提供「不再提醒此版本」（$(Format-FixtureSkipState $d0)）"
    Assert-Soft ($null -ne $d0 -and -not $d0.ResetSkipOnScreen) `
      "[C.reset-skip-hidden] Reset-UpdDialogButtons 复位后，强制更新 v$x 的对话框又露出了「不再提醒此版本」（Visibility=[$($d0.ResetSkipVisibility)] IsVisible=[$($d0.ResetSkipOnScreen)]）"
    Assert-Soft ($null -ne $script:UpdateInfo -and $script:UpdateInfo.Mandatory -eq $true) '[C.updateinfo] 强制更新没有进入 $script:UpdateInfo（或 Mandatory 丢了）'
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[C.button] 强制更新 v$x 的标题栏入口应为 Visible（实际 $($ui.UpdateBtn.Visibility)）"
  }

  # ---------- D：跳过 X，出了 X+1 → 重新提醒（X+1 的文本以 X 开头） ----------

  Invoke-Scenario 'D skipped X, manifest X+1' {
    $x = New-FixtureVersion 5
    $x1 = New-FixtureVersion 51
    Initialize-FixtureScenario 'D'
    $script:ManifestFake.Body = New-FixtureManifestJson $x1 "$x1-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x1 $false)
    Set-FixtureSkipRecord $x
    Invoke-FixtureUpdateCheck 'startup'
    $d0 = Get-FixtureDialogCall 0
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x1) `
      "[D.dialog-newer] 跳过的是 v$x，更新的 v$x1 应自动弹一次（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[D.button] 发现 v$x1 后标题栏更新入口应为 Visible（实际 $($ui.UpdateBtn.Visibility)）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) "[D.record-unchanged] 跳过记录应仍是 $x（实际 [$(Get-FixtureSkipRecord)]）"
  }

  # ---------- E：启动检查 + 周期复查，两轮都不该提醒 ----------

  Invoke-Scenario 'E skipped X, two checks' {
    $x = New-FixtureVersion 61
    Initialize-FixtureScenario 'E'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    $probe = Invoke-FixtureManifestProbe $x $false
    Set-FixtureSkipRecord $probe.Version
    Invoke-FixtureUpdateCheck 'startup'
    Invoke-FixtureUpdateCheck 'periodic'
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) "[E.dialog] 已跳过 v$x，启动检查 + 周期复查共弹了 $($script:FxDialogCalls.Count) 次对话框"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[E.button] 已跳过 v$x，两轮检查后标题栏入口是 $($ui.UpdateBtn.Visibility)"
    Assert-Soft ($null -eq $script:UpdateInfo) "[E.updateinfo] 已跳过 v$x，两轮检查后 `$script:UpdateInfo 是 v$($script:UpdateInfo.Version)"
    Assert-Soft ((Get-FixtureLogCount '检测到新版本') -eq 0) "[E.log] 已跳过 v$x，两轮检查后日志里有「检测到新版本」"
    # 同场景对照：清掉跳过记录后下一轮就弹
    Set-FixtureSkipRecord ''
    Invoke-FixtureUpdateCheck 'periodic'
    $d0 = Get-FixtureDialogCall 0
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) `
      "[E.twin-dialog] 清掉跳过记录后，同一份清单的第三次检查应弹出 v$x（实际 $($script:FxDialogCalls.Count) 次）：前两轮的「没弹」不能归因于跳过记录"
  }

  # ---------- F：本次运行中才勾的「不再提醒」 ----------

  Invoke-Scenario 'F skip recorded in-session' {
    $x = New-FixtureVersion 71
    Initialize-FixtureScenario 'F'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    Assert-Fixture ((Get-FixtureSkipRecord) -ceq '') 'F 开始时不该有跳过记录'

    # 第一次（启动）检查：弹窗，用户勾「不再提醒此版本」后关窗 —— 落盘由 Show-UpdateDialog 收尾原文完成
    $script:FxUserTicksSkip = $true
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxUserTicksSkip = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) `
      "[F1.dialog] 还没有跳过记录时，v$x 应自动弹一次（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ($d0.SkipOnScreen -and $d0.UserTicked) `
      "[F1.skip-offered] 非强制更新 v$x 的对话框里用户勾不到「不再提醒此版本」（$(Format-FixtureSkipState $d0)）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) `
      "[F1.record] 用户在对话框里勾了「不再提醒」再$(Format-FixtureClose $d0)，跳过记录应为 $x（实际 [$(Get-FixtureSkipRecord)]）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[F1.button] 用户选了「不再提醒」，标题栏更新入口应收起（实际 $($ui.UpdateBtn.Visibility)）"
    Assert-Soft ((Get-FixtureLogCount "已设置不再提醒 v$x") -eq 1 -and (Get-FixtureLogCount '没能保存') -eq 0) `
      ("[F1.success-log] 「不再提醒 v$x」已存上（记录读回 [$(Get-FixtureSkipRecord)]），日志应恰好一条「已设置不再提醒 v$x」、不该有「没能保存」" +
       "（实际：$($script:FxLog -join ' / ')）")

    # 第二次：同一会话里生产周期 tick 触发的复查
    Invoke-FixtureUpdateCheck 'periodic'
    Assert-Soft ($script:FxDialogCalls.Count -eq 1) "[F2.dialog] 本次运行里刚勾了「不再提醒」，周期复查又弹了对话框（累计 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[F2.button] 本次运行里刚勾了「不再提醒」，周期复查把标题栏入口又点亮成 $($ui.UpdateBtn.Visibility)"
    Assert-Soft ((Get-FixtureLogCount '检测到新版本') -eq 1) "[F2.log] 周期复查对已跳过的 v$x 又记了「检测到新版本」（共 $(Get-FixtureLogCount '检测到新版本') 条）"

    # 第三次：重启 GUI —— 受保护状态重新初始化（同一个 ProgramData 根，记录还在），会话状态回到初值
    Invoke-FixtureProtectedStateInit 'F'
    Reset-FixtureGuiSession
    Invoke-FixtureUpdateCheck 'startup'
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) "[F3.dialog] 上次运行勾了「不再提醒」v$x，重启后仍弹出更新对话框（$($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[F3.button] 重启后已跳过的 v$x 仍点亮标题栏入口（$($ui.UpdateBtn.Visibility)）"
    Assert-Soft ($null -eq $script:UpdateInfo) "[F3.updateinfo] 重启后已跳过的 v$x 仍进入了 `$script:UpdateInfo"
  }

  # ---------- M：手动「检查更新」不受跳过记录影响；看完点「稍后再说」后，自动入口照旧尊重跳过记录 ----------

  Invoke-Scenario 'M manual check shows a skipped version' {
    $x = New-FixtureVersion 15
    Initialize-FixtureScenario 'M'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    $probe = Invoke-FixtureManifestProbe $x $false
    Set-FixtureSkipRecord $probe.Version
    # 启动时的自动检查按跳过记录保持安静（A 场景的结论）；随后用户主动点「检查更新」
    Invoke-FixtureUpdateCheck 'startup'
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) "[M.auto-suppressed] 已跳过 v$x，启动时的自动检查弹了对话框"
    Invoke-FixtureManualCheck
    $d0 = Get-FixtureDialogCall 0
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) `
      "[M.manual-shows-skipped] 用户主动点「检查更新」应看到已跳过的 v$x（弹了 $($script:FxDialogCalls.Count) 次）：手动检查不该被「不再提醒此版本」挡住"
    Assert-Soft (@($script:FxConfirmCalls | Where-Object { $_.Contains('已是最新') -or $_.Contains('检查更新失败') }).Count -eq 0) `
      "[M.manual-not-latest] 清单里有 v$x，手动检查却提示了 [$($script:FxConfirmCalls -join ' / ')]"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[M.manual-button] 手动检查发现 v$x 后标题栏入口应为 Visible（实际 $($ui.UpdateBtn.Visibility)）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) "[M.record-unchanged] 用户没勾「不再提醒」，跳过记录却从 $x 变成了 [$(Get-FixtureSkipRecord)]"

    # 用户点了「稍后再说」，随后执行一次优化/还原：收尾的 Set-BusyState $false 不该把这个已跳过的版本自动补弹出来（780fb30）
    $n = $script:FxDialogCalls.Count
    Invoke-FixtureBusyCycle
    Assert-Soft ($script:FxDialogCalls.Count -eq $n) `
      "[M.busy-no-reprompt] 已跳过的 v$x 只是被手动「检查更新」看了一眼（点了「稍后再说」），执行一次优化/还原收尾时又被自动弹了出来（累计 $($script:FxDialogCalls.Count) 次）"
    # 30 分钟周期复查：已跳过，自动检查不弹
    $n = $script:FxDialogCalls.Count
    Invoke-FixtureUpdateCheck 'periodic'
    Assert-Soft ($script:FxDialogCalls.Count -eq $n) "[M.periodic-no-dialog] 已跳过的 v$x，周期复查又弹了（复查前 $n 次，复查后 $($script:FxDialogCalls.Count) 次）"

    # 入口亮着就必须点得开（不能亮着却是死的）；这次用户在详情里勾「不再提醒」→ 入口收起
    $n = $script:FxDialogCalls.Count
    $script:FxUserTicksSkip = $true
    $clicked = Invoke-FixtureTitleBarClick
    $script:FxUserTicksSkip = $false
    $dc = Get-FixtureDialogCall $n
    Assert-Soft ($clicked -and $script:FxDialogCalls.Count -eq $n + 1 -and $dc.Version -ceq $x) `
      ("[M.click-opens-dialog] 手动检查后标题栏入口是 $($ui.UpdateBtn.Visibility)（点击=$clicked），点了却没有打开 v$x 的更新详情" +
       "（弹窗累计 $($script:FxDialogCalls.Count) 次）：入口亮着却是死的")
    Assert-Soft ($null -ne $dc -and $dc.UserTicked -and "$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') `
      "[M.click-skip-collapses] 从标题栏入口打开 v$x 并勾了「不再提醒」后，入口应收起（勾上=$($dc.UserTicked)，入口 $($ui.UpdateBtn.Visibility)）"
  }

  # ---------- T：标题栏入口 —— 自动弹窗点了「稍后再说」，之后从入口打开并勾「不再提醒」 ----------

  Invoke-Scenario 'T title-bar entry: later, then skip from the entry' {
    $x = New-FixtureVersion 13
    Initialize-FixtureScenario 'T'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    Invoke-FixtureUpdateCheck 'startup'
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and -not (Get-FixtureDialogCall 0).UserTicked) `
      "[T.auto-dialog] 没有跳过记录时 v$x 应自动弹一次（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-True ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[T.lit-after-later] 自动弹窗点了「稍后再说」后标题栏入口应亮着（实际 $($ui.UpdateBtn.Visibility)）"

    $script:FxUserTicksSkip = $true
    $clicked = Invoke-FixtureTitleBarClick
    $script:FxUserTicksSkip = $false
    $d1 = Get-FixtureDialogCall 1
    Assert-True ($clicked -and $script:FxDialogCalls.Count -eq 2 -and $d1.Version -ceq $x) `
      "[T.click-opens-dialog] 点亮着的标题栏入口应打开 v$x 的更新详情（点击=$clicked，弹窗累计 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ($d1.SkipOnScreen -and $d1.UserTicked) `
      "[T.skip-offered] 从标题栏入口打开的非强制更新 v$x 对话框里勾不到「不再提醒此版本」（$(Format-FixtureSkipState $d1)）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) "[T.record] 用户在标题栏入口打开的对话框里勾了「不再提醒」，跳过记录应为 $x（实际 [$(Get-FixtureSkipRecord)]）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') `
      "[T.button-collapsed] 用户从标题栏入口勾了「不再提醒」v$x，入口应收起（实际 $($ui.UpdateBtn.Visibility)）：已跳过的版本整个运行期间一直亮着"
    Assert-Soft ((Get-FixtureLogCount "已设置不再提醒 v$x") -eq 1) "[T.success-log] 跳过记录已存上，日志里应有一条「已设置不再提醒 v$x」（实际：$($script:FxLog -join ' / ')）"

    # 30 分钟后的周期复查：v$x 已跳过 —— 不弹、入口不再亮
    Invoke-FixtureUpdateCheck 'periodic'
    Assert-Soft ($script:FxDialogCalls.Count -eq 2) "[T.periodic-no-dialog] 已从标题栏入口跳过 v$x，周期复查又弹了（累计 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[T.periodic-button] 已从标题栏入口跳过 v$x，周期复查后入口是 $($ui.UpdateBtn.Visibility)"
  }

  # ---------- Q：手动检查的对话框里勾「不再提醒」，再执行一次优化/还原 ----------

  Invoke-Scenario 'Q manual check: skip ticked, then a busy cycle' {
    $x = New-FixtureVersion 17
    Initialize-FixtureScenario 'Q'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    $script:FxUserTicksSkip = $true
    Invoke-FixtureManualCheck
    $script:FxUserTicksSkip = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) "[Q.manual-dialog] 手动「检查更新」应弹出 v$x 的更新详情（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ($d0.SkipOnScreen -and $d0.UserTicked) "[Q.skip-offered] 手动检查弹出的非强制更新 v$x 对话框里勾不到「不再提醒此版本」（$(Format-FixtureSkipState $d0)）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) "[Q.record] 用户在手动检查的对话框里勾了「不再提醒」，跳过记录应为 $x（实际 [$(Get-FixtureSkipRecord)]）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') `
      "[Q.button-collapsed] 用户在手动检查的对话框里勾了「不再提醒」v$x，标题栏入口应收起（实际 $($ui.UpdateBtn.Visibility)）"

    # 随后执行一次优化/还原：收尾的 Set-BusyState $false 不该把刚跳过的 v$x 再自动弹出来（780fb30）
    Invoke-FixtureBusyCycle
    Assert-Soft ($script:FxDialogCalls.Count -eq 1) `
      "[Q.busy-no-reprompt] 用户在手动检查里刚勾了「不再提醒」v$x，执行一次优化/还原收尾时又被自动弹了出来（累计 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[Q.busy-button] 忙碌结束后，已跳过的 v$x 的标题栏入口是 $($ui.UpdateBtn.Visibility)"
    $n = $script:FxDialogCalls.Count
    Invoke-FixtureUpdateCheck 'periodic'
    Assert-Soft ($script:FxDialogCalls.Count -eq $n) "[Q.periodic-no-dialog] 手动检查里跳过的 v$x，周期复查又弹了（复查前 $n 次，复查后 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[Q.periodic-button] 手动检查里跳过的 v$x，周期复查后入口是 $($ui.UpdateBtn.Visibility)"
  }

  # ---------- U：手动检查当面看过（「稍后再说」），再执行一次优化/还原 —— 同一版本本次运行不再自动补弹 ----------

  Invoke-Scenario 'U manual check: later, then a busy cycle' {
    $x = New-FixtureVersion 25
    Initialize-FixtureScenario 'U'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    Invoke-FixtureManualCheck
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) "[U.manual-dialog] 手动「检查更新」应弹出 v$x 的更新详情（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-True ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[U.manual-button] 手动检查发现 v$x、点了「稍后再说」后标题栏入口应亮着（实际 $($ui.UpdateBtn.Visibility)）"
    Invoke-FixtureBusyCycle
    Assert-Soft ($script:FxDialogCalls.Count -eq 1) `
      ("[U.busy-no-reprompt] 手动「检查更新」已当面弹过 v$x（用户点了「稍后再说」），执行一次优化/还原收尾时又自动弹了一次" +
       "（累计 $($script:FxDialogCalls.Count) 次）：同一版本本次运行只该自动提示一次")
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[U.busy-button] 「稍后再说」之后标题栏入口应保持点亮（实际 $($ui.UpdateBtn.Visibility)）"
    # 入口仍然点得开
    $n = $script:FxDialogCalls.Count
    $clicked = Invoke-FixtureTitleBarClick
    Assert-Soft ($clicked -and $script:FxDialogCalls.Count -eq $n + 1 -and (Get-FixtureDialogCall $n).Version -ceq $x) `
      "[U.click-opens-dialog] 亮着的标题栏入口（$($ui.UpdateBtn.Visibility)，点击=$clicked）没有打开 v$x 的更新详情"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq '') "[U.record-unchanged] 用户从没勾过「不再提醒」，跳过记录却成了 [$(Get-FixtureSkipRecord)]"
  }

  # ---------- K：检查结果在忙碌中回来（执行优化/还原期间），忙碌结束时 Set-BusyState 补弹 ----------

  # K0 对照：没有跳过记录的 v$x 在忙碌中被检出 —— 忙碌时不弹，收尾时补弹一次（证明本测试驱动的补弹确实会弹）
  Invoke-Scenario 'K0 control: X found while busy -> deferred dialog' {
    $x = New-FixtureVersion 33
    Initialize-FixtureScenario 'K0'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    Invoke-FixtureSetBusyState $true
    Invoke-FixtureUpdateCheck 'startup'
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) "[K0.no-dialog-while-busy] 执行优化/还原期间检出 v$x，不该当场弹窗打断（弹了 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible' -and $null -ne $script:UpdateInfo -and "$($script:UpdateInfo.Version)" -ceq $x) `
      "[K0.lit-while-busy] 忙碌中检出 v$x，入口应点亮、`$script:UpdateInfo 应为 v$x（入口 $($ui.UpdateBtn.Visibility)，UpdateInfo [$($script:UpdateInfo.Version)]）"
    Invoke-FixtureSetBusyState $false
    Wait-FixtureDispatcherQueue
    Assert-FixtureDialogsHealthy 'K0 busy end'
    $d0 = Get-FixtureDialogCall 0
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) `
      "[K0.deferred-dialog] 忙碌中检出、还没提示过的 v$x，忙碌结束时应补弹一次（实际 $($script:FxDialogCalls.Count) 次）"
    Invoke-FixtureBusyCycle
    Assert-Soft ($script:FxDialogCalls.Count -eq 1) "[K0.deferred-once] v$x 已经补弹过，下一次忙碌结束又弹了（累计 $($script:FxDialogCalls.Count) 次）"
  }

  # K1：已跳过的 v$x 在忙碌中被检出 —— 忙碌结束时既不补弹、入口也不该亮（tick 的过滤在忙碌时同样生效）
  Invoke-Scenario 'K1 skipped X found while busy' {
    $x = New-FixtureVersion 35
    Initialize-FixtureScenario 'K1'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    $probe = Invoke-FixtureManifestProbe $x $false
    Set-FixtureSkipRecord $probe.Version
    Invoke-FixtureSetBusyState $true
    Invoke-FixtureUpdateCheck 'startup'
    Invoke-FixtureSetBusyState $false
    Wait-FixtureDispatcherQueue
    Assert-FixtureDialogsHealthy 'K1 busy end'
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) "[K1.dialog] 已跳过的 v$x 在执行优化/还原期间被检出，忙碌结束时被补弹了出来（$($script:FxDialogCalls.Count) 次）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[K1.button] 已跳过的 v$x 在忙碌中被检出，标题栏入口却亮成了 $($ui.UpdateBtn.Visibility)"
    Assert-Soft ($null -eq $script:UpdateInfo) "[K1.updateinfo] 已跳过的 v$x 在忙碌中被检出，`$script:UpdateInfo 却成了 v$($script:UpdateInfo.Version)"
    Assert-Soft ((Get-FixtureLogCount '检测到新版本') -eq 0) "[K1.log] 已跳过的 v$x 在忙碌中被检出，日志里出现了「检测到新版本」"
    # 同场景对照：清掉记录，同样在忙碌中复查一次 → 收尾时补弹
    Set-FixtureSkipRecord ''
    Invoke-FixtureSetBusyState $true
    Invoke-FixtureUpdateCheck 'periodic'
    Invoke-FixtureSetBusyState $false
    Wait-FixtureDispatcherQueue
    Assert-FixtureDialogsHealthy 'K1 twin busy end'
    Assert-Soft ($script:FxDialogCalls.Count -eq 1 -and (Get-FixtureDialogCall 0).Version -ceq $x) `
      "[K1.twin-deferred-dialog] 清掉跳过记录后，忙碌中复查到的 v$x 在忙碌结束时应补弹一次（实际 $($script:FxDialogCalls.Count) 次）：前面的「没弹」不能归因于跳过记录"
  }

  # K2：v$x 在忙碌中被检出（当时还没跳过），等忙碌结束的这段时间里，同一 Windows 用户的另一个会话里的本程序
  # 勾了「不再提醒 v$x」（per-SID 记录是同一个文件）。补弹走 Show-DetectedUpdateDialog，它自己必须看跳过记录
  Invoke-Scenario 'K2 skip recorded after detection, before busy ends' {
    $x = New-FixtureVersion 37
    Initialize-FixtureScenario 'K2'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    Invoke-FixtureSetBusyState $true
    Invoke-FixtureUpdateCheck 'startup'
    # 前提是产品行为（与 K0 同一结论），不成立时按产品失败报，K2 后面的判断随之没有意义
    Assert-True ($script:FxDialogCalls.Count -eq 0 -and $null -ne $script:UpdateInfo -and "$($script:UpdateInfo.Version)" -ceq $x) `
      ("[K2.detected-while-busy] 忙碌中检出、还没跳过的 v$x 应已记进 UpdateInfo 且未当场弹窗" +
       "（弹窗 $($script:FxDialogCalls.Count) 次，UpdateInfo [$($script:UpdateInfo.Version)]）")
    Set-FixtureSkipRecord $x
    Invoke-FixtureSetBusyState $false
    Wait-FixtureDispatcherQueue
    Assert-FixtureDialogsHealthy 'K2 busy end'
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) `
      ("[K2.gate] v$x 的跳过记录在检出之后、忙碌结束之前写下，忙碌结束时的自动补弹（Show-DetectedUpdateDialog）无视它弹了出来" +
       "（$($script:FxDialogCalls.Count) 次）：自动弹窗的共同出口没有看跳过记录")
  }

  # ---------- X：标题栏入口 / 手动检查打开的对话框还开着，周期复查检出了更新的版本 ----------
  # 这两个入口直接调 Show-UpdateDialog。对话框模态期间自己泵消息，30 分钟的周期复查照常派发；检出新版本时 tick 走
  # Show-DetectedUpdateDialog，它只认 $script:UpdateDialogOpen。这个标志原来只由 Show-DetectedUpdateDialog 自己挂，于是第二个
  # 对话框嵌套弹在第一个的模态帧里：$script:UpdDlg / UpdUi / UpdDlgInfo 被改写，外层对话框的「稍后再说」去设内层（已关闭）
  # 窗口的 DialogResult，抛异常、关不掉。用户点的是自己眼前那个窗口的按钮（夹具按名字在 FxDlgWindow 里找）。
  # 新版本被压下之后不能丢：入口亮着、UpdateInfo 是它，下一次忙碌结束时照常补弹。
  function Invoke-NewerWhileOpenScenario([string]$Tag, [int]$N, [string]$Entry) {
    $x = New-FixtureVersion $N
    $y = New-FixtureVersion ($N + 1)
    Initialize-FixtureScenario $Tag
    $script:ManifestFake.Body = New-FixtureManifestJson $y "$y-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $y $false)
    $script:FxNewerManifest = $script:ManifestFake.Body
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    if ($Entry -ceq 'title-bar') {
      # 启动检查弹出 v$x，用户点「稍后再说」：标题栏入口亮着
      Invoke-FixtureUpdateCheck 'startup'
      Assert-True ($script:FxDialogCalls.Count -eq 1 -and "$($ui.UpdateBtn.Visibility)" -ceq 'Visible') `
        "[$Tag.entry-lit] 启动检查应弹一次 v$x、点「稍后再说」后标题栏入口亮着（弹窗 $($script:FxDialogCalls.Count) 次，入口 $($ui.UpdateBtn.Visibility)）"
    }
    $before = $script:FxDialogCalls.Count
    # 对话框开着的时候发布了 v$y，30 分钟的周期复查在它的模态帧里触发；用户等这一轮检查跑完再点「稍后再说」
    $script:FxHitsAtDuring = -1
    $script:FxDuringDialog = {
      $script:ManifestFake.Body = $script:FxNewerManifest
      $script:FxHitsAtDuring = $script:ManifestFake.CreateCount
      Start-FixturePeriodicTick
    }
    $script:FxHoldDialogUntil = { $script:FxPeriodicFired -ge 1 -and -not $script:UpdateCheckBusy }
    if ($Entry -ceq 'title-bar') { $opened = Invoke-FixtureTitleBarClick } else { Invoke-FixtureManualCheck; $opened = $true }
    $script:FxHoldDialogUntil = $null
    $d = Get-FixtureDialogCall $before
    Assert-Fixture ($opened -and $null -ne $d -and $d.Version -ceq $x) "$Tag：$Entry 没有打开 v$x 的更新对话框（弹窗累计 $($script:FxDialogCalls.Count) 次）"
    Assert-Fixture ($d.Held -ceq 'released' -and $script:FxPeriodicFired -eq 1 -and $script:FxHitsAtDuring -ge 0 -and
      $script:ManifestFake.CreateCount -eq $script:FxHitsAtDuring + 1 -and -not $script:UpdateCheckBusy -and -not $script:UpdateTimer.IsEnabled) `
      ("$($Tag)：v$x 的对话框开着时，周期复查没有触发并跑完一轮检查（Held=[$($d.Held)]，触发 $script:FxPeriodicFired 次，" +
       "取清单 $($script:ManifestFake.CreateCount - $script:FxHitsAtDuring) 次）")
    # 锚点：tick 确实在对话框开着时拿到了 v$y，走到了「检出新版本」那一支
    Assert-Fixture ((Get-FixtureLogCount "检测到新版本 v$y-display") -eq 1) `
      "$($Tag)：周期复查没有在 v$x 的对话框开着时检出 v$y（日志：$($script:FxLog -join ' / ')）"
    Assert-Soft ($script:FxNestedDialogs.Count -eq 0 -and $script:FxDialogCalls.Count -eq $before + 1) `
      ("[$Tag.no-nested-dialog] 从 $Entry 入口打开的 v$x 对话框还开着，周期复查检出 v$y 时又建了一个更新对话框" +
       "（嵌套：$($script:FxNestedDialogs -join ' / ')；顶层弹窗 $($script:FxDialogCalls.Count - $before) 次）")
    Assert-Soft ($d.ClosedWith -ceq 'LaterBtn' -and -not $d.UserProblem -and $d.ShowDialogResult -eq $false) `
      "[$Tag.outer-closes] v$x 的对话框没能用它自己的「稍后再说」正常关掉（$(Format-FixtureClose $d)；$($d.UserProblem)）"
    Assert-Soft ($null -ne $script:UpdateInfo -and "$($script:UpdateInfo.Version)" -ceq $y -and "$($ui.UpdateBtn.Visibility)" -ceq 'Visible') `
      "[$Tag.newer-pending] 压下的 v$y 应留在标题栏入口上（UpdateInfo [$($script:UpdateInfo.Version)]，入口 $($ui.UpdateBtn.Visibility)）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq '') "[$Tag.record-unchanged] 用户没勾「不再提醒」，跳过记录却成了 [$(Get-FixtureSkipRecord)]"
    $n = $script:FxDialogCalls.Count
    Invoke-FixtureBusyCycle
    Assert-Soft ($script:FxDialogCalls.Count -eq $n + 1 -and (Get-FixtureDialogCall $n).Version -ceq $y) `
      ("[$Tag.newer-prompted-later] v$y 在对话框开着时被检出、当时没弹，下一次执行优化/还原结束时应补弹一次" +
       "（实际 $($script:FxDialogCalls.Count - $n) 次）")
  }

  Invoke-Scenario 'X1 title-bar dialog open, periodic check finds a newer version' { Invoke-NewerWhileOpenScenario 'X1' 27 'title-bar' }
  Invoke-Scenario 'X2 manual-check dialog open, periodic check finds a newer version' { Invoke-NewerWhileOpenScenario 'X2' 55 'manual' }

  # ---------- N：清单不满足内置更新（退回浏览器下载）—— 对话框同样要给「不再提醒此版本」 ----------

  Invoke-Scenario 'N1 browser-fallback dialog (manifest without sha256/size)' {
    $x = New-FixtureVersion 43
    Initialize-FixtureScenario 'N1'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion 'no-hash'
    [void](Invoke-FixtureManifestProbe $x $false $false)
    $script:FxUserTicksSkip = $true
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxUserTicksSkip = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) "[N1.dialog] 没有跳过记录时 v$x 应自动弹一次（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ($d0.UpdBtnVisibility -ceq 'Collapsed') "[N1.browser-branch] 清单缺 sha256/size（CanInline=False），对话框却仍给「立即更新」（[$($d0.UpdBtnVisibility)]）"
    Assert-Soft ($d0.SkipOnScreen -and $d0.UserTicked) `
      ("[N1.skip-offered] 退回浏览器下载的非强制更新 v$x 对话框里勾不到「不再提醒此版本」（$(Format-FixtureSkipState $d0)）：" +
       '这类更新永远跳不过，每次启动都弹')
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) "[N1.record] 用户在退回浏览器下载的对话框里勾了「不再提醒」，跳过记录应为 $x（实际 [$(Get-FixtureSkipRecord)]）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[N1.button-collapsed] 用户勾了「不再提醒」v$x，标题栏入口应收起（实际 $($ui.UpdateBtn.Visibility)）"
    # 重启 GUI：同一个 ProgramData 根，记录还在 —— 不再自动弹
    Invoke-FixtureProtectedStateInit 'N1'
    Reset-FixtureGuiSession
    Invoke-FixtureUpdateCheck 'startup'
    Assert-Soft ($script:FxDialogCalls.Count -eq 0) "[N1.restart-no-dialog] 上次运行在退回浏览器下载的对话框里跳过了 v$x，重启后又弹了（$($script:FxDialogCalls.Count) 次）"
  }

  Invoke-Scenario 'N2 browser-fallback dialog (setupUrl outside the whitelist)' {
    $x = New-FixtureVersion 45
    Initialize-FixtureScenario 'N2'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion 'untrusted-url'
    [void](Invoke-FixtureManifestProbe $x $false $false)
    $script:FxUserTicksSkip = $true
    $script:FxProbeResetButtons = $true
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxUserTicksSkip = $false
    $script:FxProbeResetButtons = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) "[N2.dialog] 没有跳过记录时 v$x 应自动弹一次（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft ($d0.SkipOnScreen) `
      "[N2.skip-offered] setupUrl 过不了白名单、退回浏览器下载的非强制更新 v$x 对话框里没有「不再提醒此版本」（$(Format-FixtureSkipState $d0)）"
    Assert-Soft ($d0.ResetSkipOnScreen) `
      "[N2.reset-skip-offered] 退回浏览器下载的对话框经 Reset-UpdDialogButtons 复位后，「不再提醒此版本」应仍在屏幕上（Visibility=[$($d0.ResetSkipVisibility)] IsVisible=[$($d0.ResetSkipOnScreen)]）"
    Assert-Soft ($d0.UserTicked -and (Get-FixtureSkipRecord) -ceq $x) "[N2.record] 勾了「不再提醒」后跳过记录应为 $x（勾上=$($d0.UserTicked)，记录 [$(Get-FixtureSkipRecord)]）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[N2.button-collapsed] 用户勾了「不再提醒」v$x，标题栏入口应收起（实际 $($ui.UpdateBtn.Visibility)）"
  }

  Invoke-Scenario 'N3 browser-fallback dialog, mandatory' {
    $x = New-FixtureVersion 47
    Initialize-FixtureScenario 'N3'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $x 'no-hash'
    [void](Invoke-FixtureManifestProbe $x $true $false)
    $script:FxUserTicksSkip = $true
    $script:FxProbeResetButtons = $true
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxUserTicksSkip = $false
    $script:FxProbeResetButtons = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x -and $d0.Mandatory) `
      "[N3.dialog-mandatory] 强制更新 v$x（退回浏览器下载）应自动弹出（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-Soft (-not $d0.SkipOnScreen -and -not $d0.UserTicked) "[N3.skip-hidden] 退回浏览器下载的强制更新 v$x 对话框里仍提供「不再提醒此版本」（$(Format-FixtureSkipState $d0)）"
    Assert-Soft (-not $d0.ResetSkipOnScreen) `
      "[N3.reset-skip-hidden] 复位后强制更新 v$x 的对话框又露出了「不再提醒此版本」（Visibility=[$($d0.ResetSkipVisibility)] IsVisible=[$($d0.ResetSkipOnScreen)]）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq '') "[N3.record-unchanged] 强制更新 v$x 被记成了跳过（[$(Get-FixtureSkipRecord)]）"
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Visible') "[N3.button] 强制更新 v$x 的标题栏入口应为 Visible（实际 $($ui.UpdateBtn.Visibility)）"
  }

  # ---------- O：勾了「不再提醒此版本」再点「前往下载」—— 生产处理器打开下载页、DialogResult=$true 关窗，勾选照样算数 ----------
  # （其余场景都是点「稍后再说」关的窗，生产把 DialogResult 设成 $false；两种关法跳过记录都必须落下）

  function Invoke-GoAfterSkipScenario([string]$Tag, [int]$N, [string]$Shape) {
    $x = New-FixtureVersion $N
    Initialize-FixtureScenario $Tag
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion $Shape
    $probe = Invoke-FixtureManifestProbe $x $false ($Shape -ceq 'inline')
    Assert-Fixture ("$($probe.Url)" -like 'https://*') "清单的下载页 [$($probe.Url)] 不是 https：生产「前往下载」会拦下它，测不到点了它关窗的那一支"
    $script:FxUserTicksSkip = $true
    $script:FxCloseWith = 'GoBtn'
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxUserTicksSkip = $false
    $script:FxCloseWith = ''
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x) "[$Tag.dialog] 没有跳过记录时 v$x 应自动弹一次（实际 $($script:FxDialogCalls.Count) 次）"
    Assert-True ($d0.ClosedWith -ceq 'GoBtn') "[$Tag.go-clickable] 非强制更新 v$x 的对话框里用户点不了「前往下载」（$($d0.UserProblem)）"
    Assert-Soft ($d0.SkipOnScreen -and $d0.UserTicked) "[$Tag.skip-offered] 非强制更新 v$x 的对话框里用户勾不到「不再提醒此版本」（$(Format-FixtureSkipState $d0)）"
    Assert-Soft ((Get-FixtureSkipRecord) -ceq $x) `
      ("[$Tag.record] 用户勾了「不再提醒」再$(Format-FixtureClose $d0)，跳过记录应为 $x（实际 [$(Get-FixtureSkipRecord)]）：" +
       '选了去下载页自己下载，同样不该再被自动提醒')
    Assert-Soft ("$($ui.UpdateBtn.Visibility)" -ceq 'Collapsed') "[$Tag.button] 用户勾了「不再提醒」v$x 再点「前往下载」，标题栏入口应收起（实际 $($ui.UpdateBtn.Visibility)）"
    Assert-Soft ($script:FxOpenUrlCalls.Count -eq 1 -and $script:FxOpenUrlCalls[0] -ceq "$($probe.Url)") `
      "[$Tag.go-opened] 点「前往下载」应经 broker 打开清单里的下载页 [$($probe.Url)] 一次（实际：$($script:FxOpenUrlCalls -join ' / ')）"
  }

  Invoke-Scenario 'O1 inline dialog: tick skip, then 前往下载' { Invoke-GoAfterSkipScenario 'O1' 63 'inline' }
  Invoke-Scenario 'O2 browser-fallback dialog: tick skip, then 前往下载' { Invoke-GoAfterSkipScenario 'O2' 65 'no-hash' }

  # ---------- V：勾了「不再提醒」却没存上 —— 日志必须如实说 ----------

  Invoke-Scenario 'V skip ticked but the record cannot be saved' {
    $x = New-FixtureVersion 53
    Initialize-FixtureScenario 'V'
    $script:ManifestFake.Body = New-FixtureManifestJson $x "$x-display" $script:GuiVersion
    [void](Invoke-FixtureManifestProbe $x $false)
    # 配置文件的位置被一个同名目录占着：既存不进记录，也读不出记录（这里不调读取函数，只看文件系统）
    $cfgPath = Get-BoosterUpdateConfigPath
    [void][IO.Directory]::CreateDirectory($cfgPath)
    Assert-Fixture ((Test-Path -LiteralPath $cfgPath -PathType Container) -and -not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) `
      "没能让 $cfgPath 变成目录：保存失败的前提不成立"
    # 界面的如实日志靠 Set-BoosterSkipVersion 的返回值：写不进去时它必须报告失败
    Assert-Soft ((Set-BoosterSkipVersion $x) -eq $false) `
      "[V.save-reports-failure] $cfgPath 被目录占着、写不进去，Set-BoosterSkipVersion 却报告保存成功：界面只能谎称「已设置不再提醒」"
    $script:FxUserTicksSkip = $true
    Invoke-FixtureUpdateCheck 'startup'
    $script:FxUserTicksSkip = $false
    $d0 = Get-FixtureDialogCall 0
    Assert-True ($script:FxDialogCalls.Count -eq 1 -and $d0.Version -ceq $x -and $d0.UserTicked) `
      ("[V.dialog] 跳过记录读不出（配置文件位置是个目录）时，v$x 应照常自动弹一次、用户勾得到「不再提醒」" +
       "（弹窗 $($script:FxDialogCalls.Count) 次）：读不出的记录不能让更新提醒整个消失")
    Assert-Fixture ((Test-Path -LiteralPath $cfgPath -PathType Container) -and -not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) `
      '保存失败的前提被改变了：配置文件位置不再是目录'
    Assert-Soft (@($script:FxLog | Where-Object { $_.Contains("v$x") -and $_.Contains('没能保存') }).Count -eq 1) `
      ("[V.save-failed-log] 「不再提醒 v$x」没有存上（配置文件写不进去），日志里应有一条说明「没能保存」、下次启动仍会提示" +
       "（实际：$($script:FxLog -join ' / ')）")
    Assert-Soft ((Get-FixtureLogCount '已设置不再提醒') -eq 0) `
      "[V.no-false-success-log] 「不再提醒 v$x」没有存上，日志却写「已设置不再提醒」（实际：$($script:FxLog -join ' / ')）"
  }

  Assert-Soft ((Get-RealLocalUpdaterState) -ceq $localUpdaterBefore) `
    "[L.localappdata] 真实 LocalAppData 的 DeltaForceBooster 配置目录被改动了（本测试与修好的产品都不该碰它）：$script:RealLocalConfigDir"
}
finally {
  try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:Failures.Count -gt 0) {
  Write-Host ''
  Write-Host "update-check tests FAILED: $($script:Failures.Count) failure(s), $script:Assertions assertions"
  foreach ($f in $script:Failures) { Write-Host "  $f" }
  exit 1
}
Write-Host "update-check tests passed: $script:Assertions assertions"
exit 0
