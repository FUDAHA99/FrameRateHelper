#requires -Version 5.1
param()

# 本文件含中文，必须带 UTF-8 BOM —— PS 5.1 会把无 BOM 文件按系统 ANSI（这里是 GBK）读。
#
# ============================================================================
#  身份冻结测试
# ============================================================================
#
# 本分支把产品显示名改成了「帧率优化助手」，但 ASCII 标识符 DeltaForceBooster
# 及其全部派生名**永久冻结**。这个文件的作用是让任何一次「顺手全局替换一下」
# 立刻变红。
#
# 为什么冻结 —— 这些字符串描述的不是我们的品牌，是**用户机器上已经存在的东西**：
#
#   %ProgramData%\DeltaForceBooster      用户回退系统改动的唯一依据（卸载时永久保留）
#   backup.key                           那些备份的 HMAC 密钥，与备份同根
#   DeltaForceBooster-PowerPlanLock      写进了备份文档，且被 Assert-BackupOperation
#                                        的 sched 白名单逐字校验
#   三角洲优化 · 卓越性能                用户电源选项里已经存在的方案名，-ceq 精确比对
#   Global\DeltaForceBooster.Engine      全机唯一的系统写入串行锁
#   Global\...LaunchSession              卸载器靠它判断主程序是否在运行
#   ProductId=DeltaForceBooster          覆盖安装与 D 盘锚点的身份闸门
#   .DeltaForceBooster.migrated-<32hex>  已经写在用户磁盘上的目录名
#
# 改名后的失败模式是**肯定式的安抚**，不是报错：优化页读实时系统值照常显示
# 「已优化」，还原页平静地说「当前没有仍由工具管理的可还原改动」。用户不会来
# 报 bug —— 他会相信系统是干净的。
#
# 特别注意：DeltaForce 是 DeltaForceBooster 的前缀子串。任何
# DeltaForce -> X 的全局替换都会打中游戏进程名 DeltaForceClient.exe，
# 后果是 IFEO 备份不过白名单 -> 整份备份 throw -> 整页还原瘫痪。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}

$script:FileCache = @{}
function Get-Source([string]$Relative) {
  if (-not $script:FileCache.ContainsKey($Relative)) {
    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "冻结清单引用的文件不存在：$Relative" }
    $script:FileCache[$Relative] = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
  }
  $script:FileCache[$Relative]
}

function Assert-Frozen([string]$Literal, [string]$Reason, [string[]]$Files) {
  foreach ($f in $Files) {
    Assert-True ((Get-Source $f).Contains($Literal)) "冻结身份丢失：$f 里应有 [$Literal] —— $Reason"
  }
}

# ---------- 1. 磁盘状态根 ----------
# 十多份独立硬编码，故意不做常量收敛：export-diagnostics.ps1 必须能在主程序起不来时
# 独立运行，user-context-worker 跑在另一个完整性级别，C# 侧是另外三个编译产物。
# 收敛会制造耦合，所以改用这条测试保证它们始终一致。

# ---------- 1a. 状态根：不能只查「文件里出现过这个词」 ----------
#
# 独立复核实测：只把 scripts\delta-booster.ps1 里**真正那一条** ProgramData 根赋值
# 的 'DeltaForceBooster' 改成别的名字，下面的 Assert-Frozen 全部照常通过 —— 因为它是
# 全文搜字面量，而这个词在同一份文件里还有十几处（旧数据根、互斥体名、路径派生）。
# 改了这一条，已安装用户的备份、backup.key、per-SID 配置全部找不到。
#
# 两道防线：
#   A. 逐条赋值（AST）—— 每一处对状态根的赋值，其右侧的**引号字面量**都必须是
#      冻结值。注意裸命令名（Join-Path 这种）在 AST 里也是 StringConstantExpressionAst，
#      所以必须按 StringConstantType 排掉 BareWord，否则这条断言自己就是假的。
#      赋值数量也钉死：新增一处根赋值必须有人看过。
#   B. 逐值钉死 —— 每个组件里「值中含冻结根名」的每一个字面量，完整值逐项比对（第 1 节末尾的 B 段）。
#      注释不进 AST；内嵌在 here-string 里的卸载脚本 / C# 源码按各自的语法递归展开。
#      （第二轮复核 IF-1：只数出现次数时，改成 'DeltaForceBooster2' 或 'Old\DeltaForceBooster'
#      计数不变，照样全绿。）

# A. 逐条赋值：delta-booster.ps1 里对两个状态根的**每一处**赋值
#    （包括嵌在 Set-TargetUserContext 函数里的那一处 —— 只取顶层赋值会漏掉它）
$engineRaw = [IO.File]::ReadAllText((Join-Path $root 'scripts\delta-booster.ps1'), [Text.Encoding]::UTF8)
$engineTokens = $null; $engineErrors = $null
$engineAst = [Management.Automation.Language.Parser]::ParseInput($engineRaw, [ref]$engineTokens, [ref]$engineErrors)
Assert-True ($engineErrors.Count -eq 0) '引擎解析失败，无法做状态根冻结核对'
$rootAssignments = @($engineAst.FindAll({
  param($n)
  $n -is [Management.Automation.Language.AssignmentStatementAst] -and
  "$($n.Left)" -in '$script:ProgramDataRoot', '$script:UserDataRoot'
}, $true))
Assert-True ($rootAssignments.Count -eq 3) `
  ("状态根赋值个数变了（实际 $($rootAssignments.Count)，预期 3）—— " +
   '新增或删减一处根赋值必须有人看过，不能静默滑过去')
foreach ($assign in $rootAssignments) {
  $quoted = @($assign.Right.FindAll({
    param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $n.StringConstantType -ne 'BareWord'
  }, $true))
  Assert-True ($quoted.Count -ge 1) `
    ("第 $($assign.Extent.StartLineNumber) 行的状态根赋值里一个引号字面量都没有 —— " +
     '根名被改成变量或计算值了，冻结核对就失效了')
  foreach ($lit in $quoted) {
    Assert-True ($lit.Value -ceq 'DeltaForceBooster') `
      ("第 $($assign.Extent.StartLineNumber) 行的状态根赋值用了非冻结字面量：[$($lit.Value)] —— " +
       '改了这里，已安装用户的备份、backup.key、per-SID 配置全部找不到')
  }
}

# ---------- 1b. 状态根的**完整位置**：父目录、全部写入与真实加载顺序都要钉住 ----------
#
# 独立复核第二轮（R3）实测：把 $script:ProgramDataRoot 的父目录从 $script:CommonAppData 换成
# $script:CurrentLocalAppData、根名 'DeltaForceBooster' 不动，上面 A 和下面 B 照常通过 —— 它们只看根名。
# 可这一改等于把备份、backup.key、IPC、per-SID 配置整体搬进原用户可写的 LocalAppData：
# 已安装用户的状态全部失联，high token 还开始读写用户可控目录。
# 攻击复核又实测了 17 种写法（K01-K17：未限定 / 类型化 / Set-Variable 重绑、只在生产里成立的分支、
# Set-TargetUserContext 与 Initialize-UserDataStore 顺手改写、GUI 点源后改写、卸载脚本与闸门的事后覆盖、
# C# 派生变量改写……），只查「推导那一行」的防线全部放过。
# 再一轮复核（A1-A11）又实测了一批：GUI 在初始化之后才点源 updater / tuning（updater 顶层「声明」一句
# $script:BoosterUserConfigDir = $null，高权限 GUI 的「不再提醒此版本」就再也存不下来）、引导闸门外层 catch 只记日志、
# 显式上下文不再把 LocalAppData 绑定到 SID / 不更新 SID、GUI per-SID 分区跟了提权令牌、迁移来源顺序颠倒、
# 安装向导把 legacy-roots 写成别的文件名、受保护目录对 Users 可读、release 构建带上 DFB_TESTING。下面各层都有对应的真跑或钉死。
#
# 所以分两层：
#
# 第一层：行为。真跑产品自己的语句，进程环境变量 ProgramData / ALLUSERSPROFILE / LOCALAPPDATA / APPDATA /
# USERPROFILE 全部换成毒值，读出来的路径与测试自己从 Known Folder 推出的期望逐项比对。它不管写法，
# 整族拦住；只桩掉「写盘 / 判管理员 / 判目录存在」这几个与路径推导无关的点，一律不落盘。
#   C1-C4  引擎顶层那串赋值（真实值 + 三个互不相同的哨兵父目录，区分 Target / Current）以及
#          Set-TargetUserContext 尾部两条分支、整函数调用。
#   F-A    整个引擎按 GUI 的方式点源（生产加载顺序）；隐式 / 显式 x 管理员 / 非管理员跑 Set-TargetUserContext
#          （每次调用前先把上下文写成另一个用户的陈旧值，并核对 HKCU 实际落到哪个配置单元）；再按入口分发的顺序跑
#          Initialize-UserDataStore，以及备份库 / IPC 的初始化（目录位置 + BUILTIN\Users 只读位）；显式上下文的两个负例
#          （调用方交来的 LocalAppData 不是该 SID 的必须拒绝；该 SID 的 Local AppData 验证不了必须拒绝）；
#          最后跑引擎自己的会话目录闸门。
#   F-A2   显式上下文 + 不是本进程的 SID（标准用户输管理员凭据的 OTS 提权、卸载器的 -UserSid 路径）。
#   F-G    GUI 启动段原样执行：点源引擎 -> Set-TargetUserContext -> Initialize-ProtectedUserStateStore -> 一直到
#          updater.ps1 / tuning-experiment.ps1 加载完（它们与 GUI 共用脚本作用域），前后各快照一次，并核对高权限
#          updater 的配置路径。F-G2：原用户不是进程令牌的用户（OTS 提权）时，GUI 的 per-SID 分区跟原用户走。
#   F-T    会话目录闸门（GUI 引导闸门、GUI 交换目录、引擎会话目录）与 tuning 备份引用判定：
#          受保护位置必须放行，原用户的 %TEMP% / LocalAppData 必须拒绝；GUI 引导闸门还要放回它外层每一层 try 的
#          原样 catch 里再跑一次（catch 只记日志 = 放行）。
#   F-W    worker 的 Get-WorkerLocalAppData（差分：真实环境 / 每个变量单独毒化 / 全部毒化，失败时点名依赖的变量）；
#          F-W2 worker 旧数据迁移在沙箱里真跑：同一文件两处都有时 LocalAppData 优先；F-P updater 的 Get-BoosterUpdateConfigPath。
#   F-U    卸载脚本（make-installer.ps1 里的 here-string）第一个函数之前的整段路径前缀原样执行；
#          $hasBackup 那一条在沙箱里真跑（受保护备份 / 只有 legacy-roots.json 都必须提示先还原）。
#
# 第二层：结构。只管行为够不到的地方 —— 启动时不执行的函数、各组件里其余的推导点、C# 源码：
#   D / E  每一处 'DeltaForceBooster...' 拼接点的父表达式解析到 GetFolderPath 的 SpecialFolder，整表钉死。
#   F-B    解析器看过的变量不许有它看不见的写法（类型化、作用域别名、多重赋值、Set-Variable、foreach、[ref]、
#          -OutVariable）；拼接结果不许事后覆盖；根来源函数的每个 return 解析到同一个 Known Folder；
#          GUI 点源引擎后不许在别处改写引擎的根变量；GUI 点源的其它模块（updater / tuning）任何函数里都不许写
#          GUI / 引擎的根变量（F-B-3）。
#   F-C    从根变量派生出的子路径（backup / ipc / backup.key / legacy-roots.json / users / config ...）整表钉死，
#          派生变量只许由它的根变量推导赋值。
#   F-D    C#：根变量及其派生变量在所在代码块里只许赋值一次，派生子路径整表钉死；安装向导写的 legacy-roots 文件名
#          必须就是引擎 / 卸载脚本读的那个；测试钩子的 release 分支必须是 return null。
#   F-D2   release 构建（不带 -TestBuild）不定义 DFB_TESTING：真跑三份构建脚本里算 define 的那一句；四份构建脚本
#          （含没有测试构建的 make-engine-host）里 DFB_TESTING / csc 的 define 开关只许出现在那一句门控赋值里。

function Get-OrdinalSorted([string[]]$Items, [switch]$Unique) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Items)) { if (-not $Unique -or $seen.Add($item)) { $list.Add($item) } }
  $arr = $list.ToArray()
  [Array]::Sort($arr, [StringComparer]::Ordinal)
  $arr
}

function ConvertTo-PsLiteral([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }

function Get-ParsedAst([string]$Text, [string]$What) {
  $t = $null; $e = $null
  $parsed = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$t, [ref]$e)
  Assert-True (@($e).Count -eq 0) "$What does not parse; root-location checks cannot run"
  $parsed
}

# 'file' 或 'file::$var'（后者取该文件里唯一一处 $var = <here-string> 的原文）
function Get-RootScanText([string]$Key) {
  $parts = $Key -split '::', 2
  $raw = Get-Source $parts[0]
  if ($parts.Count -eq 1) { return $raw }
  $outer = Get-ParsedAst $raw $parts[0]
  $holder = @($outer.FindAll({
    param($x)
    $x -is [Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -ceq $parts[1]
  }, $true))
  Assert-True ($holder.Count -eq 1) "$Key : expected exactly one here-string holder, found $($holder.Count)"
  $lit = $holder[0].Right.Expression
  Assert-True ($lit -is [Management.Automation.Language.StringConstantExpressionAst] -or
               $lit -is [Management.Automation.Language.ExpandableStringExpressionAst]) "$Key : holder is not a string literal"
  $lit.Value
}

function Get-UnwrappedExpr($Node) {
  while ($true) {
    if ($Node -is [Management.Automation.Language.ParenExpressionAst]) { $Node = $Node.Pipeline; continue }
    if ($Node -is [Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) { $Node = $Node.PipelineElements[0]; continue }
    if ($Node -is [Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.Expression; continue }
    return $Node
  }
}

function Test-AstTypeIs($Node, [string[]]$Names) {
  $Node -is [Management.Automation.Language.TypeExpressionAst] -and ($Names -ccontains $Node.TypeName.FullName)
}

function Get-EnclosingFunction($Node) {
  for ($p = $Node.Parent; $p; $p = $p.Parent) {
    if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { return $p }
  }
  $null
}

function Get-AstRoot($Node) { $p = $Node; while ($p.Parent) { $p = $p.Parent }; $p }

# 把一个「父目录」表达式解析成 SpecialFolder 名。能走的路只有：
#   [Environment]::GetFolderPath(<SpecialFolder>)、[IO.Path]::GetFullPath(x)、x.TrimEnd(..)、
#   变量（本函数内赋值 > 本函数参数 > 脚本级赋值；$script: 变量取全文件所有赋值）、
#   同文件里无参调用的函数（取其最后一条语句）。多处赋值取并集。其它一律 unresolved。
function Resolve-RootBase($Node, [int]$Depth = 0) {
  if ($Depth -gt 8) { return 'unresolved:depth' }
  $n = Get-UnwrappedExpr $Node
  if ($n -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
    $member = "$($n.Member.Value)"
    $callArgs = @($n.Arguments)
    if ($n.Static -and (Test-AstTypeIs $n.Expression @('Environment','System.Environment')) -and
        $member -ceq 'GetFolderPath' -and $callArgs.Count -eq 1) {
      $a = Get-UnwrappedExpr $callArgs[0]
      if ($a -is [Management.Automation.Language.MemberExpressionAst] -and $a.Static -and
          (Test-AstTypeIs $a.Expression @('Environment+SpecialFolder','System.Environment+SpecialFolder'))) {
        return "$($a.Member.Value)"
      }
      if ($a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.StringConstantType -ne 'BareWord') {
        return "$($a.Value)"
      }
      return "unresolved:$($a.Extent.Text)"
    }
    if ($n.Static -and (Test-AstTypeIs $n.Expression @('IO.Path','System.IO.Path')) -and
        $member -ceq 'GetFullPath' -and $callArgs.Count -eq 1) {
      return (Resolve-RootBase $callArgs[0] ($Depth + 1))
    }
    if (-not $n.Static -and $member -ceq 'TrimEnd') { return (Resolve-RootBase $n.Expression ($Depth + 1)) }
    return "unresolved:$($n.Extent.Text)"
  }
  if ($n -is [Management.Automation.Language.VariableExpressionAst]) {
    # 定义查找走每个文件只建一次的写入索引（Get-FbReadBinding，见 1c）：口径不变 ——
    # $script: 变量取全文件所有普通赋值；否则本函数内赋值 > 本函数参数 > 脚本级赋值
    $name = $n.VariablePath.UserPath
    $defs = @((Get-FbReadBinding $n).Defs)
    if ($defs.Count -eq 0 -and $name -notlike 'script:*') {
      $func = Get-EnclosingFunction $n
      if ($func) {
        $paramAsts = @($func.Parameters) + @($(if ($func.Body.ParamBlock) { $func.Body.ParamBlock.Parameters }))
        foreach ($p in $paramAsts) {
          if ($p -and $p.Name.VariablePath.UserPath -ieq $name) { return "param:$name" }
        }
      }
    }
    if ($defs.Count -eq 0) { return "unresolved:`$$name" }
    $kinds = @(Get-OrdinalSorted -Unique @($defs | ForEach-Object { Resolve-RootBase $_.Right ($Depth + 1) }))
    return ($kinds -join '|')
  }
  if ($n -is [Management.Automation.Language.CommandAst] -and $n.CommandElements.Count -eq 1) {
    $cmd = $n.GetCommandName()
    $fn = @((Get-FbIndex (Get-AstRoot $n)).Functions | Where-Object { $_.Name -ieq $cmd })
    if ($fn.Count -ne 1 -or -not $fn[0].Body.EndBlock -or @($fn[0].Body.EndBlock.Statements).Count -eq 0) { return "unresolved:$cmd" }
    return (Resolve-RootBase @($fn[0].Body.EndBlock.Statements)[-1] ($Depth + 1))
  }
  "unresolved:$($n.Extent.Text)"
}

function Get-RootChildValue($Node) {
  $c = Get-UnwrappedExpr $Node
  if ($c -is [Management.Automation.Language.StringConstantExpressionAst] -and $c.StringConstantType -ne 'BareWord') { return $c.Value }
  if ($c -is [Management.Automation.Language.ExpandableStringExpressionAst]) { return $c.Value }
  $null
}

# 每一处「<父> + 'DeltaForceBooster[\...]'」拼接点 -> "<父的 SpecialFolder> + <子路径原文>"
#   Join-Path（位置或命名参数）与 [IO.Path]::Combine 的拼接点由 Get-FbJoinNodes（见 1c，编译好的类型谓词，
#   600KB 的 GUI 也只遍历一次）给出父 / 子两个实参
function Get-PsStateRootSites($Ast) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($j in @(Get-FbJoinNodes $Ast)) {
    $value = Get-RootChildValue $j.Child
    if ($value -imatch '^DeltaForceBooster(?:\\|$)') { $out.Add(('{0} + {1}' -f (Resolve-RootBase $j.Parent), $value)) }
  }
  Get-OrdinalSorted $out.ToArray()
}

# C#：先去掉 // 与 /* */ 注释（字符串、逐字字符串、字符字面量原样保留，免得把 "https://" 截断）
function Remove-CSharpComments([string]$Code) {
  $rx = '//[^\r\n]*|/\*[\s\S]*?\*/|@"(?:[^"]|"")*"|"(?:[^"\\\r\n]|\\.)*"|''(?:[^''\\\r\n]|\\.)+'''
  [regex]::Replace($Code, $rx, [Text.RegularExpressions.MatchEvaluator]{
    param($m)
    if ($m.Value.StartsWith('/')) { ' ' } else { $m.Value }
  })
}

# 从 '(' 之后开始，按顶层逗号切出调用实参，直到配对的 ')'
function Get-CSharpCallArgs([string]$Text, [int]$Start) {
  $parts = New-Object System.Collections.Generic.List[string]
  $depth = 0; $argStart = $Start; $i = $Start
  while ($i -lt $Text.Length) {
    $ch = $Text[$i]
    if ($ch -eq [char]'"') {
      $verbatim = ($i -gt 0 -and $Text[$i - 1] -eq [char]'@')
      $i++
      while ($i -lt $Text.Length) {
        if ($verbatim) {
          if ($Text[$i] -eq [char]'"') { if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq [char]'"') { $i += 2; continue }; break }
        } else {
          if ($Text[$i] -eq [char]'\') { $i += 2; continue }
          if ($Text[$i] -eq [char]'"') { break }
        }
        $i++
      }
    } elseif ($ch -eq [char]"'") {
      $i++
      while ($i -lt $Text.Length -and $Text[$i] -ne [char]"'") { if ($Text[$i] -eq [char]'\') { $i++ }; $i++ }
    } elseif ($ch -eq [char]'(' -or $ch -eq [char]'[' -or $ch -eq [char]'{') {
      $depth++
    } elseif ($ch -eq [char]')' -or $ch -eq [char]']' -or $ch -eq [char]'}') {
      if ($depth -eq 0) { $parts.Add($Text.Substring($argStart, $i - $argStart).Trim()); return $parts.ToArray() }
      $depth--
    } elseif ($ch -eq [char]',' -and $depth -eq 0) {
      $parts.Add($Text.Substring($argStart, $i - $argStart).Trim()); $argStart = $i + 1
    }
    $i++
  }
  $parts.ToArray()
}

function ConvertTo-CSharpBaseKind([string]$Expr) {
  $e = ($Expr -replace '\s+', ' ').Trim()
  if ($e -cmatch '^Environment\.GetFolderPath\( ?Environment\.SpecialFolder\.(\w+) ?\)$') { return $Matches[1] }
  if ($e -cmatch '^(Test\w+Path)\(\)$') { return "hook:$($Matches[1])" }
  "expr:$e"
}

function Get-CSharpStateRootSites([string]$Code) {
  $clean = Remove-CSharpComments $Code
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($m in @([regex]::Matches($clean, '\bPath\.Combine\('))) {
    $callArgs = @(Get-CSharpCallArgs $clean ($m.Index + $m.Length))
    if ($callArgs.Count -lt 2 -or $callArgs[1] -inotmatch '^@?"DeltaForceBooster(?:\\{1,2}[^"]*)?"$') { continue }
    $base = ($callArgs[0] -replace '\s+', ' ').Trim()
    if ($base -cmatch '^[A-Za-z_]\w*$') {
      $before = $clean.Substring(0, $m.Index)
      $decls = [regex]::Matches($before, ('\b(?:string|var)\s+{0}\s*=\s*([^;]+);' -f $base))
      if ($decls.Count -eq 0) { $kind = "unresolved:$base" }
      else {
        $decl = $decls[$decls.Count - 1]
        $kinds = New-Object System.Collections.Generic.List[string]
        $kinds.Add((ConvertTo-CSharpBaseKind $decl.Groups[1].Value))
        $tail = $before.Substring($decl.Index + $decl.Length)
        foreach ($re in [regex]::Matches($tail, ('(?<![\w.]){0}\s*=(?!=)\s*([^;]+);' -f $base))) {
          $kinds.Add((ConvertTo-CSharpBaseKind $re.Groups[1].Value))
        }
        $kind = $kinds.ToArray() -join '|'
      }
    } else { $kind = ConvertTo-CSharpBaseKind $base }
    $out.Add(('{0} + {1}' -f $kind, $callArgs[1]))
  }
  Get-OrdinalSorted $out.ToArray()
}

# 隔离 runspace 里求值一段脚本，脚本最后必须输出一张结果表
function Invoke-RootProbe([string]$Script, [string]$What) {
  $ps = [PowerShell]::Create()
  try {
    [void]$ps.AddScript("`$ErrorActionPreference = 'Stop'`r`n" + $Script)
    $out = $null
    try { $out = @($ps.Invoke()) }
    catch {
      $inner = $_.Exception
      while ($inner.InnerException) { $inner = $inner.InnerException }
      Assert-True $false "$What : running the real product statements threw: $($inner.Message)"
    }
    Assert-True ($ps.Streams.Error.Count -eq 0) "$What : evaluation wrote an error: $(@($ps.Streams.Error)[0])"
    Assert-True ($out.Count -eq 1 -and $out[0] -is [hashtable]) "$What : probe did not return exactly one result table"
    $out[0]
  } finally { $ps.Dispose() }
}

# 多重集差：只报差异，别让整张表淹没真正变了的那一行
function Get-SiteDiff([string[]]$Want, [string[]]$Got) {
  $left = New-Object System.Collections.Generic.List[string]
  foreach ($w in @($Want)) { $left.Add($w) }
  $extra = New-Object System.Collections.Generic.List[string]
  foreach ($g in @($Got)) { $at = $left.IndexOf($g); if ($at -ge 0) { $left.RemoveAt($at) } else { $extra.Add($g) } }
  'missing [' + ($left.ToArray() -join '; ') + '] unexpected [' + ($extra.ToArray() -join '; ') + ']'
}

function Assert-PathEquals([string]$Actual, [string]$Expected, [string]$What) {
  Assert-True ([string]::Equals($Actual, $Expected, [StringComparison]::Ordinal)) `
    "$What : expected [$Expected] but the real code produced [$Actual]"
}

# ----- C. 引擎：真跑赋值链 -----
$realCommon = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$realLocal  = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
Assert-True ($realCommon -and $realLocal -and [IO.Path]::IsPathRooted($realCommon) -and [IO.Path]::IsPathRooted($realLocal) -and
             -not [string]::Equals($realCommon, $realLocal, [StringComparison]::OrdinalIgnoreCase)) `
  'anchor: this machine must report distinct rooted CommonApplicationData and LocalApplicationData'
$realLocalFull = [IO.Path]::GetFullPath($realLocal)
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
# 哨兵只做字符串，不落盘；放在一个真实存在的盘符下，因为 PS 5.1 的 Join-Path 会校验盘符
$sentinelBase = [IO.Path]::Combine([IO.Path]::GetPathRoot($realCommon), '__dfb_identity_sentinel__')
$sentinel = @{
  Common  = [IO.Path]::Combine($sentinelBase, 'common-appdata')
  Current = [IO.Path]::Combine($sentinelBase, 'current-localappdata')
  Target  = [IO.Path]::Combine($sentinelBase, 'target-localappdata')
  PdRoot  = [IO.Path]::Combine($sentinelBase, 'programdata-root')
  Stale   = [IO.Path]::Combine($sentinelBase, 'stale-value')
}
$fakeSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
Assert-True (@(Get-OrdinalSorted -Unique @($sentinel.Values)).Count -eq 5) 'anchor: the five sentinel parents must be distinct'

$chainOrder = '$script:CommonAppData','$script:CurrentLocalAppData','$script:TargetLocalAppData',
  '$script:UserDataRoot','$script:ProgramDataRoot','$script:ConfigDir','$script:ProfileDir',
  '$script:BackupDir','$script:IpcDir','$script:BackupKeyFile','$script:LegacyRootsFile'
$chain = @{}
foreach ($st in @($engineAst.EndBlock.Statements)) {
  if ($st -is [Management.Automation.Language.AssignmentStatementAst] -and $chainOrder -ccontains "$($st.Left)") {
    Assert-True (-not $chain.ContainsKey("$($st.Left)")) "engine assigns $($st.Left) more than once at script level"
    $chain["$($st.Left)"] = $st
  }
}
Assert-True ($chain.Count -eq $chainOrder.Count) `
  "engine script-level root chain: expected $($chainOrder.Count) assignments, found $($chain.Count)"
function Get-ChainText([string[]]$Names) {
  (@($chain.Values | Where-Object { $Names -ccontains "$($_.Left)" } | Sort-Object { $_.Extent.StartOffset }) |
    ForEach-Object { $_.Extent.Text }) -join "`r`n"
}
$resultTable = "`r`n@{ " + ((@($chainOrder) | ForEach-Object { '{0} = {1}' -f $_.Substring(8), $_ }) -join '; ') + ' }'

# C1：真实值 + 毒化环境变量
$poisoned = @{}
foreach ($envName in 'ProgramData','ALLUSERSPROFILE','LOCALAPPDATA','APPDATA','USERPROFILE') {
  $poisoned[$envName] = [Environment]::GetEnvironmentVariable($envName, 'Process')
  [Environment]::SetEnvironmentVariable($envName, [IO.Path]::Combine($sentinelBase, "poisoned-env-$envName"), 'Process')
}
try {
  $real = Invoke-RootProbe ((Get-ChainText $chainOrder) + $resultTable) 'C1 engine root chain (real values, poisoned env)'
} finally {
  foreach ($envName in @($poisoned.Keys)) { [Environment]::SetEnvironmentVariable($envName, $poisoned[$envName], 'Process') }
}
$realPd = [IO.Path]::Combine($realCommon, 'DeltaForceBooster')
$realUd = [IO.Path]::Combine($realLocalFull, 'DeltaForceBooster')
Assert-PathEquals $real.CommonAppData $realCommon 'C1 $script:CommonAppData must be the CommonApplicationData known folder (not an env var)'
Assert-PathEquals $real.CurrentLocalAppData $realLocal 'C1 $script:CurrentLocalAppData must be the LocalApplicationData known folder'
Assert-PathEquals $real.TargetLocalAppData $realLocalFull 'C1 $script:TargetLocalAppData must default to the full LocalApplicationData path'
Assert-PathEquals $real.ProgramDataRoot $realPd 'C1 $script:ProgramDataRoot moved: backups, backup.key, IPC and per-SID state of installed users live exactly here'
Assert-PathEquals $real.UserDataRoot $realUd 'C1 $script:UserDataRoot moved away from <LocalAppData>\DeltaForceBooster'
foreach ($leaf in @(@('BackupDir', $realPd, 'backup'), @('IpcDir', $realPd, 'ipc'), @('BackupKeyFile', $realPd, 'backup.key'),
                    @('LegacyRootsFile', $realPd, 'legacy-roots.json'), @('ConfigDir', $realUd, 'config'), @('ProfileDir', $realUd, 'profiles'))) {
  Assert-PathEquals $real[$leaf[0]] ([IO.Path]::Combine($leaf[1], $leaf[2])) "C1 `$script:$($leaf[0]) is no longer <root>\$($leaf[2])"
}

# C2：三个父变量各自一个哨兵，只求值派生出的根
$c2Prologue = "`$script:CommonAppData = $(ConvertTo-PsLiteral $sentinel.Common)`r`n" +
              "`$script:CurrentLocalAppData = $(ConvertTo-PsLiteral $sentinel.Current)`r`n" +
              "`$script:TargetLocalAppData = $(ConvertTo-PsLiteral $sentinel.Target)`r`n"
$sent = Invoke-RootProbe ($c2Prologue + (Get-ChainText ($chainOrder | Select-Object -Skip 3)) + $resultTable) 'C2 engine root chain (sentinel parents)'
$sentPd = [IO.Path]::Combine($sentinel.Common, 'DeltaForceBooster')
$sentUd = [IO.Path]::Combine($sentinel.Target, 'DeltaForceBooster')
Assert-PathEquals $sent.ProgramDataRoot $sentPd 'C2 $script:ProgramDataRoot must be derived from $script:CommonAppData and nothing else'
Assert-PathEquals $sent.UserDataRoot $sentUd 'C2 script-level $script:UserDataRoot must be derived from $script:TargetLocalAppData and nothing else'
foreach ($leaf in @(@('BackupDir', $sentPd, 'backup'), @('IpcDir', $sentPd, 'ipc'), @('BackupKeyFile', $sentPd, 'backup.key'),
                    @('LegacyRootsFile', $sentPd, 'legacy-roots.json'), @('ConfigDir', $sentUd, 'config'), @('ProfileDir', $sentUd, 'profiles'))) {
  Assert-PathEquals $sent[$leaf[0]] ([IO.Path]::Combine($leaf[1], $leaf[2])) "C2 `$script:$($leaf[0]) must hang off its own root"
}

# C3 / C4：Set-TargetUserContext 里的第二处赋值
$stcFn = @($engineAst.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -ceq 'Set-TargetUserContext' }, $true))
$gpusrFn = @($engineAst.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -ceq 'Get-ProtectedUserStateRoot' }, $true))
Assert-True ($stcFn.Count -eq 1 -and $gpusrFn.Count -eq 1) 'engine must define Set-TargetUserContext and Get-ProtectedUserStateRoot exactly once'
$tailNames = '$script:UserDataRoot','$script:ConfigDir','$script:ProfileDir'
$tailStatements = foreach ($name in $tailNames) {
  $hits = @($stcFn[0].Body.FindAll({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -ceq $name }, $true))
  Assert-True ($hits.Count -eq 1) "Set-TargetUserContext must assign $name exactly once (found $($hits.Count))"
  Assert-True ([object]::ReferenceEquals($hits[0].Parent, $stcFn[0].Body.EndBlock)) `
    "Set-TargetUserContext: the $name assignment must stay an unconditional top-level statement of the function"
  $hits[0]
}
$tailText = (@($tailStatements | Sort-Object { $_.Extent.StartOffset }) | ForEach-Object { $_.Extent.Text }) -join "`r`n"
$stcProbeHead = "function Test-Admin { [bool]`$script:DfbProbeAdmin }`r`n" + $gpusrFn[0].Extent.Text + "`r`n" +
  "`$script:CommonAppData = $(ConvertTo-PsLiteral $sentinel.Common)`r`n" +
  "`$script:CurrentLocalAppData = $(ConvertTo-PsLiteral $sentinel.Current)`r`n" +
  "`$script:TargetLocalAppData = $(ConvertTo-PsLiteral $sentinel.Target)`r`n" +
  "`$script:ProgramDataRoot = $(ConvertTo-PsLiteral $sentinel.PdRoot)`r`n" +
  "`$script:TargetUserSid = $(ConvertTo-PsLiteral $fakeSid)`r`n" +
  "`$script:UserDataRoot = $(ConvertTo-PsLiteral $sentinel.Stale); `$script:ConfigDir = `$script:UserDataRoot; `$script:ProfileDir = `$script:UserDataRoot`r`n"
$stcResult = "`r`n@{ UserDataRoot = `$script:UserDataRoot; ConfigDir = `$script:ConfigDir; ProfileDir = `$script:ProfileDir; " +
  "TargetLocalAppData = `$script:TargetLocalAppData; TargetUserSid = `$script:TargetUserSid }"
foreach ($admin in $true, $false) {
  $adminLine = "`$script:DfbProbeAdmin = `$$admin`r`n"
  $c3 = Invoke-RootProbe ($stcProbeHead + $adminLine + $tailText + $stcResult) "C3 Set-TargetUserContext tail (admin=$admin)"
  $c3Ud = $(if ($admin) { [IO.Path]::Combine($sentinel.PdRoot, 'users', $fakeSid) } else { [IO.Path]::Combine($sentinel.Target, 'DeltaForceBooster') })
  Assert-PathEquals $c3.UserDataRoot $c3Ud $(if ($admin) {
      'C3 admin per-SID state must be <ProgramDataRoot>\users\<SID> (Get-ProtectedUserStateRoot)' } else {
      'C3 non-admin state must be <TargetLocalAppData>\DeltaForceBooster' })
  Assert-PathEquals $c3.ConfigDir ([IO.Path]::Combine($c3Ud, 'config')) "C3 ConfigDir (admin=$admin)"
  Assert-PathEquals $c3.ProfileDir ([IO.Path]::Combine($c3Ud, 'profiles')) "C3 ProfileDir (admin=$admin)"

  $c4 = Invoke-RootProbe ($stcProbeHead + $adminLine + $stcFn[0].Extent.Text + "`r`nSet-TargetUserContext '' ''" + $stcResult) `
    "C4 whole Set-TargetUserContext (admin=$admin)"
  Assert-PathEquals $c4.TargetLocalAppData $realLocalFull 'C4 implicit context must target the real LocalApplicationData'
  Assert-PathEquals $c4.TargetUserSid $currentSid 'C4 implicit context must target the current user SID'
  $c4Ud = $(if ($admin) { [IO.Path]::Combine($sentinel.PdRoot, 'users', $currentSid) } else { $realUd })
  Assert-PathEquals $c4.UserDataRoot $c4Ud "C4 Set-TargetUserContext no longer lands UserDataRoot on the protected/user root (admin=$admin)"
  Assert-PathEquals $c4.ConfigDir ([IO.Path]::Combine($c4Ud, 'config')) "C4 ConfigDir (admin=$admin)"
}


# ---------- 1c. 行为层与结构层共用的 AST 工具（攻击复核补丁；各层的职责见 1b 开头） ----------

function Get-BareVarName([string]$UserPath) {
  foreach ($q in 'script:', 'global:', 'local:', 'private:', 'variable:') {
    if ($UserPath.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)) { return $UserPath.Substring($q.Length) }
  }
  $UserPath
}

function Test-ScriptQualified([string]$UserPath) {
  $UserPath.StartsWith('script:', [StringComparison]::OrdinalIgnoreCase) -or
  $UserPath.StartsWith('global:', [StringComparison]::OrdinalIgnoreCase)
}

function Get-FbJoinParts($Node) {
  if ($Node -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
    $a = @($Node.Arguments)
    if ($a.Count -lt 2) { return $null }
    return @{ Parent = $a[0]; Child = $a[1] }
  }
  $positional = New-Object System.Collections.Generic.List[object]
  $named = @{}
  $els = @($Node.CommandElements)
  for ($i = 1; $i -lt $els.Count; $i++) {
    if ($els[$i] -is [Management.Automation.Language.CommandParameterAst]) {
      if ($els[$i].Argument) { $named[$els[$i].ParameterName] = $els[$i].Argument }
      elseif ($i + 1 -lt $els.Count) { $named[$els[$i].ParameterName] = $els[$i + 1]; $i++ }
    } else { $positional.Add($els[$i]) }
  }
  $parent = $(if ($named.ContainsKey('Path')) { $named['Path'] } elseif ($positional.Count -gt 0) { $positional[0] })
  $child = $(if ($named.ContainsKey('ChildPath')) { $named['ChildPath'] }
             elseif ($named.ContainsKey('Path')) { if ($positional.Count -gt 0) { $positional[0] } }
             elseif ($positional.Count -gt 1) { $positional[1] })
  if ($null -eq $parent -or $null -eq $child) { return $null }
  @{ Parent = $parent; Child = $child }
}

# FindAll 的 scriptblock 谓词在 600KB 的 GUI 上每个节点都要进一次 PowerShell；改用编译好的类型谓词
function New-FbTypePredicate([Type[]]$Types) {
  $pa = [Linq.Expressions.Expression]::Parameter([Management.Automation.Language.Ast], 'a')
  $body = $null
  foreach ($ty in $Types) {
    $e = [Linq.Expressions.Expression]::TypeIs($pa, $ty)
    $body = $(if ($body) { [Linq.Expressions.Expression]::OrElse($body, $e) } else { $e })
  }
  [Linq.Expressions.Expression]::Lambda([Func[Management.Automation.Language.Ast, bool]], $body,
    [Linq.Expressions.ParameterExpression[]]@($pa)).Compile()
}
$script:FbJoinPredicate = New-FbTypePredicate @([Management.Automation.Language.CommandAst], [Management.Automation.Language.InvokeMemberExpressionAst])
$script:FbIndexPredicate = New-FbTypePredicate @([Management.Automation.Language.AssignmentStatementAst], [Management.Automation.Language.CommandAst],
  [Management.Automation.Language.ForEachStatementAst], [Management.Automation.Language.FunctionDefinitionAst], [Management.Automation.Language.ConvertExpressionAst])

# 按 AST 对象本身缓存（同一个文件只遍历一次）；哈希只用来分桶，取出时再核对是不是同一个对象
function Get-FbCached([hashtable]$Cache, $Root) {
  $k = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Root)
  if ($Cache.ContainsKey($k) -and [object]::ReferenceEquals($Cache[$k].Root, $Root)) { return $Cache[$k].Value }
  $null
}
function Set-FbCached([hashtable]$Cache, $Root, $Value) {
  $Cache[[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Root)] = [pscustomobject]@{ Root = $Root; Value = $Value }
}

# 所有「路径拼接」节点：Join-Path 与 [IO.Path]::Combine
$script:FbJoinCache = @{}
function Get-FbJoinNodes($Ast) {
  $hit = Get-FbCached $script:FbJoinCache $Ast
  if ($null -ne $hit) { return $hit }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($x in $Ast.FindAll($script:FbJoinPredicate, $true)) {
    $isJoin = $(if ($x -is [Management.Automation.Language.CommandAst]) { $x.GetCommandName() -ieq 'Join-Path' }
                else { $x.Static -and "$($x.Member.Value)" -ieq 'Combine' -and (Test-AstTypeIs $x.Expression @('IO.Path','System.IO.Path')) })
    if (-not $isJoin) { continue }
    $parts = Get-FbJoinParts $x
    if ($parts) { $out.Add([pscustomobject]@{ Node = $x; Parent = $parts.Parent; Child = $parts.Child }) }
  }
  $arr = $out.ToArray()
  Set-FbCached $script:FbJoinCache $Ast $arr
  $arr
}

function Test-FbIsRootSite($J) { (Get-RootChildValue $J.Child) -imatch '^DeltaForceBooster(?:\\|$)' }

function Get-FbWriteTargets($Assign) {
  $list = New-Object System.Collections.Generic.List[object]
  $left = $Assign.Left
  $typed = $false
  while ($left -is [Management.Automation.Language.AttributedExpressionAst]) { $typed = $true; $left = $left.Child }
  if ($left -is [Management.Automation.Language.VariableExpressionAst]) {
    $list.Add([pscustomobject]@{ Var = $left; Plain = (-not $typed) -and $Assign.Operator -eq 'Equals' })
  } elseif ($left -is [Management.Automation.Language.ArrayLiteralAst]) {
    foreach ($el in @($left.Elements)) {
      $e = $el
      while ($e -is [Management.Automation.Language.AttributedExpressionAst]) { $e = $e.Child }
      if ($e -is [Management.Automation.Language.VariableExpressionAst]) { $list.Add([pscustomobject]@{ Var = $e; Plain = $false }) }
    }
  }
  $list.ToArray()
}

# 每个文件只遍历一次 AST：所有「写变量」的节点（赋值 / 变量类命令 / -OutVariable 等 / foreach / [ref]）与函数定义
$script:FbIndexCache = @{}
function Get-FbIndex($Root) {
  $hit = Get-FbCached $script:FbIndexCache $Root
  if ($null -ne $hit) { return $hit }
  $byName = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]' ([StringComparer]::OrdinalIgnoreCase)
  $fns = New-Object System.Collections.Generic.List[object]
  $varCmds = 'Set-Variable', 'New-Variable', 'sv', 'nv', 'Clear-Variable', 'clv', 'Remove-Variable', 'rv'
  $outParams = 'OutVariable', 'ov', 'ErrorVariable', 'ev', 'WarningVariable', 'wv', 'InformationVariable', 'iv', 'PipelineVariable', 'pv'
  $raw = New-Object System.Collections.Generic.List[object]   # 元组：kind, 节点, 变量节点, plain, UserPath
  foreach ($x in $Root.FindAll($script:FbIndexPredicate, $true)) {
    if ($x -is [Management.Automation.Language.FunctionDefinitionAst]) { $fns.Add($x); continue }
    if ($x -is [Management.Automation.Language.AssignmentStatementAst]) {
      $left = $x.Left
      if ($left -is [Management.Automation.Language.VariableExpressionAst]) {
        $raw.Add(@('assign', $x, $left, ($x.Operator -eq 'Equals'), $left.VariablePath.UserPath))
      } else {
        foreach ($tg in (Get-FbWriteTargets $x)) { $raw.Add(@('assign', $x, $tg.Var, $tg.Plain, $tg.Var.VariablePath.UserPath)) }
      }
      continue
    }
    if ($x -is [Management.Automation.Language.ForEachStatementAst]) { $raw.Add(@('foreach', $x, $x, $false, $x.Variable.VariablePath.UserPath)); continue }
    if ($x -is [Management.Automation.Language.ConvertExpressionAst]) {
      if ($x.Type.TypeName.Name -ieq 'ref' -and $x.Child -is [Management.Automation.Language.VariableExpressionAst]) {
        $raw.Add(@('ref', $x, $x, $false, $x.Child.VariablePath.UserPath))
      }
      continue
    }
    $cn = "$($x.GetCommandName())"
    $isVarCmd = $varCmds -icontains $cn
    if (-not $isVarCmd) {
      $hasParam = $false
      foreach ($el in $x.CommandElements) { if ($el -is [Management.Automation.Language.CommandParameterAst]) { $hasParam = $true; break } }
      if (-not $hasParam) { continue }
    }
    $els = @($x.CommandElements)
    for ($i = 1; $i -lt $els.Count; $i++) {
      $argNode = $null
      if ($els[$i] -is [Management.Automation.Language.CommandParameterAst]) {
        if ($outParams -icontains $els[$i].ParameterName) {
          $argNode = $(if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] })
        } elseif ($isVarCmd -and $els[$i].Argument) { $argNode = $els[$i].Argument }
      } elseif ($isVarCmd) { $argNode = $els[$i] }   # 严格：变量类命令里任何一个字符串实参都当成变量名
      if ($argNode -is [Management.Automation.Language.StringConstantExpressionAst]) {
        $raw.Add(@('command', $x, $x, $false, "$($argNode.Value)".TrimStart('+')))
      }
    }
  }
  foreach ($r in $raw) {
    $bare = Get-BareVarName $r[4]
    if (-not $byName.ContainsKey($bare)) { $byName[$bare] = New-Object System.Collections.Generic.List[object] }
    $byName[$bare].Add($r)
  }
  $ix = [pscustomobject]@{ ByName = $byName; Functions = $fns.ToArray(); Records = @{} }
  Set-FbCached $script:FbIndexCache $Root $ix
  $ix
}

# 某个名字的全部写入记录（第一次用到时才补齐作用域信息）
function Get-FbNameRecords($Ix, [string]$Name) {
  if ($Ix.Records.ContainsKey($Name)) { return ,$Ix.Records[$Name] }
  $list = New-Object System.Collections.Generic.List[object]
  if ($Ix.ByName.ContainsKey($Name)) {
    foreach ($r in $Ix.ByName[$Name].ToArray()) {
      $node = $r[1]
      $list.Add([pscustomobject]@{ Node = $node; Kind = $r[0]; Plain = [bool]$r[3]; UserPath = $r[4]; Bare = (Get-BareVarName $r[4])
                                   Fn = (Get-EnclosingFunction $r[2]); Qualified = ($r[0] -eq 'command' -or (Test-ScriptQualified $r[4]))
                                   Simple = ($r[0] -eq 'assign' -and $node.Left -is [Management.Automation.Language.VariableExpressionAst]) })
    }
  }
  $arr = $list.ToArray()
  $Ix.Records[$Name] = $arr
  ,$arr
}

# 某个变量在某个作用域里的**全部**写入（$Scope = $null 表示脚本级变量）
function Get-FbWrites($Root, $Scope, [string]$Name) {
  $res = New-Object System.Collections.Generic.List[object]
  foreach ($e in (Get-FbNameRecords (Get-FbIndex $Root) $Name)) {
    if ($e.Kind -eq 'command') { $in = $null -eq $Scope -or [object]::ReferenceEquals($e.Fn, $Scope) }
    elseif ($null -eq $Scope) { $in = $e.Qualified -or $null -eq $e.Fn }
    else { $in = (-not $e.Qualified) -and [object]::ReferenceEquals($e.Fn, $Scope) }
    if ($in) { $res.Add($e) }
  }
  $res.ToArray()
}

# 与 Resolve-RootBase 相同口径：一个变量读取点被解析器解析到哪些定义、按哪个作用域
function Get-FbReadBinding($VarAst) {
  $up = $VarAst.VariablePath.UserPath
  $simple = @((Get-FbNameRecords (Get-FbIndex (Get-AstRoot $VarAst)) (Get-BareVarName $up)) |
              Where-Object { $_.Kind -eq 'assign' -and $_.Simple -and $_.UserPath -ieq $up })
  if ($up -like 'script:*') {
    return [pscustomobject]@{ Scopes = @($null); Form = $up; Defs = @($simple | ForEach-Object { $_.Node }) }
  }
  $func = Get-EnclosingFunction $VarAst
  if ($func) {
    $defs = @($simple | Where-Object { [object]::ReferenceEquals($_.Fn, $func) } | ForEach-Object { $_.Node })
    if ($defs.Count -gt 0) { return [pscustomobject]@{ Scopes = @($func); Form = $up; Defs = $defs } }
    $paramAsts = @($func.Parameters) + @($(if ($func.Body.ParamBlock) { $func.Body.ParamBlock.Parameters }))
    foreach ($p in $paramAsts) {
      if ($p -and $p.Name.VariablePath.UserPath -ieq $up) { return [pscustomobject]@{ Scopes = @($func); Form = $up; Defs = @() } }
    }
  }
  $defs = @($simple | Where-Object { $null -eq $_.Fn } | ForEach-Object { $_.Node })
  $scopes = $(if ($func) { @($func, $null) } else { @($null) })
  [pscustomobject]@{ Scopes = $scopes; Form = $up; Defs = $defs }
}

# 沿解析器的同一条路走一遍，记下它看过的变量读取点与函数
function Add-FbConsulted($Node, $Acc, [int]$Depth = 0) {
  if ($Depth -gt 8) { return }
  $n = Get-UnwrappedExpr $Node
  if ($n -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
    $member = "$($n.Member.Value)"
    if ($n.Static -and (Test-AstTypeIs $n.Expression @('IO.Path','System.IO.Path')) -and $member -ceq 'GetFullPath' -and @($n.Arguments).Count -eq 1) {
      Add-FbConsulted @($n.Arguments)[0] $Acc ($Depth + 1)
    } elseif (-not $n.Static -and $member -ceq 'TrimEnd') { Add-FbConsulted $n.Expression $Acc ($Depth + 1) }
    return
  }
  if ($n -is [Management.Automation.Language.VariableExpressionAst]) {
    $Acc.Reads.Add($n)
    foreach ($d in @((Get-FbReadBinding $n).Defs)) { Add-FbConsulted $d.Right $Acc ($Depth + 1) }
    return
  }
  if ($n -is [Management.Automation.Language.CommandAst] -and $n.CommandElements.Count -eq 1) {
    $cmd = $n.GetCommandName()
    $fn = @((Get-FbIndex (Get-AstRoot $n)).Functions | Where-Object { $_.Name -ieq $cmd })
    if ($fn.Count -eq 1 -and $fn[0].Body.EndBlock -and @($fn[0].Body.EndBlock.Statements).Count -gt 0) {
      $Acc.Functions.Add($fn[0])
      Add-FbConsulted @($fn[0].Body.EndBlock.Statements)[-1] $Acc ($Depth + 1)
    }
  }
}

# 同一个文件只解析一次（GUI 有 600KB）
$script:FbAstCache = @{}
function Get-FbAst([string]$Key) {
  if ($Key -eq 'scripts\delta-booster.ps1') { return $engineAst }
  if (-not $script:FbAstCache.ContainsKey($Key)) { $script:FbAstCache[$Key] = Get-ParsedAst (Get-RootScanText $Key) $Key }
  $script:FbAstCache[$Key]
}

function Get-FbResultVar($Node) {
  for ($p = $Node.Parent; $p; $p = $p.Parent) {
    if ($p -is [Management.Automation.Language.FunctionDefinitionAst] -or $p -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $null }
    if ($p -is [Management.Automation.Language.AssignmentStatementAst]) {
      $t = @(Get-FbWriteTargets $p)
      if ($t.Count -eq 1) { return $t[0].Var }
      return $null
    }
  }
  $null
}

function Get-FbVarScope($VarAst) {
  $fn = Get-EnclosingFunction $VarAst
  $(if ((Test-ScriptQualified $VarAst.VariablePath.UserPath) -or -not $fn) { $null } else { $fn })
}

function Test-FbContains($Outer, $Inner) {
  $Inner.Extent.StartOffset -ge $Outer.Extent.StartOffset -and $Inner.Extent.EndOffset -le $Outer.Extent.EndOffset
}

# 一个读取点是否读的是 (Scope, Name) 这个变量
function Test-FbReadsVar($VarAst, $Scope, [string]$Name) {
  if ((Get-BareVarName $VarAst.VariablePath.UserPath) -ine $Name) { return $false }
  $scopes = @((Get-FbReadBinding $VarAst).Scopes)
  if ($null -eq $Scope) { return ($null -eq $scopes[0]) -or $scopes.Count -eq 2 }
  [object]::ReferenceEquals($scopes[0], $Scope)
}

# ----- 行为层公共件 -----
$script:FbCommandPredicate = New-FbTypePredicate @([Management.Automation.Language.CommandAst])
$script:ProbeSession = '0123456789abcdef0123456789abcdef'
$script:ProbeBackupName = 'backup-01234567-89ab-cdef-0123-456789abcdef.json'
$script:PoisonedEnv = @{}
foreach ($envName in 'ProgramData', 'ALLUSERSPROFILE', 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
  $script:PoisonedEnv[$envName] = [IO.Path]::Combine($sentinelBase, "poisoned-env-$envName")
}
# 探针与测试同进程：毒化的环境变量、TEMP / TMP / 会话标记、引擎顶层改写的 PSModulePath，一律在 finally 里还原
function Invoke-EnvProbe([string]$Script, [string]$What) {
  $names = @(@($script:PoisonedEnv.Keys) + @('TEMP', 'TMP', 'DFB_ENGINE_HOST_SESSION', 'PSModulePath'))
  $saved = @{}
  foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
  try {
    foreach ($n in @($script:PoisonedEnv.Keys)) { [Environment]::SetEnvironmentVariable($n, $script:PoisonedEnv[$n], 'Process') }
    Invoke-RootProbe $Script $What
  } finally {
    foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
  }
}

# 某个文件里一个脚本级函数的原文（必须恰好一处）
function Get-TopFunctionText($Ast, [string]$Name, [string]$What) {
  $hits = @($Ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $Name })
  Assert-True ($hits.Count -eq 1) "$What must define $Name exactly once at script level (found $($hits.Count))"
  $hits[0].Extent.Text
}

# 目录存在 / reparse / ACL 与路径推导无关：闸门探针里用一张假的「已存在目录」表代替真实磁盘
$script:GateStubs = @'
function Test-Path {
  param([string]$LiteralPath, [string]$PathType, [string]$Path)
  $p = $(if ($LiteralPath) { $LiteralPath } else { $Path })
  @($global:DfbProbeExisting) -contains [IO.Path]::GetFullPath($p).TrimEnd('\')
}
function Test-PathHasReparsePoint { param([string]$Path) $false }
function Test-BootstrapPathHasReparsePoint { param([string]$Path) $false }
function Test-ProtectedDirectoryAclExact { param([string]$Path, [bool]$UsersRead) $true }
'@
$probeProtectedSession = [IO.Path]::Combine($realCommon, 'DeltaForceBooster', 'session-temp', $script:ProbeSession)
$probeUserTemp = [IO.Path]::Combine($realLocalFull, 'Temp')
Assert-True (-not [string]::Equals($probeProtectedSession, $probeUserTemp, [StringComparison]::OrdinalIgnoreCase)) 'anchor: gate probe directories must differ'
function Assert-GateVerdicts([hashtable]$Result, [string]$Key, [string]$What) {
  Assert-True ([string]::Equals("$($Result["$Key/protected"])", "accepted:$probeProtectedSession", [StringComparison]::Ordinal)) `
    ("$What must accept exactly the protected session directory <CommonApplicationData>\DeltaForceBooster\session-temp\<session> " +
     "[$probeProtectedSession], got [$($Result["$Key/protected"])]")
  Assert-True ("$($Result["$Key/usertemp"])".StartsWith('rejected:', [StringComparison]::Ordinal)) `
    ("$What accepted the per-user %TEMP% [$probeUserTemp] as the admin session directory: [$($Result["$Key/usertemp"])]")
}
$probeBackupRefs = [ordered]@{
  protected = [IO.Path]::Combine($realCommon, 'DeltaForceBooster', 'backup', $script:ProbeBackupName)
  localappdata = [IO.Path]::Combine($realLocalFull, 'DeltaForceBooster', 'backup', $script:ProbeBackupName)
  sibling = [IO.Path]::Combine($realCommon, 'DeltaForceBooster', 'backup-old', $script:ProbeBackupName)
}
function Assert-BackupRefVerdicts([hashtable]$Result, [string]$What) {
  Assert-True ($Result['backupref/protected'] -eq $true) "$What must accept a backup under <CommonApplicationData>\DeltaForceBooster\backup [$($probeBackupRefs.protected)]"
  Assert-True ($Result['backupref/localappdata'] -eq $false) "$What accepted a backup under the user-writable LocalAppData [$($probeBackupRefs.localappdata)]"
  Assert-True ($Result['backupref/sibling'] -eq $false) "$What accepted a sibling directory that only shares the backup root prefix [$($probeBackupRefs.sibling)]"
}
function Get-BackupRefProbeText([string]$Function) {
  $lines = foreach ($k in @($probeBackupRefs.Keys)) {
    "`$probeResult['backupref/$k'] = [bool]($Function $(ConvertTo-PsLiteral $probeBackupRefs[$k]))"
  }
  $lines -join "`r`n"
}

# ----- F-A. 引擎整文件点源（与 GUI 完全相同的加载方式），生产状态下读根 -----
$faEnginePath = Join-Path $root 'scripts\delta-booster.ps1'
$faProtected = 'CommonAppData', 'ProgramDataRoot', 'BackupDir', 'IpcDir', 'BackupKeyFile', 'LegacyRootsFile'
$faNames = @(@($chainOrder) | ForEach-Object { $_.Substring(8) }) + @('UseExplicitUserHive', 'TargetUserSid')
$faScript = @'
. __ENGINE__
$faNames = @(__NAMES__)
# 快照同时记下 HKCU 实际落到哪个配置单元（Split-RegPath 是引擎所有 HKCU 读写的唯一入口）
$faSnap = { $h = @{}; foreach ($n in $faNames) { $h[$n] = Get-Variable -Name $n -ValueOnly -ErrorAction SilentlyContinue }
  $hk = @(Split-RegPath 'HKCU:\Software\DfbIdentityProbe'); $h['Hkcu'] = "$($hk[0].Name)|$($hk[1])"; $h }
$probeResult = @{ load = (. $faSnap) }
function Test-Admin { [bool]$global:DfbFaAdmin }
function New-ProtectedDirectory { param([string]$Path, [bool]$UsersRead) [void]$global:DfbFaDirs.Add("$Path|$UsersRead") }
# 每次调用前先把上下文写成另一个用户的陈旧值（OTS 提权：引擎进程是审批管理员，加载时的 SID 不是原用户）：
# 「没有更新」与「更新成同一个值」这样才分得开
$faStale = {
  $script:TargetUserSid = __FAKESID__; $script:TargetLocalAppData = __STALE__
  $script:UserDataRoot = __STALE__; $script:ConfigDir = __STALE__; $script:ProfileDir = __STALE__
}
foreach ($faAdmin in $true, $false) {
  $global:DfbFaAdmin = $faAdmin
  . $faStale; $script:UseExplicitUserHive = $true
  Set-TargetUserContext '' ''
  $probeResult["admin=$faAdmin/implicit"] = (. $faSnap)
  . $faStale; $script:UseExplicitUserHive = $false
  Set-TargetUserContext __SID__ __LOCAL__
  $probeResult["admin=$faAdmin/explicit"] = (. $faSnap)
}
# 入口分发处理 GUI 请求的前两步：显式上下文 -> Initialize-UserDataStore（管理员；目录只记录，不落盘）
$global:DfbFaAdmin = $true
$global:DfbFaDirs = New-Object System.Collections.Generic.List[string]
Set-TargetUserContext __SID__ __LOCAL__
try { Initialize-UserDataStore; $faInitError = '' } catch { $faInitError = $_.Exception.Message }
$probeResult['init'] = (. $faSnap)
$probeResult['init']['Dirs'] = $global:DfbFaDirs.ToArray()
$probeResult['init']['Error'] = $faInitError
# 备份库与 IPC 目录的初始化（第一次写备份 / 回传结果时才跑）：只桩掉「文件是否存在 / 读 ACL / 列目录」，目录只记录
$global:DfbFaDirs = New-Object System.Collections.Generic.List[string]
& {
  function Test-Path { param([string]$LiteralPath, [string]$PathType, [string]$Path) $true }
  function Get-Item { param([string]$LiteralPath, [switch]$Force) [pscustomobject]@{ PSIsContainer = $false } }
  function Get-ChildItem { }
  function Test-PathHasReparsePoint { param([string]$Path) $false }
  function Test-ProtectedFileAcl { param([string]$Path) $true }
  Initialize-ProtectedStore
  Initialize-IpcStore
}
$probeResult['stores'] = (. $faSnap)
$probeResult['stores']['Dirs'] = $global:DfbFaDirs.ToArray()
# 显式上下文的负例一：调用方交来的 LocalAppData 必须就是该 SID 系统配置文件里的 Local AppData
# （诱饵目录真实存在、在固定盘、路径无 reparse point —— 能拒绝它的只剩 SID 绑定这一道）
Set-TargetUserContext __SID__ __LOCAL__
try { Set-TargetUserContext __SID__ __DECOY__; $faVerdict = 'accepted' } catch { $faVerdict = 'rejected:' + $_.Exception.Message }
$probeResult['decoy'] = (. $faSnap)
$probeResult['decoy']['Verdict'] = $faVerdict
# 负例二：该 SID 的 Local AppData 验证不了（展开器拒绝）时必须拒绝，不许退回「信任调用方」
$global:DfbFaRealExpand = ${function:Expand-TrustedProfilePath}
$global:DfbFaExpandLocal = 0
function Expand-TrustedProfilePath([string]$RawPath, [string]$ProfilePath) {
  if ($ProfilePath) { $global:DfbFaExpandLocal++; throw 'F-A probe: the Local AppData of this profile cannot be verified' }
  & $global:DfbFaRealExpand $RawPath $ProfilePath
}
try { Set-TargetUserContext __SID__ __LOCAL__; $faVerdict = 'accepted' } catch { $faVerdict = 'rejected:' + $_.Exception.Message }
${function:Expand-TrustedProfilePath} = $global:DfbFaRealExpand
$probeResult['unverifiable'] = @{ Verdict = $faVerdict; Calls = $global:DfbFaExpandLocal }
# 管理员引擎自己的会话目录闸门
__GATESTUBS__
foreach ($probeCase in @(@{ Name = 'protected'; Dir = __PSESSION__ }, @{ Name = 'usertemp'; Dir = __UTEMP__ })) {
  $global:DfbProbeExisting = @($probeCase.Dir)
  $env:TEMP = $probeCase.Dir; $env:TMP = $probeCase.Dir; $env:DFB_ENGINE_HOST_SESSION = __SESSION__
  try { $probeResult["gate/$($probeCase.Name)"] = 'accepted:' + (Get-ValidatedEngineSessionRoot) }
  catch { $probeResult["gate/$($probeCase.Name)"] = 'rejected:' + $_.Exception.Message }
}
$probeResult
'@
$faScript = $faScript.Replace('__GATESTUBS__', $script:GateStubs)
$faScript = $faScript.Replace('__ENGINE__', (ConvertTo-PsLiteral $faEnginePath))
$faScript = $faScript.Replace('__NAMES__', ((@($faNames) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ','))
$faScript = $faScript.Replace('__SID__', (ConvertTo-PsLiteral $currentSid))
$faScript = $faScript.Replace('__LOCAL__', (ConvertTo-PsLiteral $realLocalFull))
$faScript = $faScript.Replace('__PSESSION__', (ConvertTo-PsLiteral $probeProtectedSession))
$faScript = $faScript.Replace('__UTEMP__', (ConvertTo-PsLiteral $probeUserTemp))
$faScript = $faScript.Replace('__SESSION__', (ConvertTo-PsLiteral $script:ProbeSession))
$faScript = $faScript.Replace('__FAKESID__', (ConvertTo-PsLiteral $fakeSid))
$faScript = $faScript.Replace('__STALE__', (ConvertTo-PsLiteral $sentinel.Stale))
Assert-True (Test-Path -LiteralPath "Registry::HKEY_USERS\$currentSid") `
  'anchor: F-A needs the current user hive under HKEY_USERS to run the explicit Set-TargetUserContext path (run the suite as the interactive user)'
# 诱饵：一个真实存在、固定盘、无 reparse point、但不是该 SID Local AppData 的目录
$faDecoy = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'dfb-identity-decoy-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($faDecoy)
try {
  $faDecoyReparse = $false
  $faWalk = [IO.Path]::GetPathRoot($faDecoy)
  foreach ($part in @($faDecoy.Substring($faWalk.Length) -split '\\' | Where-Object { $_ })) {
    $faWalk = [IO.Path]::Combine($faWalk, $part)
    if (([IO.File]::GetAttributes($faWalk) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $faDecoyReparse = $true }
  }
  Assert-True ((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($faDecoy))).DriveType -eq [IO.DriveType]::Fixed -and -not $faDecoyReparse -and
               -not [string]::Equals($faDecoy.TrimEnd('\'), $realLocalFull.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) `
    "anchor: F-A decoy LocalAppData [$faDecoy] must be an existing fixed-disk directory without reparse points, so that only the SID binding can refuse it"
  $faScript = $faScript.Replace('__DECOY__', (ConvertTo-PsLiteral $faDecoy))
  $fa = Invoke-EnvProbe $faScript 'F-A whole engine dot-sourced like the GUI (poisoned env)'
} finally {
  if ([IO.Directory]::Exists($faDecoy)) { [IO.Directory]::Delete($faDecoy, $true) }
}
Assert-True ($fa.Count -eq 11) ("anchor: F-A must return the load snapshot, 4 Set-TargetUserContext snapshots, the Initialize-UserDataStore / store " +
  "snapshots, the 2 refused-context verdicts and 2 session-gate verdicts (got $($fa.Count))")
$faExpect = @{
  CommonAppData = $realCommon; CurrentLocalAppData = $realLocal; TargetLocalAppData = $realLocalFull
  ProgramDataRoot = $realPd; UserDataRoot = $realUd
  ConfigDir = [IO.Path]::Combine($realUd, 'config'); ProfileDir = [IO.Path]::Combine($realUd, 'profiles')
  BackupDir = [IO.Path]::Combine($realPd, 'backup'); IpcDir = [IO.Path]::Combine($realPd, 'ipc')
  BackupKeyFile = [IO.Path]::Combine($realPd, 'backup.key'); LegacyRootsFile = [IO.Path]::Combine($realPd, 'legacy-roots.json')
}
Assert-True ($faExpect.Count -eq $chainOrder.Count) 'anchor: F-A expectation table must cover every chain variable'
foreach ($k in @($faExpect.Keys | Sort-Object)) {
  Assert-PathEquals $fa['load'][$k] $faExpect[$k] "F-A load-time `$script:$k (whole engine top level, production order, poisoned env)"
}
foreach ($admin in $true, $false) {
  foreach ($ctx in 'implicit', 'explicit') {
    $s = $fa["admin=$admin/$ctx"]
    foreach ($k in $faProtected) {
      Assert-PathEquals $s[$k] $faExpect[$k] "F-A after Set-TargetUserContext (admin=$admin, $ctx): `$script:$k must not move"
    }
    # 进入调用前上下文是另一个用户的陈旧值（$fakeSid / 哨兵路径），所以这里比的是「被更新成了传入的用户」
    Assert-True ([string]::Equals("$($s['TargetUserSid'])", $currentSid, [StringComparison]::OrdinalIgnoreCase)) `
      "F-A after Set-TargetUserContext (admin=$admin, $ctx): TargetUserSid must be the SID passed in [$currentSid], got [$($s['TargetUserSid'])]"
    Assert-PathEquals $s['TargetLocalAppData'] $realLocalFull "F-A after Set-TargetUserContext (admin=$admin, $ctx): TargetLocalAppData"
    Assert-True ([bool]$s['UseExplicitUserHive'] -eq ($ctx -eq 'explicit')) "F-A after Set-TargetUserContext (admin=$admin, $ctx): UseExplicitUserHive"
    $hkWant = $(if ($ctx -eq 'explicit') { "HKEY_USERS|$currentSid\Software\DfbIdentityProbe" } else { 'HKEY_CURRENT_USER|Software\DfbIdentityProbe' })
    Assert-True ([string]::Equals("$($s['Hkcu'])", $hkWant, [StringComparison]::OrdinalIgnoreCase)) `
      "F-A after Set-TargetUserContext (admin=$admin, $ctx): HKCU must map to [$hkWant] (the user's own hive), got [$($s['Hkcu'])]"
    $ud = $(if ($admin) { [IO.Path]::Combine($realPd, 'users', $currentSid) } else { $realUd })
    Assert-PathEquals $s['UserDataRoot'] $ud "F-A after Set-TargetUserContext (admin=$admin, $ctx): UserDataRoot"
    Assert-PathEquals $s['ConfigDir'] ([IO.Path]::Combine($ud, 'config')) "F-A after Set-TargetUserContext (admin=$admin, $ctx): ConfigDir"
    Assert-PathEquals $s['ProfileDir'] ([IO.Path]::Combine($ud, 'profiles')) "F-A after Set-TargetUserContext (admin=$admin, $ctx): ProfileDir"
  }
}
Assert-True ([string]::Equals("$($fa['load']['Hkcu'])", 'HKEY_CURRENT_USER|Software\DfbIdentityProbe', [StringComparison]::OrdinalIgnoreCase)) `
  "F-A load-time: HKCU must map to the process user's own hive before any explicit context, got [$($fa['load']['Hkcu'])]"
$faSidRoot = [IO.Path]::Combine($realPd, 'users', $currentSid)
$faInit = $fa['init']
Assert-True ([string]::IsNullOrEmpty("$($faInit['Error'])")) `
  "F-A Initialize-UserDataStore (admin, explicit) refused the state the real Set-TargetUserContext produced: $($faInit['Error'])"
foreach ($k in $faProtected) {
  Assert-PathEquals $faInit[$k] $faExpect[$k] "F-A after Initialize-UserDataStore (admin, explicit): `$script:$k must not move"
}
Assert-PathEquals $faInit['UserDataRoot'] $faSidRoot 'F-A after Initialize-UserDataStore (admin, explicit): UserDataRoot'
Assert-PathEquals $faInit['ConfigDir'] ([IO.Path]::Combine($faSidRoot, 'config')) 'F-A after Initialize-UserDataStore (admin, explicit): ConfigDir'
Assert-PathEquals $faInit['ProfileDir'] ([IO.Path]::Combine($faSidRoot, 'profiles')) 'F-A after Initialize-UserDataStore (admin, explicit): ProfileDir'
$faInitDirs = @(@($realPd, [IO.Path]::Combine($realPd, 'users'), $faSidRoot, [IO.Path]::Combine($faSidRoot, 'config'), [IO.Path]::Combine($faSidRoot, 'profiles')) |
  ForEach-Object { "$_|False" })
Assert-True ([string]::Equals((@($faInit['Dirs']) -join '; '), ($faInitDirs -join '; '), [StringComparison]::Ordinal)) `
  ('F-A Initialize-UserDataStore (admin) created protected directories [path|UsersRead: ' + (@($faInit['Dirs']) -join '; ') + '] instead of [' + ($faInitDirs -join '; ') + ']')
# 备份库 / IPC：目录位置与 BUILTIN\Users 只读位都钉住（只有 IPC 目录可被普通用户读）
$faStores = $fa['stores']
foreach ($k in $faProtected) {
  Assert-PathEquals $faStores[$k] $faExpect[$k] "F-A after Initialize-ProtectedStore / Initialize-IpcStore: `$script:$k must not move"
}
$faStoreDirs = @("$realPd|False", "$([IO.Path]::Combine($realPd, 'backup'))|False", "$realPd|False", "$([IO.Path]::Combine($realPd, 'ipc'))|True")
Assert-True ([string]::Equals((@($faStores['Dirs']) -join '; '), ($faStoreDirs -join '; '), [StringComparison]::Ordinal)) `
  ('F-A Initialize-ProtectedStore / Initialize-IpcStore created protected directories [path|UsersRead: ' + (@($faStores['Dirs']) -join '; ') +
   '] instead of [' + ($faStoreDirs -join '; ') + '] (only the IPC directory may be readable by BUILTIN\Users)')
# 显式上下文的两个负例
Assert-True ("$($fa['decoy']['Verdict'])".StartsWith('rejected:', [StringComparison]::Ordinal)) `
  ("F-A explicit Set-TargetUserContext accepted a LocalAppData [$faDecoy] that is not the Local AppData of SID [$currentSid]: " +
   'the only check binding the caller-supplied path to that user is gone')
Assert-PathEquals $fa['decoy']['TargetLocalAppData'] $realLocalFull 'F-A a refused explicit Set-TargetUserContext must keep the previous, verified TargetLocalAppData'
Assert-PathEquals $fa['decoy']['UserDataRoot'] $faSidRoot 'F-A a refused explicit Set-TargetUserContext must keep the previous, verified UserDataRoot'
Assert-True ([int]$fa['unverifiable']['Calls'] -ge 1) `
  ("anchor: F-A the explicit Set-TargetUserContext path never expanded this profile's 'Local AppData' shell folder, " +
   'so the fail-closed case did not run (HKEY_USERS\<SID>\...\User Shell Folders has no Local AppData value on this machine)')
Assert-True ("$($fa['unverifiable']['Verdict'])".StartsWith('rejected:', [StringComparison]::Ordinal)) `
  'F-A explicit Set-TargetUserContext must fail closed when the Local AppData of the SID cannot be verified, but it accepted the caller-supplied path'
Assert-GateVerdicts $fa 'gate' 'F-T engine Get-ValidatedEngineSessionRoot'

# ----- F-G. GUI 启动段原样执行：点源引擎 -> Set-TargetUserContext -> Initialize-ProtectedUserStateStore -----
# GUI 与引擎共用一个脚本作用域，GUI 的 per-SID 根会覆盖引擎的结果；这里跑的是 GUI 文件里那几条语句本身，
# 只桩掉 Test-Admin（GUI 永远是 high）、New-ProtectedDirectory（记录不落盘）与 Stop-UntrustedGuiStartup（改成抛出）。
$fgAst = Get-FbAst 'gui\DeltaForceBooster-GUI.ps1'
$fgTop = @($fgAst.EndBlock.Statements)
$fgDot = New-Object System.Collections.Generic.List[object]
$fgInit = New-Object System.Collections.Generic.List[object]
foreach ($c in $fgAst.FindAll($script:FbCommandPredicate, $true)) {
  if ($c.InvocationOperator -eq 'Dot' -and $c.CommandElements.Count -ge 1 -and $c.CommandElements[0].Extent.Text -like '*delta-booster.ps1*') { $fgDot.Add($c) }
  elseif ($c.GetCommandName() -ceq 'Initialize-ProtectedUserStateStore') { $fgInit.Add($c) }
}
function Get-TopStatementIndex($Node, [object[]]$Top) {
  $p = $Node
  while ($p.Parent -and -not ($p.Parent -is [Management.Automation.Language.NamedBlockAst] -and $null -eq $p.Parent.Parent.Parent)) { $p = $p.Parent }
  [Array]::IndexOf($Top, $p)
}
Assert-True ($fgDot.Count -eq 1) "GUI must dot-source the engine exactly once (found $($fgDot.Count))"
Assert-True ($fgInit.Count -eq 1) "GUI must call Initialize-ProtectedUserStateStore exactly once (found $($fgInit.Count))"
$fgGuard = @(for ($p = $fgInit[0].Parent; $p; $p = $p.Parent) {
  if ($p -is [Management.Automation.Language.IfStatementAst] -or $p -is [Management.Automation.Language.LoopStatementAst] -or
      $p -is [Management.Automation.Language.SwitchStatementAst] -or $p -is [Management.Automation.Language.FunctionDefinitionAst]) { $p } })
$fgFrom = Get-TopStatementIndex $fgDot[0] $fgTop
$fgTo = Get-TopStatementIndex $fgInit[0] $fgTop
Assert-True ($fgGuard.Count -eq 0 -and $fgFrom -ge 0 -and $fgTo -gt $fgFrom) `
  'GUI must dot-source the engine and then call Initialize-ProtectedUserStateStore unconditionally, both as script-level statements in that order'
$fgNames = @($faNames) + @('ProtectedUserStateRoot', 'UserConfigDir', 'BoosterUserConfigDir')
# GUI 在脚本级点源的模块（与 GUI 共用同一个脚本作用域）。AddScript({...}) 里的 `. $ModulePath` 跑在另一个 runspace，不算。
function Resolve-GuiModulePath($Cmd) {
  $n = Get-UnwrappedExpr $Cmd.CommandElements[0]
  for ($d = 0; $d -lt 4; $d++) {
    if ($n -is [Management.Automation.Language.VariableExpressionAst]) {
      $defs = @(Get-FbWrites $fgAst $null (Get-BareVarName $n.VariablePath.UserPath))
      if ($defs.Count -ne 1 -or $defs[0].Kind -ne 'assign' -or -not $defs[0].Simple -or $null -ne $defs[0].Fn) { return "unresolved:$($n.Extent.Text)" }
      $n = Get-UnwrappedExpr $defs[0].Node.Right; continue
    }
    if ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ieq 'Join-Path') {
      $parts = Get-FbJoinParts $n
      if ($parts -and "$($parts.Parent.Extent.Text)" -ieq '$script:RootDir' -and $null -ne (Get-RootChildValue $parts.Child)) { return (Get-RootChildValue $parts.Child) }
    }
    return "unresolved:$($n.Extent.Text)"
  }
  'unresolved:depth'
}
$fgMods = New-Object System.Collections.Generic.List[object]
foreach ($c in $fgAst.FindAll($script:FbCommandPredicate, $true)) {
  if ($c.InvocationOperator -ne 'Dot') { continue }
  $deferred = $false
  for ($p = $c.Parent; $p; $p = $p.Parent) {
    if ($p -is [Management.Automation.Language.ScriptBlockExpressionAst] -or $p -is [Management.Automation.Language.FunctionDefinitionAst]) { $deferred = $true; break }
  }
  if (-not $deferred) { $fgMods.Add([pscustomobject]@{ Path = (Resolve-GuiModulePath $c); Index = (Get-TopStatementIndex $c $fgTop) }) }
}
$fgModPaths = @($fgMods.ToArray() | Sort-Object Index | ForEach-Object { $_.Path })
$fgModWant = @('scripts\delta-booster.ps1', 'scripts\updater.ps1', 'scripts\tuning-experiment.ps1')
Assert-True ([string]::Equals(($fgModPaths -join '; '), ($fgModWant -join '; '), [StringComparison]::Ordinal)) `
  ("anchor: the GUI must dot-source exactly [$($fgModWant -join '; ')] into its own script scope, in that order, found [$($fgModPaths -join '; ')] " +
   '(a new module shares the GUI state roots: add it to the F-G load range and to the F-B module write scan)')
$fgLast = [int](@($fgMods.ToArray() | Sort-Object Index)[-1].Index)
Assert-True ($fgLast -gt $fgTo -and @($fgMods.ToArray() | Where-Object { $_.Index -le $fgTo }).Count -eq 1) `
  'anchor: the GUI must load its other modules (updater, tuning) after Initialize-ProtectedUserStateStore'
$fgScript = New-Object System.Text.StringBuilder
[void]$fgScript.AppendLine("`$script:RootDir = $(ConvertTo-PsLiteral $root)")
[void]$fgScript.AppendLine("`$script:OriginalUserSid = $(ConvertTo-PsLiteral $currentSid)")
[void]$fgScript.AppendLine("`$script:OriginalUserLocalAppData = $(ConvertTo-PsLiteral $realLocalFull.TrimEnd('\'))")
[void]$fgScript.AppendLine('function Stop-UntrustedGuiStartup { param([string]$Reason) throw "GUI start-up stopped: $Reason" }')
[void]$fgScript.AppendLine($fgTop[$fgFrom].Extent.Text)
[void]$fgScript.AppendLine(@'
function Test-Admin { $true }
function New-ProtectedDirectory { param([string]$Path, [bool]$UsersRead) [void]$global:DfbFgDirs.Add("$Path|$UsersRead") }
function Write-BootLog { param([string]$Line) }
$global:DfbFgDirs = New-Object System.Collections.Generic.List[string]
'@)
for ($i = $fgFrom + 1; $i -le $fgTo; $i++) { [void]$fgScript.AppendLine($fgTop[$i].Extent.Text) }
$fgSnapText = '$fgSnap = @{}; foreach ($n in @(' + ((@($fgNames) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ',') + ')) { $fgSnap[$n] = Get-Variable -Name $n -ValueOnly -ErrorAction SilentlyContinue }'
[void]$fgScript.AppendLine($fgSnapText)
[void]$fgScript.AppendLine('$probeResult = @{ init = $fgSnap }')
[void]$fgScript.AppendLine('$probeResult[''init''][''Dirs''] = $global:DfbFgDirs.ToArray()')
# 初始化之后到最后一个模块加载为止的 GUI 顶层语句原样执行（旧状态迁移那一步要走原用户 broker：桩成抛出，GUI 自己的 catch 接住）
[void]$fgScript.AppendLine('function Invoke-EngineHostUserAction { throw ''F-G probe: no EngineHost broker in the test'' }')
for ($i = $fgTo + 1; $i -le $fgLast; $i++) { [void]$fgScript.AppendLine($fgTop[$i].Extent.Text) }
[void]$fgScript.AppendLine($fgSnapText)
[void]$fgScript.AppendLine(@'
$probeResult['modules'] = $fgSnap
$probeResult['modules']['UpdaterLoaded'] = [bool](Get-Command Get-BoosterUpdateConfigPath -CommandType Function -ErrorAction SilentlyContinue)
$probeResult['modules']['TuningLoaded'] = [bool]$script:TuningModuleLoaded -and [bool](Get-Command Test-PathUnderProtectedTuningBackup -CommandType Function -ErrorAction SilentlyContinue)
# 高权限 GUI 里「不再提醒此版本」读写的就是这个路径：只桩掉「是否提权 / 目录是否存在 / 建目录」
function Test-BoosterUpdaterElevated { $true }
function Test-Path { param([string]$LiteralPath, [string]$PathType, [string]$Path) $true }
function New-Item { param([string]$ItemType, [string]$Path, [switch]$Force) }
try { $probeResult['modules']['UpdaterConfig'] = 'path:' + (Get-BoosterUpdateConfigPath) }
catch { $probeResult['modules']['UpdaterConfig'] = 'threw:' + $_.Exception.Message }
$probeResult
'@)
$fgAll = Invoke-EnvProbe $fgScript.ToString() 'F-G GUI start-up statements (engine dot-source -> Set-TargetUserContext -> Initialize-ProtectedUserStateStore -> module loads)'
$fg = $fgAll['init']
foreach ($k in $faProtected) { Assert-PathEquals $fg[$k] $faExpect[$k] "F-G GUI start-up: `$script:$k must not move" }
foreach ($k in 'ProtectedUserStateRoot', 'UserDataRoot') {
  Assert-PathEquals $fg[$k] $faSidRoot "F-G GUI start-up: `$script:$k must be <ProgramDataRoot>\users\<SID>"
}
foreach ($k in 'ConfigDir', 'UserConfigDir', 'BoosterUserConfigDir') {
  Assert-PathEquals $fg[$k] ([IO.Path]::Combine($faSidRoot, 'config')) "F-G GUI start-up: `$script:$k"
}
Assert-PathEquals $fg['ProfileDir'] ([IO.Path]::Combine($faSidRoot, 'profiles')) 'F-G GUI start-up: $script:ProfileDir'
Assert-PathEquals $fg['TargetLocalAppData'] $realLocalFull.TrimEnd('\') 'F-G GUI start-up: $script:TargetLocalAppData'
Assert-True ([bool]$fg['UseExplicitUserHive'] -and [string]::Equals("$($fg['TargetUserSid'])", $currentSid, [StringComparison]::OrdinalIgnoreCase)) `
  'F-G GUI start-up must leave the engine in the explicit context of the original user'
$fgWantDirs = @(@($realPd, [IO.Path]::Combine($realPd, 'users'), $faSidRoot, [IO.Path]::Combine($faSidRoot, 'config'),
                  [IO.Path]::Combine($faSidRoot, 'profiles')) | ForEach-Object { "$_|False" }) + @("$([IO.Path]::Combine($realPd, 'startup-logs'))|True")
Assert-True ([string]::Equals((@($fg['Dirs']) -join '; '), ($fgWantDirs -join '; '), [StringComparison]::Ordinal)) `
  ('F-G GUI start-up created protected directories [path|UsersRead: ' + (@($fg['Dirs']) -join '; ') + '] instead of [' + ($fgWantDirs -join '; ') +
   '] (per-SID state must not be readable by BUILTIN\Users; only startup-logs is)')

# GUI 初始化之后才点源 updater.ps1 / tuning-experiment.ps1，而且与它们共用脚本作用域：模块加载时对这些变量的任何改写
# 都会在整个 GUI 会话里生效（例如 updater 顶层「声明」一句 $script:BoosterUserConfigDir = $null，高权限 GUI 的
# 「不再提醒此版本」就再也存不下来）。所以接着原样执行到最后一个模块加载，再快照一次。
$fgMod = $fgAll['modules']
Assert-True ([bool]$fgMod['UpdaterLoaded']) 'anchor: F-G the GUI module loads did not load scripts\updater.ps1 in the probe (the GUI swallows its load error)'
Assert-True ([bool]$fgMod['TuningLoaded']) 'anchor: F-G the GUI module loads did not load scripts\tuning-experiment.ps1 in the probe (the GUI swallows its load error)'
foreach ($k in $fgNames) {
  Assert-True ([string]::Equals("$($fgMod[$k])", "$($fg[$k])", [StringComparison]::Ordinal)) `
    "F-G after the GUI module loads (updater.ps1, tuning-experiment.ps1): `$script:$k changed from [$($fg[$k])] to [$($fgMod[$k])]"
}
Assert-True ([string]::Equals("$($fgMod['UpdaterConfig'])", 'path:' + [IO.Path]::Combine($faSidRoot, 'config', 'updater.json'), [StringComparison]::Ordinal)) `
  ("F-G after the GUI module loads: the elevated updater must keep its config at <ProgramDataRoot>\users\<SID>\config\updater.json " +
   "[$([IO.Path]::Combine($faSidRoot, 'config', 'updater.json'))], got [$($fgMod['UpdaterConfig'])]")

# F-G2：原用户不是 GUI 进程令牌的用户（标准用户输入管理员凭据的 OTS 提权）时，GUI 的 per-SID 分区必须跟原用户走，
# 不能跟提权令牌走。真机只有一个已登录用户，所以单独跑 GUI 的 Initialize-ProtectedUserStateStore，原用户用假 SID。
$fg2Script = (Get-TopFunctionText $fgAst 'Initialize-ProtectedUserStateStore' 'GUI') + "`r`n" + @'
function New-ProtectedDirectory { param([string]$Path, [bool]$UsersRead) [void]$global:DfbFg2Dirs.Add("$Path|$UsersRead") }
function Write-BootLog { param([string]$Line) }
$global:DfbFg2Dirs = New-Object System.Collections.Generic.List[string]
$script:ProgramDataRoot = __PDROOT__
$script:OriginalUserSid = __FAKESID__
Initialize-ProtectedUserStateStore
@{ ProtectedUserStateRoot = $script:ProtectedUserStateRoot; UserDataRoot = $script:UserDataRoot; ConfigDir = $script:ConfigDir
   ProfileDir = $script:ProfileDir; UserConfigDir = $script:UserConfigDir; BoosterUserConfigDir = $script:BoosterUserConfigDir
   Dirs = $global:DfbFg2Dirs.ToArray() }
'@
$fg2Script = $fg2Script.Replace('__PDROOT__', (ConvertTo-PsLiteral $realPd)).Replace('__FAKESID__', (ConvertTo-PsLiteral $fakeSid))
$fg2 = Invoke-EnvProbe $fg2Script 'F-G2 GUI Initialize-ProtectedUserStateStore for an original user other than the process token'
$fg2Root = [IO.Path]::Combine($realPd, 'users', $fakeSid)
Assert-True (-not [string]::Equals($fakeSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) 'anchor: F-G2 needs an original-user SID that is not the process SID'
foreach ($k in 'ProtectedUserStateRoot', 'UserDataRoot') {
  Assert-PathEquals $fg2[$k] $fg2Root "F-G2 GUI per-SID state under OTS elevation: `$script:$k must be <ProgramDataRoot>\users\<original user SID>, not the elevated token's SID"
}
foreach ($k in 'ConfigDir', 'UserConfigDir', 'BoosterUserConfigDir') {
  Assert-PathEquals $fg2[$k] ([IO.Path]::Combine($fg2Root, 'config')) "F-G2 GUI per-SID state under OTS elevation: `$script:$k"
}
Assert-PathEquals $fg2['ProfileDir'] ([IO.Path]::Combine($fg2Root, 'profiles')) 'F-G2 GUI per-SID state under OTS elevation: $script:ProfileDir'

# F-A2：显式上下文、目标 SID 又不是当前进程身份（标准用户 + 管理员凭据的 OTS 提权，卸载器的 -UserSid 路径）。
# 真机只能用当前用户跑显式分支，所以这里复用 C3 抽出的尾部语句，把 UseExplicitUserHive 置成生产值 $true，SID 用假 SID。
foreach ($admin in $true, $false) {
  $x = Invoke-RootProbe ($stcProbeHead + "`$script:UseExplicitUserHive = `$true`r`n`$script:DfbProbeAdmin = `$$admin`r`n" + $tailText + $stcResult) `
    "F-A explicit context for another user (admin=$admin)"
  $want = $(if ($admin) { [IO.Path]::Combine($sentinel.PdRoot, 'users', $fakeSid) } else { [IO.Path]::Combine($sentinel.Target, 'DeltaForceBooster') })
  Assert-PathEquals $x.UserDataRoot $want "F-A explicit context for another user (admin=$admin): UserDataRoot"
}

# ----- F-T. GUI 的两道会话目录闸门与备份引用判定 -----
# 引导闸门在 GUI 顶层的 try 里：从 $expectedTemp 的赋值起，到第一条带 throw 的语句为止，原样执行。
$ftStart = @((Get-FbNameRecords (Get-FbIndex $fgAst) 'expectedTemp') |
  Where-Object { $_.Kind -eq 'assign' -and $_.Simple -and $null -eq $_.Fn } | Sort-Object { $_.Node.Extent.StartOffset })
Assert-True ($ftStart.Count -ge 1) 'anchor: the GUI start-up gate must assign $expectedTemp at script level'
$ftBlock = @($ftStart[0].Node.Parent.Statements)
$ftGate = New-Object System.Collections.Generic.List[string]
$ftClosed = $false
for ($i = [Array]::IndexOf($ftBlock, $ftStart[0].Node); $i -ge 0 -and $i -lt $ftBlock.Count; $i++) {
  $ftGate.Add($ftBlock[$i].Extent.Text)
  # 范围止于「检查 $actualTemp 并 throw」的那一条（中间多一道带 throw 的前置校验不会把真正的闸门截掉）
  if (@($ftBlock[$i].FindAll({ param($x) $x -is [Management.Automation.Language.ThrowStatementAst] }, $true)).Count -gt 0 -and
      @($ftBlock[$i].FindAll({ param($x) $x -is [Management.Automation.Language.VariableExpressionAst] -and $x.VariablePath.UserPath -ieq 'actualTemp' }, $true)).Count -gt 0) {
    $ftClosed = $true; break
  }
}
Assert-True $ftClosed 'anchor: the GUI start-up gate must end with a statement that checks $actualTemp and throws on an untrusted session directory'
# 闸门抛出之后由谁接住：把闸门放回它外面每一层 try 的原样 catch / finally 里再跑一次（Stop-UntrustedGuiStartup 桩成抛出）。
# 只单独跑闸门本身，看不见「外层 catch 只记日志、启动继续」这类改法。
$ftWrapped = $ftGate.ToArray() -join "`r`n"
$ftTries = 0
for ($p = $ftStart[0].Node.Parent; $p; $p = $p.Parent) {
  if ($p -is [Management.Automation.Language.TryStatementAst] -and (Test-FbContains $p.Body $ftStart[0].Node)) {
    $ftTries++
    $ftCatches = (@($p.CatchClauses) | ForEach-Object { $_.Extent.Text }) -join "`r`n"
    $ftFinally = $(if ($p.Finally) { 'finally ' + $p.Finally.Extent.Text } else { '' })
    $ftWrapped = "try {`r`n$ftWrapped`r`n}`r`n$ftCatches`r`n$ftFinally"
  }
}
$ftScript = $script:GateStubs + "`r`n" +
  (Get-TopFunctionText $fgAst 'Get-ProtectedEngineExchangeRoot' 'GUI') + "`r`n" +
  (Get-TopFunctionText $fgAst 'Test-TuningBackupReference' 'GUI') + "`r`n" + @'
function Stop-UntrustedGuiStartup { param([string]$Reason) throw "GUI start-up stopped: $Reason" }
function Write-BootLog { param([string]$Line) }
$probeResult = @{}
foreach ($probeCase in @(@{ Name = 'protected'; Dir = __PSESSION__ }, @{ Name = 'usertemp'; Dir = __UTEMP__ })) {
  $global:DfbProbeExisting = @($probeCase.Dir)
  $env:TEMP = $probeCase.Dir; $env:TMP = $probeCase.Dir; $env:DFB_ENGINE_HOST_SESSION = __SESSION__
  $sessionText = __SESSION__
  try {
__GATE__
    $probeResult["boot/$($probeCase.Name)"] = 'accepted:' + [IO.Path]::GetFullPath("$env:TEMP").TrimEnd('\')
  } catch { $probeResult["boot/$($probeCase.Name)"] = 'rejected:' + $_.Exception.Message }
  try {
__WRAPPEDGATE__
    $probeResult["bootwrapped/$($probeCase.Name)"] = 'accepted:' + [IO.Path]::GetFullPath("$env:TEMP").TrimEnd('\')
  } catch { $probeResult["bootwrapped/$($probeCase.Name)"] = 'rejected:' + $_.Exception.Message }
  try { $probeResult["exchange/$($probeCase.Name)"] = 'accepted:' + (Get-ProtectedEngineExchangeRoot) }
  catch { $probeResult["exchange/$($probeCase.Name)"] = 'rejected:' + $_.Exception.Message }
}
__BACKUPREFS__
$probeResult
'@
$ftScript = $ftScript.Replace('__WRAPPEDGATE__', $ftWrapped)
$ftScript = $ftScript.Replace('__GATE__', ($ftGate.ToArray() -join "`r`n"))
$ftScript = $ftScript.Replace('__BACKUPREFS__', (Get-BackupRefProbeText 'Test-TuningBackupReference'))
$ftScript = $ftScript.Replace('__PSESSION__', (ConvertTo-PsLiteral $probeProtectedSession))
$ftScript = $ftScript.Replace('__UTEMP__', (ConvertTo-PsLiteral $probeUserTemp))
$ftScript = $ftScript.Replace('__SESSION__', (ConvertTo-PsLiteral $script:ProbeSession))
$ft = Invoke-EnvProbe $ftScript 'F-T GUI session gates and backup-reference check (run as written)'
Assert-GateVerdicts $ft 'boot' 'F-T GUI start-up session-temp gate'
Assert-True ("$($ft['bootwrapped/usertemp'])".StartsWith('rejected:', [StringComparison]::Ordinal)) `
  ("F-T GUI start-up session-temp gate: its enclosing error handling ($ftTries try/catch as written) swallows the rejection, so start-up " +
   "continues with the per-user %TEMP% [$probeUserTemp]: [$($ft['bootwrapped/usertemp'])]")
Assert-True ([string]::Equals("$($ft['bootwrapped/protected'])", "accepted:$probeProtectedSession", [StringComparison]::Ordinal)) `
  ("F-T GUI start-up session-temp gate inside its enclosing error handling must accept exactly the protected session directory " +
   "[$probeProtectedSession], got [$($ft['bootwrapped/protected'])]")
Assert-GateVerdicts $ft 'exchange' 'F-T GUI Get-ProtectedEngineExchangeRoot'
Assert-BackupRefVerdicts $ft 'F-T GUI Test-TuningBackupReference'

# tuning-experiment 自己的备份引用白名单（与 GUI 那份独立推导）
$fxAst = Get-FbAst 'scripts\tuning-experiment.ps1'
$fx = Invoke-EnvProbe ((Get-TopFunctionText $fxAst 'Test-PathUnderProtectedTuningBackup' 'scripts\tuning-experiment.ps1') +
  "`r`n`$probeResult = @{}`r`n" + (Get-BackupRefProbeText 'Test-PathUnderProtectedTuningBackup') + "`r`n`$probeResult") `
  'F-T tuning-experiment backup-reference check (run as written)'
Assert-BackupRefVerdicts $fx 'F-T tuning-experiment Test-PathUnderProtectedTuningBackup'

# ----- F-W. worker：旧数据迁移源只能来自 LocalApplicationData Known Folder -----
$fwAst = Get-FbAst 'scripts\user-context-worker.ps1'
[void](Get-TopFunctionText $fwAst 'Get-WorkerLocalAppData' 'scripts\user-context-worker.ps1')
$fwFns = @($fwAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text })
# 差分跑：真实环境一次，然后每个用户目录类环境变量单独毒化一次，最后全部毒化一次。
# 真实环境返回 Known Folder、某个变量一毒化就抛出或换了值 —— 失败消息直接点名依赖的是哪个变量
# （以前毒化值恰好是不存在的目录，读环境变量的改法只会在 worker 自己的校验里抛出，只能报一句笼统的「抛异常」）。
$fwNames = @('LOCALAPPDATA', 'USERPROFILE', 'APPDATA', 'ProgramData', 'ALLUSERSPROFILE')
$fwScript = ($fwFns -join "`r`n") + "`r`n" + @'
function Invoke-FwCase { try { 'returned:' + (Get-WorkerLocalAppData) } catch { 'threw:' + $_.Exception.Message } }
$fwPoison = __POISON__
$probeResult = @{ real = (Invoke-FwCase) }
foreach ($n in @($fwPoison.Keys)) {
  $keep = [Environment]::GetEnvironmentVariable($n, 'Process')
  [Environment]::SetEnvironmentVariable($n, $fwPoison[$n], 'Process')
  try { $probeResult["only:$n"] = Invoke-FwCase } finally { [Environment]::SetEnvironmentVariable($n, $keep, 'Process') }
}
foreach ($n in @($fwPoison.Keys)) { [Environment]::SetEnvironmentVariable($n, $fwPoison[$n], 'Process') }
$probeResult['all'] = Invoke-FwCase
$probeResult
'@
$fwScript = $fwScript.Replace('__POISON__', ('[ordered]@{ ' + ((@($fwNames) | ForEach-Object { '{0} = {1}' -f (ConvertTo-PsLiteral $_), (ConvertTo-PsLiteral $script:PoisonedEnv[$_]) }) -join '; ') + ' }'))
$fwSaved = @{}
foreach ($n in $fwNames) { $fwSaved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
try { $fw = Invoke-RootProbe $fwScript 'F-W worker Get-WorkerLocalAppData (real env, each variable poisoned alone, all poisoned)' }
finally { foreach ($n in $fwNames) { [Environment]::SetEnvironmentVariable($n, $fwSaved[$n], 'Process') } }
$fwWant = 'returned:' + $realLocalFull.TrimEnd('\')
Assert-True ([string]::Equals("$($fw['real'])", $fwWant, [StringComparison]::Ordinal)) `
  "F-W worker Get-WorkerLocalAppData (real environment) must return the LocalApplicationData known folder [$($realLocalFull.TrimEnd('\'))], got [$($fw['real'])]"
foreach ($case in @(@($fwNames | ForEach-Object { "only:$_" }) + @('all'))) {
  $got = "$($fw[$case])"
  $what = $(if ($case -eq 'all') { 'with every user-folder variable poisoned' } else { "with only `$env:$($case.Substring(5)) poisoned" })
  $dep = $(if ($case -eq 'all') { 'the user-folder environment variables' } else { "`$env:$($case.Substring(5))" })
  Assert-True (-not $got.StartsWith('threw:', [StringComparison]::Ordinal)) `
    "F-W worker Get-WorkerLocalAppData depends on ${dep}: $what it threw [$($got.Substring([Math]::Min(6, $got.Length)))] although the real environment returned the known folder"
  Assert-True ([string]::Equals($got, $fwWant, [StringComparison]::Ordinal)) `
    "F-W worker Get-WorkerLocalAppData must return the LocalApplicationData known folder, not an environment variable: $what it returned [$got]"
}

# ----- F-W2. worker 旧数据迁移：同一个文件两处都有时，以 LocalAppData（v0.19.4 起的新位置）为准 -----
# Add-LegacyJson 按 RelativePath 去重、先到先得，Import-ProtectedLegacyState 又只 CreateNew 不覆盖：
# 来源顺序一旦颠倒，旧的程序目录副本（电源方案原值、方案、性能历史）会永久顶替新数据。
# 真跑 Invoke-WorkerLegacyMigration：两个沙箱目录分别当程序目录和 LocalAppData，毒化环境下运行。
$fw2Box = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'dfb-identity-migration-' + [guid]::NewGuid().ToString('N'))
try {
  $fw2Prog = [IO.Path]::Combine($fw2Box, 'prog')
  $fw2Local = [IO.Path]::Combine($fw2Box, 'local')
  $fw2Files = [ordered]@{
    'prog\config\power-scheme.json' = '{"from":"program-dir"}'
    'local\DeltaForceBooster\config\power-scheme.json' = '{"from":"localappdata"}'
    'prog\config\disclaimer.json' = '{"from":"program-dir-only"}'
    'local\DeltaForceBooster\profiles\fw2-probe.json' = '{"from":"localappdata-only"}'
  }
  foreach ($rel in @($fw2Files.Keys)) {
    $p = [IO.Path]::Combine($fw2Box, $rel)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p))
    [IO.File]::WriteAllText($p, $fw2Files[$rel], (New-Object Text.UTF8Encoding($false)))
  }
  $fw2Fns = [IO.Path]::Combine($fw2Prog, 'scripts', 'worker-functions.ps1')
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fw2Fns))
  [IO.File]::WriteAllText($fw2Fns, ($fwFns -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
  $fw2Script = @'
. __FNS__
function Get-WorkerLocalAppData { __LOCAL__ }
$pkg = Invoke-WorkerLegacyMigration
$probeResult = @{ Skipped = (@($pkg.Skipped) -join ' | ') }
foreach ($f in @($pkg.Files)) { $probeResult["$($f.RelativePath)"] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$($f.ContentBase64)")) }
$probeResult
'@
  $fw2Script = $fw2Script.Replace('__FNS__', (ConvertTo-PsLiteral $fw2Fns)).Replace('__LOCAL__', (ConvertTo-PsLiteral $fw2Local))
  $fw2 = Invoke-EnvProbe $fw2Script 'F-W2 worker Invoke-WorkerLegacyMigration (sandbox program dir + LocalAppData, poisoned env)'
} finally {
  if ([IO.Directory]::Exists($fw2Box)) { [IO.Directory]::Delete($fw2Box, $true) }
}
Assert-True ([string]::Equals("$($fw2['config\power-scheme.json'])", '{"from":"localappdata"}', [StringComparison]::Ordinal)) `
  ("F-W2 worker legacy migration must take config\power-scheme.json from <LocalAppData>\DeltaForceBooster (the newer location) before the program directory, " +
   "got [$($fw2['config\power-scheme.json'])] (skipped: $($fw2['Skipped']))")
Assert-True ([string]::Equals("$($fw2['config\disclaimer.json'])", '{"from":"program-dir-only"}', [StringComparison]::Ordinal)) `
  "F-W2 worker legacy migration must still collect a file that exists only in the program directory, got [$($fw2['config\disclaimer.json'])] (skipped: $($fw2['Skipped']))"
Assert-True ([string]::Equals("$($fw2['profiles\fw2-probe.json'])", '{"from":"localappdata-only"}', [StringComparison]::Ordinal)) `
  "F-W2 worker legacy migration must collect <LocalAppData>\DeltaForceBooster\profiles, got [$($fw2['profiles\fw2-probe.json'])] (skipped: $($fw2['Skipped']))"

# ----- F-P. updater：medium 回退到 LocalAppData，high 只用受保护 per-SID 配置目录 -----
# 桩掉「是否提权」「目录是否存在 / 建目录」：测试进程读不了受保护目录，也不许落盘。
$fpAst = Get-FbAst 'scripts\updater.ps1'
$fpSidConfig = [IO.Path]::Combine($faSidRoot, 'config')
$fpScript = @'
function Test-BoosterUpdaterElevated { [bool]$global:DfbFpElevated }
function Test-Path { param([string]$LiteralPath, [string]$PathType, [string]$Path) $true }
function New-Item { param([string]$ItemType, [string]$Path, [switch]$Force) }
__FUNC__
$probeResult = @{}
$global:DfbFpElevated = $false
$probeResult['medium'] = Get-BoosterUpdateConfigPath
$global:DfbFpElevated = $true
$script:BoosterUserConfigDir = __SIDCONFIG__
$probeResult['high'] = Get-BoosterUpdateConfigPath
$script:BoosterUserConfigDir = $null
try { $probeResult['high-without-protected-dir'] = 'accepted:' + (Get-BoosterUpdateConfigPath) }
catch { $probeResult['high-without-protected-dir'] = 'rejected:' + $_.Exception.Message }
$probeResult
'@
$fpScript = $fpScript.Replace('__FUNC__', (Get-TopFunctionText $fpAst 'Get-BoosterUpdateConfigPath' 'scripts\updater.ps1'))
$fpScript = $fpScript.Replace('__SIDCONFIG__', (ConvertTo-PsLiteral $fpSidConfig))
$fp = Invoke-EnvProbe $fpScript 'F-P updater Get-BoosterUpdateConfigPath (poisoned env)'
Assert-PathEquals $fp['medium'] ([IO.Path]::Combine($realLocalFull, 'DeltaForceBooster', 'config', 'updater.json')) `
  'F-P updater (medium) must keep its config under <LocalApplicationData>\DeltaForceBooster\config'
Assert-PathEquals $fp['high'] ([IO.Path]::Combine($fpSidConfig, 'updater.json')) 'F-P updater (high) must use the protected per-SID config directory handed over by the GUI'
Assert-True ("$($fp['high-without-protected-dir'])".StartsWith('rejected:', [StringComparison]::Ordinal)) `
  "F-P elevated updater without the protected per-SID config directory fell back to [$($fp['high-without-protected-dir'])]"

# ----- F-U. 卸载脚本：路径前缀原样执行 + $hasBackup 沙箱真跑 -----
# 卸载脚本以 high token 运行，决定「要不要先问用户还原」和「受保护目录在哪里」。从第一条语句到第一个函数定义之前
# 的整段前缀全是路径计算（外加 Add-Type WinForms），原样执行；写法换成 [string] / $local: / Set-Variable 都一样读得到。
$fuAst = Get-FbAst 'build\make-installer.ps1::$uninstallPs'
$fuTop = @($fuAst.EndBlock.Statements)
$fuEnd = -1
for ($i = 0; $i -lt $fuTop.Count; $i++) { if ($fuTop[$i] -is [Management.Automation.Language.FunctionDefinitionAst]) { $fuEnd = $i; break } }
Assert-True ($fuEnd -gt 0) 'anchor: the uninstall script must start with its path prefix, followed by its first function definition'
$fuInstall = [IO.Path]::Combine($sentinelBase, 'install-root')
$fuScript = "`$InstallRoot = $(ConvertTo-PsLiteral $fuInstall); `$UserSid = $(ConvertTo-PsLiteral $currentSid); " +
  "`$UserLocalAppData = $(ConvertTo-PsLiteral $realLocalFull); `$WaitPid = 0; `$WaitPid2 = 0; `$StageRoot = ''`r`n" +
  ((@($fuTop[0..($fuEnd - 1)]) | ForEach-Object { $_.Extent.Text }) -join "`r`n") +
  "`r`n@{ programData = `$programData; protectedRoot = `$protectedRoot; protectedBackup = `$protectedBackup; legacyRoots = `$legacyRoots }"
$fu = Invoke-EnvProbe $fuScript 'F-U uninstall script path prefix (run as written, poisoned env)'
foreach ($row in @(
    @('programData', $realCommon, 'F-U uninstall $programData must be the CommonApplicationData known folder'),
    @('protectedRoot', $realPd, 'F-U uninstall $protectedRoot must be <CommonApplicationData>\DeltaForceBooster'),
    @('protectedBackup', [IO.Path]::Combine($realPd, 'backup'), 'F-U uninstall $protectedBackup must be <protected root>\backup'),
    @('legacyRoots', [IO.Path]::Combine($realPd, 'legacy-roots.json'), 'F-U uninstall $legacyRoots must be <protected root>\legacy-roots.json'))) {
  $v = $fu[$row[0]]
  # 没赋值 ≠ 赋错了：多半是赋值挪到了第一个函数定义之后（本测试只执行那之前的前缀），消息要说清楚
  $what = $row[2] + $(if ($null -eq $v) { " (`$$($row[0]) is not assigned before the uninstall script's first function definition, the prefix this probe executes)" } else { '' })
  Assert-PathEquals $v $row[1] $what
}

# $hasBackup 决定卸载前是否先问「还原系统改动」。为假时卸载静默跳过还原，改动全部留在系统里。
$fuHas = @($fuTop | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and "$($_.Left)" -ceq '$hasBackup' })
Assert-True ($fuHas.Count -eq 1) "anchor: the uninstall script must compute `$hasBackup exactly once at script level (found $($fuHas.Count))"
$fuSandbox = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'dfb-identity-uninstall-' + [guid]::NewGuid().ToString('N'))
try {
  $fuCases = [ordered]@{ backup = $true; legacy = $true; none = $false }
  $fuText = New-Object System.Text.StringBuilder
  [void]$fuText.AppendLine('$probeResult = @{}')
  foreach ($case in @($fuCases.Keys)) {
    $pd = [IO.Path]::Combine($fuSandbox, $case, 'ProgramData')
    $pr = [IO.Path]::Combine($pd, 'DeltaForceBooster')
    $dest = [IO.Path]::Combine($fuSandbox, $case, 'install')
    [void][IO.Directory]::CreateDirectory($pr)
    [void][IO.Directory]::CreateDirectory($dest)
    if ($case -eq 'backup') {
      [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($pr, 'backup'))
      [IO.File]::WriteAllText([IO.Path]::Combine($pr, 'backup', 'backup-20260101-000000.json'), '{}')
    }
    if ($case -eq 'legacy') { [IO.File]::WriteAllText([IO.Path]::Combine($pr, 'legacy-roots.json'), '{"SchemaVersion":1,"Roots":[]}') }
    [void]$fuText.AppendLine("`$dest = $(ConvertTo-PsLiteral $dest); `$programData = $(ConvertTo-PsLiteral $pd); `$protectedRoot = $(ConvertTo-PsLiteral $pr)")
    [void]$fuText.AppendLine("`$protectedBackup = $(ConvertTo-PsLiteral ([IO.Path]::Combine($pr, 'backup'))); `$legacyRoots = $(ConvertTo-PsLiteral ([IO.Path]::Combine($pr, 'legacy-roots.json')))")
    [void]$fuText.AppendLine($fuHas[0].Extent.Text)
    [void]$fuText.AppendLine("`$probeResult['$case'] = `$hasBackup")
  }
  [void]$fuText.AppendLine('$probeResult')
  $fh = Invoke-RootProbe $fuText.ToString() 'F-U uninstall $hasBackup (run as written in a sandbox)'
  Assert-True ($fh['none'] -eq $false) 'anchor: F-U uninstall $hasBackup must be false when the protected root holds no backup record'
  Assert-True ($fh['backup'] -eq $true) 'F-U uninstall no longer offers restore when the only backups are protected ones (<protected root>\backup\backup-*.json)'
  Assert-True ($fh['legacy'] -eq $true) 'F-U uninstall no longer offers restore when only <protected root>\legacy-roots.json records old backups'
} finally {
  if ([IO.Directory]::Exists($fuSandbox)) { [IO.Directory]::Delete($fuSandbox, $true) }
}

# ----- 第二层（结构）：行为够不到的推导点 -----
# ----- D. 其它 PowerShell 组件：每一处独立推导都钉死父目录 -----
$expectedPsRootSites = [ordered]@{
  'scripts\delta-booster.ps1' = @(
    'CommonApplicationData + DeltaForceBooster',
    'CommonApplicationData + DeltaForceBooster\session-temp\$session',
    'LocalApplicationData|param:LocalAppDataPath + DeltaForceBooster',
    'LocalApplicationData|param:LocalAppDataPath + DeltaForceBooster')
  'gui\DeltaForceBooster-GUI.ps1' = @(
    'CommonApplicationData + DeltaForceBooster',
    'CommonApplicationData + DeltaForceBooster\backup',
    'CommonApplicationData + DeltaForceBooster\diagnostics',
    'CommonApplicationData + DeltaForceBooster\session-temp\$session',
    'CommonApplicationData + DeltaForceBooster\session-temp\$sessionText')
  'scripts\export-diagnostics.ps1' = @('CommonApplicationData + DeltaForceBooster')
  'scripts\tuning-experiment.ps1' = @('CommonApplicationData + DeltaForceBooster\backup')
  'scripts\user-context-worker.ps1' = @('LocalApplicationData + DeltaForceBooster')
  'scripts\updater.ps1' = @('LocalApplicationData + DeltaForceBooster\config')
  'build\make-installer.ps1::$uninstallPs' = @(
    'CommonApplicationData + DeltaForceBooster',
    'CommonApplicationData + DeltaForceBooster',
    'CommonApplicationData + DeltaForceBooster\uninstall-stage')
}
$psSiteTotal = 0
foreach ($key in @($expectedPsRootSites.Keys)) {
  $want = @(Get-OrdinalSorted $expectedPsRootSites[$key])
  Assert-True ($want.Count -gt 0) "anchor: pinned site list for $key is empty"
  $ast = Get-FbAst $key
  $got = @(Get-PsStateRootSites $ast)
  $psSiteTotal += $got.Count
  Assert-True ([string]::Equals(($got -join "`n"), ($want -join "`n"), [StringComparison]::Ordinal)) `
    ("$key : state-root derivation sites changed (parent folder or child path): " + (Get-SiteDiff $want $got))
}
Assert-True ($psSiteTotal -eq 16) "anchor: expected 16 PowerShell state-root derivation sites in total, found $psSiteTotal"

# ----- E. C# 组件 -----
$expectedCsRootSites = [ordered]@{
  'build\make-engine-host.ps1::$cs' = @('CommonApplicationData + "DeltaForceBooster"')
  'build\uninstall-host.cs' = @('CommonApplicationData + "DeltaForceBooster"')
  'build\setup-wizard.cs' = @(
    'expr:Path.GetPathRoot(full) + "DeltaForceBooster"',
    'hook:TestLocalAppDataPath|LocalApplicationData + "DeltaForceBooster"',
    'hook:TestProgramDataPath|CommonApplicationData + "DeltaForceBooster"',
    'hook:TestProgramFilesPath|ProgramFiles + "DeltaForceBooster"')
}
$csSiteTotal = 0
foreach ($key in @($expectedCsRootSites.Keys)) {
  $want = @(Get-OrdinalSorted $expectedCsRootSites[$key])
  Assert-True ($want.Count -gt 0) "anchor: pinned C# site list for $key is empty"
  $got = @(Get-CSharpStateRootSites (Get-RootScanText $key))
  $csSiteTotal += $got.Count
  Assert-True ([string]::Equals(($got -join "`n"), ($want -join "`n"), [StringComparison]::Ordinal)) `
    ("$key : C# state-root derivation sites changed (parent folder or child path): " + (Get-SiteDiff $want $got))
}
Assert-True ($csSiteTotal -eq 6) "anchor: expected 6 C# state-root derivation sites in total, found $csSiteTotal"

# ----- F-B / F-C. 其它 PowerShell 组件：根变量的全部写入 + 派生子路径 -----
$expectedDerivedSites = [ordered]@{
  'scripts\delta-booster.ps1' = @('$ProgramDataRoot >> backup', '$ProgramDataRoot >> backup.key', '$ProgramDataRoot >> ipc', '$ProgramDataRoot >> legacy-roots.json', '$ProgramDataRoot >> users', '$ProgramDataRoot >> users', '$UserDataRoot >> config', '$UserDataRoot >> config', '$UserDataRoot >> profiles', '$UserDataRoot >> profiles')
  'gui\DeltaForceBooster-GUI.ps1' = @('$bootLogRoot >> startup-logs')
  'scripts\export-diagnostics.ps1' = @('$programData >> <$sub>', '$programData >> startup-logs')
  'scripts\tuning-experiment.ps1' = @()
  'scripts\user-context-worker.ps1' = @()
  'scripts\updater.ps1' = @('$d @ Get-BoosterUpdateConfigPath >> updater.json')
  'build\make-installer.ps1::$uninstallPs' = @('$protectedRoot >> backup', '$protectedRoot >> legacy-roots.json')
}
# 结果变量 / 派生变量上「不是 DeltaForceBooster 推导」的写入：只许这几处（逐字钉死，新增一处必须有人看过）
$expectedExtraWrites = @{
  'scripts\delta-booster.ps1' = @()
  'gui\DeltaForceBooster-GUI.ps1' = @()
  'scripts\export-diagnostics.ps1' = @()
  'scripts\tuning-experiment.ps1' = @()
  'scripts\user-context-worker.ps1' = @()
  'scripts\updater.ps1' = @('root $d: $d = $script:BoosterUserConfigDir', 'root $d: $d = [IO.Path]::GetFullPath($d)')
  'build\make-installer.ps1::$uninstallPs' = @()
}
$fbReadTotal = 0; $fbResultTotal = 0; $fcDerivedTotal = 0
foreach ($key in @($expectedPsRootSites.Keys)) {
  $ast = Get-FbAst $key
  $joins = @(Get-FbJoinNodes $ast)
  $sites = @($joins | Where-Object { Test-FbIsRootSite $_ })
  Assert-True ($sites.Count -eq @($expectedPsRootSites[$key]).Count) "anchor: F-B $key site count must match the pinned D table"

  # F-B-1：解析器看过的变量不许有它看不见的写法
  $acc = [pscustomobject]@{ Reads = (New-Object System.Collections.Generic.List[object]); Functions = (New-Object System.Collections.Generic.List[object]) }
  foreach ($s in $sites) { Add-FbConsulted $s.Parent $acc }
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($r in $acc.Reads.ToArray()) {
    $b = Get-FbReadBinding $r
    $fnName = "$((Get-EnclosingFunction $r).Name)"
    if (-not $seen.Add("$fnName|$($b.Form)")) { continue }
    $fbReadTotal++
    foreach ($scope in @($b.Scopes)) {
      foreach ($w in @(Get-FbWrites $ast $scope (Get-BareVarName $b.Form))) {
        $visible = $w.Kind -eq 'assign' -and $w.Plain -and [string]::Equals($w.UserPath, $b.Form, [StringComparison]::OrdinalIgnoreCase) -and
                   @($b.Defs | Where-Object { [object]::ReferenceEquals($_, $w.Node) }).Count -eq 1
        Assert-True $visible ("F-B $key : `$$($b.Form) (read by a state-root derivation) is also written in a form the root " +
          "resolver cannot see [line $($w.Node.Extent.StartLineNumber): $($w.Node.Extent.Text)]")
      }
    }
  }
  foreach ($f in $acc.Functions.ToArray()) {
    $last = Resolve-RootBase @($f.Body.EndBlock.Statements)[-1]
    foreach ($ret in @($f.Body.FindAll({ param($x) $x -is [Management.Automation.Language.ReturnStatementAst] -and $x.Pipeline }, $true))) {
      if ((Get-EnclosingFunction $ret) -ne $f) { continue }
      $rk = Resolve-RootBase $ret.Pipeline
      Assert-True ([string]::Equals($rk, $last, [StringComparison]::Ordinal)) `
        "F-B $key : $($f.Name) returns [$rk] on an early path but [$last] at the end; every exit of a root source must resolve to the same known folder"
    }
  }

  # F-B-2：D 站点的结果变量只许由 DeltaForceBooster 推导赋值（不许事后覆盖 / 兜底改写）
  $resultVars = New-Object System.Collections.Generic.List[object]
  $rvSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($s in $sites) {
    $rv = Get-FbResultVar $s.Node
    if (-not $rv) { continue }
    $scope = Get-FbVarScope $rv
    $name = Get-BareVarName $rv.VariablePath.UserPath
    if ($rvSeen.Add("$($scope.Name)|$name")) { $resultVars.Add([pscustomobject]@{ Scope = $scope; Name = $name }) }
  }
  $extra = New-Object System.Collections.Generic.List[string]
  foreach ($rv in $resultVars.ToArray()) {
    $fbResultTotal++
    foreach ($w in @(Get-FbWrites $ast $rv.Scope $rv.Name)) {
      $ok = $w.Kind -eq 'assign' -and @($sites | Where-Object { Test-FbContains $w.Node.Right $_.Node }).Count -gt 0
      if (-not $ok) { $extra.Add(('root ${0}: {1}' -f $rv.Name, ($w.Node.Extent.Text -replace '\s+', ' '))) }
    }
  }
  $gotExtra = @(Get-OrdinalSorted $extra.ToArray())
  $wantExtra = @(Get-OrdinalSorted @($expectedExtraWrites[$key] | Where-Object { $_ -like 'root *' }))
  Assert-True ([string]::Equals(($gotExtra -join "`n"), ($wantExtra -join "`n"), [StringComparison]::Ordinal)) `
    ("F-B $key : a state-root variable is overwritten outside its DeltaForceBooster derivation (post-derivation override / fallback): " +
     (Get-SiteDiff $wantExtra $gotExtra))
  # 引擎也纳入 F-C：F-A 只在「加载 + Set-TargetUserContext + GUI 初始化」这几个时点读值，
  # 其它函数里（例如 Initialize-UserDataStore）对派生根的改写要靠这张表拦

  # F-C：从根变量派生的子路径整表钉死；派生变量同样不许被改写
  $joinsByParent = @{}
  foreach ($j in $joins) {
    $p = Get-UnwrappedExpr $j.Parent
    if ($p -is [Management.Automation.Language.VariableExpressionAst]) {
      $pn = Get-BareVarName $p.VariablePath.UserPath
      if (-not $joinsByParent.ContainsKey($pn)) { $joinsByParent[$pn] = New-Object System.Collections.Generic.List[object] }
      $joinsByParent[$pn].Add($j)
    }
  }
  foreach ($pk in @($joinsByParent.Keys)) { $joinsByParent[$pk] = $joinsByParent[$pk].ToArray() }
  $derived = New-Object System.Collections.Generic.List[string]
  $derivedVars = New-Object System.Collections.Generic.List[object]
  foreach ($rv in $resultVars.ToArray()) {
    # 根变量本身的来源已由 D 表钉死；这里用「哪个根变量」做行名即可
    $rows = @('${0}{1}' -f $rv.Name, $(if ($rv.Scope) { " @ $($rv.Scope.Name)" } else { '' }))
    foreach ($j in @($joinsByParent[$rv.Name])) {
      if ($null -eq $j) { continue }
      $p = Get-UnwrappedExpr $j.Parent
      if (-not (Test-FbReadsVar $p $rv.Scope $rv.Name)) { continue }
      $childText = $(if ($null -ne (Get-RootChildValue $j.Child)) { Get-RootChildValue $j.Child } else { "<$($j.Child.Extent.Text)>" })
      $derived.Add(('{0} >> {1}' -f ($rows -join ' ; '), $childText))
      $dv = $(if ($null -ne (Get-RootChildValue $j.Child)) { Get-FbResultVar $j.Node })   # 只管固定子路径；循环变量拼出来的不算
      if ($dv) { $derivedVars.Add([pscustomobject]@{ Scope = (Get-FbVarScope $dv); Name = (Get-BareVarName $dv.VariablePath.UserPath); Parent = $rv.Name }) }
    }
  }
  $gotDerived = @(Get-OrdinalSorted $derived.ToArray())
  $wantDerived = @(Get-OrdinalSorted $expectedDerivedSites[$key])
  $fcDerivedTotal += $gotDerived.Count
  Assert-True ([string]::Equals(($gotDerived -join "`n"), ($wantDerived -join "`n"), [StringComparison]::Ordinal)) `
    ("F-C $key : sub-paths derived from the state root changed: " + (Get-SiteDiff $wantDerived $gotDerived))
  $dExtra = New-Object System.Collections.Generic.List[string]
  foreach ($dv in $derivedVars.ToArray()) {
    foreach ($w in @(Get-FbWrites $ast $dv.Scope $dv.Name)) {
      $ok = $w.Kind -eq 'assign' -and @(@($joinsByParent[$dv.Parent]) | Where-Object { $_ -and (Test-FbContains $w.Node.Right $_.Node) }).Count -gt 0
      if (-not $ok) { $dExtra.Add(('derived ${0}: {1}' -f $dv.Name, ($w.Node.Extent.Text -replace '\s+', ' '))) }
    }
  }
  $gotExtra = @(Get-OrdinalSorted $dExtra.ToArray())
  $wantExtra = @(Get-OrdinalSorted @($expectedExtraWrites[$key] | Where-Object { $_ -like 'derived *' }))
  Assert-True ([string]::Equals(($gotExtra -join "`n"), ($wantExtra -join "`n"), [StringComparison]::Ordinal)) `
    ("F-C $key : a derived state path is written from something other than its state root: " + (Get-SiteDiff $wantExtra $gotExtra))
}
# GUI 点源了引擎、共用同一个脚本作用域：GUI 里对引擎根变量的任何写法都会改掉引擎的根。
# 只许 Initialize-ProtectedUserStateStore 里那三条（其值已由 F-A 真跑核对）。
$fbGuiAst = Get-FbAst 'gui\DeltaForceBooster-GUI.ps1'
$fbGuiOwned = @('ProtectedUserStateRoot', 'UserConfigDir', 'BoosterUserConfigDir')
$fbRootNames = @(@($chainOrder) | ForEach-Object { $_.Substring(8) }) + $fbGuiOwned
$fbGuiWrites = New-Object System.Collections.Generic.List[string]
foreach ($n in $fbRootNames) {
  foreach ($w in @(Get-FbWrites $fbGuiAst $null $n)) {
    $fbGuiWrites.Add(('{0} @ {1}: {2}' -f $n, "$((Get-EnclosingFunction $w.Node).Name)", ($w.Node.Extent.Text -replace '\s+', ' ')))
  }
}
$fbGuiWant = @(Get-OrdinalSorted @(
  'BoosterUserConfigDir @ Initialize-ProtectedUserStateStore: $script:BoosterUserConfigDir = $configRoot',
  'ConfigDir @ Initialize-ProtectedUserStateStore: $script:ConfigDir = $configRoot',
  'ProfileDir @ Initialize-ProtectedUserStateStore: $script:ProfileDir = $profileRoot',
  'ProtectedUserStateRoot @ Initialize-ProtectedUserStateStore: $script:ProtectedUserStateRoot = $userRoot',
  'UserConfigDir @ Initialize-ProtectedUserStateStore: $script:UserConfigDir = $configRoot',
  'UserDataRoot @ Initialize-ProtectedUserStateStore: $script:UserDataRoot = $userRoot'))
$fbGuiGot = @(Get-OrdinalSorted $fbGuiWrites.ToArray())
Assert-True ([string]::Equals(($fbGuiGot -join "`n"), ($fbGuiWant -join "`n"), [StringComparison]::Ordinal)) `
  ('F-B gui\DeltaForceBooster-GUI.ps1 rebinds an engine state-root variable after dot-sourcing the engine: ' + (Get-SiteDiff $fbGuiWant $fbGuiGot))
# F-B-3：GUI 在自己的脚本作用域里点源的其它模块（F-G 里解析出的清单），任何函数里都不许写这些根变量 ——
# F-G 只执行到模块加载完，模块函数运行期（例如定时更新检查、实验读写）的改写要靠这一条拦。
# 引擎本身对链上变量的写法由 F-A / F-C 管，这里只查它是否碰 GUI 自己的三个根。
Assert-True ($fgModPaths.Count -eq 3) "anchor: F-B module write scan must cover the 3 modules the GUI dot-sources (found $($fgModPaths.Count))"
foreach ($mod in $fgModPaths) {
  $modNames = $(if ($mod -eq 'scripts\delta-booster.ps1') { $fbGuiOwned } else { $fbRootNames })
  $modAst = Get-FbAst $mod
  $modHits = New-Object System.Collections.Generic.List[string]
  foreach ($n in $modNames) {
    foreach ($w in @(Get-FbWrites $modAst $null $n)) {
      $modHits.Add(('{0} @ {1}: {2}' -f $n, "$((Get-EnclosingFunction $w.Node).Name)", ($w.Node.Extent.Text -replace '\s+', ' ')))
    }
  }
  Assert-True ($modHits.Count -eq 0) ("F-B $mod is dot-sourced into the GUI script scope but writes a state-root variable the GUI owns: [" +
    ($modHits.ToArray() -join '; ') + ']')
}
Assert-True ($fbReadTotal -eq 13) "anchor: F-B expected 13 distinct variable reads on root derivation paths, found $fbReadTotal"
Assert-True ($fbResultTotal -eq 13) "anchor: F-B expected 13 state-root result variables, found $fbResultTotal"
Assert-True ($fcDerivedTotal -eq 16) "anchor: F-C expected 16 derived sub-path sites, found $fcDerivedTotal"

# ----- F-D. C#：根变量 / 派生变量在所在代码块内只许赋值一次；测试钩子的 release 分支必须是 return null -----
function Get-CsBlockEnd([string]$Text, [int]$Start) {
  $depth = 0; $i = $Start
  while ($i -lt $Text.Length) {
    $ch = $Text[$i]
    if ($ch -eq [char]'"') {
      $verbatim = ($i -gt 0 -and $Text[$i - 1] -eq [char]'@')
      $i++
      while ($i -lt $Text.Length) {
        if ($verbatim) { if ($Text[$i] -eq [char]'"') { if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq [char]'"') { $i += 2; continue }; break } }
        else { if ($Text[$i] -eq [char]'\') { $i += 2; continue }; if ($Text[$i] -eq [char]'"') { break } }
        $i++
      }
    } elseif ($ch -eq [char]"'") {
      $i++
      while ($i -lt $Text.Length -and $Text[$i] -ne [char]"'") { if ($Text[$i] -eq [char]'\') { $i++ }; $i++ }
    } elseif ($ch -eq [char]'{') { $depth++ }
    elseif ($ch -eq [char]'}') { if ($depth -eq 0) { return $i }; $depth-- }
    $i++
  }
  $Text.Length
}

$fdVarTotal = 0; $fdHookTotal = 0
$fdDerived = @{}
foreach ($key in @($expectedCsRootSites.Keys)) {
  $fdDerived[$key] = New-Object System.Collections.Generic.List[string]
  $clean = Remove-CSharpComments (Get-RootScanText $key)
  $queue = New-Object System.Collections.Generic.List[object]
  foreach ($m in @([regex]::Matches($clean, '\bPath\.Combine\('))) {
    $callArgs = @(Get-CSharpCallArgs $clean ($m.Index + $m.Length))
    if ($callArgs.Count -lt 2 -or $callArgs[1] -inotmatch '^@?"DeltaForceBooster(?:\\{1,2}[^"]*)?"$') { continue }
    $stmtStart = [Math]::Max([Math]::Max($clean.LastIndexOf(';', $m.Index), $clean.LastIndexOf('{', $m.Index)), $clean.LastIndexOf('}', $m.Index)) + 1
    $lhs = $clean.Substring($stmtStart, $m.Index - $stmtStart)
    $lm = [regex]::Match($lhs, '(?:^|[\s,])([A-Za-z_]\w*)\s*=\s*$')
    if ($lm.Success) { $queue.Add([pscustomobject]@{ Name = $lm.Groups[1].Value; At = $m.Index; DeclAt = $stmtStart + $lm.Groups[1].Index }) }
  }
  for ($qi = 0; $qi -lt $queue.Count; $qi++) {
    $v = $queue[$qi]
    $fdVarTotal++
    $blockEnd = Get-CsBlockEnd $clean $v.At
    $declAt = $v.DeclAt
    $region = $clean.Substring($declAt, $blockEnd - $declAt)
    $assigns = @([regex]::Matches($region, ('(?<![\w.]){0}\s*(?:[-+*/%&|^]|\?\?|<<|>>)?=(?!=)' -f [regex]::Escape($v.Name))))
    $refs = @([regex]::Matches($region, ('\b(?:ref|out)\s+{0}\b' -f [regex]::Escape($v.Name))))
    Assert-True ($assigns.Count -eq 1 -and $refs.Count -eq 0) `
      "F-D $key : C# state path variable '$($v.Name)' is assigned $($assigns.Count) times / passed by ref $($refs.Count) times in its block (must be exactly its one derivation)"
    foreach ($d in @([regex]::Matches($region, ('(?:\b(?:string|var)\s+|,\s*)([A-Za-z_]\w*)\s*=\s*Path\.Combine\(\s*{0}\s*,' -f [regex]::Escape($v.Name))))) {
      $queue.Add([pscustomobject]@{ Name = $d.Groups[1].Value; At = $declAt + $d.Index + $d.Length; DeclAt = $declAt + $d.Groups[1].Index })
      # 派生变量的子路径也记下来（<父变量> >> <其余实参原文>），整表钉死；派生变量自己叫什么不进表（改名不算改路径）
      $dOpen = $declAt + $d.Index + $d.Value.IndexOf('Path.Combine(') + 'Path.Combine('.Length
      $dArgs = @(Get-CSharpCallArgs $clean $dOpen)
      $fdDerived[$key].Add(('{0} >> {1}' -f $v.Name,
        ((@($dArgs | Select-Object -Skip 1) | ForEach-Object { ($_ -replace '\s+', ' ').Trim() }) -join ', ')))
    }
  }
  foreach ($hook in @(@(@($expectedCsRootSites[$key]) | ForEach-Object { [regex]::Matches($_, 'hook:(\w+)') | ForEach-Object { $_.Groups[1].Value } }) + @($(if ($key -eq 'build\setup-wizard.cs') { 'TestRoot' })) |
                     Where-Object { $_ } | Select-Object -Unique)) {
    $fdHookTotal++
    $hm = [regex]::Match($clean, ('static\s+string\s+{0}\(\)\s*\{{(?<body>[^{{}}]*)\}}' -f $hook))
    Assert-True $hm.Success "F-D $key : test hook $hook() not found"
    $body = ($hm.Groups['body'].Value -replace '\s+', ' ').Trim()
    Assert-True ($body -cmatch '^#if DFB_TESTING (?:(?!#).)*#else return null; #endif$') `
      "F-D $key : test hook $hook() must be 'return null' outside DFB_TESTING builds, found [$body]"
  }
}
Assert-True ($fdVarTotal -eq 11) "anchor: F-D expected 11 C# state path variables, found $fdVarTotal"
Assert-True ($fdHookTotal -eq 4) "anchor: F-D expected 4 release-null test hooks, found $fdHookTotal"
# 写入方与读取方必须是同一个文件：安装向导把被隔离的旧备份根记进 legacy-roots 文件，引擎（$script:LegacyRootsFile，
# C1 真跑出来的值）和卸载脚本（$legacyRoots，F-U 真跑出来的值）读它。写成别的名字，还原页与卸载都静默地「没有可还原的」。
$fdLegacyLeaf = '"' + [IO.Path]::GetFileName("$($real.LegacyRootsFile)") + '"'
Assert-True ([string]::Equals([IO.Path]::GetFileName("$($fu.legacyRoots)"), [IO.Path]::GetFileName("$($real.LegacyRootsFile)"), [StringComparison]::Ordinal) -and
             $fdLegacyLeaf -ne '""') 'anchor: F-D the engine LegacyRootsFile and the uninstall $legacyRoots must name the same file'
$fdWizChildren = @($fdDerived['build\setup-wizard.cs'].ToArray() | ForEach-Object { ($_ -split ' >> ', 2)[1] })
Assert-True ($fdWizChildren -ccontains $fdLegacyLeaf) `
  ("F-D build\setup-wizard.cs no longer records legacy backup roots in <ProgramData>\DeltaForceBooster\$($fdLegacyLeaf.Trim('"')), the file the engine " +
   "(`$script:LegacyRootsFile) and the uninstaller (`$legacyRoots) read; its state-root children are [$($fdWizChildren -join '; ')]")
$expectedCsDerived = [ordered]@{
  'build\make-engine-host.ps1::$cs' = @('product >> "session-temp"', 'tempRoot >> session')
  'build\uninstall-host.cs' = @('product >> "uninstall-stage"', 'stage >> "uninstall.ps1"', 'stages >> Guid.NewGuid().ToString("N")')
  'build\setup-wizard.cs' = @('root >> "legacy-roots.json"', 'root >> ".legacy-roots-" + Guid.NewGuid().ToString("N") + ".tmp"')
}
foreach ($key in @($expectedCsDerived.Keys)) {
  $want = @(Get-OrdinalSorted $expectedCsDerived[$key])
  $got = @(Get-OrdinalSorted $fdDerived[$key].ToArray())
  Assert-True ($want.Count -gt 0) "anchor: pinned C# derived sub-path list for $key is empty"
  Assert-True ([string]::Equals(($got -join "`n"), ($want -join "`n"), [StringComparison]::Ordinal)) `
    ("F-D $key : C# sub-paths derived from the state root changed: " + (Get-SiteDiff $want $got))
}

# F-D2：release 构建（不带 -TestBuild）不许定义 DFB_TESTING。上面钉的是测试钩子的 #else 分支必须 return null，
# 这里钉另一半：发布版编译时根本不走 #if DFB_TESTING 分支（否则 DFB_TEST_PROGRAMDATA 之类能重定向状态根）。
# 真跑三份构建脚本里算 define 的那一句；csc 的每一次调用只能经由它拿 define。
# make-engine-host.ps1 没有测试构建（EngineHost 也编译带 #if DFB_TESTING 的 runtime-root-validation.cs）：它的 csc 一个 define 都不许拿。
$fdBuildScripts = [ordered]@{ 'build\make-installer.ps1' = '$defineArgs'; 'build\make-launcher.ps1' = '$defineArgs'; 'build\make-uninstall-host.ps1' = '$defines'
                              'build\make-engine-host.ps1' = $null }
$fdCscTotal = 0
$fdDefProbe = New-Object System.Text.StringBuilder
[void]$fdDefProbe.AppendLine('$probeResult = @{}')
$fdDefAssign = @{}
foreach ($bs in @($fdBuildScripts.Keys)) {
  $bsVar = $fdBuildScripts[$bs]
  $bsAst = Get-FbAst $bs
  $fdDefAssign[$bs] = $null
  if ($bsVar) {
    $bsDefs = @($bsAst.FindAll({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and "$($x.Left)" -ceq $bsVar }, $true))
    Assert-True ($bsDefs.Count -eq 1) "anchor: F-D2 $bs must compute $bsVar exactly once (found $($bsDefs.Count))"
    $fdDefAssign[$bs] = $bsDefs[0]
    foreach ($tb in $false, $true) {
      [void]$fdDefProbe.AppendLine("`$TestBuild = `$$tb")
      [void]$fdDefProbe.AppendLine($bsDefs[0].Extent.Text)
      [void]$fdDefProbe.AppendLine("`$probeResult[$(ConvertTo-PsLiteral "$bs|$tb")] = [string[]]@($bsVar)")
    }
  }
  $bsCsc = @($bsAst.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] -and $x.InvocationOperator -eq 'Ampersand' -and
                                       "$($x.CommandElements[0].Extent.Text)" -ceq '$csc' }, $true))
  Assert-True ($bsCsc.Count -ge 1) "anchor: F-D2 $bs must invoke csc"
  foreach ($cc in $bsCsc) {
    $fdCscTotal++
    $splAll = @($cc.CommandElements | Where-Object { $_ -is [Management.Automation.Language.VariableExpressionAst] -and $_.Splatted })
    $spl = @($splAll | Where-Object { $bsVar -and ('$' + $_.VariablePath.UserPath) -ceq $bsVar })
    $noLiteral = $cc.Extent.Text.IndexOf('DFB_TESTING', [StringComparison]::OrdinalIgnoreCase) -lt 0
    if ($bsVar) {
      Assert-True ($spl.Count -eq 1 -and $noLiteral) `
        ("F-D2 $bs : csc (line $($cc.Extent.StartLineNumber)) must take its defines only from @$($bsVar.Substring(1)) and never spell DFB_TESTING itself: " +
         ($cc.Extent.Text -replace '\s+', ' '))
    } else {
      Assert-True ($splAll.Count -eq 0 -and $noLiteral -and $cc.Extent.Text -notmatch '(?i)[/-](?:define|d):') `
        ("F-D2 $bs : csc (line $($cc.Extent.StartLineNumber)) has no test build and must not take any define (it compiles the #if DFB_TESTING " +
         "hooks of runtime-root-validation.cs): " + ($cc.Extent.Text -replace '\s+', ' '))
    }
  }
  # 其余位置（另一个被 splat 的数组、响应文件……）也不许出现 DFB_TESTING / csc 的 define 开关：只许出现在上面那一句门控赋值里。
  # C# 源码 here-string 里的 #if / #else / #endif 预处理行不算。
  $fdAllowed = $fdDefAssign[$bs]
  $fdHits = New-Object System.Collections.Generic.List[string]
  foreach ($lit in @($bsAst.FindAll({ param($x) $x -is [Management.Automation.Language.StringConstantExpressionAst] -or
                                               $x -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) {
    if ($fdAllowed -and $lit.Extent.StartOffset -ge $fdAllowed.Extent.StartOffset -and $lit.Extent.EndOffset -le $fdAllowed.Extent.EndOffset) { continue }
    $litVal = (@("$($lit.Value)" -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#\s*(?:if|elif|else|endif)\b' }) -join "`n"
    if ($litVal -match '(?i)DFB_TESTING|[/-](?:define|d):') {
      $litText = $lit.Extent.Text -replace '\s+', ' '
      $fdHits.Add("line $($lit.Extent.StartLineNumber): $($litText.Substring(0, [Math]::Min(100, $litText.Length)))")
    }
  }
  Assert-True ($fdHits.Count -eq 0) ("F-D2 $bs : DFB_TESTING or a csc define switch appears outside the -TestBuild-gated define computation, " +
    "so a release build can compile the test hooks: [" + ($fdHits.ToArray() -join '; ') + ']')
}
Assert-True ($fdCscTotal -eq 5) "anchor: F-D2 expected 5 csc invocations in the 4 build scripts, found $fdCscTotal"
# 新增一份编译 C# 的构建脚本必须进上面的表（它可能同样编译带测试钩子的源码）
foreach ($fdFile in @(Get-ChildItem -LiteralPath (Join-Path $root 'build') -Filter '*.ps1' -File)) {
  $fdRel = 'build\' + $fdFile.Name
  if ($fdBuildScripts.Contains($fdRel)) { continue }
  $fdText = [IO.File]::ReadAllText($fdFile.FullName, [Text.Encoding]::UTF8)
  Assert-True ($fdText -notmatch '(?i)\bcsc\b|DFB_TESTING') `
    "anchor: F-D2 $fdRel compiles C# or mentions DFB_TESTING but is not in the F-D2 build-script table (add it with its -TestBuild-gated define variable)"
}
[void]$fdDefProbe.AppendLine('$probeResult')
$fdDefs = Invoke-RootProbe $fdDefProbe.ToString() 'F-D2 build-script define computations (TestBuild off / on)'
foreach ($bs in @($fdBuildScripts.Keys | Where-Object { $fdBuildScripts[$_] })) {
  foreach ($tb in $false, $true) {
    Assert-True ($fdDefs.ContainsKey("$bs|$tb")) "anchor: F-D2 $bs define computation (TestBuild=$tb) did not run"
    $got = (@($fdDefs["$bs|$tb"]) | Where-Object { $_ }) -join ' '
    $want = $(if ($tb) { '/define:DFB_TESTING' } else { '' })
    Assert-True ([string]::Equals($got, $want, [StringComparison]::Ordinal)) $(if ($tb) {
        "F-D2 $bs : a -TestBuild build must define exactly /define:DFB_TESTING, got [$got]" } else {
        "F-D2 $bs : a release build (no -TestBuild) must not define DFB_TESTING (the test hooks would honour DFB_TEST_* path overrides), got [$got]" })
  }
}

# B. 冻结根名逐值钉死（不是数出现次数）。
#    旧做法按文件数 'DeltaForceBooster' 子串出现了几次：改成 'DeltaForceBooster2' 或 'Old\DeltaForceBooster'，
#    子串照样出现一次，计数不变（独立复核 IF-1 实测：卸载脚本、诊断导出、安装向导都能这样改名而全绿；
#    同一文件里别处还有这个词，Contains 式的 Assert-Frozen 也照样满足）。
#    现在收集每个文件里「值里含冻结根名」的每一个字面量的**完整值**，排序后与钉死表逐项比对：
#      * PowerShell：非裸词的字符串常量与可展开字符串（注释不进 AST）；
#      * 内嵌的其它语言按它自己的语法递归（卸载脚本 here-string 是 PowerShell；EngineHost / launcher /
#        卸载宿主程序集属性的 here-string 是 C#），不把整段 here-string 当成一个值；
#      * C#：去掉注释后的字符串字面量原文（含引号与 @ 前缀）。
#    值里的换行记成 <CR>/<LF>。任何一个值改名、加前后缀、增删都会红，失败消息只列差异行。
#    这是「有人看过才能改」的表：正当地改了带这个词的提示文案，就把对应那一行一起改掉。
$script:FrozenEmbedded = @{
  'build\make-installer.ps1' = @{ '$uninstallPs' = 'ps' }
  'build\make-engine-host.ps1' = @{ '$cs' = 'cs' }
  'build\make-launcher.ps1' = @{ '$cs' = 'cs' }
  'build\make-uninstall-host.ps1' = @{ '$commonAssembly' = 'cs' }
}
$script:FrozenLiteralPredicate = New-FbTypePredicate @([Management.Automation.Language.StringConstantExpressionAst],
  [Management.Automation.Language.ExpandableStringExpressionAst])

function Format-FrozenValue([string]$Value) { $Value.Replace("`r", '<CR>').Replace("`n", '<LF>') }

function Get-CSharpFrozenLiterals([string]$Code) {
  $rx = '@"(?:[^"]|"")*"|"(?:[^"\\\r\n]|\\.)*"|''(?:[^''\\\r\n]|\\.)+'''
  foreach ($m in [regex]::Matches((Remove-CSharpComments $Code), $rx)) {
    if ($m.Value.StartsWith("'")) { continue }
    if ($m.Value.IndexOf('DeltaForceBooster', [StringComparison]::OrdinalIgnoreCase) -ge 0) { Format-FrozenValue $m.Value }
  }
}

function Get-PsFrozenLiterals($Ast, [hashtable]$Embedded, [string]$What) {
  $out = New-Object System.Collections.Generic.List[string]
  $holders = New-Object System.Collections.Generic.List[object]
  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($lit in $Ast.FindAll($script:FrozenLiteralPredicate, $true)) {
    if ($lit.Value.IndexOf('DeltaForceBooster', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $p = $lit.Parent
    if ($p -is [Management.Automation.Language.CommandExpressionAst]) { $p = $p.Parent }
    if ($p -is [Management.Automation.Language.AssignmentStatementAst] -and $Embedded.ContainsKey("$($p.Left)")) {
      $holders.Add([pscustomobject]@{ Var = "$($p.Left)"; Lit = $lit })
    } elseif (-not ($lit -is [Management.Automation.Language.StringConstantExpressionAst] -and $lit.StringConstantType -eq 'BareWord')) {
      $candidates.Add($lit)
    }
  }
  foreach ($k in @($Embedded.Keys)) {
    $n = @($holders.ToArray() | Where-Object { $_.Var -ceq $k }).Count
    Assert-True ($n -eq 1) "anchor: $What must embed $k as exactly one literal (the frozen-name scan recurses into it), found $n"
  }
  foreach ($h in $holders.ToArray()) {
    $inner = $(if ($Embedded[$h.Var] -eq 'ps') { Get-PsFrozenLiterals (Get-ParsedAst $h.Lit.Value "$What::$($h.Var)") @{} "$What::$($h.Var)" }
               else { Get-CSharpFrozenLiterals $h.Lit.Value })
    foreach ($v in @($inner)) { if ($null -ne $v) { $out.Add("$($h.Var)> $v") } }
  }
  foreach ($lit in $candidates.ToArray()) {
    $inside = $false
    foreach ($h in $holders.ToArray()) {
      if ($lit.Extent.StartOffset -ge $h.Lit.Extent.StartOffset -and $lit.Extent.EndOffset -le $h.Lit.Extent.EndOffset) { $inside = $true; break }
    }
    if (-not $inside) { $out.Add((Format-FrozenValue $lit.Value)) }
  }
  $out.ToArray()
}

function Get-FrozenLiterals([string]$Rel) {
  $raw = Get-Source $Rel
  if ($Rel.EndsWith('.cs', [StringComparison]::OrdinalIgnoreCase)) { return @(Get-CSharpFrozenLiterals $raw) }
  $embedded = $(if ($script:FrozenEmbedded.ContainsKey($Rel)) { $script:FrozenEmbedded[$Rel] } else { @{} })
  # 与 D / F-B / F-D2 共用同一份解析结果（Get-FbAst 按文件缓存；GUI 有 600KB，不重复解析）
  @(Get-PsFrozenLiterals (Get-FbAst $Rel) $embedded $Rel)
}

$expectedFrozenLiterals = [ordered]@{
  'scripts\delta-booster.ps1' = @(
    'DeltaForceBooster',
    'DeltaForceBooster',
    'DeltaForceBooster',
    'DeltaForceBooster',
    'DeltaForceBooster one-time power override restore',
    'DeltaForceBooster-PowerPlanLock',
    'DeltaForceBooster-RestorePowerOverride',
    'DeltaForceBooster\session-temp\$session',
    'Global\DeltaForceBooster.Engine',
    '^\.DeltaForceBooster\.migrated-[0-9A-Fa-f]{32}$',
    'gui\DeltaForceBooster-GUI.ps1',
    '由 DeltaForceBooster 创建，还原优化后如不需要可手动删除')
  'scripts\user-context-worker.ps1' = @(
    'DeltaForceBooster',
    '^DeltaForceBooster\.UserWorker\.[0-9a-fA-F]{32}$')
  'scripts\export-diagnostics.ps1' = @(
    'DeltaForceBooster',
    'DeltaForceBooster-GUI',
    'DeltaForceBooster|EngineHost|优化工具|powershell',
    'gui\DeltaForceBooster-GUI.ps1')
  'scripts\tuning-experiment.ps1' = @(
    'DeltaForceBooster\backup')
  'gui\DeltaForceBooster-GUI.ps1' = @(
    'DeltaForceBooster',
    'DeltaForceBooster v$script:DisplayVersion｜会话开始：$(Get-Date -Format ''yyyy-MM-dd HH:mm:ss'')<CR><LF>',
    'DeltaForceBooster 诊断报告',
    'DeltaForceBooster\backup',
    'DeltaForceBooster\diagnostics',
    'DeltaForceBooster\session-temp\$session',
    'DeltaForceBooster\session-temp\$sessionText',
    'Local\DeltaForceBooster.GUI',
    'Local\DeltaForceBooster.OptimizationContext',
    'Local\DeltaForceBooster.PerformanceSessions',
    '^DeltaForceBooster\.Engine\.[0-9a-fA-F]{32}$',
    '写不进 %ProgramData%\DeltaForceBooster。常见于杀毒软件拦截，或该目录被上一次安装留下了错误权限。')
  'build\make-installer.ps1' = @(
    '$uninstallPs> DeltaForceBooster',
    '$uninstallPs> DeltaForceBooster',
    '$uninstallPs> DeltaForceBooster',
    '$uninstallPs> DeltaForceBooster',
    '$uninstallPs> DeltaForceBooster 卸载',
    '$uninstallPs> DeltaForceBooster 卸载',
    '$uninstallPs> DeltaForceBooster 卸载',
    '$uninstallPs> DeltaForceBooster 卸载',
    '$uninstallPs> DeltaForceBooster 卸载',
    '$uninstallPs> DeltaForceBooster 卸载',
    '$uninstallPs> DeltaForceBooster 卸载',
    '$uninstallPs> DeltaForceBooster-PowerPlanLock',
    '$uninstallPs> DeltaForceBooster-PowerPlanLock',
    '$uninstallPs> DeltaForceBooster-PowerPlanLock-$taskSuffix',
    '$uninstallPs> DeltaForceBooster\uninstall-stage',
    '$uninstallPs> ProductId=DeltaForceBooster',
    '$uninstallPs> ProductId=DeltaForceBooster',
    '$uninstallPs> ^DeltaForceBooster-PowerPlanLock(-[0-9A-Fa-f]{12})?$',
    '$uninstallPs> · 电源方案锁定计划任务删除失败，请在「任务计划程序」中手动删除 DeltaForceBooster-PowerPlanLock。',
    'DeltaForceBooster-Setup-v$displayVer-TEST.exe',
    'DeltaForceBooster-Setup-v$displayVer.exe',
    'DeltaForceBooster-Setup-v$displayVer.exe',
    'SchemaVersion=2<LF>ProductId=DeltaForceBooster<LF>LauncherSha256=$launcherSha<LF>EngineHostSha256=$engineHostSha<LF>',
    'gui\DeltaForceBooster-GUI.ps1',
    'gui\DeltaForceBooster-GUI.ps1',
    'https://github.com/$releaseRepo/releases/download/v$ver/DeltaForceBooster-Setup.exe')
  'build\make-engine-host.ps1' = @(
    '$cs> "DeltaForceBooster 开源项目"',
    '$cs> "DeltaForceBooster"',
    '$cs> "DeltaForceBooster"',
    '$cs> "DeltaForceBooster-GUI.ps1"',
    '$cs> "DeltaForceBooster.Engine."',
    '$cs> "DeltaForceBooster.Launch."',
    '$cs> "DeltaForceBooster.Launch."',
    '$cs> "ProductId=DeltaForceBooster"',
    '$cs> @"Global\DeltaForceBooster.LaunchSession"',
    'gui\DeltaForceBooster-GUI.ps1',
    'gui\DeltaForceBooster-GUI.ps1')
  'build\make-launcher.ps1' = @(
    '$cs> "DeltaForceBooster 开源项目"',
    '$cs> "DeltaForceBooster"',
    '$cs> "DeltaForceBooster-Tests"',
    '$cs> "DeltaForceBooster-Tests"',
    '$cs> "DeltaForceBooster.Launch."',
    '$cs> "DeltaForceBooster.UserWorker."',
    '$cs> "ProductId=DeltaForceBooster"',
    '$cs> @"Global\DeltaForceBooster.LaunchSession"',
    '$cs> @"Local\DeltaForceBooster.LaunchInstance"',
    'gui\DeltaForceBooster-GUI.ps1',
    'gui\DeltaForceBooster-GUI.ps1')
  'build\make-uninstall-host.ps1' = @(
    '$commonAssembly> "DeltaForceBooster 开源项目"',
    '$commonAssembly> "DeltaForceBooster"')
  'build\setup-wizard.cs' = @(
    '".DeltaForceBooster.migrated-"',
    '"DeltaForceBooster launcher"',
    '"DeltaForceBooster 卸载"',
    '"DeltaForceBooster 图形界面"',
    '"DeltaForceBooster 开源项目"',
    '"DeltaForceBooster 开源项目"',
    '"DeltaForceBooster 开源项目"',
    '"DeltaForceBooster 更新检查模块"',
    '"DeltaForceBooster 核心脚本"',
    '"DeltaForceBooster 诊断脚本"',
    '"DeltaForceBooster"',
    '"DeltaForceBooster"',
    '"DeltaForceBooster"',
    '"DeltaForceBooster"',
    '"DeltaForceBooster"',
    '"DeltaForceBooster"',
    '"DeltaForceBooster"',
    '"DeltaForceBooster-GUI.ps1"',
    '"DeltaForceBooster-GUI.ps1"',
    '"DeltaForceBooster-Tests"',
    '"gui\\DeltaForceBooster-GUI.ps1"',
    '"传入目录不是可识别的旧版 DeltaForceBooster："',
    '"其他盘仅支持磁盘根目录下的一级受保护安装目录，例如 D:\\DeltaForceBooster"',
    '"现有一级目录不是已验证的 DeltaForceBooster 安装锚点（缺少 anchor.identity）："',
    '"目标目录非空且不是可验证的 DeltaForceBooster 安装："',
    '"目标目录非空且不是可验证的 DeltaForceBooster 安装："',
    '"系统盘自动使用 Program Files；其他固定 NTFS 盘自动使用盘符根目录下的 DeltaForceBooster 保护目录，程序代码位于 app 子目录。只有点击「开始安装」后才会请求 UAC。"',
    '@"^\.DeltaForceBooster\.migrated-[0-9a-fA-F]{32}$"')
  'build\uninstall-host.cs' = @(
    '"DeltaForceBooster"',
    '"DeltaForceBooster.Uninstall."',
    '"DeltaForceBooster.Uninstall."',
    '"ProductId=DeltaForceBooster"',
    '@"Global\DeltaForceBooster.LaunchSession"')
  'build\uninstall-launcher.cs' = @(
    '"DeltaForceBooster"',
    '"DeltaForceBooster.Uninstall."',
    '@"Global\DeltaForceBooster.LaunchSession"')
  'build\runtime-root-validation.cs' = @(
    '"DeltaForceBooster-Tests"',
    '"ProductId=DeltaForceBooster"')
}
$frozenTotal = 0
foreach ($rel in @($expectedFrozenLiterals.Keys)) {
  $want = @(Get-OrdinalSorted $expectedFrozenLiterals[$rel])
  Assert-True ($want.Count -gt 0) "anchor: pinned frozen-literal list for $rel is empty"
  $got = @(Get-OrdinalSorted @(Get-FrozenLiterals $rel))
  $frozenTotal += $got.Count
  Assert-True ([string]::Equals(($got -join "`n"), ($want -join "`n"), [StringComparison]::Ordinal)) `
    ("B $rel : literal values containing the frozen root name changed (renamed, prefixed, suffixed, added or removed): " + (Get-SiteDiff $want $got))
}
Assert-True ($frozenTotal -eq 119) "anchor: expected 119 literals containing the frozen root name in total, found $frozenTotal"

# ---------- 2. 备份完整性密钥与签名备份的位置约束 ----------
$engine = Get-Source 'scripts\delta-booster.ps1'
Assert-True ($engine.Contains('Join-Path $script:ProgramDataRoot ''backup.key''')) 'backup.key 必须与备份同根 —— 分开存放会让整树迁移丢掉密钥，旧备份一律报「文件可能已被修改」'
Assert-True ($engine.Contains('if (-not $isProtected) { throw ''带完整性签名的新备份必须位于受保护备份目录'' }')) '签名备份的位置约束被改动了。它意味着：状态根一旦改名，存量用户的备份不是被跳过而是直接抛异常'

# ---------- 3. 计划任务前缀（写进了备份文档并被白名单校验）----------
Assert-True ($engine.Contains('$script:LockTaskPrefix = ''DeltaForceBooster-PowerPlanLock''')) '电源锁定任务前缀被改。含 sched op 的历史备份会过不了 Assert-BackupOperation 的白名单'
Assert-True ($engine -match "'sched'\s*\{[\s\S]{0,240}LockTaskPrefix") '备份 sched op 的白名单不再引用 LockTaskPrefix —— 两者必须同源，否则改一处就静默作废历史备份'
Assert-True ($engine.Contains('$script:PowerCleanupTaskPrefix = ''DeltaForceBooster-RestorePowerOverride''')) '一次性电源恢复任务前缀被改。旧任务会对新版隐形，卸载器也删不掉'
Assert-True ((Get-Source 'build\make-installer.ps1').Contains('''DeltaForceBooster-PowerPlanLock''')) '卸载器的任务清理清单与引擎的任务前缀脱钩了'

# ---------- 4. 工具自建电源方案名 ----------
# 这是用户电源选项里已经存在的一个方案的名字，不是产品文案。
Assert-True ($engine.Contains('$script:ToolSchemeName = ''三角洲优化 · 卓越性能''')) '工具电源方案名被改。旧方案不再被认领，会重复建方案，深度调优也会被闸门拦死'
Assert-True ($engine.Contains('-ceq $script:ToolSchemeName')) '方案名比对不再是大小写精确的 -ceq —— 放宽会误认用户自建的同名方案'

# ---------- 5. 内核对象名 ----------
Assert-True ($engine.Contains('$script:EngineMutexName = ''Global\DeltaForceBooster.Engine''')) '引擎互斥体改名 = 新旧两个提权引擎可同时改注册表/电源/BCD，各写一半的写前日志'
foreach ($spec in @(
  @{ File = 'build\make-launcher.ps1';       Literal = 'Global\DeltaForceBooster.LaunchSession'; Why = '卸载器靠它判断主程序是否在运行' }
  @{ File = 'build\make-engine-host.ps1';    Literal = 'Global\DeltaForceBooster.LaunchSession'; Why = '同上，EngineHost 侧' }
  @{ File = 'build\uninstall-host.cs';       Literal = 'Global\DeltaForceBooster.LaunchSession'; Why = '同上，卸载宿主侧' }
  @{ File = 'build\uninstall-launcher.cs';   Literal = 'Global\DeltaForceBooster.LaunchSession'; Why = '同上，卸载启动器侧' }
  @{ File = 'build\make-launcher.ps1';       Literal = 'Local\DeltaForceBooster.LaunchInstance'; Why = '启动器单实例标记' }
  @{ File = 'gui\DeltaForceBooster-GUI.ps1'; Literal = 'Local\DeltaForceBooster.GUI';            Why = 'GUI 单实例标记' }
)) { Assert-Frozen $spec.Literal $spec.Why @($spec.File) }

# ---------- 6. 跨进程管道名（名字写进了正则，漏一侧就是启动失败）----------
$gui = Get-Source 'gui\DeltaForceBooster-GUI.ps1'
Assert-True ($gui.Contains('^DeltaForceBooster\.Engine\.[0-9a-fA-F]{32}')) 'GUI 侧的控制管道名正则被改。生产方在 EngineHost，两侧必须同步'
Assert-True ((Get-Source 'build\make-engine-host.ps1').Contains('"DeltaForceBooster.Engine." + RandomHex()')) 'EngineHost 侧的控制管道名被改，与 GUI 的正则脱钩'
Assert-True ((Get-Source 'scripts\user-context-worker.ps1').Contains('^DeltaForceBooster\.UserWorker\.[0-9a-fA-F]{32}')) '原用户 worker 的回复管道名正则被改'
Assert-True ((Get-Source 'build\make-launcher.ps1').Contains('"DeltaForceBooster.UserWorker." + RandomHex()')) 'launcher 侧的 worker 管道名与 worker 的正则脱钩'

# ---------- 7. 安装身份闸门 ----------
# AssemblyProduct 不只是元数据：setup-wizard.cs 拿 PE 的 ProductName 和 InstallProductId
# 做 Ordinal 比对，改了会让存量用户的覆盖安装与 D 盘锚点识别永久失败。
foreach ($f in 'build\make-launcher.ps1','build\make-engine-host.ps1','build\make-uninstall-host.ps1','build\setup-wizard.cs') {
  Assert-Frozen '[assembly: AssemblyProduct("DeltaForceBooster")]' 'PE 的 ProductName 是安装身份闸门的比对对象' @($f)
}
Assert-Frozen 'const string InstallProductId = "DeltaForceBooster";' '覆盖安装与锚点身份' @('build\setup-wizard.cs')
foreach ($f in 'build\make-launcher.ps1','build\make-engine-host.ps1','build\uninstall-host.cs','build\runtime-root-validation.cs') {
  Assert-Frozen 'ProductId=DeltaForceBooster' '各进程读取 install.identity 时的产品身份行' @($f)
}
Assert-Frozen '''ProductId=DeltaForceBooster''' '卸载器 here-string 里的身份校验' @('build\make-installer.ps1')

# AssemblyCompany 和 AssemblyProduct 一样是闸门，不是元数据：setup-wizard.cs 用
# StringComparison.Ordinal 把 PE 的 CompanyName 与这个字面量逐字比对（两处），
# 不一致就拒绝把它当成本产品的文件。改名时它很容易被当成「品牌文案」顺手换掉，
# 而失败发生在**安装阶段**，本地构建-运行一遍根本碰不到。
foreach ($f in 'build\make-launcher.ps1','build\make-engine-host.ps1','build\make-uninstall-host.ps1','build\setup-wizard.cs') {
  Assert-Frozen '[assembly: AssemblyCompany("DeltaForceBooster 开源项目")]' 'PE 的 CompanyName 是安装向导的身份闸门' @($f)
}
Assert-True ((@([regex]::Matches((Get-Source 'build\setup-wizard.cs'),
  [regex]::Escape('!string.Equals(vi.CompanyName, "DeltaForceBooster 开源项目", StringComparison.Ordinal)')))).Count -eq 2) `
  '安装向导里比对 CompanyName 的两处校验被改动或删除了'

# ---------- 7b. 上游版权不得被移除 ----------
# 本分支是 Leonard8818/-Delta-Force-Graphics-Optimizer 的 fork，绝大部分代码仍出自上游。
# MIT 明确要求「上述版权声明与本许可声明须包含在软件的所有副本或实质部分中」——
# 删掉上游那一行不是改名，是许可违规。这里连同本分支自己的版权行一起钉住。
$license = Get-Source 'LICENSE'
foreach ($line in 'Copyright (c) 2026 Leonard8818', 'Copyright (c) 2026 FUDAHA99') {
  Assert-True ($license.Contains($line)) "LICENSE 少了一行版权声明：$line"
}
Assert-True ($license.Contains('The above copyright notice and this permission notice shall be included in all')) `
  'LICENSE 的 MIT 正文被改动了'
foreach ($f in 'build\make-launcher.ps1','build\make-engine-host.ps1','build\make-uninstall-host.ps1','build\setup-wizard.cs') {
  Assert-Frozen '[assembly: AssemblyCopyright("MIT License · Copyright (c) 2026 Leonard8818, FUDAHA99")]' `
    '发布二进制的版权字段必须同时写明上游与本分支' @($f)
}
# SKILL.md 被设计成可以脱离仓库被 Agent 远程单独读取（README 里就给了 raw 地址）。
# 那种场景下读者拿不到 README、NOTICE 或免责声明，所以「非官方」必须写在它自己里。
$skill = Get-Source 'SKILL.md'
foreach ($skillNeedle in '非官方', '腾讯') {
  Assert-True ($skill.Contains($skillNeedle)) `
    "SKILL.md 缺少非官方声明：$skillNeedle（它会被远程单独读取，拿不到其他文件）"
}

$notice = Get-Source 'NOTICE.md'
foreach ($needle in '这是一个分支（fork）', '上游作者不对本分支负责', 'Leonard8818/-Delta-Force-Graphics-Optimizer') {
  Assert-True ($notice.Contains($needle)) "NOTICE.md 缺少分支归属说明：$needle"
}
# 上游的服务端布局与官网不属于本分支：这几句留着就是在说假话
foreach ($f in 'README.md','CONTRIBUTING.md') {
  # 上游官网的域名不再写在这里：它已从全部历史里抹掉，而把第三方的
  # 商业站点写进一个公开仓库只为了断言它不存在，本身就是在发布它。
  # 「官网」二字不能禁：源码里还有大量「三角洲官网视觉基准」这类指游戏官网的正当说法。
  foreach ($stale in '数据接收服务', '运营看板') {
    Assert-True (-not (Get-Source $f).Contains($stale)) "$f 里还留着上游专有的说法：$stale（本分支没有服务端，也没有官网）"
  }
}
# 发布二进制里那几条**失败路径的恢复指引**同样不能指向「官网」——那是用户在
# 「程序文件不完整」「更新包复验失败」时看到的唯一出路，而本分支没有官网；
# 他照着去搜，搜到的是上游那一套（遥测、静默安装的内核驱动、上游更新源）。
# 只禁这两个短语，不禁「官网」二字：源码里还有大量「三角洲官网视觉基准」这类
# 指游戏官网的注释，那些是对的。
foreach ($f in 'build\make-launcher.ps1','build\make-engine-host.ps1','build\setup-wizard.cs',
               'build\make-installer.ps1','scripts\updater.ps1') {
  foreach ($stale in '官网重新安装', '从官网下载') {
    Assert-True (-not (Get-Source $f).Contains($stale)) `
      "$f 的失败提示仍把用户指向「官网」，而本分支没有官网：$stale"
  }
}

# ---------- 8. 已写在用户磁盘上的目录 schema ----------
Assert-True ($engine.Contains('^\.DeltaForceBooster\.migrated-')) '旧根隔离目录名 schema 被改。读侧改了就再也认不出用户盘上已有的那些目录'
Assert-True ((Get-Source 'build\setup-wizard.cs').Contains('".DeltaForceBooster.migrated-"')) '写侧的隔离目录名与读侧脱钩'

# ---------- 9. payload 文件名 ----------
# 被多套哈希白名单钉住，漏改会让构建大声失败 —— 但卸载器 here-string 里那两处
# 没有构建期保护，漏改只会在用户卸载时静默跳过还原。
foreach ($f in 'build\make-launcher.ps1','build\make-engine-host.ps1','build\make-installer.ps1') {
  Assert-Frozen 'gui\DeltaForceBooster-GUI.ps1' '启动器/宿主哈希白名单里的 GUI 路径' @($f)
}
$mk = Get-Source 'build\make-installer.ps1'
Assert-True ($mk.Contains('Join-Path $dest ''scripts\delta-booster.ps1''')) '卸载器 here-string 里的引擎路径 —— 这里没有构建期保护，漏改会让卸载时的还原静默失效'
Assert-True ($mk.Contains('Join-Path $dest ''启动优化工具.exe''')) '卸载器 here-string 里的启动器路径，同上'

# ---------- 10. 环境变量前缀 ----------
# 不落盘、用户不可见、改名收益为零；但要求编译产物与 PS 文件原子同步，
# 漏一处的表现是「软件完全打不开」，而启动失败提示会把用户指向完全错误的方向。
$hostSrc = Get-Source 'build\make-engine-host.ps1'
foreach ($name in 'DFB_ENGINE_HOST_SESSION','DFB_ENGINE_HOST_PID','DFB_LAUNCHER_PID','DFB_ORIGINAL_USER_SID','DFB_ORIGINAL_LOCALAPPDATA','DFB_REPAIR_ONLY','DFB_ENGINE_CONTROL_PIPE') {
  Assert-True ($gui.Contains($name)) "GUI 启动闸门要求的环境变量被改名：$name"
  Assert-True ($hostSrc.Contains($name)) "EngineHost 侧未设置该环境变量：$name"
}

# ---------- 11. 游戏词汇（与商标风险无关，改了就是功能坏掉）----------
foreach ($spec in @(
  @{ File = 'scripts\delta-booster.ps1';     Literal = 'DeltaForceClient-Win64-Shipping.exe'; Why = '游戏主程序名。DeltaForce 是 DeltaForceBooster 的前缀子串，全局替换会打中它' }
  @{ File = 'scripts\delta-booster.ps1';     Literal = 'DeltaForceClient.exe';                Why = '同上，IFEO 备份白名单里的进程名' }
  @{ File = 'scripts\delta-booster.ps1';     Literal = 'DeltaForce.exe';                      Why = '同上' }
  @{ File = 'gui\DeltaForceBooster-GUI.ps1'; Literal = '三角洲行动';                          Why = '免责对象与游戏指代。产品自称去掉三角洲后，这是唯一说明「给哪个游戏用、与官方什么关系」的地方' }
  @{ File = 'DISCLAIMER.md';                 Literal = '《三角洲行动》';                      Why = '免责声明必须点明与腾讯及官方无关' }
)) { Assert-Frozen $spec.Literal $spec.Why @($spec.File) }

# ---------- 12. 显示层改名之后，读取侧必须继续认旧名 ----------
# 窗口标题是跨进程 Ordinal 比对的：启动器靠它激活已有窗口，安装器靠它在覆盖
# 文件之前关掉正在跑的旧实例。只认新标题的后果不是"少激活一个窗口"，而是
# 安装器认为"没有实例需要关"，然后在旧引擎正在改系统的途中覆盖文件 ——
# setup-wizard.cs 的 CloseRunningBooster 上方那段注释说的正是绝不能发生这种事。
$launcherSrc = Get-Source 'build\make-launcher.ps1'
$wizard = Get-Source 'build\setup-wizard.cs'
Assert-True ($launcherSrc.Contains('const string MainWindowTitle = "帧率优化助手";')) '启动器的主窗口标题没有切到新名字'
Assert-True ($launcherSrc.Contains('const string LegacyMainWindowTitle = "三角洲行动 · 画面优化助手";')) '启动器丢掉了旧窗口标题 —— 升级期间会认不出还开着的旧版主窗口'
Assert-True ($launcherSrc.Contains('LegacyMainWindowTitle, StringComparison.Ordinal)')) '启动器定义了旧标题却没有真的拿它做比对'
Assert-True ($wizard.Contains('t != "帧率优化助手" && t != "三角洲行动 · 画面优化助手"')) '安装器的 CloseRunningBooster 不再同时匹配新旧标题 —— 用户开着旧版装新版时会被静默覆盖'

# GUI 两个窗口的标题必须逐字一致：上面两个消费方都是精确比对。
Assert-True ((([regex]::Matches($gui, [regex]::Escape('Title="帧率优化助手"'))).Count) -eq 2) 'GUI 的主窗口与对话框标题不再都是"帧率优化助手" —— 跨进程比对是精确匹配'

# 快捷方式：创建侧用新名，删除侧必须是新旧并集，否则用户机器上会留死链和双份图标。
Assert-True ($wizard.Contains('MainLnkNames = { "帧率优化助手.lnk", "三角洲行动优化助手.lnk" }')) '快捷方式清理清单丢掉了旧名字'
Assert-True ($wizard.Contains('MenuDirNames = { "帧率优化助手", "DeltaForceBooster" }')) '开始菜单目录清理清单丢掉了旧目录名'
Assert-True ($wizard.Contains('Shortcut.ReadTarget(lnk)')) '清理旧快捷方式时没有解析目标 —— 按名字盲删等于替用户赌桌面上没有同名的别的东西'
$mkInstaller = Get-Source 'build\make-installer.ps1'
Assert-True ($mkInstaller.Contains("'帧率优化助手.lnk','三角洲行动优化助手.lnk','卸载优化助手.lnk'")) '卸载器的开始菜单清理清单不是新旧并集'
Assert-True ($mkInstaller.Contains("'帧率优化助手','DeltaForceBooster' | ForEach-Object")) '卸载器的开始菜单目录清理清单不是新旧并集'
$uninstLauncher = Get-Source 'build\uninstall-launcher.cs'
Assert-True ($uninstLauncher.Contains('"帧率优化助手.lnk", "三角洲行动优化助手.lnk"')) '原用户卸载入口的快捷方式清理清单不是新旧并集'

# AssemblyProduct 冻结但 AssemblyTitle/Description 必须已切换 —— UAC 同意框显示的是
# FileDescription，它必须和用户刚点的那个窗口同名，否则就是反钓鱼断言失守。
Assert-True ($launcherSrc.Contains('[assembly: AssemblyTitle("帧率优化助手")]')) '启动器的 AssemblyTitle 没切到新名字'
Assert-True ((Get-Source 'build\make-engine-host.ps1').Contains('[assembly: AssemblyDescription("帧率优化助手 管理员助手")]')) 'EngineHost 的 FileDescription 没切到新名字 —— 这是 UAC 同意框上显示的文字'

# 安装向导必须有免责声明：改名后产品自称里不再有游戏名，这是用户安装前唯一的正式说明。
foreach ($needle in '与腾讯公司及《三角洲行动》官方没有任何关系', '不是官方产品') {
  Assert-True ($wizard.Contains($needle)) "安装向导缺少免责声明：$needle"
}
# DumpStrings 是硬编码副本，不从控件读；漏改不会报错，只会静默产出说谎的自检文件。
Assert-True ($wizard.Contains('sb.AppendLine("欢迎标题=欢迎安装 帧率优化助手");')) 'DumpStrings 里的欢迎标题副本与实际控件文案脱钩了'

Write-Host "identity freeze tests passed: $script:Assertions assertions"
