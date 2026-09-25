#requires -Version 5.1
param()

# 启动引导日志的回归测试。
# 这一层存在的唯一理由：主界面前三千行任何失败原本都不产生磁盘记录，
# 「软件打不开」类反馈因此无法定位。下面每条断言都在守护一个让它失效的方式。

$ErrorActionPreference = 'Stop'
# 各探针 finally 里清理临时目录一律 -ErrorAction SilentlyContinue：杀软或索引器临时占着句柄时，
# 清理失败不该把一次通过的测试变红（复核提出的抖动风险）。
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI AST parse failed: ' + (($errors | ForEach-Object Message) -join '; '))
$raw = [IO.File]::ReadAllText($guiPath, [Text.Encoding]::UTF8)

# 整棵 GUI 语法树只遍历一次，把后面要用的节点按种类收进桶里。PS 5.1 里整树 FindAll 逐节点回调一遍约 0.4 秒，
# 每条检查各自 FindAll 会让本文件多出好几秒。桶里的函数定义按文档顺序保留全部，按名字取时取第一个
# （与原来 FindAll | Select-Object -First 1 相同）；受保护状态变量的读写、会话标志的赋值、调用点留给后面的接线检查。
$protectedStateVars = @('ProtectedUserStateRoot', 'UserDataRoot', 'ConfigDir', 'ProfileDir', 'UserConfigDir', 'BoosterUserConfigDir')
$stateVarKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $protectedStateVars) { [void]$stateVarKeys.Add($name); [void]$stateVarKeys.Add("script:$name") }
$assignKeys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @($stateVarKeys) + @('script:BootLogPath', 'script:OriginalUserSid',
                                        'script:RepairOnlySession', 'script:NetCafeCompatibilityMode',
                                        'ProgramDataRoot', 'script:ProgramDataRoot', 'CommonAppData', 'script:CommonAppData')) {
  [void]$assignKeys.Add($name)
}
$guiFunctionDefs = @{}
$guiFunctionDefList = New-Object System.Collections.ArrayList
$guiInitCalls = New-Object System.Collections.ArrayList
$guiSetTargetCalls = New-Object System.Collections.ArrayList
$guiDotSources = New-Object System.Collections.ArrayList
$guiStateRefs = New-Object System.Collections.ArrayList
$guiAssignments = New-Object System.Collections.ArrayList
$null = $ast.FindAll({
  param($c)
  if ($c -is [Management.Automation.Language.VariableExpressionAst]) {
    if ($stateVarKeys.Contains("$($c.VariablePath.UserPath)")) { [void]$guiStateRefs.Add($c) }
  } elseif ($c -is [Management.Automation.Language.CommandAst]) {
    switch ("$($c.GetCommandName())") {
      'Initialize-ProtectedUserStateStore' { [void]$guiInitCalls.Add($c) }
      'Set-TargetUserContext' { [void]$guiSetTargetCalls.Add($c) }
    }
    if ($c.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot) { [void]$guiDotSources.Add($c) }
  } elseif ($c -is [Management.Automation.Language.AssignmentStatementAst]) {
    $left = $c.Left
    while ($left -is [Management.Automation.Language.AttributedExpressionAst]) { $left = $left.Child }
    if ($left -is [Management.Automation.Language.VariableExpressionAst] -and $assignKeys.Contains("$($left.VariablePath.UserPath)")) {
      [void]$guiAssignments.Add([pscustomobject]@{
        Node = $c; Path = "$($left.VariablePath.UserPath)"; Target = ("$($left.VariablePath.UserPath)" -replace '^(?i)script:', '') })
    }
  } elseif ($c -is [Management.Automation.Language.FunctionDefinitionAst]) {
    [void]$guiFunctionDefList.Add($c)
    if (-not $guiFunctionDefs.ContainsKey($c.Name)) { $guiFunctionDefs[$c.Name] = $c }
  }
  $false
}, $true)
Assert-True ($guiFunctionDefs.Count -gt 0 -and $guiStateRefs.Count -gt 0 -and $guiAssignments.Count -gt 0) `
  'the GUI AST index is empty; the queries below would compare nothing'

function Get-GuiFunctionDefinitions([string]$Name) {
  @($guiFunctionDefList.ToArray() | Where-Object { $_.Name -eq $Name })
}

function Get-GuiFunctionText([string]$Name) {
  Assert-True ($guiFunctionDefs.ContainsKey($Name)) "function not found: $Name"
  $guiFunctionDefs[$Name].Extent.Text
}

$guiFunctionTexts = @{}
foreach ($name in 'Write-BootLog', 'Get-StartupFailureHint') {
  $guiFunctionTexts[$name] = Get-GuiFunctionText $name
  Invoke-Expression $guiFunctionTexts[$name]
}

# ---- 静态不变量 ----

# 引导日志必须早于 PSModulePath 收紧，因此块内不得使用任何 cmdlet：
# 一个 cmdlet 就可能触发模块自动加载，把用户可写路径拉进高权限进程。
$bootBlockStart = $raw.IndexOf('$script:BootLogPath = ''''')
if ($bootBlockStart -lt 0) { $bootBlockStart = $raw.IndexOf("`$script:BootLogPath = ''") }
Assert-True ($bootBlockStart -ge 0) 'bootstrap log block not found'
$hardenStart = $raw.IndexOf('$env:PSModulePath =')
Assert-True ($hardenStart -ge 0) 'PSModulePath hardening not found'
Assert-True ($bootBlockStart -lt $hardenStart) `
  'bootstrap logger is defined after PSModulePath hardening, so early failures produce no log'

# 引导块的结束锚点是上游那段注释的开头，不是 PSModulePath 赋值 —— 两者之间还夹着
# 上游原有的 $trustedBootstrapModuleRoots 计算（它确实用了 Test-Path，那不是本层的代码）
$bootBlockEnd = $raw.IndexOf('# 这两个 Get-CimInstance', $bootBlockStart)
Assert-True ($bootBlockEnd -gt $bootBlockStart) 'bootstrap block end marker not found'
$bootBlock = $raw.Substring($bootBlockStart, $bootBlockEnd - $bootBlockStart)

# GUI 在脚本作用域（顶层语句）定义的函数：名字 → 定义节点 / 起始位置。下面的允许清单和 Initialize 的命令检查共用。
$guiTopFunctions = @{}; $guiTopFunctionOffsets = @{}
foreach ($stmt in @($ast.EndBlock.Statements)) {
  if ($stmt -is [Management.Automation.Language.FunctionDefinitionAst] -and -not $guiTopFunctions.ContainsKey($stmt.Name)) {
    $guiTopFunctions[$stmt.Name] = $stmt; $guiTopFunctionOffsets[$stmt.Name] = $stmt.Extent.StartOffset
  }
}

# ---- 引导块允许清单（复核 X3）----
# 原来是 14 个 cmdlet 名字的禁用清单：Get-ExecutionPolicy、Get-Culture、Get-Variable、Get-Command、别名 gl / gci
# 都不在单子上，照样在收紧 PSModulePath 之前触发模块自动加载（复核演示过：植入的同名模块代码被执行）。
# 改成允许清单，按 AST 判断（注释里提到某个 cmdlet 名字不算使用它 —— 第一版的误报就是注释写着「不用 Sort-Object」）：
# 引导块和 trap 里的每一个命令调用，都必须是 GUI 在脚本作用域、并且在这次调用之前已经定义的函数（目前只有
# Write-BootLog）。调用一个这时还没定义的名字，同样会走命令发现和模块自动加载。不许 & / . 调用、不许动态命令名，
# 也不许经 $ExecutionContext、${function:…} / ${alias:…}、[scriptblock]、[powershell] 在运行时拿到命令再执行
# （复核 X8 提过 ${function:Write-Log}.Invoke() 这种写法：它不产生命令节点）。
# 检查范围从脚本第一句开始，不从 $script:BootLogPath = '' 开始：引导块前面插一句 (Get-Culture).Name，或在那里定义一个
# 调用 cmdlet 的辅助函数、再在快照里调用它，同样早于收紧。范围覆盖到 trap 为止的每一条顶层语句（含函数定义的函数体），
# 允许调用的函数又必须定义在调用之前，所以它们的函数体都在范围里、都过了同一关。
$bootRegionNodes = @(@($ast.ParamBlock) + @($ast.EndBlock.Statements) + @($ast.EndBlock.Traps) | Where-Object {
  $_ -and $_.Extent.StartOffset -lt $bootBlockEnd })
$bootRegionTraps = @($bootRegionNodes | Where-Object { $_ -is [Management.Automation.Language.TrapStatementAst] })
Assert-True ($bootRegionTraps.Count -eq 1 -and $bootRegionTraps[0].Extent.StartOffset -gt $bootBlockStart) `
  ("expected exactly one script-scope trap inside the bootstrap block (found $($bootRegionTraps.Count)); " +
   'startup fail-fast depends on it, and the allow-list below must cover it')
$bootCommands = @($bootRegionNodes | ForEach-Object { $_.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) })
$bootLoggerCalls = 0
foreach ($cmd in $bootCommands) {
  $cmdName = "$($cmd.GetCommandName())"
  $cmdWhere = "line $($cmd.Extent.StartLineNumber): $($cmd.Extent.Text)"
  Assert-True ($cmd.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Unknown -and $cmdName) `
    "bootstrap block or trap invokes a command with & / . or a dynamic name before PSModulePath is hardened ($cmdWhere)"
  Assert-True ($guiTopFunctionOffsets.ContainsKey($cmdName) -and $guiTopFunctionOffsets[$cmdName] -lt $cmd.Extent.StartOffset) `
    ("bootstrap block or trap calls '$cmdName', which is not a function the GUI defines at script scope before that call; " +
     "a cmdlet, an alias or a not-yet-defined name triggers command discovery / module autoload before PSModulePath is hardened ($cmdWhere)")
  if ($cmdName -eq 'Write-BootLog') { $bootLoggerCalls++ }
}
Assert-True ($bootCommands.Count -gt 0 -and $bootLoggerCalls -gt 0) `
  "the bootstrap block allow-list compared nothing (found $($bootCommands.Count) commands, $bootLoggerCalls Write-BootLog calls); the region or the AST query is broken"
# 运行时拿到命令再执行、不产生命令节点的入口：$ExecutionContext（含 ${variable:ExecutionContext}、$global:ExecutionContext
# 这类限定写法）、${function:…} / ${alias:…}、[scriptblock] / [powershell] / [runspace] 等类型，以及解析命令或执行代码的成员
# （$Host.Runspace.CreateNestedPipeline(…)、….InvokeCommand.InvokeScript(…) 等）。
$bootDynamicTypes = @([scriptblock], [powershell], [Management.Automation.Runspaces.Runspace],
                      [Management.Automation.Runspaces.RunspaceFactory], [Management.Automation.Runspaces.InitialSessionState])
$bootDynamicMembers = @('InvokeCommand', 'InvokeScript', 'NewScriptBlock', 'GetCommand', 'GetCmdlet',
                        'CreatePipeline', 'CreateNestedPipeline', 'AddScript', 'AddCommand')
$bootDynamic = @($bootRegionNodes | ForEach-Object { $_.FindAll({
  param($n)
  ($n -is [Management.Automation.Language.VariableExpressionAst] -and
    (("$($n.VariablePath.UserPath)" -replace '^[^:]*:', '') -eq 'ExecutionContext' -or
     @('function', 'alias') -contains "$($n.VariablePath.DriveName)")) -or
  ($n -is [Management.Automation.Language.TypeExpressionAst] -and $bootDynamicTypes -contains $n.TypeName.GetReflectionType()) -or
  ($n -is [Management.Automation.Language.MemberExpressionAst] -and
    $n.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and $bootDynamicMembers -contains "$($n.Member.Value)")
}, $true) })
Assert-True ($bootDynamic.Count -eq 0) `
  ('bootstrap block or trap builds and runs code at runtime, which escapes the command allow-list: ' +
   (@($bootDynamic | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" }) -join ' | '))
# ---- 引导块允许清单结束 ----

# 落盘位置不得依赖环境变量：闸门失败时 %TEMP% 本身就可能是错的。
# 注意只检查「路径推导」这一段，不是整个块 —— 块里把 $env:TEMP 的值写进日志是
# 有诊断价值的，那和用它推导路径是两回事。
$rootAssignIdx = $bootBlock.IndexOf('$bootLogRoot =')
Assert-True ($rootAssignIdx -ge 0) 'bootstrap log root assignment not found'
$rootAssignEnd = $bootBlock.IndexOf('[IO.Directory]::Exists', $rootAssignIdx)
Assert-True ($rootAssignEnd -gt $rootAssignIdx) 'bootstrap root existence guard not found after the assignment'
$rootAssign = $bootBlock.Substring($rootAssignIdx, $rootAssignEnd - $rootAssignIdx)
Assert-True ($rootAssign.Contains('CommonApplicationData')) `
  'bootstrap log path is not derived from CommonApplicationData'
Assert-True (-not $rootAssign.Contains('$env:')) `
  'bootstrap log path is derived from an environment variable, which is untrustworthy when the startup gate fails'

# ---- 最关键的一条：引导日志绝不能创建受保护根目录 ----
# 根目录必须由 New-ProtectedDirectory 以 Admin/SYSTEM 独占 ACL 建立。若本层抢先用
# CreateDirectory 建出来，它会继承 ProgramData 的默认 ACL（Owner=当前用户、
# BUILTIN\Users:Write），Test-DirectoryAclSafe 随即判定不安全，New-ProtectedDirectory
# 抛「已拒绝接管」，于是全新安装的机器每一次都打不开。
# 这正是本层第一版引入过的缺陷，任何人改回去都必须在这里被挡下。
Assert-True ($bootBlock.Contains('[IO.Directory]::Exists($bootLogRoot)')) `
  'bootstrap block no longer checks that the protected root already exists before writing'
Assert-True (-not $bootBlock.Contains('CreateDirectory($bootLogRoot)')) `
  'bootstrap block creates the protected root; this bricks startup on a fresh install (ACL takeover refused)'
Assert-True ($bootBlock.Contains('CreateDirectory($bootLogDir)')) `
  'bootstrap block no longer creates the startup-logs leaf directory'

# 会话标记是命名管道名的组成部分，而这份日志对普通用户可读 —— 不得全文落盘
Assert-True ($bootBlock.Contains('Substring(0, 8)')) `
  'the session marker is no longer truncated before being written to a user-readable log'
Assert-True (-not ($bootBlock -match 'SESSION=\{\d\}" -f[^)]*DFB_ENGINE_HOST_SESSION')) `
  'the full session marker is written to the boot log'

# ---- startup-logs：唯一一个对普通用户可读（UsersRead = $true）的受保护子目录 ----
# 必须可读：「软件打不开」时要能以普通权限导出诊断包，要求提权才能诊断提权失败是死锁；但不能写。
# 旧版两条正则匹配的是源码文本，把那行 New-ProtectedDirectory 整行注释掉照样绿（独立复核变异 08）。
$initFn = @(Get-GuiFunctionDefinitions 'Initialize-ProtectedUserStateStore')
Assert-True ($initFn.Count -eq 1) 'Initialize-ProtectedUserStateStore not found or duplicated'

# 结构 1：那条 UsersRead=$true 的调用只允许被 try 的主体包着，不许挂在任何条件、循环、catch 或内嵌脚本块下。
# 「目录已存在就跳过」「看某个 $script:/$env: 状态」这类门卫在测试环境与生产环境里取值正好相反，
# 行为测试只能覆盖其中一边。祖先链只挡「包在条件下」这一种写法；排在它前面的兄弟语句提前离开函数
# 由紧接着的结构 2 挡，按状态取值才生效的其余写法由后面的运行时状态矩阵（场景 5）挡。
$readableCalls = @($initFn[0].FindAll({
  param($c)
  $c -is [Management.Automation.Language.CommandAst] -and "$($c.GetCommandName())" -eq 'New-ProtectedDirectory' -and
  $c.CommandElements.Count -eq 3 -and "$($c.CommandElements[2].Extent.Text)" -eq '$true'
}, $true))
Assert-True ($readableCalls.Count -eq 1) `
  "Initialize-ProtectedUserStateStore must contain exactly one user-readable New-ProtectedDirectory call (found $($readableCalls.Count))"
$ancestor = $readableCalls[0]; $previous = $null; $unconditional = $true
while ($ancestor -and -not [object]::ReferenceEquals($ancestor, $initFn[0])) {
  $allowed = $ancestor -is [Management.Automation.Language.CommandAst] -or
    $ancestor -is [Management.Automation.Language.PipelineAst] -or
    $ancestor -is [Management.Automation.Language.StatementBlockAst] -or
    $ancestor -is [Management.Automation.Language.NamedBlockAst] -or
    ($ancestor -is [Management.Automation.Language.ScriptBlockAst] -and [object]::ReferenceEquals($ancestor.Parent, $initFn[0])) -or
    ($ancestor -is [Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($ancestor.Body, $previous))
  if (-not $allowed) { $unconditional = $false; break }
  $previous = $ancestor; $ancestor = $ancestor.Parent
}
Assert-True $unconditional `
  ('the user-readable startup-logs provisioning sits under a ' + $ancestor.GetType().Name + '; it must run on every start')

# 结构 2：祖先链挡不住排在调用前面的兄弟语句提前离开函数，例如函数体首一句
# if ($script:RepairOnlySession) { return } —— 测试里那个变量恒为空、修复会话里恒为真（复核 SB-1 / 对手 M-REPAIR）。
# 所以祖先链经过的每一层语句块里，排在调用路径前面的语句都不许含 return / exit，也不许含会跳出本函数的
# break / continue（带标签的，或不在这条语句自己的循环 / switch 里的；不看内嵌脚本块）。
# 包着调用的那个 try 主体里，排在它前面的语句还不许 throw：那会被同一个 catch 吞掉、只记一行日志就跳过加固。
# 这一条不看状态取值：拼名字查变量、读一个任何探针都不设的变量这类状态矩阵看不见的门卫也挡得住；
# 反过来，按状态 throw 让整个初始化失败、按状态改参数，由后面的状态矩阵挡。
function Get-EarlyExitNodes($Statement) {
  @($Statement.FindAll({
    param($n)
    $n -is [Management.Automation.Language.ReturnStatementAst] -or
    $n -is [Management.Automation.Language.ExitStatementAst] -or
    $n -is [Management.Automation.Language.BreakStatementAst] -or
    $n -is [Management.Automation.Language.ContinueStatementAst]
  }, $false) | Where-Object {
    if ($_ -is [Management.Automation.Language.ReturnStatementAst] -or
        $_ -is [Management.Automation.Language.ExitStatementAst] -or $_.Label) { return $true }
    for ($p = $_.Parent; $p; $p = $p.Parent) {
      if ($p -is [Management.Automation.Language.LoopStatementAst] -or
          $p -is [Management.Automation.Language.SwitchStatementAst]) { return $false }
      if ([object]::ReferenceEquals($p, $Statement)) { break }
    }
    $true
  })
}
# 非空锚（检测器自检）：检测器坏掉时下面的扫描会恒真，所以先拿一段已知答案的代码验一遍。
$exitSelfTestTokens = $null; $exitSelfTestErrors = $null
$exitSelfTest = [Management.Automation.Language.Parser]::ParseInput(
  'if ($a) { return }; foreach ($b in 1) { break }; switch (1) { 1 { continue } }; while ($c) { if ($d) { break outer } }; if ($e) { break }; $f = { return }',
  [ref]$exitSelfTestTokens, [ref]$exitSelfTestErrors)
$exitSelfTestHits = @($exitSelfTest.EndBlock.Statements | ForEach-Object { Get-EarlyExitNodes $_ } | ForEach-Object { "$($_.Extent.Text)" })
Assert-True (($exitSelfTestHits -join '|') -eq 'return|break outer|break') `
  ('the early-exit detector is broken; on its self-test it reported: ' + ($exitSelfTestHits -join ' | '))

$scannedBeforeReadable = 0; $walkedFunctionBody = $false
$pathChild = $readableCalls[0]; $pathParent = $pathChild.Parent
while ($pathParent -and -not [object]::ReferenceEquals($pathParent, $initFn[0])) {
  if ($pathParent -is [Management.Automation.Language.StatementBlockAst] -or
      $pathParent -is [Management.Automation.Language.NamedBlockAst]) {
    if ([object]::ReferenceEquals($pathParent, $initFn[0].Body.EndBlock)) { $walkedFunctionBody = $true }
    $inTryBody = $pathParent.Parent -is [Management.Automation.Language.TryStatementAst] -and
      [object]::ReferenceEquals($pathParent.Parent.Body, $pathParent)
    foreach ($stmt in @($pathParent.Statements)) {
      if ([object]::ReferenceEquals($stmt, $pathChild)) { break }
      $scannedBeforeReadable++
      $exits = @(Get-EarlyExitNodes $stmt)
      Assert-True ($exits.Count -eq 0) `
        ("a statement before the user-readable startup-logs provisioning can leave Initialize-ProtectedUserStateStore " +
         "early ($($exits[0].Extent.Text), line $($stmt.Extent.StartLineNumber)): $($stmt.Extent.Text)")
      if ($inTryBody) {
        $throws = @($stmt.FindAll({ param($n) $n -is [Management.Automation.Language.ThrowStatementAst] }, $false))
        Assert-True ($throws.Count -eq 0) `
          ("a statement before the user-readable startup-logs provisioning throws inside the same try body (line " +
           "$($stmt.Extent.StartLineNumber)); that try's own catch swallows it and the provisioning is skipped: $($stmt.Extent.Text)")
      }
    }
  }
  $pathChild = $pathParent; $pathParent = $pathParent.Parent
}
Assert-True ($walkedFunctionBody -and $scannedBeforeReadable -gt 0) `
  "the early-exit scan never reached the function body or compared nothing (scanned $scannedBeforeReadable statements); the walk is broken"

# ---- 运行时状态矩阵：下面每个行为探针都在「生产里真实可能处于的每一种状态」下重复同一组断言 ----
# 探针真跑的是产品原文（Initialize-ProtectedUserStateStore、trap 体、顶层 try 语句），它们读到的运行时状态
# 在测试里和生产里往往相反：测试进程没有引导日志、没有 EngineHost 下发的 DFB_* 环境变量、也不是修复会话，
# 生产里这些都有值。只在测试默认状态下断言，「看状态决定做不做」的写法就只被测到一边 —— 独立复核 R6
# （trap 的日志段包进 if (-not $script:BootLogPath)）、复核 SB-1 与对手 M-REPAIR（Initialize 体首插
# if ($script:RepairOnlySession) { return }）都是这样绿的。固定四种状态：
#   1. 全新安装：BootLogPath 为空（产品第一句赋的初值；受保护根尚未建立时就停在这里 —— 这也正是
#      Initialize-ProtectedUserStateStore 第一次建立它的那次启动）
#   2. 被探代码读到的每个 $script:/$env: 变量都强制成真值（和 1 一起覆盖两个取值方向；只看得见变量表达式）
#   3. 生产标准会话：BootLogPath 指向真实存在、已写过首行的日志文件，DFB_* 按 EngineHost 下发的设上，
#      会话校验块里赋过的 $script: 状态照生产设上，RepairOnlySession = $false
#   4. 生产修复 / 兼容会话：同 3，但 DFB_REPAIR_ONLY = '1'、RepairOnlySession = $true、NetCafeCompatibilityMode = $true。
#      能走到 Initialize 的修复会话一定也是兼容模式（UAC 修复分支与「以管理员身份运行」分支都在顶层调用它之前设这个
#      标志，见后面的生产顺序锚）。3、4 抓得住 2 看不见的门卫，例如用 Get-Variable 拼名字去查状态。
# 生产里 GUI 由 EngineHost 启动，这组环境变量一定有值；测试里默认是空的。
$aclProdEnv = [ordered]@{
  DFB_ENGINE_HOST_PID = '4242'; DFB_LAUNCHER_PID = '4343'; DFB_ENGINE_HOST_SESSION = 'abcdef0123456789abcdef0123456789'
  DFB_ORIGINAL_USER_SID = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
  DFB_ORIGINAL_LOCALAPPDATA = 'C:\DfbTest\OriginalUser\AppData\Local'
  DFB_ENGINE_CONTROL_PIPE = 'DeltaForceBooster.Engine.0123456789abcdef0123456789abcdef'; DFB_REPAIR_ONLY = '0'
}
$probeAutomaticVars = @('_', 'PSItem', 'null', 'true', 'false', 'args', 'input', 'this')
$probeLogHeader = '[00:00:00.000] probe: boot log header' + [Environment]::NewLine

function Get-TruthyProbeState($ProbedAst, [string[]]$Keep = @()) {
  $paths = @($ProbedAst.FindAll({ param($c) $c -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
    ForEach-Object { "$($_.VariablePath.UserPath)" } | Sort-Object -Unique |
    Where-Object { $probeAutomaticVars -notcontains $_ -and $Keep -notcontains ($_ -replace '^(?i)(script|global|local|private):', '') })
  $vars = @{}; $envVars = @{}
  foreach ($path in $paths) {
    if ($path -like 'env:*') { $envVars[$path.Substring(4)] = '1' }
    else { $vars[($path -replace '^(?i)(script|global|local|private):', '')] = $true }
  }
  @{ Paths = $paths; Vars = $vars; Env = $envVars }
}

function New-ProductionProbeStates([string]$Dir) {
  Assert-True ($aclProdEnv.Count -gt 0) 'the production DFB_* environment profile ($aclProdEnv) is missing'
  [void][IO.Directory]::CreateDirectory($Dir)
  $logFile = Join-Path $Dir ('startup-20260101-000000-{0}.log' -f $PID)
  # 生产里 trap / 顶层 try / Initialize 能运行之前，引导块已经写过「主界面启动」那一行：文件是存在的
  [IO.File]::WriteAllText($logFile, $probeLogHeader, (New-Object Text.UTF8Encoding($true)))
  $standard = @{
    BootLogPath = $logFile; EngineHostSessionValidated = $true; RepairOnlySession = $false; NetCafeCompatibilityMode = $null
    OriginalUserSid = "$($aclProdEnv['DFB_ORIGINAL_USER_SID'])"; OriginalUserLocalAppData = "$($aclProdEnv['DFB_ORIGINAL_LOCALAPPDATA'])"
    EngineHostPid = [int]$aclProdEnv['DFB_ENGINE_HOST_PID']; LauncherPid = [int]$aclProdEnv['DFB_LAUNCHER_PID']
  }
  $repair = $standard.Clone()
  $repair['RepairOnlySession'] = $true; $repair['NetCafeCompatibilityMode'] = $true
  $repairEnv = [ordered]@{}
  foreach ($key in $aclProdEnv.Keys) { $repairEnv[$key] = $aclProdEnv[$key] }
  $repairEnv['DFB_REPAIR_ONLY'] = '1'
  @{ Name = 'production standard session, real boot log file'; Vars = $standard; Env = $aclProdEnv; LogFile = $logFile }
  @{ Name = 'production repair-only / compatibility session, real boot log file'; Vars = $repair; Env = $repairEnv; LogFile = $logFile }
}

function New-RuntimeProbeStates($ProbedAst, [string]$Subject, [string]$Dir, [string[]]$Keep = @()) {
  $truthy = Get-TruthyProbeState $ProbedAst $Keep
  $states = @(
    @{ Name = 'fresh install, empty BootLogPath'; Vars = @{ BootLogPath = '' }; Env = @{}; LogFile = '' }
    @{ Name = ("every variable $Subject reads forced truthy (" + ($truthy.Paths -join ', ') + ')')
       Vars = $truthy.Vars; Env = $truthy.Env; LogFile = '' }
  ) + @(New-ProductionProbeStates $Dir)
  Assert-True ($states.Count -eq 4) "the runtime probe states for $Subject were not all built"
  $states
}

function Invoke-InProbeState([Collections.IDictionary]$Vars, [Collections.IDictionary]$EnvVars, [scriptblock]$Body) {
  $savedVars = @{}; $savedEnv = @{}
  try {
    foreach ($key in @($EnvVars.Keys)) {
      $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
      [Environment]::SetEnvironmentVariable($key, "$($EnvVars[$key])", 'Process')
    }
    foreach ($key in @($Vars.Keys)) {
      $savedVars[$key] = @(Get-Variable -Name $key -Scope Script -ErrorAction SilentlyContinue)
      Set-Variable -Name $key -Value $Vars[$key] -Scope Script
    }
    & $Body
  } finally {
    foreach ($key in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    foreach ($key in @($savedVars.Keys)) {
      if ($savedVars[$key].Count -gt 0) { Set-Variable -Name $key -Value $savedVars[$key][0].Value -Scope Script }
      else { Remove-Variable -Name $key -Scope Script -ErrorAction SilentlyContinue }
    }
  }
}

# ---- Initialize 调用的每个命令都必须有定义；New-ProtectedDirectory 的桩按引擎自己的声明生成（复核 X6 / X7）----
# 下面的探针原来各自手写 function New-ProtectedDirectory([string]$Path, [bool]$UsersRead)。于是引擎把 UsersRead
# 改成 [switch] 时（GUI 按位置传的 $true 在简单函数里落进 $args、被悄悄丢掉，startup-logs 从此只有管理员可读，
# 不提权的导出器又读不到日志），或者引擎把函数改了名时（每次启动都因 CommandNotFound 被拒），测试照样绿。现在：
#  - Initialize 调用的每个命令，要么是引擎或 GUI 在脚本作用域定义的函数（GUI 的必须定义在顶层调用之前），要么是 cmdlet。
#  - 桩的签名逐字取自引擎那份定义（参数表，或带特性的 param 块），参数绑定和生产一致；桩记下没绑定上的实参，不许有。
#  - Initialize 传递调用到的其余引擎 / GUI 函数（两个桩之外）在探针里加载真实定义，不让它们在探针里 CommandNotFound
#    （复核 FR1：合理地加一句引擎的 Test-PathHasReparsePoint，不该以一条原始异常变红）。
$engineAstTokens = $null; $engineAstErrors = $null
$engineAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\delta-booster.ps1'),
  [ref]$engineAstTokens, [ref]$engineAstErrors)
Assert-True ($engineAstErrors.Count -eq 0) ('scripts\delta-booster.ps1 parse failed: ' + (($engineAstErrors | ForEach-Object Message) -join '; '))
$engineFunctionDefs = @{}
foreach ($stmt in @($engineAst.EndBlock.Statements)) {
  if ($stmt -is [Management.Automation.Language.FunctionDefinitionAst] -and -not $engineFunctionDefs.ContainsKey($stmt.Name)) {
    $engineFunctionDefs[$stmt.Name] = $stmt
  }
}
Assert-True ($engineFunctionDefs.Count -gt 0) 'the engine defines no script-scope function; the engine AST query is broken'

$initCallOffset = $(if ($guiInitCalls.Count -gt 0) {
  ($guiInitCalls | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Minimum).Minimum } else { [int]::MaxValue })
$initCommandNames = @($initFn[0].Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) |
  ForEach-Object { "$($_.GetCommandName())" } | Where-Object { $_ } | Sort-Object -Unique)
Assert-True ($initCommandNames -contains 'New-ProtectedDirectory') `
  ('Initialize-ProtectedUserStateStore no longer calls New-ProtectedDirectory; the command check below compared nothing (calls: ' +
   ($initCommandNames -join ', ') + ')')
function Test-IsCmdletName([string]$Name) {
  $resolved = @(Get-Command -Name $Name -CommandType Cmdlet, Alias -ErrorAction SilentlyContinue)[0]
  if ($resolved -and $resolved.CommandType -eq [Management.Automation.CommandTypes]::Alias) { $resolved = $resolved.ResolvedCommand }
  [bool]($resolved -and $resolved.CommandType -eq [Management.Automation.CommandTypes]::Cmdlet)
}
foreach ($initCommand in $initCommandNames) {
  $definedBy = ''
  if ($engineFunctionDefs.ContainsKey($initCommand)) { $definedBy = 'engine' }
  elseif ($guiTopFunctionOffsets.ContainsKey($initCommand) -and $guiTopFunctionOffsets[$initCommand] -lt $initCallOffset) { $definedBy = 'gui' }
  elseif (Test-IsCmdletName $initCommand) { $definedBy = 'cmdlet' }
  Assert-True ([bool]$definedBy) `
    ("Initialize-ProtectedUserStateStore calls '$initCommand', which neither the engine nor the GUI defines at script scope " +
     '(GUI functions must be defined before the startup call) and which is no cmdlet: the call throws CommandNotFoundException ' +
     'and every start is refused')
}
Assert-True ($engineFunctionDefs.ContainsKey('New-ProtectedDirectory')) `
  ("the engine (scripts\delta-booster.ps1) no longer defines New-ProtectedDirectory at script scope, " +
   "but the GUI's Initialize-ProtectedUserStateStore calls it")

$npdDef = $engineFunctionDefs['New-ProtectedDirectory']
$npdParamAsts = @($(if ($npdDef.Parameters) { $npdDef.Parameters } elseif ($npdDef.Body.ParamBlock) { $npdDef.Body.ParamBlock.Parameters }))
$npdParamNames = @($npdParamAsts | ForEach-Object { "$($_.Name.VariablePath.UserPath)" })
Assert-True ($npdParamNames -contains 'Path' -and $npdParamNames -contains 'UsersRead') `
  ("the engine's New-ProtectedDirectory no longer declares `$Path and `$UsersRead (declares: " + ($npdParamNames -join ', ') +
   '); the recording stub cannot tell which directory the GUI makes user-readable')
$npdText = $npdDef.Extent.Text
$npdHead = $npdText.Substring(0, $npdDef.Body.Extent.StartOffset - $npdDef.Extent.StartOffset)
$npdParamBlock = ''
if ($npdDef.Body.ParamBlock) {
  $npdBlock = $npdDef.Body.ParamBlock
  $npdBlockStart = (@($npdBlock.Extent.StartOffset) + @($npdBlock.Attributes | ForEach-Object { $_.Extent.StartOffset }) |
    Measure-Object -Minimum).Minimum
  $npdParamBlock = $npdText.Substring($npdBlockStart - $npdDef.Extent.StartOffset, $npdBlock.Extent.EndOffset - $npdBlockStart)
}
$npdSignature = (($npdHead.Trim() -replace '^function\s+', '') + ' ' + $npdParamBlock).Trim() -replace '\s+', ' '
function Get-ProtectedDirectoryStub([string]$ListVariable) {
  $npdHead + "{`n" + $npdParamBlock + "`n" +
  "  [void]`$script:$ListVariable.Add([pscustomobject]@{ Path = `"`$Path`"; UsersRead = [bool]`$UsersRead; Unbound = @(`$args) })`n" +
  "  if (`$script:AclFailPath -and `"`$Path`" -eq `$script:AclFailPath) { throw `"stubbed ACL failure at `$Path`" }`n}"
}

function Get-ProbeHelperDefinitions($RootAst, [string[]]$Stubbed) {
  $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($stubName in $Stubbed) { [void]$seen.Add($stubName) }
  $pending = New-Object 'Collections.Generic.Queue[object]'
  $pending.Enqueue($RootAst)
  $helperTexts = New-Object 'Collections.Generic.List[string]'
  while ($pending.Count -gt 0) {
    $node = $pending.Dequeue()
    foreach ($cmd in @($node.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))) {
      $cmdName = "$($cmd.GetCommandName())"
      if (-not $cmdName -or -not $seen.Add($cmdName)) { continue }
      $def = $(if ($guiTopFunctions.ContainsKey($cmdName)) { $guiTopFunctions[$cmdName] }
               elseif ($engineFunctionDefs.ContainsKey($cmdName)) { $engineFunctionDefs[$cmdName] })
      if ($def) { $helperTexts.Add($def.Extent.Text); $pending.Enqueue($def.Body) }
    }
  }
  ,$helperTexts.ToArray()
}
$initHelperTexts = Get-ProbeHelperDefinitions $initFn[0].Body `
  @('Initialize-ProtectedUserStateStore', 'New-ProtectedDirectory', 'Write-BootLog', 'Stop-UntrustedGuiStartup')

# 行为：真的执行 Initialize-ProtectedUserStateStore，只替换真正落盘/改 ACL 的 New-ProtectedDirectory
# （桩按引擎的声明生成，记录每次调用的路径、UsersRead 和没绑定上的实参，可按路径注入失败）和落盘的 Write-BootLog。
$aclSavedVars = @{}
foreach ($name in @('ProgramDataRoot', 'OriginalUserSid', 'BootLogPath', 'RepairOnlySession', 'NetCafeCompatibilityMode',
                    'EngineHostSessionValidated', 'EngineHostPid', 'LauncherPid', 'OriginalUserLocalAppData') + $protectedStateVars) {
  $aclSavedVars[$name] = @(Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue)
}
$aclLiveRoot = Join-Path ([IO.Path]::GetTempPath()) ('dfb-acl-live-' + [guid]::NewGuid().ToString('N'))
$aclSavedEnv = @{}
try {
  # 场景 5 的状态矩阵；Keep 的两个是函数必须拿到有效值的输入（SID 校验、根目录），不参与强制
  $initRealStates = @(New-RuntimeProbeStates $initFn[0] 'Initialize-ProtectedUserStateStore' (Join-Path $aclLiveRoot 'prod-log') `
    -Keep 'OriginalUserSid', 'ProgramDataRoot')
  # 场景 1–4 照生产把这组环境变量设上再跑，以它们为条件的分支（例如 if (-not $env:DFB_ENGINE_HOST_PID) { ... }）
  # 才会走生产那一边。
  foreach ($name in $aclProdEnv.Keys) {
    $aclSavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $aclProdEnv[$name], 'Process')
  }
  & {
    param([string]$FunctionText, [string]$LiveRoot, [object[]]$States, [string[]]$StateVarNames)
    Invoke-Expression $FunctionText
    $script:AclCalls = New-Object 'Collections.Generic.List[object]'
    $script:AclFailPath = ''
    $script:AclBootLog = New-Object 'Collections.Generic.List[string]'
    foreach ($helperText in $initHelperTexts) { Invoke-Expression $helperText }
    Invoke-Expression (Get-ProtectedDirectoryStub 'AclCalls')
    function Write-BootLog([string]$Line) { [void]$script:AclBootLog.Add("$Line") }

    # 生产里本函数运行时引导日志早已就绪、会话 SID 已验证。先把这些「生产里有值」的状态设上，
    # 以「尚未设置」为条件的分支才不会只在测试里成立。合成 SID 只当目录名用，要能过 IsAccountSid。
    $script:OriginalUserSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    $script:BootLogPath = 'C:\ProgramData\DeltaForceBooster\startup-logs\startup-probe.log'
    $script:ProgramDataRoot = Join-Path ([IO.Path]::GetTempPath()) ('dfb-acl-' + [guid]::NewGuid().ToString('N'))
    $startupLogs = Join-Path $script:ProgramDataRoot 'startup-logs'
    $configDir = Join-Path (Join-Path (Join-Path $script:ProgramDataRoot 'users') $script:OriginalUserSid) 'config'

    # 1) 正常路径：startup-logs 恰好一次、UsersRead=$true，且是唯一一个可读目录
    Initialize-ProtectedUserStateStore
    $unbound = @($script:AclCalls | Where-Object { @($_.Unbound).Count -gt 0 })
    Assert-True ($unbound.Count -eq 0) `
      ("Initialize-ProtectedUserStateStore passes argument(s) that the engine's $npdSignature does not bind, " +
       'so production silently drops them: ' + (@($unbound | ForEach-Object { "$($_.Path) <- $(@($_.Unbound) -join ', ')" }) -join ' | '))
    $hits =@($script:AclCalls | Where-Object { $_.Path -eq $startupLogs })
    Assert-True ($hits.Count -eq 1 -and $hits[0].UsersRead -eq $true) `
      ("startup-logs was not provisioned exactly once as user-readable at $startupLogs; provisioned: " +
       (@($script:AclCalls | ForEach-Object { "$($_.Path)=$($_.UsersRead)" }) -join ' | '))
    $readable = @($script:AclCalls | Where-Object { $_.UsersRead })
    Assert-True ($readable.Count -eq 1) `
      ('more than one protected directory is user-readable: ' + (@($readable | ForEach-Object { $_.Path }) -join ' | '))

    # 2) 诊断目录失败不得影响启动，但这次失败本身必须留痕（注入的失败原文出现在日志里）
    $script:AclCalls.Clear(); $script:AclBootLog.Clear(); $script:ConfigDir = ''
    $script:AclFailPath = $startupLogs
    $diagThrew = $false
    try { Initialize-ProtectedUserStateStore } catch { $diagThrew = $true }
    Assert-True (-not $diagThrew) 'a startup-logs provisioning failure aborts startup; diagnostics must never block the app'
    Assert-True ($script:ConfigDir -eq $configDir) 'the protected config dir was not established although only the diagnostics dir failed'
    Assert-True (($script:AclBootLog -join "`n").Contains("stubbed ACL failure at $startupLogs")) `
      'the startup-logs provisioning failure left no trace of itself in the boot log'

    # 3) 核心状态目录失败必须继续中止启动（挡住「整个函数体包 try/catch」让上一条恒真）
    $script:AclCalls.Clear()
    $script:AclFailPath = $configDir
    $coreThrew = $false
    try { Initialize-ProtectedUserStateStore } catch { $coreThrew = $true }
    Assert-True $coreThrew 'a protected state directory failure no longer aborts startup; the GUI would run on unprotected state'

    # 4) 目录已存在时同样必须重新加固。生产里这才是常态：引导块在本函数之前就用不带 ACL 的
    #    CreateDirectory 建出了 startup-logs。真建几个普通目录（不设 ACL，不需要管理员）。
    [void][IO.Directory]::CreateDirectory((Join-Path $LiveRoot 'startup-logs'))
    $liveUser = Join-Path (Join-Path $LiveRoot 'users') $script:OriginalUserSid
    [void][IO.Directory]::CreateDirectory((Join-Path $liveUser 'config'))
    [void][IO.Directory]::CreateDirectory((Join-Path $liveUser 'profiles'))
    $script:ProgramDataRoot = $LiveRoot
    $script:AclCalls.Clear(); $script:AclFailPath = ''
    Initialize-ProtectedUserStateStore
    $reHardened = @($script:AclCalls | Where-Object { $_.Path -eq (Join-Path $LiveRoot 'startup-logs') -and $_.UsersRead })
    Assert-True ($reHardened.Count -eq 1) `
      'startup-logs is not re-hardened when it already exists; the boot block pre-creates it with an admin-only ACL'

    # 5) 生产里调用本函数时可能处于的每一种运行时状态（见上面的状态矩阵）下，它都必须完整建立受保护状态：
    #    不抛；五个核心目录都以管理员独占建立；startup-logs 恰好一次、且是唯一的可读目录；六个状态变量都指向受保护区。
    #    场景 1–4 只在一种状态下跑，按修复会话 / 兼容模式 / 任何会话标志跳过的门卫在那里永远走不到（复核 SB-1、
    #    对手 M-REPAIR / M-NETCAFE）。状态变量要在探针体内读出来：Invoke-InProbeState 退出时会还原它强制过的变量。
    $stateIndex = 0
    foreach ($runtimeState in $States) {
      $stateIndex++
      $script:ProgramDataRoot = Join-Path $LiveRoot ('state-' + $stateIndex)
      $script:OriginalUserSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
      foreach ($stateVar in $StateVarNames) { Set-Variable -Name $stateVar -Value '' -Scope Script }
      $script:AclCalls.Clear(); $script:AclFailPath = ''
      $run = Invoke-InProbeState $runtimeState.Vars $runtimeState.Env {
        $initFailure = ''
        try { $null = Initialize-ProtectedUserStateStore } catch { $initFailure = "$($_.Exception.Message)" }
        $stateValues = @{}
        foreach ($stateVar in $StateVarNames) {
          $stateValues[$stateVar] = "$(Get-Variable -Name $stateVar -Scope Script -ValueOnly -ErrorAction SilentlyContinue)"
        }
        [pscustomobject]@{ Failure = $initFailure; Values = $stateValues }
      }
      $where = "[init / $($runtimeState.Name)]"
      Assert-True (-not $run.Failure) "$where Initialize-ProtectedUserStateStore failed in a state production reaches: $($run.Failure)"
      $provisioned = (@($script:AclCalls | ForEach-Object { "$($_.Path)=$($_.UsersRead)" }) -join ' | ')
      $stateLogs = Join-Path $script:ProgramDataRoot 'startup-logs'
      $stateLogHits = @($script:AclCalls | Where-Object { $_.Path -eq $stateLogs -and $_.UsersRead })
      Assert-True ($stateLogHits.Count -eq 1) `
        ("$where startup-logs was not provisioned exactly once as user-readable; in this session it stays admin-only " +
         "and the unelevated diagnostics export is blind (provisioned: $provisioned)")
      $stateReadable = @($script:AclCalls | Where-Object { $_.UsersRead })
      Assert-True ($stateReadable.Count -eq 1) "$where more than one protected directory is user-readable (provisioned: $provisioned)"
      $stateUserRoot = Join-Path (Join-Path $script:ProgramDataRoot 'users') $script:OriginalUserSid
      $stateCore = @($script:ProgramDataRoot, (Join-Path $script:ProgramDataRoot 'users'), $stateUserRoot,
                     (Join-Path $stateUserRoot 'config'), (Join-Path $stateUserRoot 'profiles'))
      $stateMissing = @($stateCore | Where-Object {
        $corePath = $_
        @($script:AclCalls | Where-Object { $_.Path -eq $corePath -and -not $_.UsersRead }).Count -eq 0
      })
      Assert-True ($stateMissing.Count -eq 0) `
        ("$where core protected directories were not provisioned admin-only: " + ($stateMissing -join ' | ') + " (provisioned: $provisioned)")
      $stateExpected = @{
        ProtectedUserStateRoot = $stateUserRoot; UserDataRoot = $stateUserRoot
        ConfigDir = (Join-Path $stateUserRoot 'config'); ProfileDir = (Join-Path $stateUserRoot 'profiles')
        UserConfigDir = (Join-Path $stateUserRoot 'config'); BoosterUserConfigDir = (Join-Path $stateUserRoot 'config')
      }
      $stateWrong = @($StateVarNames | Where-Object { $run.Values[$_] -ne $stateExpected[$_] } |
        ForEach-Object { "$_='$($run.Values[$_])'" })
      Assert-True ($stateWrong.Count -eq 0) `
        ("$where the protected state variables do not all point into the protected store: " + ($stateWrong -join ', '))
    }
    Assert-True ($stateIndex -eq 4) "the protected state init ran in $stateIndex runtime states instead of 4"
  } $initFn[0].Extent.Text $aclLiveRoot $initRealStates $protectedStateVars
} finally {
  foreach ($name in $aclSavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $aclSavedEnv[$name], 'Process') }
  foreach ($name in $aclSavedVars.Keys) {
    if ($aclSavedVars[$name].Count -gt 0) { Set-Variable -Name $name -Value $aclSavedVars[$name][0].Value -Scope Script }
    else { Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue }
  }
  if (Test-Path -LiteralPath $aclLiveRoot) { Remove-Item -LiteralPath $aclLiveRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- 兜底陷阱：必须存在、必须先记日志、必须以 break 无条件终止 ----
# 不用正则：原来的 '(?s)trap\s*\{.*?Write-BootLog.*?break' 里 .*? 不受 trap 范围约束，会一路
# 匹配到文件后面别处某个 if 里的 break——把 trap 里的 break 改成 continue 照样绿（独立复核变异 07）。
# 这里全走 AST（注释不是节点），并且只在这一个 trap 的子树里判定。
# 脚本作用域的 trap 挂在脚本各命名块的 Traps 上（不在 Statements 里），直接取，不必整树遍历
$topTraps = @(@($ast.DynamicParamBlock, $ast.BeginBlock, $ast.ProcessBlock, $ast.EndBlock) |
  Where-Object { $_ -and $_.Traps } | ForEach-Object { $_.Traps })
Assert-True ($topTraps.Count -eq 1) 'expected exactly one script-scope trap; startup fail-fast depends on it'
$topTrap = $topTraps[0]
Assert-True ($null -eq $topTrap.TrapType) 'script-scope trap is narrowed to one exception type; other terminating errors bypass it'

# TrapStatementAst.Body 是 StatementBlockAst（没有 EndBlock），直接取 .Statements。
# break 必须是 body 的最后一条直属语句（包在 if/catch 里的不算），而且是整个 trap 子树里唯一的
# 控制转移语句：末尾仍是裸 break、前面却插一句 if ($script:GuiReady) { continue } 的写法，
# 在测试里那个变量恒为空、上线后恒为真——只有「唯一」这条能挡住。throw 不计入：它本身也终止并传播。
$trapStatements = @($topTrap.Body.Statements)
$trapLast = $trapStatements[$trapStatements.Count - 1]
$trapLastIsBreak = $trapLast -is [Management.Automation.Language.BreakStatementAst] -and $null -eq $trapLast.Label
Assert-True $trapLastIsBreak 'script-scope trap does not end in an unconditional, unlabeled break'
$trapFlow = @($topTrap.FindAll({
  param($candidate)
  $candidate -is [Management.Automation.Language.BreakStatementAst] -or
  $candidate -is [Management.Automation.Language.ContinueStatementAst] -or
  $candidate -is [Management.Automation.Language.ReturnStatementAst] -or
  $candidate -is [Management.Automation.Language.ExitStatementAst]
}, $true))
Assert-True ($trapFlow.Count -eq 1 -and [object]::ReferenceEquals($trapFlow[0], $trapLast)) `
  'script-scope trap holds a control-transfer statement besides its final break; the break can be skipped at runtime'
$trapLogCalls = @($topTrap.FindAll({
  param($candidate)
  $candidate -is [Management.Automation.Language.CommandAst] -and "$($candidate.GetCommandName())" -eq 'Write-BootLog'
}, $true) | Sort-Object { $_.Extent.StartOffset })
Assert-True ($trapLogCalls.Count -ge 1 -and $trapLogCalls[0].Extent.StartOffset -lt $trapLast.Extent.StartOffset) `
  'script-scope trap no longer writes a boot log before it terminates'

# 行为：把产品 trap 原文取出来真跑。四种运行时状态 × 四种错误形态 × 两种 ErrorActionPreference，每一格都断言：
# 这一次抛出的错误原文进了日志，出错点之后的语句没有执行，错误继续向外传播。
#  - 状态：见上面的状态矩阵。1、2 桩掉落盘的 Write-BootLog（记下 trap 交给它的每一行）；3、4 用产品自己的
#    Write-BootLog（带 BootLogPath 闸门）写真实文件，每一探之前把文件重置成只有首行，断言原始错误真的落进了文件。
#  - 错误形态（对手 M-CAT / M-RTE）：裸 throw 是唯一一个既是 OperationStopped、又是 RuntimeException 的错误；只用它，
#    「只在 Category 为 OperationStopped 时记」「只在 RuntimeException 时记」这类门卫照样绿 —— 而生产里最常见的
#    「打不开」恰恰是 Get-CimInstance -ErrorAction Stop（CimException / ItemNotFound）、Add-Type 缺组件、.NET 方法异常。
#    所以叉乘四种形态，各带唯一标记（落进 $_.Exception.Message，中英文系统都能断言）。裸 throw 的标记故意带中文：
#    中文系统上大多数真实错误消息是本地化的中文，「只记纯 ASCII 消息」这类门卫在英文系统上跑测试也要现形。
#  - ErrorActionPreference（复核 F3）：Continue 那一遍守 break —— 删掉 break 时 trap 退回「记录并继续」，Stop 会把它
#    伪装成终止；Stop 那一遍是生产形态（GUI 第一句就设 Stop）—— trap 体里 Write-BootLog 之前任何非终止错误在 Stop 下
#    都变成终止错误、被 trap 自己的空 catch 吞掉，一行都不记，而在 Continue 下它照常往下记。
# trap 体里若将来调用别的产品函数，要在探针里补同名桩，否则那次调用会被 trap 自己的内层 catch 吞掉、表现为「什么都没记」。
# 另：trap 在引导块的允许清单范围之内，trap 里只能调用 GUI 在它之前定义的函数（目前只有 Write-BootLog）。
# 错误标记在运行时拼出来（复核 X10）：出错那一行的源码里不出现完整标记，所以 trap 的「位置」那一行
# （它记的是出错行的源码）不能替错误消息本身满足断言。
$probeBootLogger = $guiFunctionTexts['Write-BootLog']   # 产品原文，文件开头已经取过

function Invoke-TrapProbe([string]$ProductLogFile, [string]$RaiserText, [string]$Eap) {
  $script:TrapProbeLog = New-Object System.Collections.ArrayList
  $script:TrapProbeSentinel = 'NOT-REACHED'
  if ($ProductLogFile) {
    # 每一探都从「只有首行」的真实日志重新开始，否则上一探留下的同一标记会让这一探的断言空转
    [IO.File]::WriteAllText($ProductLogFile, $probeLogHeader, (New-Object Text.UTF8Encoding($true)))
  }
  $logger = $(if ($ProductLogFile) { $probeBootLogger }
              else { 'function Write-BootLog([string]$Line) { [void]$script:TrapProbeLog.Add($Line) }' })
  $source = @"
`$ErrorActionPreference = '$Eap'
$logger
$($topTrap.Extent.Text)
$RaiserText
`$script:TrapProbeSentinel = 'REACHED'
"@
  $threw = $false
  try { & ([scriptblock]::Create($source)) 2>$null } catch { $threw = $true }
  $logText = $(if ($ProductLogFile) { [IO.File]::ReadAllText($ProductLogFile, [Text.Encoding]::UTF8) }
               else { $script:TrapProbeLog -join "`n" })
  [pscustomobject]@{ LogText = "$logText"; Reached = ($script:TrapProbeSentinel -ne 'NOT-REACHED'); Threw = $threw }
}

$trapRaisers = @(
  @{ What = 'bare throw (OperationStopped / RuntimeException)'; Marker = 'trap probe: uncaught terminating error 未捕获'
     Text = "throw ('trap probe: uncaught terminating ' + 'error 未捕获')" }
  @{ What = 'thrown .NET exception object (not a RuntimeException)'; Marker = 'DOTNET-TRAP-9A3F'
     Text = "throw (New-Object System.InvalidOperationException(('DOTNET-' + 'TRAP-9A3F')))" }
  @{ What = 'cmdlet -ErrorAction Stop failure (category is not OperationStopped)'; Marker = 'CMDLET-TRAP-7B2E'
     Text = "Get-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) ('CMDLET-' + 'TRAP-7B2E-none.txt')) -ErrorAction Stop" }
  @{ What = 'error that is neither OperationStopped nor a RuntimeException'; Marker = 'WRITEERR-TRAP-5C1D'
     Text = "Write-Error -Message ('WRITEERR-' + 'TRAP-5C1D') -Category InvalidArgument -ErrorAction Stop" }
)
Assert-True ($trapRaisers.Count -eq 4) 'trap raiser shapes were not all built'
foreach ($trapRaiser in $trapRaisers) {
  Assert-True (-not $trapRaiser.Text.Contains($trapRaiser.Marker)) `
    "the trap raiser '$($trapRaiser.What)' carries its marker literally on the failing line; the trap's location line alone would satisfy the probe"
}
$trapProdDir = Join-Path ([IO.Path]::GetTempPath()) ('dfb-trap-prod-' + [guid]::NewGuid().ToString('N'))
try {
  $trapStates = @(New-RuntimeProbeStates $topTrap 'the trap' $trapProdDir)
  $trapCells = 0
  foreach ($trapState in $trapStates) {
    $trapLoggerNote = $(if ($trapState.LogFile) { ', product Write-BootLog' } else { '' })
    foreach ($trapRaiser in $trapRaisers) {
      foreach ($trapEap in 'Continue', 'Stop') {
        $trapCells++
        $where = "[trap / $($trapState.Name)$trapLoggerNote / $($trapRaiser.What) / ErrorActionPreference $trapEap]"
        $trapProbe = Invoke-InProbeState $trapState.Vars $trapState.Env { Invoke-TrapProbe $trapState.LogFile $trapRaiser.Text $trapEap }
        Assert-True ($trapProbe.LogText.Contains($trapRaiser.Marker)) `
          "$where the real trap body did not log the uncaught terminating error that was actually raised"
        Assert-True (-not $trapProbe.Reached -and $trapProbe.Threw) `
          ("$where execution continued past an uncaught terminating error, " +
           'or the error did not propagate; fail-fast depends on runtime state')
      }
    }
  }
  Assert-True ($trapCells -eq 32) "the trap probe ran $trapCells state x error-shape x ErrorActionPreference cells instead of 32"
} finally {
  if (Test-Path -LiteralPath $trapProdDir) { Remove-Item -LiteralPath $trapProdDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- 真实启动路径必须真的调用 Initialize-ProtectedUserStateStore（独立复核 R7）----
# 上面 startup-logs 那段测试自己抽出函数、自己调用：把 GUI 顶层那句 try/catch 整个删掉，它照样绿，
# 而真实启动从此不再建立、加固受保护状态目录，也不再给 startup-logs 设可读 ACL。这里守接线本身。
# 结构（AST）：全文恰好一处调用；它是某个脚本作用域 try 的主体里的直属语句（不在函数、条件、循环、
#   脚本块、finally 里）；那个 try 只有一个不限类型的 catch；这句 try 排在它依赖的一切之后、排在第一处
#   用到它所建立状态的顶层语句之前；那组状态变量在 GUI 里只由这个函数赋值。
#   trap 不参与先后比较：PowerShell 的 trap 对整个作用域生效，与书写位置无关。
# 行为：把那句顶层 try 原文抽出来真跑（函数桩成「记一次调用 / 抛错」，Stop-UntrustedGuiStartup
#   桩成记下原因），在上面那四种状态下都断言：成功时调用一次且不中止；失败时恰好中止一次，
#   原因带着原始错误，并且映射到受保护状态初始化那条专门的处理建议。
$topBlock = $ast.EndBlock
$topStatements = @($topBlock.Statements)
Assert-True ($topStatements.Count -gt 0) 'the GUI has no script-scope statements; the AST query is broken'

function Get-TopStatementIndex($Node) {
  $n = $Node
  while ($n -and -not [object]::ReferenceEquals($n.Parent, $topBlock)) { $n = $n.Parent }
  for ($i = 0; $i -lt $topStatements.Count; $i++) {
    if ([object]::ReferenceEquals($topStatements[$i], $n)) { return $i }
  }
  return -1
}

function Get-EnclosingFunction($Node) {
  for ($p = $Node.Parent; $p; $p = $p.Parent) {
    if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { return $p }
  }
  return $null
}

function Get-ScriptScopeIndexes($Nodes) {
  @($Nodes | Where-Object { $_ -and $null -eq (Get-EnclosingFunction $_) } |
    ForEach-Object { Get-TopStatementIndex $_ } | Where-Object { $_ -ge 0 })
}

# 节点桶（$guiFunctionDefs / $guiInitCalls / $guiAssignments …）在文件开头那一次整树遍历里已经建好。

# 结构 1：恰好一处调用，且是脚本作用域 try 主体里的一条直属、无参语句
Assert-True ($guiInitCalls.Count -eq 1) `
  ("the GUI must call Initialize-ProtectedUserStateStore exactly once (found $($guiInitCalls.Count)); " +
   'the function tests above stay green even when real startup never runs it')
$initCall = $guiInitCalls[0]
$initChain = @(); for ($p = $initCall.Parent; $p; $p = $p.Parent) { $initChain += $p.GetType().Name }
$initTry = $initCall.Parent.Parent.Parent
Assert-True ($initCall.CommandElements.Count -eq 1 -and
  $initCall.Parent -is [Management.Automation.Language.PipelineAst] -and @($initCall.Parent.PipelineElements).Count -eq 1 -and
  $initCall.Parent.Parent -is [Management.Automation.Language.StatementBlockAst] -and
  $initTry -is [Management.Automation.Language.TryStatementAst] -and
  [object]::ReferenceEquals($initTry.Body, $initCall.Parent.Parent) -and
  [object]::ReferenceEquals($initTry.Parent, $topBlock)) `
  ('Initialize-ProtectedUserStateStore must be a plain statement directly in the body of a script-scope try; it sits under ' +
   ($initChain -join ' < '))
Assert-True (@($initTry.CatchClauses).Count -eq 1 -and $initTry.CatchClauses[0].IsCatchAll) `
  'the script-scope try around Initialize-ProtectedUserStateStore needs exactly one untyped catch; a typed catch lets other failures skip the refusal'
$initTryIdx = Get-TopStatementIndex $initTry
Assert-True ($initTryIdx -ge 0) 'the script-scope try around Initialize-ProtectedUserStateStore is not a top-level statement'
$initLine = $initTry.Extent.StartLineNumber

# 结构 2：排在它依赖的一切之后（每一项都先断言确实找到了，避免两边都查不到时比较恒真）
$initPrereqs = @(
  @{ What = 'the Initialize-ProtectedUserStateStore definition'; Nodes = @($guiFunctionDefs['Initialize-ProtectedUserStateStore']) }
  @{ What = 'the Stop-UntrustedGuiStartup definition its catch calls'; Nodes = @($guiFunctionDefs['Stop-UntrustedGuiStartup']) }
  @{ What = 'the Write-BootLog definition'; Nodes = @($guiFunctionDefs['Write-BootLog']) }
  @{ What = 'the boot log path setup ($script:BootLogPath)'
     Nodes = @($guiAssignments | Where-Object { $_.Target -eq 'BootLogPath' } | ForEach-Object { $_.Node }) }
  @{ What = 'the session SID validation ($script:OriginalUserSid)'
     Nodes = @($guiAssignments | Where-Object { $_.Target -eq 'OriginalUserSid' } | ForEach-Object { $_.Node }) }
  @{ What = 'the engine dot-source that defines New-ProtectedDirectory and ProgramDataRoot'
     Nodes = @($guiDotSources | Where-Object { "$($_.CommandElements[0].Extent.Text)" -match 'delta-booster\.ps1' }) }
  @{ What = 'the Set-TargetUserContext re-verification of that SID'; Nodes = @($guiSetTargetCalls) }
)
foreach ($pre in $initPrereqs) {
  $preIdx = Get-ScriptScopeIndexes $pre.Nodes
  Assert-True ($preIdx.Count -gt 0) "script-scope prerequisite of the protected state init not found: $($pre.What)"
  $preLast = ($preIdx | Measure-Object -Maximum).Maximum
  Assert-True ($preLast -lt $initTryIdx) `
    ("the script-scope Initialize-ProtectedUserStateStore call (line $initLine) runs before " +
     "$($pre.What) (line $($topStatements[$preLast].Extent.StartLineNumber))")
}

# 结构 2b：生产顺序锚（复核 SB-1）。状态矩阵里「修复 / 兼容会话」那一种之所以算生产状态，是因为这两个会话标志
# 在顶层调用 Initialize-ProtectedUserStateStore 之前就已赋值（修复标志在会话校验块里，兼容标志在 UAC 分支里）。
# 改名或挪到调用之后，矩阵里那一种状态就不再对应生产，要在这里先红、并同步更新状态矩阵。
foreach ($sessionFlag in 'RepairOnlySession', 'NetCafeCompatibilityMode') {
  $flagIdx = Get-ScriptScopeIndexes @($guiAssignments | Where-Object { $_.Target -eq $sessionFlag } | ForEach-Object { $_.Node })
  Assert-True ($flagIdx.Count -gt 0 -and ($flagIdx | Measure-Object -Minimum).Minimum -lt $initTryIdx) `
    ("`$script:$sessionFlag is no longer assigned at script scope before Initialize-ProtectedUserStateStore runs (line $initLine); " +
     'the repair-only / compatibility probe state no longer mirrors production')
}

# 结构 3：排在第一处用到它所建立状态的顶层语句之前。「用到」= 顶层直接读写这组变量，或调用（传递地）
# 读它们的任何 GUI 函数 —— 例如旧数据迁移调用的 Import-ProtectedLegacyState 读 ProtectedUserStateRoot。
$directStateReaders = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$firstStateUse = -1; $firstStateUseNode = $null
foreach ($ref in $guiStateRefs) {
  $owner = Get-EnclosingFunction $ref
  if ($owner) {
    if ($owner.Name -ne 'Initialize-ProtectedUserStateStore') { [void]$directStateReaders.Add($owner.Name) }
  } else {
    $refIdx = Get-TopStatementIndex $ref
    if ($refIdx -ge 0 -and $refIdx -ne $initTryIdx -and ($firstStateUse -lt 0 -or $refIdx -lt $firstStateUse)) {
      $firstStateUse = $refIdx; $firstStateUseNode = $ref
    }
  }
}
Assert-True ($directStateReaders.Count -gt 0 -and $firstStateUse -ge 0) `
  'no GUI function or script-scope statement reads the protected state variables; the first-use query is broken'
$stateReaderMemo = @{}
function Test-ReadsProtectedState([string]$Name) {
  if ($Name -eq 'Initialize-ProtectedUserStateStore' -or -not $guiFunctionDefs.ContainsKey($Name)) { return $false }
  if ($stateReaderMemo.ContainsKey($Name)) { return $stateReaderMemo[$Name] }
  $stateReaderMemo[$Name] = $directStateReaders.Contains($Name)   # 递归环里先按直接读取与否占位
  if (-not $stateReaderMemo[$Name]) {
    $callees = @($guiFunctionDefs[$Name].Body.FindAll({ param($c) $c -is [Management.Automation.Language.CommandAst] }, $true) |
      ForEach-Object { "$($_.GetCommandName())" } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($callee in $callees) {
      if (Test-ReadsProtectedState $callee) { $stateReaderMemo[$Name] = $true; break }
    }
  }
  $stateReaderMemo[$Name]
}
for ($i = 0; $i -lt $firstStateUse; $i++) {
  if ($i -eq $initTryIdx -or $topStatements[$i] -is [Management.Automation.Language.FunctionDefinitionAst]) { continue }
  $readerCall = @($topStatements[$i].FindAll({ param($c) $c -is [Management.Automation.Language.CommandAst] }, $true) |
    Where-Object { $null -eq (Get-EnclosingFunction $_) -and "$($_.GetCommandName())" -and (Test-ReadsProtectedState "$($_.GetCommandName())") } |
    Select-Object -First 1)
  if ($readerCall.Count -gt 0) { $firstStateUse = $i; $firstStateUseNode = $readerCall[0]; break }
}
# 消息里给出触发的那一行源码（变量引用或调用读取者的那一处），而不是整句顶层语句的第一行（常常只是「try {」）
Assert-True ($initTryIdx -lt $firstStateUse) `
  ("script-scope code uses the protected state at line $($firstStateUseNode.Extent.StartLineNumber) " +
   "(statement starting at line $($topStatements[$firstStateUse].Extent.StartLineNumber)) " +
   "before Initialize-ProtectedUserStateStore establishes it at line $initLine; first use: " +
   "$("$($firstStateUseNode.Extent.StartScriptPosition.Line)".Trim())")

# 结构 4：这组状态变量在 GUI 里只由 Initialize-ProtectedUserStateStore 赋值（每个都赋、别处都不赋），
# 否则初始化之后被改指到别处（例如原用户可写的 LocalAppData），接线还在、保护却没了。
# 函数里不带 script: 的同名赋值是局部变量，不算。
$stateWrites = @($guiAssignments | Where-Object { $protectedStateVars -contains $_.Target })
$initWritten = @($stateWrites | Where-Object { [object]::ReferenceEquals((Get-EnclosingFunction $_.Node), $initFn[0]) } |
  ForEach-Object { $_.Target } | Sort-Object -Unique)
Assert-True ($initWritten.Count -eq $protectedStateVars.Count) `
  ('Initialize-ProtectedUserStateStore no longer assigns every protected state variable; assigns: ' + ($initWritten -join ', '))
$strayWrites = @($stateWrites | Where-Object {
  $owner = Get-EnclosingFunction $_.Node
  -not [object]::ReferenceEquals($owner, $initFn[0]) -and ($null -eq $owner -or $_.Path -like 'script:*')
})
Assert-True ($strayWrites.Count -eq 0) `
  ('protected state variables are reassigned outside Initialize-ProtectedUserStateStore: ' +
   (@($strayWrites | ForEach-Object { "line $($_.Node.Extent.StartLineNumber): $($_.Node.Extent.Text)" }) -join ' | '))
# 结构 4b：受保护根 $script:ProgramDataRoot 由引擎从 CommonApplicationData 推导（见后面 startup-logs 的接线检查），
# GUI 只读不写。GUI 在调用之前把它改指到别处（例如原用户可写的 LocalAppData），调用和接线都还在，受保护区却换了地方。
$rootWrites = @($guiAssignments | Where-Object { @('ProgramDataRoot', 'CommonAppData') -contains $_.Target } |
  Where-Object { $null -eq (Get-EnclosingFunction $_.Node) -or $_.Path -like 'script:*' })
Assert-True ($rootWrites.Count -eq 0) `
  ("the GUI re-points the engine's protected root: " +
   (@($rootWrites | ForEach-Object { "line $($_.Node.Extent.StartLineNumber): $($_.Node.Extent.Text)" }) -join ' | '))

# 行为：真跑那句顶层 try 原文。四种状态下成功路径与失败路径都要成立。
function Invoke-InitWiringProbe([string]$StatementText, [bool]$InitFails) {
  $script:InitProbeCalls = 0
  $script:InitProbeStops = New-Object System.Collections.ArrayList
  $failLiteral = $(if ($InitFails) { '$true' } else { '$false' })
  $source = @"
`$ErrorActionPreference = 'Stop'
function Initialize-ProtectedUserStateStore {
  `$script:InitProbeCalls++
  if ($failLiteral) { throw 'init probe: stubbed protected state failure' }
}
function Stop-UntrustedGuiStartup([string]`$Reason) { [void]`$script:InitProbeStops.Add(`$Reason) }
$StatementText
"@
  $escaped = ''
  try { & ([scriptblock]::Create($source)) } catch { $escaped = "$($_.Exception.Message)" }
  [pscustomobject]@{ Calls = $script:InitProbeCalls; Stops = @($script:InitProbeStops); Escaped = $escaped }
}

# 拒绝原因必须映射到「受保护状态初始化失败」那一条专门建议（对手 M-HINT）：只要求「不是兜底那句」时，
# 把前缀改成「父进程校验失败：」照样绿 —— 用户会被引导去重装，而真正的原因是杀软拦截或目录权限。
# 参照原因沿用下面「已知原因必须命中专门分支」那组断言里的同一句，所以它本身也受那组断言守着。
$fallbackHint = Get-StartupFailureHint 'a reason nobody anticipated'
$protectedStateHint = Get-StartupFailureHint '受保护用户状态初始化失败：拒绝访问'
Assert-True ($protectedStateHint -ne $fallbackHint) 'the protected-state-init reason has no dedicated hint; the hint pin below would be vacuous'
# 接线探针只桩了 Initialize-ProtectedUserStateStore 和 Stop-UntrustedGuiStartup，另外能用的只有文件开头加载过真实定义的
# Write-BootLog / Get-StartupFailureHint 和 cmdlet。那句顶层 try 以后再调用别的 GUI / 引擎函数时，探针里没有它，原来会以误导性的
# 「did not end in exactly one Stop-UntrustedGuiStartup」变红（复核 FR2）。这里先把原因说清楚。
$wiringModeled = @('Initialize-ProtectedUserStateStore', 'Stop-UntrustedGuiStartup') + @($guiFunctionTexts.Keys)
$wiringUnmodeled = @($initTry.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) |
  ForEach-Object { "$($_.GetCommandName())" } | Where-Object { $_ -and $wiringModeled -notcontains $_ } | Sort-Object -Unique |
  Where-Object { -not (Test-IsCmdletName $_) })
Assert-True ($wiringUnmodeled.Count -eq 0) `
  ("the script-scope startup try now also calls $($wiringUnmodeled -join ', '), which the init wiring probe neither stubs nor loads; " +
   'give it a stub in Invoke-InitWiringProbe (without one the probe would report a missing refusal that production does not have)')
$initProdDir = Join-Path ([IO.Path]::GetTempPath()) ('dfb-init-prod-' + [guid]::NewGuid().ToString('N'))
try {
  $initStates = @(New-RuntimeProbeStates $initTry 'the startup try' $initProdDir)
  $initCells = 0
  foreach ($initState in $initStates) {
    $initCells++
    $where = "[init wiring / $($initState.Name)]"
    $okRun = Invoke-InProbeState $initState.Vars $initState.Env { Invoke-InitWiringProbe $initTry.Extent.Text $false }
    Assert-True ($okRun.Calls -eq 1 -and $okRun.Stops.Count -eq 0 -and -not $okRun.Escaped) `
      ("$where the script-scope startup try did not run Initialize-ProtectedUserStateStore " +
       "exactly once and carry on (calls $($okRun.Calls), refusals $($okRun.Stops.Count), escaped '$($okRun.Escaped)')")
    $failRun = Invoke-InProbeState $initState.Vars $initState.Env { Invoke-InitWiringProbe $initTry.Extent.Text $true }
    Assert-True ($failRun.Calls -eq 1 -and $failRun.Stops.Count -eq 1) `
      ("$where a failing Initialize-ProtectedUserStateStore did not end in exactly one " +
       "Stop-UntrustedGuiStartup (calls $($failRun.Calls), refusals $($failRun.Stops.Count), escaped '$($failRun.Escaped)'); " +
       'the GUI would run on unprotected state, or die in the trap without a refusal dialog')
    Assert-True ("$($failRun.Stops[0])".Contains('init probe: stubbed protected state failure')) `
      "$where the startup refusal drops the original initialization error: $($failRun.Stops[0])"
    Assert-True ((Get-StartupFailureHint "$($failRun.Stops[0])") -eq $protectedStateHint) `
      ("$where the startup refusal reason does not map to the protected-state-init hint " +
       "(wrong or generic hint): $($failRun.Stops[0])")
  }
  Assert-True ($initCells -eq 4) "the init wiring probe ran in $initCells runtime states instead of 4"
} finally {
  if (Test-Path -LiteralPath $initProdDir) { Remove-Item -LiteralPath $initProdDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# 失败必须先落盘再弹窗：弹窗本身也可能失败，那时日志是唯一线索。
# 用 AST 节点比位置，不做文本匹配 —— 注释里提到 Add-Type 不等于调用了它。
$stopNode = @(Get-GuiFunctionDefinitions 'Stop-UntrustedGuiStartup' | Select-Object -First 1)
Assert-True ($stopNode.Count -eq 1) 'Stop-UntrustedGuiStartup not found'
$stopAst = $stopNode[0]
$stopText = $stopAst.Extent.Text

function Get-FirstCallOffset($FunctionAst, [string]$CommandName) {
  $calls = @($FunctionAst.FindAll({
    param($candidate)
    $candidate -is [Management.Automation.Language.CommandAst] -and
    "$($candidate.GetCommandName())" -eq $CommandName
  }, $true) | Sort-Object { $_.Extent.StartOffset })
  if ($calls.Count -eq 0) { return -1 }
  $calls[0].Extent.StartOffset
}

$logOffset = Get-FirstCallOffset $stopAst 'Write-BootLog'
$uiOffset = Get-FirstCallOffset $stopAst 'Add-Type'
Assert-True ($logOffset -ge 0) 'Stop-UntrustedGuiStartup does not write a boot log'
Assert-True ($uiOffset -ge 0) 'Stop-UntrustedGuiStartup no longer builds a dialog'
Assert-True ($logOffset -lt $uiOffset) `
  'Stop-UntrustedGuiStartup shows the dialog before logging; if WPF fails there is no record'

# WPF 本身起不来时（精简系统 / .NET 组件缺失）也不能把进程卡死在异常里
$stopCatches = @($stopAst.FindAll({
  param($candidate) $candidate -is [Management.Automation.Language.CatchClauseAst]
}, $true))
Assert-True ($stopCatches.Count -ge 1) 'Stop-UntrustedGuiStartup does not survive a WPF failure'

# 弹窗必须带上日志路径，否则用户不知道该交什么
Assert-True ($stopText.Contains('$script:BootLogPath')) `
  'the failure dialog does not tell the user where the log is'

# 行为：在独立 runspace 里真跑 Stop-UntrustedGuiStartup（复核 X4 / X5）—— 它以 exit 结束，在测试进程里跑会把测试本身退掉。
# 上面几条只看「第一处 Write-BootLog 早于 Add-Type」，删掉 exit 1（五个拒绝点全变成「弹个窗然后照常启动」），
# 或把记原因那一行挪到弹窗之后（弹窗卡死、进程在弹窗时被结束，日志里就没有原因），它们照样绿。
# Add-Type 桩成：在「要弹窗」那一刻把日志文件原样抄下来，然后抛错（模拟 WPF 起不来）。断言：那一刻原因和处理建议
# 都已经落盘；函数不返回，排在它后面的那一句永远不执行。
$stopProbeLog = Join-Path ([IO.Path]::GetTempPath()) ('dfb-stop-probe-' + [guid]::NewGuid().ToString('N') + '.log')
$stopProbeReason = '受保护用户状态初始化失败：' + 'STOP-PROBE-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$stopRunspace = [powershell]::Create()
try {
  [IO.File]::WriteAllText($stopProbeLog, $probeLogHeader, (New-Object Text.UTF8Encoding($true)))
  $stopSource = @"
param([string]`$LogFile, [string]`$Reason)
`$ErrorActionPreference = 'Stop'
$($guiFunctionTexts['Write-BootLog'])
$($guiFunctionTexts['Get-StartupFailureHint'])
$stopText
function Add-Type {
  `$script:StopProbeLogAtDialog = [IO.File]::ReadAllText(`$script:BootLogPath, [Text.Encoding]::UTF8)
  throw 'stop probe: dialog unavailable'
}
`$script:BootLogPath = `$LogFile
Stop-UntrustedGuiStartup `$Reason
`$script:StopProbeContinued = 'CONTINUED-PAST-REFUSAL'
"@
  [void]$stopRunspace.AddScript($stopSource).AddParameter('LogFile', $stopProbeLog).AddParameter('Reason', $stopProbeReason)
  $stopAsync = $stopRunspace.BeginInvoke()
  Assert-True ($stopAsync.AsyncWaitHandle.WaitOne(30000)) `
    '[refusal probe] Stop-UntrustedGuiStartup did not finish within 30 s in the probe runspace (a real dialog may be up)'
  $null = $stopRunspace.EndInvoke($stopAsync)
  $stopAtDialog = "$($stopRunspace.Runspace.SessionStateProxy.GetVariable('StopProbeLogAtDialog'))"
  $stopContinued = "$($stopRunspace.Runspace.SessionStateProxy.GetVariable('StopProbeContinued'))"
  $stopErrors = (@($stopRunspace.Streams.Error | ForEach-Object { "$_" }) -join ' | ')
  Assert-True ([bool]$stopAtDialog) `
    "[refusal probe] Stop-UntrustedGuiStartup never reached its dialog (Add-Type) in the probe runspace; errors: $stopErrors"
  Assert-True ($stopAtDialog.Contains($stopProbeReason)) `
    ('[refusal probe] the refusal reason was not on disk yet when the dialog was about to be shown; if WPF hangs or the process ' +
     "is ended while the dialog is up, the log holds no reason. Log at that moment: $($stopAtDialog.Trim())")
  Assert-True ($stopAtDialog.Contains($protectedStateHint)) `
    "[refusal probe] the actionable hint was not on disk yet when the dialog was about to be shown. Log at that moment: $($stopAtDialog.Trim())"
  Assert-True (-not $stopContinued) `
    '[refusal probe] Stop-UntrustedGuiStartup returned and startup went on past the refusal; every refusal site now fails open'
} finally {
  $stopRunspace.Dispose()
  if (Test-Path -LiteralPath $stopProbeLog) { Remove-Item -LiteralPath $stopProbeLog -Force -ErrorAction SilentlyContinue }
}

# ---- 行为测试 ----

# ---- 独立诊断导出器 ----
# 它解开的死锁：主界面打不开时，原本唯一的报障通道是主界面里的「上传完整诊断」。
$exporter = Join-Path $root 'scripts\export-diagnostics.ps1'
$entry = Join-Path $root '导出诊断信息.cmd'
Assert-True (Test-Path -LiteralPath $exporter -PathType Leaf) 'scripts\export-diagnostics.ps1 is missing'
Assert-True (Test-Path -LiteralPath $entry -PathType Leaf) '导出诊断信息.cmd is missing'

$exporterErrors = $null
$exporterTokens = $null
$exporterAst = [Management.Automation.Language.Parser]::ParseFile($exporter, [ref]$exporterTokens, [ref]$exporterErrors)
Assert-True ($exporterErrors.Count -eq 0) `
  ('export-diagnostics.ps1 parse failed: ' + (($exporterErrors | ForEach-Object Message) -join '; '))

# 下面全部按 AST 判断「是否真的调用/依赖」，而不是按文件里有没有出现这个名字。
# 导出器会检查 delta-booster.ps1 等文件是否存在 —— 那是诊断该做的事，不是依赖。
$exporterCalls = @($exporterAst.FindAll({
  param($candidate) $candidate -is [Management.Automation.Language.CommandAst]
}, $true))

# 不得提权：「提权被拒」正是它要诊断的故障之一
$elevating = @($exporterCalls | Where-Object {
  "$($_.GetCommandName())" -eq 'Start-Process' -and "$($_.Extent.Text)" -match '-Verb|runas'
})
Assert-True ($elevating.Count -eq 0) `
  'the exporter tries to elevate; that deadlocks the very case it exists for'

# 不得点源主程序的任何组件 —— 那些恰恰可能是坏掉的部分
$dotSourced = @($exporterCalls | Where-Object {
  $_.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot
})
Assert-True ($dotSourced.Count -eq 0) `
  ('the exporter dot-sources another script, which may itself be the broken part: ' +
   (($dotSourced | ForEach-Object { $_.Extent.Text }) -join ' | '))

# 不得依赖会话上下文环境变量：闸门失败时它们本来就可能是错的或不存在
$exporterVars = @($exporterAst.FindAll({
  param($candidate) $candidate -is [Management.Automation.Language.VariableExpressionAst]
}, $true) | Where-Object { "$($_.VariablePath.UserPath)" -like 'env:DFB_*' })
Assert-True ($exporterVars.Count -eq 0) `
  ('the exporter reads session env vars that may be invalid when startup fails: ' +
   (($exporterVars | ForEach-Object { $_.Extent.Text }) -join ' | '))

# .cmd 入口必须是纯 ASCII：批处理按系统代码页读，非 ASCII 内容在非中文区域会乱码
$entryBytes = [IO.File]::ReadAllBytes($entry)
Assert-True (-not ($entryBytes | Where-Object { $_ -gt 127 })) `
  'the .cmd entry contains non-ASCII bytes; batch files are read in the system codepage'
Assert-True ($entryBytes[0] -ne 0xEF) 'the .cmd entry has a BOM, which cmd.exe echoes as garbage'

# 必须随包分发，否则用户机器上根本没有它
$installerText = [IO.File]::ReadAllText((Join-Path $root 'build\make-installer.ps1'), [Text.Encoding]::UTF8)
Assert-True ($installerText.Contains("'导出诊断信息.cmd'")) `
  'the recovery entry is not in the installer payload whitelist and will not ship'
Assert-True ($installerText.Contains("'scripts\export-diagnostics.ps1'")) `
  'the exporter script is not in the installer payload whitelist and will not ship'

# 但绝不能进启动器的哈希白名单：它必须在完整性校验失败时仍然可用
$launcherText = [IO.File]::ReadAllText((Join-Path $root 'build\make-launcher.ps1'), [Text.Encoding]::UTF8)
$hashListStart = $launcherText.IndexOf('$hashFiles = @(')
Assert-True ($hashListStart -ge 0) 'launcher hash whitelist not found'
$hashListEnd = $launcherText.IndexOf(')', $hashListStart)
$hashList = $launcherText.Substring($hashListStart, $hashListEnd - $hashListStart)
Assert-True (-not $hashList.Contains('export-diagnostics')) `
  'the exporter is hash-pinned by the launcher, so it dies together with the integrity model it diagnoses'

# ---- 三处 startup-logs 必须是同一个目录（复核 W5）----
# 引导块把日志写进的目录、Initialize-ProtectedUserStateStore 加固成普通用户可读的目录、不提权的导出器读的目录，
# 是三个地方各自拼出来的路径。任何一处改名（例如引导块写进 startup-log），日志就落进继承了管理员独占 ACL 的目录，
# 可读的 startup-logs 一直空着，导出器报「没有日志」—— 而上面每条断言都还是绿的：它们各自用测试自己的字面量。
# 这里把真实代码在同一个临时 CommonApplicationData 上串起来跑一遍：
#   引擎推导 ProgramDataRoot 的两行 → 建根（生产里由引擎首次成功运行时建立；引导块自己从不建根）
#   → 真实引导块 + 真实 Write-BootLog 写一行 → 真实 Initialize-ProtectedUserStateStore（New-ProtectedDirectory 桩成只记录）
#   → 导出器真实的 $programData 推导，和它所有读 $programData 的采集节。
# 断言：引导日志所在的目录正是唯一被加固成可读的目录，而且导出器读得出引导日志里的那一行
# （目录里还预置了 4 份更早的旧日志，导出器只导出最近 3 份，最新这份必须在里面 —— 复核 X9）。
# New-ProtectedDirectory 的桩按引擎声明生成，Initialize 调到的其余引擎 / GUI 函数加载真实定义（见场景 1 前的说明）。
# 唯一的替换是三处 [Environment]::GetFolderPath(CommonApplicationData) 换成临时目录，每处都先断言恰好出现一次。
$cadExpr = '[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)'
function Get-OccurrenceCount([string]$Text, [string]$Needle) { ($Text.Length - $Text.Replace($Needle, '').Length) / $Needle.Length }

$bootLoggerDefs = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Write-BootLog' })
Assert-True ($bootLoggerDefs.Count -eq 1 -and $bootLoggerDefs[0].Extent.StartOffset -gt $bootBlockStart) `
  'the script-scope Write-BootLog definition that closes the boot block was not found after the boot block start'
$wiringBootText = $raw.Substring($bootBlockStart, $bootLoggerDefs[0].Extent.EndOffset - $bootBlockStart)
Assert-True ((Get-OccurrenceCount $wiringBootText $cadExpr) -eq 1) `
  'the boot block no longer derives its log root from CommonApplicationData exactly once'

$engineRaw = [IO.File]::ReadAllText((Join-Path $root 'scripts\delta-booster.ps1'), [Text.Encoding]::UTF8)
$wiringEngineLines = @(foreach ($engineVar in 'CommonAppData', 'ProgramDataRoot') {
  $engineMatches = [regex]::Matches($engineRaw, '(?m)^\$script:' + $engineVar + '[ \t]*=[^\r\n]*')
  Assert-True ($engineMatches.Count -eq 1) `
    "expected exactly one script-scope assignment of `$script:$engineVar in scripts\delta-booster.ps1 (found $($engineMatches.Count))"
  $engineMatches[0].Value
})
Assert-True ((Get-OccurrenceCount $wiringEngineLines[0] $cadExpr) -eq 1) `
  'the engine no longer derives $script:CommonAppData from CommonApplicationData'

$exporterAssigns = @($exporterAst.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.AssignmentStatementAst] -and "$($_.Left.Extent.Text)" -eq '$programData' })
Assert-True ($exporterAssigns.Count -eq 1) "the exporter must assign `$programData exactly once at script scope (found $($exporterAssigns.Count))"
Assert-True ((Get-OccurrenceCount $exporterAssigns[0].Extent.Text $cadExpr) -eq 1) `
  'the exporter no longer derives $programData from CommonApplicationData'
$exporterDataProbes = @($exporterAst.EndBlock.Statements | ForEach-Object {
  if ($_ -is [Management.Automation.Language.PipelineAst] -and @($_.PipelineElements).Count -eq 1 -and
      $_.PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and
      "$($_.PipelineElements[0].GetCommandName())" -eq 'Add-Probe') {
    foreach ($element in $_.PipelineElements[0].CommandElements) {
      if ($element -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $null -ne $element.Find({
            param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and "$($n.VariablePath.UserPath)" -eq 'programData'
          }, $true)) { $element.ScriptBlock }
    }
  }
})
Assert-True ($exporterDataProbes.Count -ge 1) 'no exporter probe reads $programData; the diagnostics export no longer looks at the protected data directory'

$wiringRoot = Join-Path ([IO.Path]::GetTempPath()) ('dfb-logs-wiring-' + [guid]::NewGuid().ToString('N'))
$wiringSaved = @{}
foreach ($name in @('BootLogPath', 'CommonAppData', 'ProgramDataRoot', 'OriginalUserSid') + $protectedStateVars) {
  $wiringSaved[$name] = @(Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue)
}
try {
  [void][IO.Directory]::CreateDirectory($wiringRoot)
  & {
    param([string]$ProbeCommonAppData, [string[]]$EngineLines, [string]$BootText, [string]$InitText,
          [string]$ExporterAssign, [object[]]$ExporterProbes)
    foreach ($line in $EngineLines) { Invoke-Expression $line.Replace($cadExpr, '$ProbeCommonAppData') }
    Assert-True ("$script:ProgramDataRoot".StartsWith($ProbeCommonAppData, [StringComparison]::OrdinalIgnoreCase)) `
      "[startup-logs wiring] the engine's ProgramDataRoot is no longer derived from CommonApplicationData: $($script:ProgramDataRoot)"
    [void][IO.Directory]::CreateDirectory($script:ProgramDataRoot)

    Invoke-Expression $BootText.Replace($cadExpr, '$ProbeCommonAppData')
    Assert-True ([bool]$script:BootLogPath) `
      "[startup-logs wiring] the real boot block kept the boot log disabled although the engine's protected root exists: $($script:ProgramDataRoot)"
    # 复核 X9：此前几次启动留下的旧日志（文件名和修改时间都更早）。导出器只导出最近 3 份，
    # 必须包括最新这份 —— 它正是用户要报的这次失败，不能换成最旧的几份。
    $olderMarkers = @(foreach ($older in 1..4) {
      $olderFile = Join-Path ([IO.Path]::GetDirectoryName($script:BootLogPath)) ('startup-2000010{0}-000000-{0}.log' -f $older)
      [IO.File]::WriteAllText($olderFile, ('W5-OLDER-' + "START-$older") + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))
      [IO.File]::SetLastWriteTime($olderFile, (New-Object DateTime(2000, 1, $older)))
      'W5-OLDER-' + "START-$older"
    })
    $sentinel = 'W5-PROBE: boot log line written before the GUI failed'
    Write-BootLog $sentinel
    Assert-True ([IO.File]::Exists($script:BootLogPath)) "[startup-logs wiring] the real boot logger did not create its file: $($script:BootLogPath)"
    $bootDir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($script:BootLogPath)).TrimEnd('\')

    $script:WiringCalls = New-Object 'Collections.Generic.List[object]'
    $script:AclFailPath = ''
    foreach ($helperText in $initHelperTexts) { Invoke-Expression $helperText }
    Invoke-Expression (Get-ProtectedDirectoryStub 'WiringCalls')
    Invoke-Expression $InitText
    $script:OriginalUserSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    Initialize-ProtectedUserStateStore
    $readableDirs = @($script:WiringCalls | Where-Object { $_.UsersRead } | ForEach-Object { [IO.Path]::GetFullPath($_.Path).TrimEnd('\') })
    Assert-True ($readableDirs.Count -eq 1 -and [string]::Equals($readableDirs[0], $bootDir, [StringComparison]::OrdinalIgnoreCase)) `
      ("[startup-logs wiring] the boot logger writes into $bootDir, but Initialize-ProtectedUserStateStore hardens a different " +
       'directory as the user-readable one: ' + ($readableDirs -join ' | '))

    # 导出器自己的 $ErrorActionPreference（export-diagnostics.ps1 开头设的 Continue），它的每一节都按这个写
    $ErrorActionPreference = 'Continue'
    Invoke-Expression $ExporterAssign.Replace($cadExpr, '$ProbeCommonAppData')
    $script:WiringExport = New-Object 'Collections.Generic.List[string]'
    function Add-Line([string]$Text = '') { [void]$script:WiringExport.Add($Text) }
    foreach ($probeBody in $ExporterProbes) {
      try { & $probeBody.GetScriptBlock() } catch { Add-Line "probe failed: $($_.Exception.Message)" }
    }
    $wiringExportText = $script:WiringExport -join "`n"
    $olderExported = @($olderMarkers | Where-Object { $wiringExportText.Contains($_) })
    Assert-True ($wiringExportText.Contains($sentinel) -or $olderExported.Count -eq 0) `
      ("[startup-logs wiring] the exporter exports older startup logs (" + ($olderExported -join ', ') +
       ') but not the newest one, which holds the failing start the user is reporting')
    Assert-True ($wiringExportText.Contains($sentinel)) `
      ("[startup-logs wiring] the unelevated diagnostics exporter does not read the directory the boot logger writes into " +
       "($bootDir); it reported: " + (@($script:WiringExport | Where-Object { $_ } | Select-Object -Last 3) -join ' / '))
  } $wiringRoot $wiringEngineLines $wiringBootText $initFn[0].Extent.Text $exporterAssigns[0].Extent.Text $exporterDataProbes
} finally {
  foreach ($name in $wiringSaved.Keys) {
    if ($wiringSaved[$name].Count -gt 0) { Set-Variable -Name $name -Value $wiringSaved[$name][0].Value -Scope Script }
    else { Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue }
  }
  if (Test-Path -LiteralPath $wiringRoot) { Remove-Item -LiteralPath $wiringRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- 引导块在生产里的另外两种真实处境（复核 X1 / X2）----
# W5 只在「受保护根已经存在」时真跑过引导块。这里再真跑两次引导块 + 环境快照的原文（到 trap 为止）：
# X1 全新安装：CommonApplicationData 下什么都没有。「绝不创建受保护根」原来只有文本钉子守着 —— 改成「记下根不存在、
#    照样往下走」，CreateDirectory(startup-logs) 就顺手建出一个归当前用户所有、继承 ACL 的根，EngineHost 从此每次都以
#    「受保护会话目录已被不安全地预占」拒绝启动。断言：CommonApplicationData 下什么都没建，引导日志保持关闭。
# X2 生产会话：环境变量照 EngineHost.StartGui 下发的设上（变量名从 build\make-engine-host.ps1 的 C# 源码里取），
#    TEMP/TMP = <CommonApplicationData>\DeltaForceBooster\session-temp\<32 位会话标记>，另有控制管道名。
#    这份日志对普通用户可读：完整会话标记（broker 握手的共享秘密）和控制管道名都不许出现，会话标记只许前 8 位。
#    216492a 的快照把 TEMP 原样写进日志，完整会话标记就在里面，而原来的文本钉子只看 SESSION= 那一行。
$bootSnapshotEnd = $topTrap.Extent.StartOffset
Assert-True ($bootSnapshotEnd -gt $bootLoggerDefs[0].Extent.EndOffset) `
  'the boot environment snapshot no longer sits between the Write-BootLog definition and the trap; the probes below would not run it'
$bootSnapshotText = $raw.Substring($bootBlockStart, $bootSnapshotEnd - $bootBlockStart)
Assert-True ((Get-OccurrenceCount $bootSnapshotText $cadExpr) -eq 1) `
  'the boot block + environment snapshot no longer derive the log root from CommonApplicationData exactly once'

# ReplaceEnvironment：先清空整个进程环境、只留 EnvVars（照 EngineHost 的 psi.EnvironmentVariables.Clear()），结束后逐条还原。
# TrapText 非空时，快照之后再真跑一次产品 trap 原文，抛一个消息里带 %TEMP% 路径的未捕获错误：会话标记也会经由异常消息进日志。
function Invoke-BootSnapshotProbe([string]$ProbeCommonAppData, [Collections.IDictionary]$EnvVars, [bool]$ReplaceEnvironment = $false,
                                  [string]$TrapText = '') {
  $savedBootLogPath = @(Get-Variable -Name BootLogPath -Scope Script -ErrorAction SilentlyContinue)
  $savedEnv = [Environment]::GetEnvironmentVariables('Process')
  try {
    if ($ReplaceEnvironment) {
      foreach ($key in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable("$key", $null, 'Process') }
    }
    foreach ($key in @($EnvVars.Keys)) { [Environment]::SetEnvironmentVariable("$key", "$($EnvVars[$key])", 'Process') }
    $derivedRoot = & {
      param([string]$ProbeCommonAppData, [string]$BootText, [string]$TrapText)
      Invoke-Expression $BootText.Replace($cadExpr, '$ProbeCommonAppData')
      Write-BootLog 'BOOT-PROBE: a later startup line'
      if ($TrapText) {
        # 形如 GUI 的 PresentMon 临时 csv 找不到：消息里是 TEMP，也就是 session-temp\<完整会话标记>
        $raiser = "throw [IO.FileNotFoundException]::new('BOOT-PROBE-TRAP missing ' + [IO.Path]::Combine(`$env:TEMP, 'dfb-presentmon-1234.csv'))"
        try { & ([scriptblock]::Create($TrapText + "`r`n" + $raiser)) 2>$null } catch {}
      }
      "$bootLogRoot"
    } $ProbeCommonAppData $bootSnapshotText $TrapText
    [pscustomobject]@{ LogPath = "$script:BootLogPath"; Root = "$derivedRoot" }
  } finally {
    foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
      if (-not $savedEnv.Contains($key)) { [Environment]::SetEnvironmentVariable("$key", $null, 'Process') }
    }
    foreach ($key in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable("$key", "$($savedEnv[$key])", 'Process') }
    if ($savedBootLogPath.Count -gt 0) { $script:BootLogPath = $savedBootLogPath[0].Value }
    else { Remove-Variable -Name BootLogPath -Scope Script -ErrorAction SilentlyContinue }
  }
}

# X1：全新安装
$freshCad = Join-Path ([IO.Path]::GetTempPath()) ('dfb-fresh-install-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($freshCad)
try {
  $freshRun = Invoke-BootSnapshotProbe $freshCad @{}
  Assert-True ($freshRun.Root.StartsWith($freshCad, [StringComparison]::OrdinalIgnoreCase)) `
    "[fresh install] the probe never ran the boot block's root derivation against the empty CommonApplicationData (root: '$($freshRun.Root)')"
  $freshCreated = @([IO.Directory]::GetFileSystemEntries($freshCad, '*', [IO.SearchOption]::AllDirectories))
  Assert-True ($freshCreated.Count -eq 0) `
    ('[fresh install] the real boot block created ' + ($freshCreated -join ' | ') + ' under an empty CommonApplicationData; ' +
     'the protected root may only be created admin-only by EngineHost / New-ProtectedDirectory, a user-owned root makes every later start fail')
  Assert-True ($freshRun.LogPath -eq '') `
    "[fresh install] the boot block enabled the boot log although the protected root does not exist: $($freshRun.LogPath)"
} finally {
  if (Test-Path -LiteralPath $freshCad) { Remove-Item -LiteralPath $freshCad -Recurse -Force -ErrorAction SilentlyContinue }
}

# X2：EngineHost 下发的生产会话环境，照 build\make-engine-host.ps1 里 StartGui 的 C# 源码构造，不在测试里另抄一份清单：
#  - 变量名和取值来源逐条取自 psi.EnvironmentVariables["NAME"] = <rhs>;。rhs 是 StartGui 的参数 session / sessionTemp /
#    controlPipe / sid / localAppData 时换成探针的对应值（sessionTemp 按 CreateSessionTemp 的布局 <CommonApplicationData>
#    \DeltaForceBooster\session-temp\<会话标记>，controlPipe = DeltaForceBooster.Engine.<32 位十六进制>），launcherPid /
#    EngineHost 自身 PID / repairOnly 换成生产值，字符串字面量照抄，其余（机器路径）取测试进程里的同名值。rhs 由这几个秘密参数拼出来、
#    探针算不出来时直接红，要求更新探针。
#  - StartGui 先 psi.EnvironmentVariables.Clear() 时，探针也清空整个进程环境、只留这一组变量，结束后逐条还原。
# 这样 EngineHost 以后多下发一个带会话标记的变量、GUI 又把它写进日志，同样逃不过去。
$hostSource = [IO.File]::ReadAllText((Join-Path $root 'build\make-engine-host.ps1'), [Text.Encoding]::UTF8)
$startGuiAt = $hostSource.IndexOf('static Process StartGui(')
$startGuiEnd = $(if ($startGuiAt -ge 0) { $hostSource.IndexOf('Process.Start(psi)', $startGuiAt) } else { -1 })
Assert-True ($startGuiAt -ge 0 -and $startGuiEnd -gt $startGuiAt) `
  'EngineHost.StartGui was not found in build\make-engine-host.ps1; the session-leak probe cannot mirror the environment it hands the GUI'
$startGuiText = $hostSource.Substring($startGuiAt, $startGuiEnd - $startGuiAt)
$leakCad = Join-Path ([IO.Path]::GetTempPath()) ('dfb-session-leak-' + [guid]::NewGuid().ToString('N'))
$leakSession = [guid]::NewGuid().ToString('N')      # EngineHost 的会话标记和管道名都是 32 位小写十六进制
$leakPipeHex = [guid]::NewGuid().ToString('N')
$leakPipe = 'DeltaForceBooster.Engine.' + $leakPipeHex
$leakTemp = Join-Path $leakCad "DeltaForceBooster\session-temp\$leakSession"
$hostParamValues = @{
  session = $leakSession; sessionTemp = $leakTemp; controlPipe = $leakPipe
  sid = $aclProdEnv['DFB_ORIGINAL_USER_SID']; localAppData = $aclProdEnv['DFB_ORIGINAL_LOCALAPPDATA']
}
$leakEnv = [ordered]@{}
foreach ($envMatch in [regex]::Matches($startGuiText, 'psi\.EnvironmentVariables\["([^"]+)"\]\s*=\s*([^;]+);')) {
  $envName = $envMatch.Groups[1].Value; $envRhs = $envMatch.Groups[2].Value.Trim()
  if ($hostParamValues.ContainsKey($envRhs)) { $leakEnv[$envName] = $hostParamValues[$envRhs] }
  elseif ($envRhs -cmatch '^launcherPid\b') { $leakEnv[$envName] = $aclProdEnv['DFB_LAUNCHER_PID'] }
  elseif ($envRhs -cmatch '^Process\.GetCurrentProcess\(\)\.Id\b') { $leakEnv[$envName] = $aclProdEnv['DFB_ENGINE_HOST_PID'] }
  elseif ($envRhs -cmatch '^repairOnly\s*\?') { $leakEnv[$envName] = $aclProdEnv['DFB_REPAIR_ONLY'] }
  elseif ($envRhs -cmatch '^"([^"\\]*)"$') { $leakEnv[$envName] = $Matches[1] }
  else {
    Assert-True ($envRhs -cnotmatch '\b(session|sessionTemp|controlPipe)\b') `
      ("EngineHost.StartGui derives $envName from '$envRhs', which the session-leak probe cannot compute; " +
       'update the probe so it hands the boot block what EngineHost hands the GUI')
    $leakEnv[$envName] = [Environment]::GetEnvironmentVariable($envName, 'Process')
  }
}
$leakExpected = [ordered]@{ TEMP = $leakTemp; TMP = $leakTemp; DFB_ENGINE_HOST_SESSION = $leakSession; DFB_ENGINE_CONTROL_PIPE = $leakPipe }
$leakMismatch = @($leakExpected.Keys | Where-Object { -not $leakEnv.Contains($_) -or "$($leakEnv[$_])" -cne $leakExpected[$_] })
Assert-True ($leakMismatch.Count -eq 0) `
  ('EngineHost.StartGui no longer hands the GUI ' + ($leakMismatch -join ', ') + ' straight from its sessionTemp / session / controlPipe ' +
   'parameters; update the session-leak probe (StartGui sets: ' + (@($leakEnv.Keys) -join ', ') + ')')
$hostClearsEnv = $startGuiText.Contains('psi.EnvironmentVariables.Clear()')
try {
  [void][IO.Directory]::CreateDirectory($leakTemp)   # EngineHost 在启动 GUI 之前建好会话临时目录，受保护根因此已经存在
  $leakRun = Invoke-BootSnapshotProbe $leakCad $leakEnv $hostClearsEnv $topTrap.Extent.Text
  Assert-True ($leakRun.LogPath -and [IO.File]::Exists($leakRun.LogPath)) `
    "[session leak] the real boot block wrote no boot log under the production session environment ('$($leakRun.LogPath)'); the leak checks would compare nothing"
  $leakLog = [IO.File]::ReadAllText($leakRun.LogPath, [Text.Encoding]::UTF8)
  Assert-True ($leakLog.Contains('BOOT-PROBE-TRAP missing') -and $leakLog.Contains('dfb-presentmon-1234.csv')) `
    '[session leak] the real trap did not log the uncaught error whose message carries the session-temp path; the trap-message leak check would compare nothing'
  $sessionLines = @($leakLog -split "`r?`n" | Where-Object { $_.IndexOf($leakSession, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    ForEach-Object { $_ -ireplace [regex]::Escape($leakSession), '<FULL-SESSION>' })
  Assert-True ($sessionLines.Count -eq 0) `
    ('[session leak] the user-readable boot log contains the full 32-hex EngineHost session marker (only its first 8 characters may be logged): ' +
     ($sessionLines -join ' | '))
  $pipeLines = @($leakLog -split "`r?`n" | Where-Object { $_.IndexOf($leakPipeHex, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
    ForEach-Object { $_ -ireplace [regex]::Escape($leakPipeHex), '<PIPE-HEX>' })
  Assert-True ($pipeLines.Count -eq 0) `
    ('[session leak] the user-readable boot log contains the EngineHost control pipe name: ' + ($pipeLines -join ' | '))
  Assert-True ($leakLog.IndexOf($leakSession.Substring(0, 8), [StringComparison]::OrdinalIgnoreCase) -ge 0) `
    '[session leak] the snapshot no longer logs even the 8-character session prefix under the production environment; the probe never saw the session reach the log'
} finally {
  if (Test-Path -LiteralPath $leakCad) { Remove-Item -LiteralPath $leakCad -Recurse -Force -ErrorAction SilentlyContinue }
}

$case = Join-Path ([IO.Path]::GetTempPath()) ('dfb-bootlog-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($case)
try {
  $script:BootLogPath = Join-Path $case 'startup.log'

  Write-BootLog 'first line'
  Assert-True ([IO.File]::Exists($script:BootLogPath)) 'boot log file was not created'

  Write-BootLog 'second line'
  $text = [IO.File]::ReadAllText($script:BootLogPath, [Text.Encoding]::UTF8)
  Assert-True ($text.Contains('first line') -and $text.Contains('second line')) `
    'boot log overwrote instead of appending'
  Assert-True ($text -match '\[\d{2}:\d{2}:\d{2}\.\d{3}\]') 'boot log lines carry no timestamp'

  # UTF-8 BOM：没有 BOM 的话中文日志在记事本和 PowerShell 里都会乱码，
  # 等于日志写了但读不了
  $bytes = [IO.File]::ReadAllBytes($script:BootLogPath)
  Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
    'boot log has no UTF-8 BOM, so non-ASCII content will be unreadable'

  # 日志器绝不能把程序弄崩 —— 那比没有日志更糟
  $script:BootLogPath = 'Z:\no-such-volume\nested\x.log'
  Write-BootLog 'should not throw'
  Assert-True ($script:BootLogPath -eq '') `
    'an unwritable path did not degrade to the no-log state'

  $script:BootLogPath = ''
  Write-BootLog 'should be a no-op'

  # 每个真实调用点的原因都必须得到一句可行动的建议，未知原因也要有兜底
  foreach ($reason in 'EngineHost 会话标记缺失或无效',
                      '启动器会话标记缺失或无效',
                      'EngineHost 修复会话标记无效',
                      '主界面没有管理员令牌',
                      '当前 UAC 策略需要受限兼容会话',
                      '原交互用户 SID 无效',
                      '原交互用户 LocalAppData 不在可验证的本地固定磁盘路径',
                      '受保护用户状态初始化失败：拒绝访问',
                      'a reason nobody anticipated') {
    $hint = Get-StartupFailureHint $reason
    Assert-True ("$hint".Trim().Length -gt 10) "no actionable hint for reason: $reason"
  }

  # 已知原因必须命中专门的分支，而不是都落到 default
  $fallback = Get-StartupFailureHint 'a reason nobody anticipated'
  foreach ($reason in 'EngineHost 会话标记缺失或无效',
                      '主界面没有管理员令牌',
                      '当前 UAC 策略需要受限兼容会话',
                      '受保护用户状态初始化失败：拒绝访问') {
    Assert-True ((Get-StartupFailureHint $reason) -ne $fallback) `
      "reason fell through to the default hint: $reason"
  }
} finally {
  Remove-Item -LiteralPath $case -Recurse -Force -ErrorAction SilentlyContinue
}

'Startup bootstrap tests passed.'
