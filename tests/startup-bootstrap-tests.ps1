#requires -Version 5.1
param()

# 启动引导日志的回归测试。
# 这一层存在的唯一理由：主界面前三千行任何失败原本都不产生磁盘记录，
# 「软件打不开」类反馈因此无法定位。下面每条断言都在守护一个让它失效的方式。

$ErrorActionPreference = 'Stop'
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

function Get-GuiFunctionText([string]$Name) {
  $node = @($ast.FindAll({
    param($candidate)
    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name
  }, $true) | Select-Object -First 1)
  Assert-True ($node.Count -eq 1) "function not found: $Name"
  $node[0].Extent.Text
}

foreach ($name in 'Write-BootLog', 'Get-StartupFailureHint') {
  Invoke-Expression (Get-GuiFunctionText $name)
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

# 按 token 流检查，而不是按原文子串 —— 注释里提到某个 cmdlet 名字不算使用它。
# （第一版就是这么误报的：注释写着「用 .NET 排序，不用 Sort-Object」。）
$forbidden = @('Get-Date', 'New-Object', 'Sort-Object', 'Get-ChildItem', 'Out-File',
               'Set-Content', 'Add-Content', 'Test-Path', 'New-Item', 'Remove-Item',
               'Write-Host', 'Get-Content', 'Join-Path', 'Split-Path')
$bootTokens = @($tokens | Where-Object {
  $_.Extent.StartOffset -ge $bootBlockStart -and $_.Extent.EndOffset -le $bootBlockEnd -and
  $_.Kind -ne [Management.Automation.Language.TokenKind]::Comment
})
Assert-True ($bootTokens.Count -gt 0) 'no tokens found inside the bootstrap block'
foreach ($name in $forbidden) {
  $hit = @($bootTokens | Where-Object { "$($_.Text)" -eq $name })
  Assert-True ($hit.Count -eq 0) `
    "bootstrap block uses the cmdlet $name, which can trigger module autoload before PSModulePath is hardened"
}

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

# startup-logs 必须对普通用户可读，否则「打不开」时无法以普通权限导出诊断
$initText = Get-GuiFunctionText 'Initialize-ProtectedUserStateStore'
Assert-True ($initText -match "New-ProtectedDirectory\s*\(Join-Path[^)]*'startup-logs'\)\s*\`$true") `
  'startup-logs is not provisioned as user-readable; an unelevated recovery tool cannot read it'
# 纯诊断设施不得影响启动
Assert-True ($initText -match '(?s)try\s*\{[^}]*startup-logs[^}]*\}\s*catch') `
  'startup-logs provisioning is not wrapped in try/catch; a diagnostics failure would block startup'

# ---- 兜底陷阱：必须存在、必须先记日志、必须以 break 无条件终止 ----
# 不用正则：原来的 '(?s)trap\s*\{.*?Write-BootLog.*?break' 里 .*? 不受 trap 范围约束，会一路
# 匹配到文件后面别处某个 if 里的 break——把 trap 里的 break 改成 continue 照样绿（独立复核变异 07）。
# 这里全走 AST（注释不是节点），并且只在这一个 trap 的子树里判定。
$topTraps = @($ast.FindAll({
  param($candidate)
  $candidate -is [Management.Automation.Language.TrapStatementAst] -and
  $candidate.Parent -is [Management.Automation.Language.NamedBlockAst] -and
  $candidate.Parent.Parent -eq $ast
}, $true))
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

# 行为：把产品 trap 原文取出来真跑一遍，只桩掉落盘的 Write-BootLog。
# 探针里 ErrorActionPreference 必须是 Continue：否则「删掉 break」退回 trap 默认的「记录并继续」时，
# 外层的 Stop 会把它伪装成终止。trap 体里若将来调用别的产品函数，要在探针里补同名桩，
# 否则那次调用会被 trap 自己的内层 catch 吞掉、表现为「什么都没记」。
$script:TrapProbeLog = New-Object System.Collections.ArrayList
$script:TrapProbeSentinel = 'NOT-REACHED'
$trapProbeSource = @"
`$ErrorActionPreference = 'Continue'
function Write-BootLog([string]`$Line) { [void]`$script:TrapProbeLog.Add(`$Line) }
$($topTrap.Extent.Text)
throw 'trap probe: uncaught terminating error'
`$script:TrapProbeSentinel = 'REACHED'
"@
$trapProbeThrew = $false
try { & ([scriptblock]::Create($trapProbeSource)) 2>$null } catch { $trapProbeThrew = $true }
Assert-True (($script:TrapProbeLog -join "`n").Contains('trap probe: uncaught terminating error')) `
  'the real trap body did not log the uncaught terminating error that was actually raised'
Assert-True ($script:TrapProbeSentinel -eq 'NOT-REACHED' -and $trapProbeThrew) `
  'execution continued past an uncaught terminating error, or the error did not propagate; fail-fast is gone'

# 第二遍：trap 体里引用的变量在测试里通常是空的（窗口没起来、环境变量没设），上线后却可能是真值。
# 全部强制成真值再跑一遍，两种取值方向都覆盖：任何「看运行时状态决定要不要终止」的写法在这里现形。
$trapVarPaths = @($topTrap.FindAll({ param($c) $c -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
  ForEach-Object { "$($_.VariablePath.UserPath)" } | Sort-Object -Unique |
  Where-Object { @('_', 'PSItem', 'null', 'true', 'false', 'args', 'input', 'this') -notcontains $_ })
$trapSavedEnv = @{}; $trapSavedVars = @{}
try {
  foreach ($path in $trapVarPaths) {
    if ($path -like 'env:*') {
      $envName = $path.Substring(4)
      $trapSavedEnv[$envName] = [Environment]::GetEnvironmentVariable($envName, 'Process')
      [Environment]::SetEnvironmentVariable($envName, '1', 'Process')
    } else {
      $varName = $path -replace '^(?i)(script|global|local|private):', ''
      $trapSavedVars[$varName] = @(Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue)
      Set-Variable -Name $varName -Value $true -Scope Script
    }
  }
  $script:TrapProbeLog.Clear()
  $script:TrapProbeSentinel = 'NOT-REACHED'
  $trapProbeThrew = $false
  try { & ([scriptblock]::Create($trapProbeSource)) 2>$null } catch { $trapProbeThrew = $true }
} finally {
  foreach ($envName in $trapSavedEnv.Keys) { [Environment]::SetEnvironmentVariable($envName, $trapSavedEnv[$envName], 'Process') }
  foreach ($varName in $trapSavedVars.Keys) {
    if ($trapSavedVars[$varName].Count -gt 0) { Set-Variable -Name $varName -Value $trapSavedVars[$varName][0].Value -Scope Script }
    else { Remove-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue }
  }
}
Assert-True ($script:TrapProbeSentinel -eq 'NOT-REACHED' -and $trapProbeThrew) `
  ('with every variable the trap reads forced truthy (' + ($trapVarPaths -join ', ') +
   '), execution continued past an uncaught terminating error; fail-fast depends on runtime state')

# 失败必须先落盘再弹窗：弹窗本身也可能失败，那时日志是唯一线索。
# 用 AST 节点比位置，不做文本匹配 —— 注释里提到 Add-Type 不等于调用了它。
$stopNode = @($ast.FindAll({
  param($candidate)
  $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $candidate.Name -eq 'Stop-UntrustedGuiStartup'
}, $true) | Select-Object -First 1)
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
