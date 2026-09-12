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

Assert-Frozen "'DeltaForceBooster'" '受保护状态根：备份、backup.key、legacy-roots、per-SID 配置全在这下面' @('scripts\delta-booster.ps1','scripts\user-context-worker.ps1','build\make-installer.ps1')
Assert-Frozen '"DeltaForceBooster"' '同上，C# 侧' @('build\setup-wizard.cs','build\uninstall-host.cs','build\make-engine-host.ps1')
foreach ($f in 'scripts\export-diagnostics.ps1', 'scripts\tuning-experiment.ps1', 'gui\DeltaForceBooster-GUI.ps1') {
  Assert-Frozen 'DeltaForceBooster' '状态根派生路径' @($f)
}

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
$notice = Get-Source 'NOTICE.md'
foreach ($needle in '这是一个分支（fork）', '上游作者不对本分支负责', 'Leonard8818/-Delta-Force-Graphics-Optimizer') {
  Assert-True ($notice.Contains($needle)) "NOTICE.md 缺少分支归属说明：$needle"
}
# 上游的服务端布局与官网不属于本分支：这几句留着就是在说假话
foreach ($f in 'README.md','CONTRIBUTING.md') {
  foreach ($stale in '数据接收服务', '运营看板', 'upstream-site.invalid') {
    Assert-True (-not (Get-Source $f).Contains($stale)) "$f 里还留着上游专有的说法：$stale（本分支没有服务端，也没有官网）"
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
