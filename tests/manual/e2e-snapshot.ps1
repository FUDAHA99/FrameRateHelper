<#
  e2e-snapshot.ps1 —— 「优化前 / 全部复原后」系统状态快照与比对（手工端到端测试，严格只读）

  测试员在测试机上用管理员身份运行：
    0. 测试期间先暂停 Windows 更新（设置 → Windows 更新 → 暂停更新）。重启时装上的累积更新会改变
       系统版本号（UBR），比对会因此判失败——系统版本变了，差异就不一定来自本软件。
    1. 优化前拍一次：      ... -File e2e-snapshot.ps1 -Out D:\e2e\before.json
    2. 在软件里执行优化 →「全部复原」→ 重启电脑
    3. 重启后再拍并比对：  ... -File e2e-snapshot.ps1 -Out D:\e2e\after.json -Compare D:\e2e\before.json
       每处不同打印一行（是什么、之前、之后）；同样的内容以 UTF-8 写进 after.json 的 Comparison 段，
       控制台不是中文代码页、或输出被重定向成乱码时，以那一段为准。每行行首另有英文标记（FAIL / EXPECTED /
       N/A / INFO），末尾还有一行英文结论。
       退出码：0 = 除预期差异外完全一致；1 = 有不一致；2 = 参数错误或脚本自身无法运行。-Out 文件已存在时拒绝覆盖。
  HKCU 下的项目按「登录这个桌面的用户」读取（软件只改这个用户的配置）：管理员身份由另一个账户批准时，
  脚本用本会话 explorer.exe 的所有者找到登录用户，读 HKEY_USERS\<SID>；也可以用 -UserSid 明确指定。
  可选：-EnginePath 指定已安装的 delta-booster.ps1（默认依次找 %ProgramFiles%\DeltaForceBooster\scripts\、
        各固定盘 \DeltaForceBooster\app\scripts\、本仓库 ..\..\scripts\）；-GamePath 指定游戏主程序；
        -ExportCatalogue 是维护者用的：把目录导出到 -Out，用来更新本文件末尾的内置目录和
        同目录的 e2e-snapshot-catalogue.json（两者内容必须一致）。

  采集范围不是手写清单：只解析引擎的 AST、从不执行引擎里的任何代码，静态求出 Get-OptItems 的每个优化项、
  每条底层操作；路径要到运行期按硬件才确定的操作（显卡 Class 键、PCI 中断策略），按引擎复原白名单
  Test-AllowedBackupRegTarget 里同一值名的路径规则在本机注册表中枚举；复原白名单里的其余位置（包括只有
  旧版本备份才会写回的 PagingFiles、DeviceDesc）也一并采集。引擎已卸载时用内置目录。
  严格只读：唯一的写入是 -Out 文件。允许的差异只有：复原后按设计保留的工具电源方案「三角洲优化 · 卓越性能」
  本身的存在（方案里的取值仍要与卓越性能模板一致）、快照时间；任一侧读不了的值记为「无法比较」。
  本文件放在 tests\manual\，不会被 tests\*.ps1 或 tests\*-tests.ps1 选中。

  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File e2e-snapshot.ps1 -Out <snapshot.json> [-Compare <before.json>] [-EnginePath <delta-booster.ps1>] [-GamePath <game exe>] [-UserSid <SID>]
#>
#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Out,
  [string]$Compare,
  [string]$EnginePath,
  [string]$GamePath,
  [string]$UserSid,
  [switch]$ExportCatalogue
)

$ErrorActionPreference = 'Stop'

# ---------- 常量 ----------

$script:SnapSchema = 'dfb-e2e-snapshot/2'
$script:SnapCatalogueSchema = 'dfb-e2e-catalogue/2'
$script:SnapScriptVersion = '2.0'
$script:SnapUsage = 'Usage: powershell -NoProfile -ExecutionPolicy Bypass -File e2e-snapshot.ps1 -Out <snapshot.json> [-Compare <before.json>] [-EnginePath <delta-booster.ps1>] [-GamePath <game exe>] [-UserSid <SID>]'
$script:SnapOutFullPath = $null
$script:SnapPsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings'
$script:SnapPuRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$script:SnapPowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$script:SnapSessionPowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$script:SnapIfeoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$script:SnapGuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:SnapWindowsDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$script:SnapSystemDrive = [IO.Path]::GetPathRoot($script:SnapWindowsDir)
# 32 位 PowerShell 里 System32 会被重定向到 SysWOW64（那里没有 bcdedit），走 Sysnative
$script:SnapNativeDir = $(if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
  Join-Path $script:SnapWindowsDir 'Sysnative' } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::System) })
$script:SnapPowerCfgExe = Join-Path $script:SnapNativeDir 'powercfg.exe'
$script:SnapBcdEditExe = Join-Path $script:SnapNativeDir 'bcdedit.exe'
$script:SnapElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
# 静态求值里「运行期才知道」的值导出成这个记号
$script:SnapRuntimeMark = '[RUNTIME]'
# 比对输出的行首标记：中文给人看，英文保证在非中文代码页 / 重定向成乱码时仍能分辨
$script:SnapTag = @{ Fail = '[失败|FAIL]'; Expected = '[预期差异|EXPECTED]'; Unc = '[无法比较|N/A]'; Info = '[信息|INFO]' }

# 运行期缓存与收集器
$script:SnapHives = @{}
$script:SnapUser = $null
$script:SnapSchemeCache = $null
$script:SnapPowerCfgListCache = $null
$script:SnapBcdCache = $null
$script:SnapMMAgentCache = $null
$script:SnapServiceCache = $null
$script:SnapReads = [ordered]@{}
$script:SnapCtx = $null
$script:SnapNotes = New-Object 'System.Collections.Generic.List[string]'

# ---------- 通用：哈希、排序、确定性 JSON ----------

function Get-SnapSha256Hex([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') } finally { $sha.Dispose() }
}

function Get-SnapShortHash([string]$Text) {
  (Get-SnapSha256Hex ([Text.Encoding]::UTF8.GetBytes($Text))).Substring(0, 16)
}

function ConvertTo-SnapHex([byte[]]$Bytes) {
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
  [BitConverter]::ToString($Bytes) -replace '-', ''
}

function Test-SnapIsList($V) {
  [bool]($null -ne $V -and $V -is [Collections.IList] -and $V -isnot [Collections.IDictionary])
}

# 返回 @{ A = 排好序的 string[] }：用一层盒子装着，空数组也能原样带回（PowerShell 会把直接返回的空数组压成 $null）
function Get-SnapSortedStrings($Values) {
  $arr = [string[]]@(@($Values) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  [Array]::Sort($arr, [StringComparer]::Ordinal)
  @{ A = $arr }
}

# 递归把对象转成「键按序数排序」的有序字典。同样返回盒子 @{ V = ... }，保住数组与空数组
function ConvertTo-SnapSortedBox($InputObject) {
  if ($null -eq $InputObject) { return @{ V = $null } }
  if ($InputObject -is [string]) { return @{ V = $InputObject } }
  if ($InputObject -is [Enum] -or $InputObject -is [char]) { return @{ V = $InputObject.ToString() } }
  if ($InputObject -is [byte[]]) { return @{ V = ('hex:' + (ConvertTo-SnapHex $InputObject)) } }
  if ($InputObject -is [ValueType]) { return @{ V = $InputObject } }
  if ($InputObject -is [Collections.IDictionary]) {
    $keys = (Get-SnapSortedStrings @($InputObject.Keys)).A
    $d = [ordered]@{}
    foreach ($k in $keys) { $d[$k] = (ConvertTo-SnapSortedBox $InputObject[$k]).V }
    return @{ V = $d }
  }
  if ($InputObject -is [Management.Automation.PSCustomObject]) {
    $keys = (Get-SnapSortedStrings @($InputObject.PSObject.Properties | ForEach-Object { $_.Name })).A
    $d = [ordered]@{}
    foreach ($k in $keys) { $d[$k] = (ConvertTo-SnapSortedBox $InputObject.PSObject.Properties[$k].Value).V }
    return @{ V = $d }
  }
  if ($InputObject -is [Collections.IEnumerable]) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $InputObject) { $list.Add((ConvertTo-SnapSortedBox $e).V) }
    return @{ V = $list.ToArray() }
  }
  @{ V = [string]$InputObject }
}

# Windows PowerShell 5.1 的 ConvertTo-Json 会把 < > & ' 转成 \u003c 之类；这里还原成原字符，
# 只认「前面有偶数个反斜杠」的真转义，不会误伤数据里本来就有的反斜杠
function Format-SnapJsonText([string]$Json) {
  $map = @{ '003c' = '<'; '003e' = '>'; '0026' = '&'; '0027' = "'" }
  [regex]::Replace($Json, '(?<!\\)((?:\\\\)*)\\u(003c|003e|0026|0027)', {
    param($m) $m.Groups[1].Value + $map[$m.Groups[2].Value.ToLowerInvariant()]
  })
}

# 5.1 的 ConvertTo-Json 按键名长度对齐缩进，文件会膨胀好几倍；这里把紧凑 JSON 重新排成两空格缩进。
# 按「字符串 / 结构符 / 其他」切词，字符串整体原样搬运，所以不会改动任何值
function Format-SnapJsonIndent([string]$Compact) {
  $sb = New-Object Text.StringBuilder
  $depth = 0
  $tokens = [regex]::Matches($Compact, '"(?:[^"\\]|\\.)*"|[{}\[\],:]|[^"{}\[\],:]+')
  for ($i = 0; $i -lt $tokens.Count; $i++) {
    $t = $tokens[$i].Value
    if ($t -eq '{' -or $t -eq '[') {
      $close = $(if ($t -eq '{') { '}' } else { ']' })
      if ($i + 1 -lt $tokens.Count -and $tokens[$i + 1].Value -eq $close) { [void]$sb.Append($t + $close); $i++; continue }
      $depth++
      [void]$sb.Append($t + "`r`n" + ('  ' * $depth))
    } elseif ($t -eq '}' -or $t -eq ']') {
      $depth--
      [void]$sb.Append("`r`n" + ('  ' * $depth) + $t)
    } elseif ($t -eq ',') {
      [void]$sb.Append(",`r`n" + ('  ' * $depth))
    } elseif ($t -eq ':') {
      [void]$sb.Append(': ')
    } else { [void]$sb.Append($t) }
  }
  $sb.ToString()
}

function ConvertTo-SnapJson($InputObject, [switch]$Compress) {
  $sorted = (ConvertTo-SnapSortedBox $InputObject).V
  $compact = Format-SnapJsonText (ConvertTo-Json -InputObject $sorted -Depth 40 -Compress)
  if ($Compress) { return $compact }
  Format-SnapJsonIndent $compact
}

# 整个脚本唯一的写入点：只写 -Out 指定、事先确认不存在的那个文件
function Write-SnapOutFile([string]$Text) {
  if (-not $script:SnapOutFullPath) { throw '内部错误：输出路径尚未确定' }
  if (Test-Path -LiteralPath $script:SnapOutFullPath) { throw "-Out 文件已存在，拒绝覆盖：$($script:SnapOutFullPath)" }
  [IO.File]::WriteAllText($script:SnapOutFullPath, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-SnapField($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [Collections.IDictionary]) {
    if ($Obj.Contains($Name)) { return ,$Obj[$Name] }
    return $null
  }
  $p = $Obj.PSObject.Properties[$Name]
  if ($p) { return ,$p.Value }
  $null
}

function Get-SnapShortText([string]$Text) {
  $t = ($Text -replace '\s+', ' ').Trim()
  if ($t.Length -gt 90) { $t = $t.Substring(0, 90) + '…' }
  $t
}

function Resolve-SnapUserPath([string]$Path) {
  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-SnapVarName($VarAst) {
  "$($VarAst.VariablePath.UserPath)" -replace '^(?i)(script|global|local|private):', ''
}

# ---------- 读数结果 ----------

function Get-SnapOkResult($Value, $Info) { [ordered]@{ Status = 'ok'; Reason = $null; Value = $Value; Info = $Info } }

function Get-SnapUnreadableResult([string]$Reason, $Info) { [ordered]@{ Status = 'unreadable'; Reason = $Reason; Value = $null; Info = $Info } }

function Get-SnapAdminReason([string]$Detail) {
  if ($script:SnapElevated) { return $Detail }
  "需要管理员权限：$($Detail)"
}

# ---------- HKCU 的目标用户 ----------
# 软件写的是「原交互用户」的 HKCU（引擎按 SID 写 HKEY_USERS\<SID>）。标准用户用另一个管理员账户的凭据提权时，
# 提权进程自己的 HKCU 是那个管理员的；所以这里先找到登录桌面的用户，再固定读 HKEY_USERS\<SID>。

function Get-SnapHive([string]$Name) {
  if (-not $script:SnapHives.ContainsKey($Name)) {
    $hive = $(if ($Name -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::Users })
    $script:SnapHives[$Name] = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
  }
  $script:SnapHives[$Name]
}

# 本会话 explorer.exe 的所有者 = 登录这个桌面的用户。Get-Process -IncludeUserName 需要管理员身份
function Get-SnapSessionUser {
  $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
  $names = @()
  try {
    $names = @(Get-Process -Name 'explorer' -IncludeUserName -ErrorAction Stop |
      Where-Object { $_.SessionId -eq $session -and $_.UserName } | ForEach-Object { "$($_.UserName)" } | Sort-Object -Unique)
  } catch { return @{ Sid = $null; Account = $null; Why = "读不到本会话 explorer.exe 的所有者（$($_.Exception.Message.Trim())）" } }
  if ($names.Count -eq 0) { return @{ Sid = $null; Account = $null; Why = '本会话里没有 explorer.exe（没有登录的桌面）' } }
  if ($names.Count -gt 1) { return @{ Sid = $null; Account = $null; Why = "本会话的 explorer.exe 分属 $($names.Count) 个账户" } }
  try { $sid = (New-Object Security.Principal.NTAccount($names[0])).Translate([Security.Principal.SecurityIdentifier]).Value }
  catch { return @{ Sid = $null; Account = $names[0]; Why = "无法把 $($names[0]) 解析成 SID（$($_.Exception.Message.Trim())）" } }
  @{ Sid = $sid; Account = $names[0]; Why = $null }
}

# Note 只打印到控制台（可能含账户名）；JsonNote / HiveReason 会进 -Out，只用 SID 哈希，不放原始 SID 或账户名
function Initialize-SnapTargetUser {
  $runAs = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $u = [ordered]@{ Sid = $null; Source = $null; RunAsSid = $runAs; Account = $null; HiveLoaded = $false; HiveReason = $null; Note = $null; JsonNote = $null }
  if ($UserSid) {
    try { $u.Sid = (New-Object Security.Principal.SecurityIdentifier($UserSid)).Value } catch { throw "-UserSid 不是合法的 SID：$UserSid" }
    $u.Source = 'param'
  } elseif ($script:SnapElevated) {
    $s = Get-SnapSessionUser
    if ($s.Sid) { $u.Sid = $s.Sid; $u.Account = $s.Account; $u.Source = 'session-explorer' }
    else {
      $u.Sid = $runAs; $u.Source = 'process'
      $u.Note = "没能确定登录这个桌面的用户，HKCU 下的项目按运行本脚本的账户读取：$($s.Why)；必要时用 -UserSid 指定"
      $u.JsonNote = '没能确定登录这个桌面的用户，HKCU 下的项目按运行本脚本的账户读取'
    }
  } else { $u.Sid = $runAs; $u.Source = 'process' }
  $sidHash = Get-SnapShortHash $u.Sid
  $k = $null
  try { $k = (Get-SnapHive 'HKU').OpenSubKey($u.Sid) } catch { $u.HiveReason = "无权打开目标用户（SID 哈希 $sidHash）的注册表配置单元（$($_.Exception.Message.Trim())）" }
  if ($k) { $k.Close(); $u.HiveLoaded = $true }
  elseif (-not $u.HiveReason) { $u.HiveReason = "目标用户（SID 哈希 $sidHash）的注册表配置单元没有加载：该用户当前没有登录" }
  if ($u.Source -eq 'session-explorer' -and $u.Sid -ne $runAs) {
    $u.Note = "运行本脚本的账户不是登录这个桌面的用户：HKCU 下的项目按登录用户 $($u.Account) 的配置单元读取（软件写的也是它）"
    $u.JsonNote = "运行本脚本的账户不是登录这个桌面的用户：HKCU 下的项目按登录用户（SID 哈希 $sidHash）的配置单元读取"
  }
  $script:SnapUser = $u
}

# ---------- 注册表（.NET API，只读打开） ----------

# 返回 @{ State = 'ok' | 'absent' | 'denied'; Key; Reason }；State 为 ok 时调用方负责 Close
function Open-SnapRegKey([string]$Path) {
  if ($Path -notmatch '^(HKLM|HKCU):\\(.+)$') { throw "不支持的注册表路径：$Path" }
  $hiveName = $Matches[1]; $sub = $Matches[2]
  if ($hiveName -eq 'HKCU') {
    if (-not $script:SnapUser) { Initialize-SnapTargetUser }
    if (-not $script:SnapUser.HiveLoaded) { return @{ State = 'denied'; Key = $null; Reason = $script:SnapUser.HiveReason } }
    $hiveName = 'HKU'; $sub = "$($script:SnapUser.Sid)\$sub"
  }
  $k = $null
  try { $k = (Get-SnapHive $hiveName).OpenSubKey($sub) }
  catch { return @{ State = 'denied'; Key = $null; Reason = "无权读取注册表键 $($Path)（$($_.Exception.Message.Trim())）" } }
  if ($null -eq $k) { return @{ State = 'absent'; Key = $null; Reason = $null } }
  @{ State = 'ok'; Key = $k; Reason = $null }
}

function ConvertTo-SnapRegData([string]$Kind, $Raw) {
  switch ($Kind) {
    'DWord'        { return @{ V = [int64][BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Raw), 0) } }
    'QWord'        { return @{ V = [BitConverter]::ToUInt64([BitConverter]::GetBytes([int64]$Raw), 0).ToString() } }
    'MultiString'  { return @{ V = [string[]]@($Raw) } }
    'String'       { return @{ V = [string]$Raw } }
    'ExpandString' { return @{ V = [string]$Raw } }
  }
  if ($Raw -is [byte[]]) { return @{ V = (ConvertTo-SnapHex $Raw) } }
  @{ V = [string]$Raw }
}

function Read-SnapValueFromKey($Key, [string]$Name) {
  $exists = $false
  foreach ($n in $Key.GetValueNames()) { if ($n -ieq $Name) { $exists = $true; break } }
  if (-not $exists) { return [ordered]@{ Exists = $false; Kind = $null; Data = $null } }
  $kind = "$($Key.GetValueKind($Name))"
  $raw = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  [ordered]@{ Exists = $true; Kind = $kind; Data = (ConvertTo-SnapRegData $kind $raw).V }
}

# 值 + 它所在的键是否存在。键存在与否也参与比较：Apply 用 CreateSubKey 建出来的键，复原只删值、
# 不删键（IFEO 除外），留下的空键同样是「没有回到之前」
function Read-SnapRegValue($Spec) {
  $o = Open-SnapRegKey "$($Spec.Path)"
  if ($o.State -eq 'denied') { return (Get-SnapUnreadableResult $o.Reason $null) }
  if ($o.State -eq 'absent') { return (Get-SnapOkResult ([ordered]@{ Exists = $false; Kind = $null; Data = $null; KeyExists = $false }) $null) }
  try { $v = Read-SnapValueFromKey $o.Key "$($Spec.Name)" } finally { $o.Key.Close() }
  $v['KeyExists'] = $true
  Get-SnapOkResult $v $null
}

# 整键读取（子键名 + 全部值），用于 IFEO：复原后留下的空键本身就是要报告的差异
function Read-SnapRegKey($Spec) {
  $o = Open-SnapRegKey "$($Spec.Path)"
  if ($o.State -eq 'denied') { return (Get-SnapUnreadableResult $o.Reason $null) }
  if ($o.State -eq 'absent') { return (Get-SnapOkResult ([ordered]@{ Exists = $false; SubKeys = [string[]]@(); Values = [ordered]@{} }) $null) }
  $k = $o.Key
  try {
    $subs = (Get-SnapSortedStrings @($k.GetSubKeyNames())).A
    $vals = [ordered]@{}
    foreach ($n in (Get-SnapSortedStrings @($k.GetValueNames())).A) {
      $kind = "$($k.GetValueKind($n))"
      $raw = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      $vals[$(if ($n -eq '') { '(default)' } else { $n })] = [ordered]@{ Kind = $kind; Data = (ConvertTo-SnapRegData $kind $raw).V }
    }
  } finally { $k.Close() }
  Get-SnapOkResult ([ordered]@{ Exists = $true; SubKeys = $subs; Values = $vals }) $null
}

# ---------- 电源方案 ----------

function Get-SnapSchemeDisplayName([string]$FriendlyName) {
  if ($FriendlyName -match '^@.*,-?\d+,(.+)$') { return $Matches[1] }
  $FriendlyName
}

function Test-SnapToolScheme([string]$Guid, [string]$Name) {
  [bool]($Name -and $Name -ceq "$($script:SnapCtx.ToolSchemeName)" -and $Guid -ine "$($script:SnapCtx.UltimateGuid)")
}

function Get-SnapPowerSchemeTable {
  if ($null -ne $script:SnapSchemeCache) { return $script:SnapSchemeCache }
  $t = @{ State = 'ok'; Reason = $null; Active = $null; Schemes = @{} }
  $o = Open-SnapRegKey $script:SnapPuRoot
  if ($o.State -ne 'ok') {
    $t.State = 'unreadable'
    $t.Reason = $(if ($o.Reason) { $o.Reason } else { '注册表里没有电源方案键' })
  } else {
    $k = $o.Key
    try {
      $t.Active = "$($k.GetValue('ActivePowerScheme'))".ToLowerInvariant()
      foreach ($g in $k.GetSubKeyNames()) {
        if ($g -notmatch "^$($script:SnapGuidRx)$") { continue }
        $fn = $null; $desc = $null
        $sk = $k.OpenSubKey($g)
        if ($sk) {
          try {
            $fn = $sk.GetValue('FriendlyName', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $desc = $sk.GetValue('Description', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
          } finally { $sk.Close() }
        }
        $t.Schemes[$g.ToLowerInvariant()] = @{
          FriendlyName = $(if ($null -ne $fn) { "$fn" } else { $null })
          Description = $(if ($null -ne $desc) { "$desc" } else { $null })
          Name = Get-SnapSchemeDisplayName "$fn"
        }
      }
    } catch {
      $t.State = 'unreadable'; $t.Reason = "读取电源方案列表失败（$($_.Exception.Message.Trim())）"
    } finally { $k.Close() }
  }
  $script:SnapSchemeCache = $t
  $t
}

# powercfg 只用 /list 与 /a 两个只读开关；输出按原样留存
function Get-SnapPowerCfgList {
  if ($null -ne $script:SnapPowerCfgListCache) { return $script:SnapPowerCfgListCache }
  $ErrorActionPreference = 'Continue'
  Write-Verbose '[只读] powercfg /list'
  $lines = @(& $script:SnapPowerCfgExe /list 2>&1 | ForEach-Object { "$_" })
  $code = $LASTEXITCODE
  $entries = @{}
  foreach ($l in $lines) {
    # 先把 GUID 取出来：赋值语句先求右侧，右侧的 -match 会覆盖 $Matches
    if ($l -match "($($script:SnapGuidRx))") {
      $g = $Matches[1].ToLowerInvariant()
      $entries[$g] = [bool]($l.TrimEnd().EndsWith('*'))
    }
  }
  $script:SnapPowerCfgListCache = @{ ExitCode = $code; Lines = [string[]]$lines; Entries = $entries }
  $script:SnapPowerCfgListCache
}

function Read-SnapPowerActive($Spec) {
  $t = Get-SnapPowerSchemeTable
  if ($t.State -ne 'ok') { return (Get-SnapUnreadableResult $t.Reason $null) }
  $name = $(if ($t.Schemes.ContainsKey($t.Active)) { $t.Schemes[$t.Active].Name } else { $null })
  Get-SnapOkResult ([ordered]@{ Guid = $t.Active; Name = $name }) $null
}

function Read-SnapPowerScheme($Spec) {
  $t = Get-SnapPowerSchemeTable
  if ($t.State -ne 'ok') { return (Get-SnapUnreadableResult $t.Reason $null) }
  $g = "$($Spec.Scheme)".ToLowerInvariant()
  if (-not $t.Schemes.ContainsKey($g)) {
    return (Get-SnapOkResult ([ordered]@{ Exists = $false; FriendlyName = $null; Description = $null; Name = $null; IsTool = $false }) $null)
  }
  $s = $t.Schemes[$g]
  Get-SnapOkResult ([ordered]@{ Exists = $true; FriendlyName = $s.FriendlyName; Description = $s.Description; Name = $s.Name
    IsTool = (Test-SnapToolScheme $g $s.Name) }) $null
}

function Read-SnapPowerCfgEntry($Spec) {
  $c = Get-SnapPowerCfgList
  if ($c.ExitCode -ne 0) { return (Get-SnapUnreadableResult "powercfg /list 退出码 $($c.ExitCode)（$(($c.Lines | Select-Object -First 2) -join ' ')）" $null) }
  $g = "$($Spec.Scheme)".ToLowerInvariant()
  $listed = $c.Entries.ContainsKey($g)
  Get-SnapOkResult ([ordered]@{ Listed = $listed; Active = [bool]($listed -and $c.Entries[$g]) }) $null
}

function Read-SnapPowerCfgA($Spec) {
  $ErrorActionPreference = 'Continue'
  Write-Verbose '[只读] powercfg /a'
  $lines = @(& $script:SnapPowerCfgExe /a 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  $code = $LASTEXITCODE
  if ($code -ne 0) { return (Get-SnapUnreadableResult "powercfg /a 退出码 $($code)（$(($lines | Select-Object -First 2) -join ' ')）" $null) }
  Get-SnapOkResult ([ordered]@{ Lines = [string[]]$lines }) $null
}

function Read-SnapPcfgSetting($Spec) {
  $o = Open-SnapRegKey "$($script:SnapPsRoot)\$($Spec.Sub)\$($Spec.Setting)"
  if ($o.State -eq 'denied') { return (Get-SnapUnreadableResult $o.Reason $null) }
  if ($o.State -eq 'absent') {
    return (Get-SnapOkResult ([ordered]@{ SettingExists = $false; Attributes = [ordered]@{ Exists = $false; Kind = $null; Data = $null }; Hidden = $null }) $null)
  }
  try { $attr = Read-SnapValueFromKey $o.Key 'Attributes' } finally { $o.Key.Close() }
  $hidden = $(if ($attr.Exists) { [bool](([int64]$attr.Data -band 1) -eq 1) } else { $false })
  Get-SnapOkResult ([ordered]@{ SettingExists = $true; Attributes = $attr; Hidden = $hidden }) $null
}

# 某方案下某电源设置的 AC / DC 显式值（不回落默认表：回落值不是这个方案里真实存着的东西），
# 外加设置子键是否存在（powercfg /setacvalueindex 会建它，复原只删 ACSettingIndex）
function Read-SnapPcfgScheme($Spec) {
  $absent = [ordered]@{ Exists = $false; Kind = $null; Data = $null }
  $schemePath = "$($script:SnapPuRoot)\$($Spec.Scheme)"
  $o = Open-SnapRegKey $schemePath
  if ($o.State -eq 'denied') { return (Get-SnapUnreadableResult $o.Reason $null) }
  if ($o.State -eq 'absent') {
    return (Get-SnapOkResult ([ordered]@{ SchemeExists = $false; SettingKeyExists = $false; Ac = $absent; Dc = $absent }) $null)
  }
  $o.Key.Close()
  $s = Open-SnapRegKey "$schemePath\$($Spec.Sub)\$($Spec.Setting)"
  if ($s.State -eq 'denied') { return (Get-SnapUnreadableResult $s.Reason $null) }
  if ($s.State -eq 'absent') {
    return (Get-SnapOkResult ([ordered]@{ SchemeExists = $true; SettingKeyExists = $false; Ac = $absent; Dc = $absent }) $null)
  }
  try {
    $ac = Read-SnapValueFromKey $s.Key 'ACSettingIndex'
    $dc = Read-SnapValueFromKey $s.Key 'DCSettingIndex'
  } finally { $s.Key.Close() }
  Get-SnapOkResult ([ordered]@{ SchemeExists = $true; SettingKeyExists = $true; Ac = $ac; Dc = $dc }) $null
}

# ---------- 休眠 / 引导配置 / 内存管理 / 服务 / 计划任务 / 文件 ----------

function Read-SnapHiberfil($Spec) {
  $path = "$($Spec.Path)"
  $di = New-Object IO.DirectoryInfo((Split-Path -Parent $path))
  # 用目录枚举而不是 File.Exists：后者在没有读权限时会把「存在」说成「不存在」
  $found = @($di.GetFiles((Split-Path -Leaf $path)))
  if ($found.Count -eq 0) { return (Get-SnapOkResult ([ordered]@{ Exists = $false }) ([ordered]@{ Size = $null })) }
  Get-SnapOkResult ([ordered]@{ Exists = $true }) ([ordered]@{ Size = [int64]$found[0].Length })
}

function Get-SnapBcdOutput {
  if ($null -ne $script:SnapBcdCache) { return $script:SnapBcdCache }
  $ErrorActionPreference = 'Continue'
  Write-Verbose '[只读] bcdedit /enum {current}'
  $lines = @(& $script:SnapBcdEditExe /enum '{current}' 2>&1 | ForEach-Object { "$_" })
  $script:SnapBcdCache = @{ ExitCode = $LASTEXITCODE; Lines = [string[]]$lines }
  $script:SnapBcdCache
}

function Read-SnapBcd($Spec) {
  $c = Get-SnapBcdOutput
  if ($c.ExitCode -ne 0) {
    $detail = (@($c.Lines | Where-Object { "$_".Trim() } | Select-Object -First 2) -join ' ').Trim()
    return (Get-SnapUnreadableResult (Get-SnapAdminReason "bcdedit /enum {current} 退出码 $($c.ExitCode)（$detail）") $null)
  }
  $rx = '^\s*' + [regex]::Escape("$($Spec.Name)") + '\s+(\S+)\s*$'
  foreach ($l in $c.Lines) { if ($l -match $rx) { return (Get-SnapOkResult ([ordered]@{ Value = $Matches[1] }) $null) } }
  # 引导项能读到但没有这个值：系统默认，与「读不了」严格区分
  Get-SnapOkResult ([ordered]@{ Value = 'absent' }) $null
}

function Read-SnapMMAgent($Spec) {
  if ($null -eq $script:SnapMMAgentCache) {
    try { $script:SnapMMAgentCache = @{ Agent = (Get-MMAgent -ErrorAction Stop); Error = $null } }
    catch { $script:SnapMMAgentCache = @{ Agent = $null; Error = $_.Exception.Message.Trim() } }
  }
  $c = $script:SnapMMAgentCache
  if ($c.Error -or $null -eq $c.Agent) { return (Get-SnapUnreadableResult (Get-SnapAdminReason "Get-MMAgent 失败（$($c.Error)）") $null) }
  $prop = switch ("$($Spec.Feature)") { 'mc' { 'MemoryCompression' } 'pc' { 'PageCombining' } default { $null } }
  if (-not $prop) { return (Get-SnapUnreadableResult "不认识的 MMAgent 功能：$($Spec.Feature)" $null) }
  Get-SnapOkResult ([ordered]@{ Enabled = [bool]$c.Agent.$prop }) ([ordered]@{ Property = $prop })
}

function Read-SnapService($Spec) {
  if ($null -eq $script:SnapServiceCache) {
    $script:SnapServiceCache = @{ List = @(Get-Service -ErrorAction SilentlyContinue) }
  }
  $name = "$($Spec.Name)"
  $m = @($script:SnapServiceCache.List | Where-Object { $_.Name -ieq $name })
  if ($m.Count -eq 0) { return (Get-SnapOkResult ([ordered]@{ Exists = $false; StartType = $null }) $null) }
  $st = $null
  try { $st = "$($m[0].StartType)" }
  catch { return (Get-SnapUnreadableResult (Get-SnapAdminReason "读取服务 $name 的启动类型失败（$($_.Exception.Message.Trim())）") $null) }
  Get-SnapOkResult ([ordered]@{ Exists = $true; StartType = $st }) $null
}

function ConvertTo-SnapTaskRecord($Task) {
  $rec = [ordered]@{ Path = "$($Task.Path)"; Enabled = [bool]$Task.Enabled }
  try {
    $def = $Task.Definition
    $acts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in $def.Actions) {
      if ([int]$a.Type -eq 0) { $acts.Add(("$($a.Path) $($a.Arguments)").Trim()) } else { $acts.Add("action-type=$($a.Type)") }
    }
    $rec['Actions'] = $acts.ToArray()
    $rec['UserId'] = "$($def.Principal.UserId)"
    $rec['RunLevel'] = [int]$def.Principal.RunLevel
    $rec['Hidden'] = [bool]$def.Settings.Hidden
  } catch { $rec['Error'] = "读取任务定义失败（$($_.Exception.Message.Trim())）" }
  $rec
}

# 计划任务只通过 COM 枚举（只读），包含隐藏任务。软件只在根文件夹 \ 注册任务（锁定任务用 schtasks /TN 不带
# 文件夹，一次性 SYSTEM 清理任务注册在 GetFolder('\')），所以根文件夹读得到就是可下结论的读数；子文件夹也扫，
# 读不了的子文件夹只记进 Info.FolderErrors，不再让整条读数作废
function Read-SnapTasks($Spec) {
  $prefix = "$($Spec.Prefix)"
  $svc = $null; $root = $null
  try { $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect(); $root = $svc.GetFolder('\') }
  catch { return (Get-SnapUnreadableResult "无法连接任务计划服务（$($_.Exception.Message.Trim())）" $null) }
  $found = @{}
  $folderErrors = New-Object 'System.Collections.Generic.List[string]'
  $rootError = $null
  try {
    foreach ($t in $root.GetTasks(1)) { if ("$($t.Name)" -like "$prefix*") { $found["$($t.Path)"] = (ConvertTo-SnapTaskRecord $t) } }
  } catch { $rootError = $_.Exception.Message.Trim() }
  $stack = New-Object 'System.Collections.Generic.Stack[object]'
  try { foreach ($sub in $root.GetFolders(0)) { $stack.Push($sub) } } catch { $folderErrors.Add("\（子文件夹列表）：$($_.Exception.Message.Trim())") }
  while ($stack.Count -gt 0) {
    $folder = $stack.Pop()
    $fpath = "$($folder.Path)"
    try {
      foreach ($t in $folder.GetTasks(1)) { if ("$($t.Name)" -like "$prefix*") { $found["$($t.Path)"] = (ConvertTo-SnapTaskRecord $t) } }
    } catch { $folderErrors.Add("$($fpath)：$($_.Exception.Message.Trim())") }
    try { foreach ($sub in $folder.GetFolders(0)) { $stack.Push($sub) } }
    catch { $folderErrors.Add("$($fpath)（子文件夹）：$($_.Exception.Message.Trim())") }
  }
  $tasks = New-Object 'System.Collections.Generic.List[object]'
  foreach ($p in (Get-SnapSortedStrings @($found.Keys)).A) { $tasks.Add($found[$p]) }
  $info = [ordered]@{ SeenTasks = $tasks.ToArray(); FolderErrors = $folderErrors.ToArray() }
  if (-not $script:SnapElevated) {
    return (Get-SnapUnreadableResult "需要管理员权限：非管理员进程看不到以 SYSTEM 身份注册的计划任务，列表可能不完整（本次看到 $($tasks.Count) 个）" $info)
  }
  if ($rootError) { return (Get-SnapUnreadableResult "任务计划根文件夹 \ 读不了（$rootError），而软件的任务都注册在那里" $info) }
  Get-SnapOkResult ([ordered]@{ Tasks = $tasks.ToArray() }) ([ordered]@{ FolderErrors = $folderErrors.ToArray() })
}

function Read-SnapFile($Spec) {
  $p = "$($Spec.Path)"
  if (-not [IO.File]::Exists($p)) { return (Get-SnapOkResult ([ordered]@{ Exists = $false; Sha256 = $null }) $null) }
  Get-SnapOkResult ([ordered]@{ Exists = $true; Sha256 = (Get-SnapSha256Hex ([IO.File]::ReadAllBytes($p))) }) $null
}

# ---------- 按正则枚举注册表路径（复原白名单里的路径规则） ----------

# 把锚定的路径正则按「字符类与分组之外的 \\」拆成逐级组件；失败返回 $null
function Split-SnapRegexPath([string]$Rx) {
  if (-not $Rx.StartsWith('^') -or -not $Rx.EndsWith('$')) { return $null }
  $body = $Rx.Substring(1, $Rx.Length - 2)
  $parts = New-Object 'System.Collections.Generic.List[string]'
  $sb = New-Object Text.StringBuilder
  $inClass = $false; $depth = 0
  for ($i = 0; $i -lt $body.Length; $i++) {
    $c = $body[$i]
    if ($c -eq [char]'\') {
      if ($i + 1 -ge $body.Length) { return $null }
      $n = $body[$i + 1]
      if ($n -eq [char]'\' -and -not $inClass -and $depth -eq 0) { $parts.Add($sb.ToString()); [void]$sb.Clear(); $i++; continue }
      [void]$sb.Append($c).Append($n); $i++; continue
    }
    if ($inClass) { if ($c -eq [char]']') { $inClass = $false } }
    elseif ($c -eq [char]'[') { $inClass = $true }
    elseif ($c -eq [char]'(') { $depth++ }
    elseif ($c -eq [char]')') { $depth-- }
    [void]$sb.Append($c)
  }
  $parts.Add($sb.ToString())
  if ($inClass -or $depth -ne 0) { return $null }
  @{ Parts = $parts.ToArray() }
}

# 组件里没有正则元字符时返回去掉转义后的字面量，否则返回 $null
function Get-SnapRegexLiteral([string]$Part) {
  $sb = New-Object Text.StringBuilder
  for ($i = 0; $i -lt $Part.Length; $i++) {
    $c = $Part[$i]
    if ($c -eq [char]'\') {
      if ($i + 1 -ge $Part.Length) { return $null }
      $n = $Part[$i + 1]
      if ([char]::IsLetterOrDigit($n)) { return $null }
      [void]$sb.Append($n); $i++; continue
    }
    if ('.[](){}|*+?^$'.IndexOf($c) -ge 0) { return $null }
    [void]$sb.Append($c)
  }
  $sb.ToString()
}

# 返回 @{ Members = 排好序的键路径; Errors = 读不了的位置 }。字面量组件直接拼接（末段的键不存在也照样列出：
# 值读数会如实记成「键不存在」），带正则的组件才枚举本机的子键
function Get-SnapRegPatternMembers([string]$Rx) {
  $errs = New-Object 'System.Collections.Generic.List[string]'
  $sp = Split-SnapRegexPath $Rx
  if (-not $sp -or $sp.Parts.Count -lt 2) { return @{ Members = [string[]]@(); Errors = [string[]]@("无法拆解的路径正则：$Rx") } }
  $hive = Get-SnapRegexLiteral $sp.Parts[0]
  if ($hive -ne 'HKLM:' -and $hive -ne 'HKCU:') { return @{ Members = [string[]]@(); Errors = [string[]]@("路径正则不是以 HKLM: / HKCU: 开头：$Rx") } }
  $cur = New-Object 'System.Collections.Generic.List[string]'
  $cur.Add($hive)
  for ($i = 1; $i -lt $sp.Parts.Count; $i++) {
    $part = $sp.Parts[$i]
    $lit = Get-SnapRegexLiteral $part
    $next = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $lit) {
      foreach ($p in $cur) { $next.Add("$p\$lit") }
    } else {
      $compRx = "^(?:$part)$"
      foreach ($p in $cur) {
        if ($p -notmatch '\\') { $errs.Add("路径正则在根键下直接用了通配：$Rx"); continue }
        $o = Open-SnapRegKey $p
        if ($o.State -eq 'denied') { $errs.Add($o.Reason); continue }
        if ($o.State -eq 'absent') { continue }
        try { foreach ($n in $o.Key.GetSubKeyNames()) { if ($n -match $compRx) { $next.Add("$p\$n") } } }
        catch { $errs.Add("枚举 $p 的子键失败（$($_.Exception.Message.Trim())）") }
        finally { $o.Key.Close() }
      }
    }
    $cur = $next
  }
  $ok = @($cur | Where-Object { $_ -match $Rx })
  @{ Members = (Get-SnapSortedStrings $ok).A; Errors = $errs.ToArray() }
}

# ---------- 枚举（让依赖本机硬件 / 游戏路径的操作在任何机器上都能被覆盖） ----------

function Get-SnapEnumLabel([string]$EnumName) {
  if ($EnumName -eq 'power-schemes') { return '枚举：注册表里的全部电源方案' }
  if ($EnumName -eq 'powercfg-list') { return '枚举：powercfg /list 列出的方案' }
  if ($EnumName -like 'regpath|*') { return "枚举：本机注册表里路径匹配 $($EnumName.Substring(8)) 的键" }
  if ($EnumName -like 'game-values|*') { return "枚举：$($EnumName.Substring(12)) 下以游戏主程序命名的值" }
  "枚举：$EnumName"
}

function Read-SnapEnum($Spec) {
  $name = "$($Spec.Enum)"
  if ($name -eq 'power-schemes') {
    $t = Get-SnapPowerSchemeTable
    if ($t.State -ne 'ok') { return (Get-SnapUnreadableResult $t.Reason $null) }
    return (Get-SnapOkResult ([ordered]@{ Members = (Get-SnapSortedStrings @($t.Schemes.Keys)).A }) $null)
  }
  if ($name -eq 'powercfg-list') {
    $c = Get-SnapPowerCfgList
    if ($c.ExitCode -ne 0) { return (Get-SnapUnreadableResult "powercfg /list 退出码 $($c.ExitCode)" $null) }
    return (Get-SnapOkResult ([ordered]@{ Members = (Get-SnapSortedStrings @($c.Entries.Keys)).A }) $null)
  }
  if ($name -like 'regpath|*') {
    $r = Get-SnapRegPatternMembers "$($Spec.Pattern)"
    if ($r.Errors.Count -gt 0) { return (Get-SnapUnreadableResult "有 $($r.Errors.Count) 处读不了：$($r.Errors[0])" ([ordered]@{ Members = $r.Members })) }
    return (Get-SnapOkResult ([ordered]@{ Members = $r.Members }) $null)
  }
  if ($name -like 'game-values|*') {
    $o = Open-SnapRegKey "$($Spec.Path)"
    if ($o.State -eq 'denied') { return (Get-SnapUnreadableResult $o.Reason $null) }
    if ($o.State -eq 'absent') { return (Get-SnapOkResult ([ordered]@{ Members = [string[]]@() }) $null) }
    $hits = New-Object 'System.Collections.Generic.List[string]'
    try {
      foreach ($n in $o.Key.GetValueNames()) {
        $leaf = $n.Substring($n.LastIndexOf('\') + 1)
        if (@($script:SnapCtx.GameExeNames) -icontains $leaf) { $hits.Add($n) }
      }
    } finally { $o.Key.Close() }
    return (Get-SnapOkResult ([ordered]@{ Members = (Get-SnapSortedStrings $hits.ToArray()).A }) $null)
  }
  Get-SnapUnreadableResult "不认识的枚举「$name」（可能来自更新版本的快照脚本）" $null
}

# ---------- 读数分发 ----------

function Read-SnapSpec($Spec) {
  try {
    switch ("$($Spec.Kind)") {
      'regvalue'      { return (Read-SnapRegValue $Spec) }
      'regkey'        { return (Read-SnapRegKey $Spec) }
      'pcfg-setting'  { return (Read-SnapPcfgSetting $Spec) }
      'pcfg-scheme'   { return (Read-SnapPcfgScheme $Spec) }
      'power-active'  { return (Read-SnapPowerActive $Spec) }
      'power-scheme'  { return (Read-SnapPowerScheme $Spec) }
      'powercfg-list' { return (Read-SnapPowerCfgEntry $Spec) }
      'powercfg-a'    { return (Read-SnapPowerCfgA $Spec) }
      'hiberfil'      { return (Read-SnapHiberfil $Spec) }
      'bcd'           { return (Read-SnapBcd $Spec) }
      'mmagent'       { return (Read-SnapMMAgent $Spec) }
      'service'       { return (Read-SnapService $Spec) }
      'sched'         { return (Read-SnapTasks $Spec) }
      'enum'          { return (Read-SnapEnum $Spec) }
      'file'          { return (Read-SnapFile $Spec) }
    }
    Get-SnapUnreadableResult "不认识的读取类型「$($Spec.Kind)」（可能来自更新版本的快照脚本）" $null
  } catch {
    Get-SnapUnreadableResult "读取时出错：$($_.Exception.Message.Trim())" $null
  }
}

function Get-SnapSpecKey($Spec) {
  $kind = "$($Spec.Kind)"
  $parts = switch ($kind) {
    'regvalue'      { @($Spec.Path, $Spec.Name) }
    'regkey'        { @($Spec.Path) }
    'pcfg-setting'  { @($Spec.Sub, $Spec.Setting) }
    'pcfg-scheme'   { @($Spec.Scheme, $Spec.Sub, $Spec.Setting) }
    'power-scheme'  { @($Spec.Scheme) }
    'powercfg-list' { @($Spec.Scheme) }
    'hiberfil'      { @($Spec.Path) }
    'bcd'           { @($Spec.Name) }
    'mmagent'       { @($Spec.Feature) }
    'service'       { @($Spec.Name) }
    'sched'         { @($Spec.Prefix) }
    'enum'          { @($Spec.Enum) }
    'file'          { @($Spec.Path) }
    default         { @() }
  }
  ((@($kind) + @($parts | ForEach-Object { "$_" })) -join '|').ToLowerInvariant()
}

# 登记一处要读的东西（按键去重），记下是哪个优化项要它；返回键
function Request-SnapRead($Spec, [string]$Label, $ItemRef, [string]$Origin, [string]$KeyOverride) {
  $key = $(if ($KeyOverride) { $KeyOverride } else { Get-SnapSpecKey $Spec })
  if (-not $script:SnapReads.Contains($key)) {
    $script:SnapReads[$key] = [ordered]@{
      Spec = $Spec; Label = $Label
      Items = (New-Object 'System.Collections.Generic.List[object]')
      Origins = (New-Object 'System.Collections.Generic.List[string]')
      Status = $null; Reason = $null; Value = $null; Info = $null
    }
  }
  $e = $script:SnapReads[$key]
  if ($ItemRef -and "$($ItemRef.Id)") {
    $dupe = $false
    foreach ($x in $e.Items) { if ("$($x.Id)" -ceq "$($ItemRef.Id)") { $dupe = $true } }
    if (-not $dupe) { $e.Items.Add([ordered]@{ Id = "$($ItemRef.Id)"; Name = "$($ItemRef.Name)" }) }
  }
  if ($Origin -and -not $e.Origins.Contains($Origin)) { $e.Origins.Add($Origin) }
  $key
}

function Complete-SnapRead([string]$Key) {
  $e = $script:SnapReads[$Key]
  if ($null -ne $e.Status) { return }
  $r = Read-SnapSpec $e.Spec
  $e.Status = $r.Status; $e.Reason = $r.Reason; $e.Value = $r.Value; $e.Info = $r.Info
}

function Get-SnapEnumMembers([string]$EnumName, [string]$Path, [string]$Pattern, $ItemRef, [string]$Origin) {
  $spec = [ordered]@{ Kind = 'enum'; Enum = $EnumName }
  if ($Path) { $spec['Path'] = $Path }
  if ($Pattern) { $spec['Pattern'] = $Pattern }
  $key = Request-SnapRead $spec (Get-SnapEnumLabel $EnumName) $ItemRef $(if ($Origin) { $Origin } else { 'catalogue' })
  Complete-SnapRead $key
  $e = $script:SnapReads[$key]
  $m = $null
  if ($e.Status -eq 'ok' -and $e.Value) { $m = $e.Value.Members } elseif ($e.Info) { $m = $e.Info.Members }
  @{ M = $m }
}

function Test-SnapListContainsCi($List, [string]$Value) {
  foreach ($x in $List) { if ("$x" -ieq $Value) { return $true } }
  $false
}

# 「以游戏主程序命名的值」的全部候选：本机已有的同类值 + 已知游戏路径
function Get-SnapGameValueNames([string]$Path, $Ref, [string]$Origin) {
  $names = New-Object 'System.Collections.Generic.List[string]'
  $enum = "game-values|$Path"
  foreach ($m in (Get-SnapEnumMembers $enum $Path $null $Ref $Origin).M) { if (-not (Test-SnapListContainsCi $names $m)) { $names.Add($m) } }
  $gp = "$($script:SnapCtx.GamePath)"
  if ($gp -and -not (Test-SnapListContainsCi $names $gp)) { $names.Add($gp) }
  @{ Names = $names.ToArray(); Enum = $enum }
}

# 模板展开：[GAME_EXE_NAME] 用三个游戏主程序名，[GAME_EXE_PATH] 用「已有的以游戏主程序命名的值」+ 已知游戏路径，
# PathPatterns（路径运行期才确定的操作）用复原白名单的路径正则在本机注册表里枚举
function Get-SnapRegTargets($Op, $Ref) {
  $list = New-Object 'System.Collections.Generic.List[object]'
  $path = "$($Op.Path)"; $name = "$($Op.Name)"
  $paths = New-Object 'System.Collections.Generic.List[object]'
  if (@($Op.PathPatterns).Count -gt 0 -and $null -ne @($Op.PathPatterns)[0]) {
    foreach ($rx in @($Op.PathPatterns)) {
      $en = "regpath|$rx"
      foreach ($m in (Get-SnapEnumMembers $en $null "$rx" $Ref 'catalogue').M) { $paths.Add(@{ P = $m; Enum = $en }) }
    }
  } elseif ($path.Contains('[GAME_EXE_NAME]')) {
    foreach ($exe in $script:SnapCtx.GameExeNames) { $paths.Add(@{ P = $path.Replace('[GAME_EXE_NAME]', $exe); Enum = $null }) }
  } else { $paths.Add(@{ P = $path; Enum = $null }) }
  foreach ($p in $paths) {
    if ($name -eq '[GAME_EXE_PATH]') {
      $g = Get-SnapGameValueNames $p.P $Ref 'catalogue'
      foreach ($n in $g.Names) { $list.Add(@{ Path = $p.P; Name = $n; Enum = $g.Enum }) }
    } else { $list.Add(@{ Path = $p.P; Name = $name; Enum = $p.Enum }) }
  }
  @{ T = $list.ToArray() }
}

function Request-SnapPowerSchemeReads($Ref) {
  $keys = New-Object 'System.Collections.Generic.List[string]'
  $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'power-active' }) '当前活动电源方案（GUID 与名称）' $Ref 'catalogue'))
  $t = Get-SnapPowerSchemeTable
  foreach ($g in (Get-SnapEnumMembers 'power-schemes' $null $null $Ref).M) {
    $nm = $(if ($t.Schemes.ContainsKey($g)) { $t.Schemes[$g].Name } else { '?' })
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'power-scheme'; Scheme = $g; Enum = 'power-schemes' }) "电源方案 $g（$($nm)）" $Ref 'catalogue'))
  }
  foreach ($g in (Get-SnapEnumMembers 'powercfg-list' $null $null $Ref).M) {
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'powercfg-list'; Scheme = $g; Enum = 'powercfg-list' }) "powercfg /list 里的方案 $g" $Ref 'catalogue'))
  }
  @{ K = $keys.ToArray() }
}

function Request-SnapRegValueRead([string]$Path, [string]$Name, [string]$Enum, [string]$Label, $Ref, [string]$Origin) {
  $keys = New-Object 'System.Collections.Generic.List[string]'
  # PowerSettings\<子组>\<设置> 的 Attributes 就是 pcfg 的隐藏标志读数，用同一个键去重
  if ($Name -ieq 'Attributes' -and $Path -match "^(?i)HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\($($script:SnapGuidRx))\\($($script:SnapGuidRx))$") {
    $sub = $Matches[1]; $setting = $Matches[2]
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'pcfg-setting'; Sub = $sub; Setting = $setting }) "电源设置 PowerSettings\$sub\$setting 的 Attributes（隐藏标志）" $Ref $Origin))
    return @{ K = $keys.ToArray() }
  }
  $spec = [ordered]@{ Kind = 'regvalue'; Path = $Path; Name = $Name }
  if ($Enum) { $spec['Enum'] = $Enum }
  $keys.Add((Request-SnapRead $spec $Label $Ref $Origin))
  if ($Path -match '^(?i)HKLM:\\SYSTEM\\CurrentControlSet\\Services\\([^\\]+)$' -and $Name -ieq 'Start') {
    $svcName = $Matches[1]
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'service'; Name = $svcName }) "服务 $svcName 的启动类型（服务控制管理器读数）" $Ref $Origin))
  }
  @{ K = $keys.ToArray() }
}

# 一条底层操作 → 它会改动的那些值的读取。返回 @{ K = 键数组; Unmapped = 原因 }
function Get-SnapOpReadKeys($Op, $Ref) {
  $keys = New-Object 'System.Collections.Generic.List[string]'
  $kind = "$($Op.Kind)"
  if ("$($Op.Unresolved)") { return @{ K = [string[]]@(); Unmapped = "$($Op.Unresolved)" } }
  $label = $(if ("$($Op.Label)") { "$($Op.Label)" } elseif ("$($Op.Name)") { "$($Op.Name)" } else { $kind })
  if ($kind -eq 'reg' -or $kind -eq 'kvstr') {
    foreach ($t in (Get-SnapRegTargets $Op $Ref).T) {
      $lbl = "注册表 $($t.Path) → $($t.Name)"
      if ($kind -eq 'kvstr') { $lbl += "（复合字符串，本项只改其中的 $($Op.Key)）" }
      foreach ($k in (Request-SnapRegValueRead $t.Path $t.Name $t.Enum $lbl $Ref 'catalogue').K) { $keys.Add($k) }
    }
    if ("$($Op.Template)" -eq 'game-exe') {
      foreach ($exe in $script:SnapCtx.GameExeNames) {
        foreach ($p in @("$($script:SnapIfeoRoot)\$exe", "$($script:SnapIfeoRoot)\$exe\PerfOptions")) {
          $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'regkey'; Path = $p }) "注册表键 $p（整键：子键与全部值）" $Ref 'catalogue'))
        }
      }
    }
  } elseif ($kind -eq 'pcfg') {
    $sub = "$($Op.Sub)"; $setting = "$($Op.Setting)"
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'pcfg-setting'; Sub = $sub; Setting = $setting }) "电源设置「$label」的 Attributes（隐藏标志；PowerSettings\$sub\$setting）" $Ref 'catalogue'))
    # 方案列表归属给 power 项；这里只为每个方案登记 AC / DC 读数（覆盖活动方案、之前的活动方案、工具方案、卓越性能模板）
    $null = Request-SnapPowerSchemeReads $null
    $t = Get-SnapPowerSchemeTable
    foreach ($g in (Get-SnapEnumMembers 'power-schemes' $null $null $null).M) {
      $nm = $(if ($t.Schemes.ContainsKey($g)) { $t.Schemes[$g].Name } else { '?' })
      $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'pcfg-scheme'; Scheme = $g; Sub = $sub; Setting = $setting; Enum = 'power-schemes' }) "电源方案 $g（$($nm)）里「$label」的 AC / DC 显式值" $Ref 'catalogue'))
    }
  } elseif ($kind -eq 'mmagent') {
    $feat = "$($Op.Feature)"
    $what = switch ($feat) { 'mc' { '内存压缩 MemoryCompression' } 'pc' { '页面合并 PageCombining' } default { $feat } }
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'mmagent'; Feature = $feat }) "MMAgent → $what" $Ref 'catalogue'))
  } elseif ($kind -eq 'hib') {
    foreach ($n in @('HibernateEnabled', 'HibernateEnabledDefault', 'HiberFileType', 'HiberFileSizePercent')) {
      $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'regvalue'; Path = $script:SnapPowerKey; Name = $n }) "注册表 $($script:SnapPowerKey) → $n" $Ref 'catalogue'))
    }
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'regvalue'; Path = $script:SnapSessionPowerKey; Name = 'HiberbootEnabled' }) "注册表 $($script:SnapSessionPowerKey) → HiberbootEnabled（快速启动）" $Ref 'catalogue'))
    $hf = Join-Path $script:SnapSystemDrive 'hiberfil.sys'
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'hiberfil'; Path = $hf }) "休眠文件 $hf 是否存在" $Ref 'catalogue'))
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'powercfg-a' }) 'powercfg /a 的输出（休眠 / 快速启动是否可用）' $Ref 'catalogue'))
  } elseif ($kind -eq 'bcd') {
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'bcd'; Name = "$($Op.Name)" }) "引导配置 {current} → $($Op.Name)" $Ref 'catalogue'))
  } elseif ($kind -eq 'file') {
    $keys.Add((Request-SnapRead ([ordered]@{ Kind = 'file'; Path = "$($Op.Path)" }) "文件 $($Op.Path)" $Ref 'catalogue'))
  } elseif ($kind -eq 'npi') {
    return @{ K = [string[]]@(); Unmapped = 'NVIDIA Profile Inspector 导入写的是显卡驱动内部的配置数据库：没有只读的读取方式，软件也不备份、不复原它' }
  } else {
    return @{ K = [string[]]@(); Unmapped = "不认识的操作类型「$kind」，无法映射到只读读取" }
  }
  $uniq = New-Object 'System.Collections.Generic.List[string]'
  foreach ($k in $keys) { if (-not $uniq.Contains($k)) { $uniq.Add($k) } }
  @{ K = $uniq.ToArray(); Unmapped = $null }
}

# 复原白名单 → 读取。Get-OptItems 里的操作先登记，所以同一位置沿用操作的标签与项目归属；
# 只在白名单里的位置（旧版本备份才可能写回的 PagingFiles、DeviceDesc 等）用白名单标签
function Request-SnapWhitelistReads($Rules) {
  $n = 0
  foreach ($r in @($Rules)) {
    if ($null -eq $r) { continue }
    $names = @($r.Names | Where-Object { $_ })
    if ("$($r.Type)" -eq 'pattern') {
      $en = "regpath|$($r.Pattern)"
      foreach ($m in (Get-SnapEnumMembers $en $null "$($r.Pattern)" $null 'restore-whitelist').M) {
        foreach ($nm in $names) { $null = Request-SnapRegValueRead $m $nm $en "注册表 $m → $nm（复原白名单：旧版本的备份可能把它写回）" $null 'restore-whitelist'; $n++ }
      }
      continue
    }
    foreach ($nm in $names) {
      if ($nm -eq '[GAME_EXE_PATH]') {
        $g = Get-SnapGameValueNames "$($r.Path)" $null 'restore-whitelist'
        foreach ($gn in $g.Names) { $null = Request-SnapRegValueRead "$($r.Path)" $gn $g.Enum "注册表 $($r.Path) → $gn（复原白名单）" $null 'restore-whitelist'; $n++ }
        continue
      }
      $null = Request-SnapRegValueRead "$($r.Path)" $nm $null "注册表 $($r.Path) → $nm（复原白名单：旧版本的备份可能把它写回）" $null 'restore-whitelist'; $n++
    }
  }
  $n
}

# ---------- 引擎静态解析：只解析 AST，从不执行引擎里的任何一行 ----------
# 旧做法是点源引擎再调用 Get-OptItems，并用「拒绝清单」式的 AST 核验去证明调用链只读。复核证明拒绝清单
# 可以绕过（[IO.StreamWriter]::new、顶层调用写文件的引擎函数、Add-Type 编译的 C#），而且 Get-OptItems
# 里的硬件探测本身就会调用 Add-Type（在 %TEMP% 里跑 csc）和 nvidia-smi。所以现在完全不执行引擎：
# 用一个只认字面量、变量、哈希表 / 数组、字符串插值、if 分支和三个纯函数（Split-Path / Join-Path /
# ForEach-Object）的小求值器把目录「读」出来。遇到命令、.NET 调用、引擎函数，一律只产出「运行期才知道」
# 标记，绝不调用。

function New-SnapUnknown([string]$Why, $Ast, [string]$Source) {
  [pscustomobject]@{ DfbSnapUnknown = $true; Why = $Why; Ast = $Ast; Source = $Source }
}

function Test-SnapUnknown($V) {
  [bool]($V -is [Management.Automation.PSCustomObject] -and $null -ne $V.PSObject.Properties['DfbSnapUnknown'])
}

function Test-SnapTruthy($V) {
  if ($null -eq $V) { return $false }
  if ($V -is [bool]) { return $V }
  if ($V -is [string]) { return ($V.Length -gt 0) }
  if (Test-SnapIsList $V) {
    $n = @($V).Count
    if ($n -eq 0) { return $false }
    if ($n -eq 1) { return (Test-SnapTruthy @($V)[0]) }
    return $true
  }
  if ($V -is [ValueType]) { return [bool]$V }
  $true
}

function ConvertTo-SnapStaticString($V) {
  if ($null -eq $V) { return '' }
  if (Test-SnapIsList $V) { return ((@($V) | ForEach-Object { "$_" }) -join ' ') }
  "$V"
}

function New-SnapStaticContext($Ast) {
  $defs = @{}
  foreach ($s in $Ast.EndBlock.Statements) { if ($s -is [Management.Automation.Language.FunctionDefinitionAst]) { $defs[$s.Name] = $s } }
  @{ Ast = $Ast; Defs = $defs; Globals = @{}; GamePathExeNames = [string[]]@() }
}

# 引擎顶层的 $script:X = <常量表达式> 依次求值（引用了运行期才知道的东西就记成未知）
function Initialize-SnapStaticGlobals($Ctx) {
  foreach ($s in $Ctx.Ast.EndBlock.Statements) {
    if ($s -isnot [Management.Automation.Language.AssignmentStatementAst]) { continue }
    if ("$($s.Operator)" -ne 'Equals' -or $s.Left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
    if ("$($s.Left.VariablePath.DriveName)") { continue }
    $Ctx.Globals[(Get-SnapVarName $s.Left)] = (Get-SnapStaticStatementValue $s.Right @{} $Ctx).V
  }
}

function Get-SnapStaticVar($VarAst, $Env, $Ctx) {
  $up = "$($VarAst.VariablePath.UserPath)"
  $name = Get-SnapVarName $VarAst
  if ($name -ieq 'null') { return @{ V = $null } }
  if ($name -ieq 'true') { return @{ V = $true } }
  if ($name -ieq 'false') { return @{ V = $false } }
  if ("$($VarAst.VariablePath.DriveName)") { return @{ V = (New-SnapUnknown "变量 `$$up 在静态解析时没有确定的值" $VarAst $null) } }
  $scoped = $up -match '^(?i)(script|global):'
  if (-not $scoped -and $Env.ContainsKey($name)) { return @{ V = $Env[$name] } }
  if ($Ctx.Globals.ContainsKey($name)) { return @{ V = $Ctx.Globals[$name] } }
  @{ V = (New-SnapUnknown "变量 `$$up 在静态解析时没有确定的值" $VarAst $null) }
}

function Add-SnapStaticOutput($Out, $V) {
  if ($null -eq $V) { return }
  if (Test-SnapIsList $V) { foreach ($x in $V) { $Out.Add($x) }; return }
  $Out.Add($V)
}

# 语句输出的收集方式与 PowerShell 一致：0 个 → $null，1 个 → 标量，多个 → 数组；有未知就整体未知
function ConvertTo-SnapStaticCollected($Out) {
  foreach ($x in $Out) { if (Test-SnapUnknown $x) { return @{ V = $x } } }
  if ($Out.Count -eq 0) { return @{ V = $null } }
  if ($Out.Count -eq 1) { return @{ V = $Out[0] } }
  @{ V = $Out.ToArray() }
}

function Add-SnapStaticValues($A, $B) {
  if (Test-SnapUnknown $A) { return @{ V = $A } }
  if (Test-SnapUnknown $B) { return @{ V = $B } }
  if ($null -eq $A) { return @{ V = $B } }
  if (Test-SnapIsList $A) {
    $l = New-Object 'System.Collections.Generic.List[object]'
    foreach ($x in $A) { $l.Add($x) }
    if (Test-SnapIsList $B) { foreach ($x in $B) { $l.Add($x) } } else { $l.Add($B) }
    return @{ V = $l.ToArray() }
  }
  if ($A -is [string]) { return @{ V = ($A + (ConvertTo-SnapStaticString $B)) } }
  if (($A -is [int] -or $A -is [long] -or $A -is [double]) -and ($B -is [int] -or $B -is [long] -or $B -is [double])) { return @{ V = ($A + $B) } }
  @{ V = (New-SnapUnknown '不支持的 + 运算' $null $null) }
}

# 把一个块里所有赋值目标标成未知（条件不可确定、或语句类型不支持时）
function Set-SnapStaticTaint($Node, $Env, $Cause) {
  foreach ($a in $Node.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $l = $a.Left
    if ($l -is [Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
    if ($l -is [Management.Automation.Language.VariableExpressionAst]) { $Env[(Get-SnapVarName $l)] = $Cause }
  }
}

function Test-SnapStaticMayOutput($Node) {
  $hits = $Node.FindAll({ param($n)
      ($n -is [Management.Automation.Language.PipelineAst] -or $n -is [Management.Automation.Language.CommandExpressionAst]) -and
      ($n.Parent -is [Management.Automation.Language.StatementBlockAst] -or $n.Parent -is [Management.Automation.Language.NamedBlockAst]) }, $false)
  foreach ($h in $hits) { return $true }
  $false
}

function Set-SnapStaticAssign($S, $Env, $Ctx) {
  $left = $S.Left
  if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
  if ($left -isnot [Management.Automation.Language.VariableExpressionAst]) {
    Set-SnapStaticTaint $S $Env (New-SnapUnknown "不支持的赋值目标：$(Get-SnapShortText $S.Left.Extent.Text)" $S $null)
    return
  }
  $name = Get-SnapVarName $left
  $scoped = "$($left.VariablePath.UserPath)" -match '^(?i)(script|global):'
  $target = $(if ($scoped) { $Ctx.Globals } else { $Env })
  $rhs = (Get-SnapStaticStatementValue $S.Right $Env $Ctx).V
  $op = "$($S.Operator)"
  if ($op -eq 'Equals') { $target[$name] = $rhs; return }
  if ($op -eq 'PlusEquals') {
    # 不能写成 $cur = $(if ...)：子表达式会把空数组展开成 $null，@() += x 就变成了 $null += x
    if (-not $scoped -and $Env.ContainsKey($name)) { $cur = $Env[$name] }
    elseif ($Ctx.Globals.ContainsKey($name)) { $cur = $Ctx.Globals[$name] }
    else { $cur = New-SnapUnknown "变量 `$$name 在 += 之前没有确定的值" $S $null }
    $target[$name] = (Add-SnapStaticValues $cur $rhs).V
    return
  }
  $target[$name] = New-SnapUnknown "不支持的赋值运算 $op" $S $null
}

function Get-SnapStaticStatementValue($S, $Env, $Ctx) {
  if ($S -is [Management.Automation.Language.CommandExpressionAst] -and $S.Redirections.Count -eq 0) { return (Get-SnapStaticExpr $S.Expression $Env $Ctx) }
  if ($S -is [Management.Automation.Language.PipelineAst] -and $S.PipelineElements.Count -eq 1) {
    $e = $S.PipelineElements[0]
    if ($e -is [Management.Automation.Language.CommandExpressionAst] -and $e.Redirections.Count -eq 0) { return (Get-SnapStaticExpr $e.Expression $Env $Ctx) }
  }
  $out = New-Object 'System.Collections.Generic.List[object]'
  Invoke-SnapStaticStatement $S $Env $Ctx $out
  ConvertTo-SnapStaticCollected $out
}

function Invoke-SnapStaticBlock($Statements, $Env, $Ctx, $Out) {
  foreach ($s in $Statements) { Invoke-SnapStaticStatement $s $Env $Ctx $Out }
}

function Invoke-SnapStaticIf($S, $Env, $Ctx, $Out) {
  foreach ($c in $S.Clauses) {
    $cond = (Get-SnapStaticStatementValue $c.Item1 $Env $Ctx).V
    if (Test-SnapUnknown $cond) {
      $u = New-SnapUnknown "条件 $(Get-SnapShortText $c.Item1.Extent.Text) 不可静态确定（$($cond.Why)）" $S $cond.Source
      Set-SnapStaticTaint $S $Env $u
      if (Test-SnapStaticMayOutput $S) { $Out.Add($u) }
      return
    }
    if (Test-SnapTruthy $cond) { Invoke-SnapStaticBlock $c.Item2.Statements $Env $Ctx $Out; return }
  }
  if ($S.ElseClause) { Invoke-SnapStaticBlock $S.ElseClause.Statements $Env $Ctx $Out }
}

function Invoke-SnapStaticStatement($S, $Env, $Ctx, $Out) {
  if ($S -is [Management.Automation.Language.AssignmentStatementAst]) { Set-SnapStaticAssign $S $Env $Ctx; return }
  if ($S -is [Management.Automation.Language.CommandExpressionAst]) { Add-SnapStaticOutput $Out (Get-SnapStaticExpr $S.Expression $Env $Ctx).V; return }
  if ($S -is [Management.Automation.Language.PipelineAst]) { Add-SnapStaticOutput $Out (Get-SnapStaticPipeline $S $Env $Ctx).V; return }
  if ($S -is [Management.Automation.Language.IfStatementAst]) { Invoke-SnapStaticIf $S $Env $Ctx $Out; return }
  if ($S -is [Management.Automation.Language.TryStatementAst]) { Invoke-SnapStaticBlock $S.Body.Statements $Env $Ctx $Out; return }
  if ($S -is [Management.Automation.Language.FunctionDefinitionAst]) { return }
  $u = New-SnapUnknown "不支持静态求值的语句（$($S.GetType().Name)）" $S $null
  Set-SnapStaticTaint $S $Env $u
  if (Test-SnapStaticMayOutput $S) { $Out.Add($u) }
}

function Get-SnapStaticPipeline($P, $Env, $Ctx) {
  $cur = $null; $have = $false
  $els = $P.PipelineElements
  for ($i = 0; $i -lt $els.Count; $i++) {
    $e = $els[$i]
    if ($e.Redirections -and $e.Redirections.Count -gt 0) { return @{ V = (New-SnapUnknown '管道里有重定向' $e $null) } }
    if ($e -is [Management.Automation.Language.CommandExpressionAst]) {
      if ($i -gt 0) { return @{ V = (New-SnapUnknown '不支持的管道形状' $e $null) } }
      $cur = (Get-SnapStaticExpr $e.Expression $Env $Ctx).V; $have = $true; continue
    }
    if ($e -is [Management.Automation.Language.CommandAst]) { $cur = (Invoke-SnapStaticCommand $e $cur $have $Env $Ctx).V; $have = $true; continue }
    return @{ V = (New-SnapUnknown '不支持的管道元素' $e $null) }
  }
  @{ V = $cur }
}

# 命令只建模三个纯函数和引擎的游戏路径校验；其余命令一律「运行期才知道」，绝不调用
function Invoke-SnapStaticCommand($C, $InputValue, [bool]$HasInput, $Env, $Ctx) {
  $name = $C.GetCommandName()
  if (-not $name) { return @{ V = (New-SnapUnknown '动态调用' $C $null) } }
  if (Test-SnapUnknown $InputValue) { return @{ V = $InputValue } }
  $switches = @{}
  $posAsts = New-Object 'System.Collections.Generic.List[object]'
  for ($i = 1; $i -lt $C.CommandElements.Count; $i++) {
    $e = $C.CommandElements[$i]
    if ($e -is [Management.Automation.Language.CommandParameterAst]) {
      if ($e.Argument) { $posAsts.Add($e.Argument) } else { $switches[$e.ParameterName] = $true }
    } else { $posAsts.Add($e) }
  }
  $lname = $name.ToLowerInvariant()
  if ($lname -eq 'foreach-object' -or $lname -eq '%' -or $lname -eq 'foreach') {
    if (-not $HasInput -or $posAsts.Count -ne 1 -or $posAsts[0] -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) {
      return @{ V = (New-SnapUnknown '不支持的 ForEach-Object 形式' $C $null) }
    }
    $sb = $posAsts[0].ScriptBlock
    if ($sb.BeginBlock -or $sb.ProcessBlock -or $sb.ParamBlock) { return @{ V = (New-SnapUnknown '不支持的 ForEach-Object 形式' $C $null) } }
    $res = New-Object 'System.Collections.Generic.List[object]'
    $inputs = $(if ($null -eq $InputValue) { @() } else { @($InputValue) })
    foreach ($it in $inputs) {
      $e2 = @{}
      foreach ($k in $Env.Keys) { $e2[$k] = $Env[$k] }
      $e2['_'] = $it; $e2['PSItem'] = $it
      Invoke-SnapStaticBlock $sb.EndBlock.Statements $e2 $Ctx $res
    }
    return (ConvertTo-SnapStaticCollected $res)
  }
  $pure = ($lname -eq 'split-path' -or $lname -eq 'join-path' -or $name -ieq 'Resolve-ValidatedGamePath')
  $why = $(if ($Ctx.Defs.ContainsKey($name)) { "运行期由引擎函数 $name 计算" } else { "命令 $name 不做静态求值" })
  $vals = New-Object 'System.Collections.Generic.List[object]'
  foreach ($a in $posAsts) {
    $v = (Get-SnapStaticExpr $a $Env $Ctx).V
    if (Test-SnapUnknown $v) {
      # 纯函数把未知原样传下去；其余命令的结果算在这个命令自己头上（例如 Get-GpuClassKeyPath $hw）
      if ($pure) { return @{ V = $v } }
      return @{ V = (New-SnapUnknown $why $C $name) }
    }
    $vals.Add($v)
  }
  if ($lname -eq 'split-path' -and -not $HasInput -and $vals.Count -eq 1 -and $vals[0] -is [string]) {
    if ($switches.ContainsKey('Leaf')) { return @{ V = [IO.Path]::GetFileName($vals[0]) } }
    return @{ V = [IO.Path]::GetDirectoryName($vals[0]) }
  }
  if ($lname -eq 'join-path' -and -not $HasInput -and $vals.Count -eq 2) {
    return @{ V = ((ConvertTo-SnapStaticString $vals[0]).TrimEnd('\') + '\' + (ConvertTo-SnapStaticString $vals[1]).TrimStart('\')) }
  }
  # 引擎在 Get-OptItems 入口用 Resolve-ValidatedGamePath 校验游戏路径：合法就原样返回，否则抛错。按这个契约建模，
  # 允许的主程序名取自它自己的字符串常量。函数改了名或改了契约，游戏相关操作会变成「运行期才知道」并在
  # 「未纳入采集」里报出来，不会悄悄漏掉
  if ($name -ieq 'Resolve-ValidatedGamePath' -and -not $HasInput -and $vals.Count -eq 1 -and $vals[0] -is [string]) {
    $p = $vals[0]
    if ([IO.Path]::IsPathRooted($p) -and (@($Ctx.GamePathExeNames) -icontains [IO.Path]::GetFileName($p))) { return @{ V = $p } }
    return @{ V = (New-SnapUnknown '游戏路径没有通过引擎的校验' $C $name) }
  }
  @{ V = (New-SnapUnknown $why $C $name) }
}

function Get-SnapStaticExpandable($X, $Env, $Ctx) {
  if ($X.Extent.Text.Contains('`')) { return @{ V = (New-SnapUnknown '字符串里有转义字符' $X $null) } }
  $value = $X.Value
  $sb = New-Object Text.StringBuilder
  $pos = 0
  foreach ($n in $X.NestedExpressions) {
    $t = $n.Extent.Text
    $idx = $value.IndexOf($t, $pos, [StringComparison]::Ordinal)
    if ($idx -lt 0) { return @{ V = (New-SnapUnknown '无法定位字符串里的变量' $X $null) } }
    [void]$sb.Append($value.Substring($pos, $idx - $pos))
    $v = (Get-SnapStaticExpr $n $Env $Ctx).V
    if (Test-SnapUnknown $v) { return @{ V = $v } }
    [void]$sb.Append((ConvertTo-SnapStaticString $v))
    $pos = $idx + $t.Length
  }
  [void]$sb.Append($value.Substring($pos))
  @{ V = $sb.ToString() }
}

function Get-SnapStaticBinary($X, $Env, $Ctx) {
  $op = "$($X.Operator)"
  $l = (Get-SnapStaticExpr $X.Left $Env $Ctx).V
  if ($op -eq 'And' -and -not (Test-SnapUnknown $l) -and -not (Test-SnapTruthy $l)) { return @{ V = $false } }
  if ($op -eq 'Or' -and -not (Test-SnapUnknown $l) -and (Test-SnapTruthy $l)) { return @{ V = $true } }
  $r = (Get-SnapStaticExpr $X.Right $Env $Ctx).V
  if (Test-SnapUnknown $l) { return @{ V = $l } }
  if (Test-SnapUnknown $r) { return @{ V = $r } }
  $scalarL = ($null -eq $l -or $l -is [string] -or $l -is [ValueType])
  $scalarR = ($null -eq $r -or $r -is [string] -or $r -is [ValueType])
  switch ($op) {
    'And' { return @{ V = [bool](Test-SnapTruthy $r) } }
    'Or'  { return @{ V = [bool](Test-SnapTruthy $r) } }
    'Plus' { return (Add-SnapStaticValues $l $r) }
    'Ieq' { if ($scalarL -and $scalarR) { return @{ V = [bool]("$l" -ieq "$r") } } }
    'Ceq' { if ($scalarL -and $scalarR) { return @{ V = [bool]("$l" -ceq "$r") } } }
    'Ine' { if ($scalarL -and $scalarR) { return @{ V = [bool]("$l" -ine "$r") } } }
    'Cne' { if ($scalarL -and $scalarR) { return @{ V = [bool]("$l" -cne "$r") } } }
    'Iin' { if ($scalarL) { return @{ V = [bool](Test-SnapListContainsCi @($r) "$l") } } }
    'Inotin' { if ($scalarL) { return @{ V = -not [bool](Test-SnapListContainsCi @($r) "$l") } } }
  }
  @{ V = (New-SnapUnknown "不支持的运算 -$op" $X $null) }
}

function Get-SnapStaticExpr($X, $Env, $Ctx) {
  if ($X -is [Management.Automation.Language.StringConstantExpressionAst]) { return @{ V = $X.Value } }
  if ($X -is [Management.Automation.Language.ConstantExpressionAst]) { return @{ V = $X.Value } }
  if ($X -is [Management.Automation.Language.ExpandableStringExpressionAst]) { return (Get-SnapStaticExpandable $X $Env $Ctx) }
  if ($X -is [Management.Automation.Language.VariableExpressionAst]) { return (Get-SnapStaticVar $X $Env $Ctx) }
  if ($X -is [Management.Automation.Language.HashtableAst]) {
    $h = [ordered]@{}
    foreach ($kv in $X.KeyValuePairs) {
      $k = (Get-SnapStaticExpr $kv.Item1 $Env $Ctx).V
      if ($null -eq $k -or (Test-SnapUnknown $k)) { return @{ V = (New-SnapUnknown '哈希表的键不可静态确定' $X $null) } }
      $v = (Get-SnapStaticStatementValue $kv.Item2 $Env $Ctx).V
      # 记住是哪一个值的 AST 求不出来：底层操作要从那里接着做「形状分析」
      if (Test-SnapUnknown $v) { $v = New-SnapUnknown $v.Why $kv.Item2 $v.Source }
      $h["$k"] = $v
    }
    return @{ V = $h }
  }
  if ($X -is [Management.Automation.Language.ArrayLiteralAst]) {
    $l = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $X.Elements) {
      $v = (Get-SnapStaticExpr $e $Env $Ctx).V
      if (Test-SnapUnknown $v) { return @{ V = $v } }
      $l.Add($v)
    }
    return @{ V = $l.ToArray() }
  }
  if ($X -is [Management.Automation.Language.ArrayExpressionAst]) {
    $out = New-Object 'System.Collections.Generic.List[object]'
    Invoke-SnapStaticBlock $X.SubExpression.Statements $Env $Ctx $out
    foreach ($x in $out) { if (Test-SnapUnknown $x) { return @{ V = $x } } }
    return @{ V = $out.ToArray() }
  }
  if ($X -is [Management.Automation.Language.SubExpressionAst]) {
    $out = New-Object 'System.Collections.Generic.List[object]'
    Invoke-SnapStaticBlock $X.SubExpression.Statements $Env $Ctx $out
    return (ConvertTo-SnapStaticCollected $out)
  }
  if ($X -is [Management.Automation.Language.ParenExpressionAst]) { return (Get-SnapStaticStatementValue $X.Pipeline $Env $Ctx) }
  if ($X -is [Management.Automation.Language.UnaryExpressionAst]) {
    $v = (Get-SnapStaticExpr $X.Child $Env $Ctx).V
    if (Test-SnapUnknown $v) { return @{ V = $v } }
    switch ("$($X.TokenKind)") {
      'Minus'   { if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return @{ V = (-$v) } } }
      'Not'     { return @{ V = -not (Test-SnapTruthy $v) } }
      'Exclaim' { return @{ V = -not (Test-SnapTruthy $v) } }
      'Comma'   { return @{ V = [object[]]@(,$v) } }
    }
    return @{ V = (New-SnapUnknown "不支持的一元运算 $($X.TokenKind)" $X $null) }
  }
  if ($X -is [Management.Automation.Language.BinaryExpressionAst]) { return (Get-SnapStaticBinary $X $Env $Ctx) }
  if ($X -is [Management.Automation.Language.ConvertExpressionAst]) {
    $v = (Get-SnapStaticExpr $X.Child $Env $Ctx).V
    if (Test-SnapUnknown $v) { return @{ V = $v } }
    switch ("$($X.Type.TypeName.Name)".ToLowerInvariant()) {
      'ordered' { if ($v -is [Collections.IDictionary]) { return @{ V = $v } } }
      'bool'    { return @{ V = [bool](Test-SnapTruthy $v) } }
      'string'  { return @{ V = (ConvertTo-SnapStaticString $v) } }
      'int'     { if ($v -is [ValueType] -or $v -is [string]) { return @{ V = [int]$v } } }
      'array'   { return @{ V = [object[]]@($v) } }
    }
    return @{ V = (New-SnapUnknown "不支持的类型转换 [$($X.Type.TypeName.Name)]" $X $null) }
  }
  if ($X -is [Management.Automation.Language.MemberExpressionAst] -and $X -isnot [Management.Automation.Language.InvokeMemberExpressionAst] -and -not $X.Static) {
    $t = (Get-SnapStaticExpr $X.Expression $Env $Ctx).V
    if (Test-SnapUnknown $t) { return @{ V = $t } }
    if ($t -is [Collections.IDictionary] -and $X.Member -is [Management.Automation.Language.StringConstantExpressionAst]) {
      $m = $X.Member.Value
      if ($t.Contains($m)) { return @{ V = $t[$m] } }
      return @{ V = $null }
    }
  }
  @{ V = (New-SnapUnknown "不支持静态求值的表达式（$($X.GetType().Name)）" $X $null) }
}

function Invoke-SnapStaticFunction([string]$Name, [object[]]$ArgValues, $Ctx) {
  $def = $Ctx.Defs[$Name]
  if (-not $def) { return @{ Ok = $false; Out = @(); Env = @{} } }
  $env = @{}
  $params = @()
  if ($def.Parameters) { $params = @($def.Parameters) } elseif ($def.Body.ParamBlock) { $params = @($def.Body.ParamBlock.Parameters) }
  for ($i = 0; $i -lt $params.Count; $i++) {
    $env[(Get-SnapVarName $params[$i].Name)] = $(if ($i -lt $ArgValues.Count) { $ArgValues[$i] } else { $null })
  }
  $out = New-Object 'System.Collections.Generic.List[object]'
  if ($def.Body.BeginBlock -or $def.Body.ProcessBlock) { $out.Add((New-SnapUnknown "函数 $Name 含 begin / process 块" $def $null)) }
  else { Invoke-SnapStaticBlock $def.Body.EndBlock.Statements $env $Ctx $out }
  @{ Ok = $true; Out = $out.ToArray(); Env = $env }
}

# 去掉求值器内部的未知标记（带着 AST 引用，不能进 JSON）
function ConvertTo-SnapStaticPlain($V) {
  if (Test-SnapUnknown $V) { return @{ V = $script:SnapRuntimeMark } }
  if ($V -is [byte[]]) { return @{ V = ('hex:' + (ConvertTo-SnapHex $V)) } }
  if ($V -is [Collections.IDictionary]) {
    $d = [ordered]@{}
    foreach ($k in @($V.Keys)) { $d["$k"] = (ConvertTo-SnapStaticPlain $V[$k]).V }
    return @{ V = $d }
  }
  if (Test-SnapIsList $V) {
    $l = New-Object 'System.Collections.Generic.List[object]'
    foreach ($x in $V) { $l.Add((ConvertTo-SnapStaticPlain $x).V) }
    return @{ V = $l.ToArray() }
  }
  @{ V = $V }
}

# 「一条底层操作」的哈希表：有常量 Kind、没有 Id（优化项本身才有 Id）
function Test-SnapOpHashtableAst($H) {
  $hasKind = $false
  foreach ($kv in $H.KeyValuePairs) {
    if ($kv.Item1 -isnot [Management.Automation.Language.StringConstantExpressionAst]) { continue }
    if ($kv.Item1.Value -ieq 'Id') { return $false }
    if ($kv.Item1.Value -ieq 'Kind') {
      $v = $kv.Item2
      if ($v -is [Management.Automation.Language.PipelineAst] -and $v.PipelineElements.Count -eq 1) { $v = $v.PipelineElements[0] }
      if ($v -is [Management.Automation.Language.CommandExpressionAst]) { $v = $v.Expression }
      $hasKind = ($v -is [Management.Automation.Language.StringConstantExpressionAst])
    }
  }
  $hasKind
}

# Ops 在运行期才生成（按硬件）：先在 Ops 表达式里找操作哈希表；找不到就到它调用的引擎函数体里找。
# 只求这些哈希表的常量部分（Kind / Name / ...），路径之类的运行期值留作未知
function Get-SnapDynamicOps($Unknown, $Env, $Ctx) {
  $res = New-Object 'System.Collections.Generic.List[object]'
  $producer = "$($Unknown.Source)"
  $ast = $Unknown.Ast
  if ($ast) {
    foreach ($h in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true)) {
      if (-not (Test-SnapOpHashtableAst $h)) { continue }
      $v = (Get-SnapStaticExpr $h $Env $Ctx).V
      if ($v -is [Collections.IDictionary]) { $res.Add($v) }
    }
    if ($res.Count -eq 0) {
      foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $fn = $c.GetCommandName()
        if (-not $fn -or -not $Ctx.Defs.ContainsKey($fn)) { continue }
        $found = 0
        foreach ($h in $Ctx.Defs[$fn].Body.FindAll({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true)) {
          if (-not (Test-SnapOpHashtableAst $h)) { continue }
          $v = (Get-SnapStaticExpr $h @{} $Ctx).V
          if ($v -is [Collections.IDictionary]) { $res.Add($v); $found++ }
        }
        if ($found -gt 0) { $producer = $fn }
      }
    }
  }
  @{ Ops = $res.ToArray(); Producer = $producer }
}

function ConvertTo-SnapStaticOp($Op, [string]$Producer, $Rules) {
  $o = [ordered]@{}
  $unknown = New-Object 'System.Collections.Generic.List[string]'
  $src = $Producer
  foreach ($k in @($Op.Keys)) {
    $v = $Op[$k]
    if ($null -eq $v) { continue }
    if (Test-SnapUnknown $v) {
      $unknown.Add("$k")
      if ("$k" -ieq 'Path' -and $v.Source) { $src = "$($v.Source)" }
      continue
    }
    $o["$k"] = (ConvertTo-SnapStaticPlain $v).V
  }
  if ($unknown.Count -gt 0 -and $src) { $o['Runtime'] = $src }
  foreach ($k in $unknown) {
    if ($k -ieq 'Label') { continue }
    if ($k -ieq 'Value') { $o['Value'] = $script:SnapRuntimeMark; continue }
    if ($k -ieq 'Path' -and (@('reg', 'kvstr') -contains "$($o['Kind'])") -and "$($o['Name'])") {
      $o['Path'] = $script:SnapRuntimeMark
      $pats = @(@($Rules) | Where-Object { "$($_.Type)" -eq 'pattern' -and (@($_.Names) -icontains "$($o['Name'])") } | ForEach-Object { "$($_.Pattern)" })
      if ($pats.Count -gt 0) { $o['PathPatterns'] = (Get-SnapSortedStrings $pats).A; $o['Template'] = 'regpath' }
      else { $o['Unresolved'] = "路径在运行期$(if ($src) { "由引擎函数 $src " })按本机硬件决定，引擎复原白名单里也没有值名「$($o['Name'])」的路径规则，无法枚举" }
      continue
    }
    $o[$k] = $script:SnapRuntimeMark
    $o['Unresolved'] = "字段 $k 在运行期$(if ($src) { "由引擎函数 $src " })才确定，静态解析拿不到"
  }
  if (-not "$($o['Kind'])") { $o['Unresolved'] = '操作类型（Kind）不可静态确定' }
  @{ V = $o }
}

function ConvertTo-SnapStaticItems($Raw, $Env, $Ctx, $Rules, $Issues) {
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($it in $Raw) {
    if (Test-SnapUnknown $it) { $Issues.Add("Get-OptItems 的输出里有一项不可静态确定：$($it.Why)"); continue }
    if ($it -isnot [Collections.IDictionary]) { $Issues.Add('Get-OptItems 的输出里有一项不是哈希表'); continue }
    $o = [ordered]@{}
    foreach ($f in @('Id', 'Name', 'Kind', 'Tier', 'Admin', 'RequiresGame', 'Reboot', 'Check')) {
      if ($it.Contains($f) -and $null -ne $it[$f] -and -not (Test-SnapUnknown $it[$f])) { $o[$f] = (ConvertTo-SnapStaticPlain $it[$f]).V }
    }
    if (-not "$($o['Id'])") { $Issues.Add('Get-OptItems 的输出里有一项的 Id 不可静态确定'); continue }
    $opsRaw = $null
    if ($it.Contains('Ops')) { $opsRaw = $it['Ops'] }
    $producer = $null
    $raws = @()
    if (Test-SnapUnknown $opsRaw) {
      $dyn = Get-SnapDynamicOps $opsRaw $Env $Ctx
      $producer = $dyn.Producer
      $raws = @($dyn.Ops)
      $o['OpsRuntime'] = $(if ($producer) { $producer } else { 'unknown' })
      if ($raws.Count -eq 0) {
        $o['OpsUnresolved'] = "底层操作在运行期$(if ($producer) { "由引擎函数 $producer " })才生成，静态解析找不到它们的形状（$($opsRaw.Why)）"
        $Issues.Add("$($o['Id'])：$($o['OpsUnresolved'])")
      }
    } elseif ($null -ne $opsRaw) { $raws = @(@($opsRaw) | Where-Object { $null -ne $_ }) }
    $ops = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $raws) {
      if (Test-SnapUnknown $r) { $o['OpsUnresolved'] = "有一条底层操作不可静态确定（$($r.Why)）"; $Issues.Add("$($o['Id'])：$($o['OpsUnresolved'])"); continue }
      if ($r -isnot [Collections.IDictionary]) { $o['OpsUnresolved'] = '有一条底层操作不是哈希表'; $Issues.Add("$($o['Id'])：$($o['OpsUnresolved'])"); continue }
      $op = (ConvertTo-SnapStaticOp $r $producer $Rules).V
      if ($op.Contains('Unresolved')) { $Issues.Add("$($o['Id'])：$($op['Unresolved'])") }
      $ops.Add($op)
    }
    $o['Ops'] = $ops.ToArray()
    $items.Add($o)
  }
  @{ Items = $items.ToArray() }
}

function Get-SnapAstVarName($Ast) {
  if ($Ast -is [Management.Automation.Language.VariableExpressionAst]) { return (Get-SnapVarName $Ast) }
  $null
}

# 在一段条件里找「$name -ieq '...'」或「$name -iin @(...)」
function Get-SnapNameTest($Ast, $Ctx) {
  foreach ($b in $Ast.FindAll({ param($n) $n -is [Management.Automation.Language.BinaryExpressionAst] }, $true)) {
    if ((Get-SnapAstVarName $b.Left) -ine 'name') { continue }
    $op = "$($b.Operator)"
    if (($op -eq 'Ieq' -or $op -eq 'Ceq') -and $b.Right -is [Management.Automation.Language.StringConstantExpressionAst]) { return [string[]]@($b.Right.Value) }
    if ($op -eq 'Iin' -or $op -eq 'Cin') {
      $v = (Get-SnapStaticExpr $b.Right @{} $Ctx).V
      if (-not (Test-SnapUnknown $v) -and $null -ne $v) { return [string[]]@(@($v) | ForEach-Object { "$_" }) }
    }
  }
  $null
}

# 分支体里用「只认游戏主程序路径」的引擎函数校验 $name（例如 Test-AllowedGameExe $name）
function Get-SnapGameExeNameTest($Block, $Ctx) {
  foreach ($c in $Block.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
    $fn = $c.GetCommandName()
    if (-not $fn -or -not $Ctx.Defs.ContainsKey($fn)) { continue }
    $usesName = $false
    foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) { if ((Get-SnapAstVarName $e) -ieq 'name') { $usesName = $true } }
    if (-not $usesName) { continue }
    $exe = @($Ctx.Defs[$fn].Body.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '(?i)\.exe$' }, $true))
    if ($exe.Count -gt 0) { return [string[]]@('[GAME_EXE_PATH]') }
  }
  $null
}

# 从路径比较节点往上找它的值名约束：同一个 -and 里的另一半、外层 if 的条件、或者条件成立后分支体里的校验
function Get-SnapWhitelistNames($Node, $Body, $Ctx) {
  $child = $Node; $p = $Node.Parent
  while ($null -ne $p -and -not [object]::ReferenceEquals($p, $Body)) {
    if ($p -is [Management.Automation.Language.BinaryExpressionAst] -and "$($p.Operator)" -eq 'And') {
      $other = $(if ([object]::ReferenceEquals($p.Left, $child)) { $p.Right } else { $p.Left })
      $n = Get-SnapNameTest $other $Ctx
      if ($n) { return $n }
    }
    if ($p -is [Management.Automation.Language.IfStatementAst]) {
      foreach ($cl in $p.Clauses) {
        if ([object]::ReferenceEquals($cl.Item2, $child)) { $n = Get-SnapNameTest $cl.Item1 $Ctx; if ($n) { return $n } }
        if ([object]::ReferenceEquals($cl.Item1, $child)) { $n = Get-SnapGameExeNameTest $cl.Item2 $Ctx; if ($n) { return $n } }
      }
    }
    $child = $p; $p = $p.Parent
  }
  $null
}

# 引擎复原白名单 Test-AllowedBackupRegTarget → 规则表。它界定了复原可能写回的全部注册表位置：
# 新版 Apply 写的（Get-OptItems）、路径运行期才确定的（显卡）、以及只为旧版本备份保留的
function Get-SnapStaticWhitelist($Ctx, $Issues) {
  $fn = $Ctx.Defs['Test-AllowedBackupRegTarget']
  if (-not $fn) { $Issues.Add('引擎里找不到复原白名单函数 Test-AllowedBackupRegTarget：只采集 Get-OptItems 推导出的位置'); return @{ R = @() } }
  $body = $fn.Body
  $raw = New-Object 'System.Collections.Generic.List[object]'
  foreach ($s in $body.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
    if ($s.Value -match '^((?:HKLM|HKCU):\\[^|]+)\|([^|\\]+)$') { $raw.Add(@{ Type = 'value'; Path = $Matches[1]; Pattern = $null; Names = [string[]]@($Matches[2]) }) }
  }
  foreach ($b in $body.FindAll({ param($n) $n -is [Management.Automation.Language.BinaryExpressionAst] }, $true)) {
    $op = "$($b.Operator)"
    if (($op -eq 'Imatch' -or $op -eq 'Cmatch') -and (Get-SnapAstVarName $b.Left) -ieq 'path' -and
        $b.Right -is [Management.Automation.Language.StringConstantExpressionAst] -and $b.Right.Value -match '^\^(HKLM|HKCU):') {
      $names = Get-SnapWhitelistNames $b $body $Ctx
      if ($names) { $raw.Add(@{ Type = 'pattern'; Path = $null; Pattern = $b.Right.Value; Names = $names }) }
      else { $Issues.Add("复原白名单规则 $($b.Right.Value) 找不到对应的值名，没有采集") }
    } elseif (($op -eq 'Ieq' -or $op -eq 'Ceq') -and (Get-SnapAstVarName $b.Left) -ieq 'path' -and
              $b.Right -is [Management.Automation.Language.StringConstantExpressionAst] -and $b.Right.Value -match '^(HKLM|HKCU):\\[^|]+$') {
      $names = Get-SnapWhitelistNames $b $body $Ctx
      if ($names) { $raw.Add(@{ Type = 'value'; Path = $b.Right.Value; Pattern = $null; Names = $names }) }
      else { $Issues.Add("复原白名单规则 $($b.Right.Value) 找不到对应的值名，没有采集") }
    } elseif (($op -eq 'Icontains' -or $op -eq 'Ccontains') -and (Get-SnapAstVarName $b.Right) -ieq 'path' -and
              $b.Left -is [Management.Automation.Language.VariableExpressionAst]) {
      $vn = Get-SnapVarName $b.Left
      $asg = @($body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and (Get-SnapAstVarName $n.Left) -ieq $vn }, $true))
      $paths = $null
      if ($asg.Count -eq 1) { $paths = (Get-SnapStaticStatementValue $asg[0].Right @{} $Ctx).V }
      $names = Get-SnapWhitelistNames $b $body $Ctx
      if ($null -eq $paths -or (Test-SnapUnknown $paths) -or -not $names) { $Issues.Add("复原白名单规则 `$$vn -icontains `$path 不可静态确定，没有采集"); continue }
      foreach ($p in @($paths)) { if ("$p" -match '^(HKLM|HKCU):\\') { $raw.Add(@{ Type = 'value'; Path = "$p"; Pattern = $null; Names = $names }) } }
    }
  }
  # 合并同一路径 / 同一正则的值名，排序保证导出稳定
  $merged = @{}
  foreach ($r in $raw) {
    $key = $(if ($r.Type -eq 'pattern') { "pattern|$($r.Pattern)" } else { "value|$("$($r.Path)".ToLowerInvariant())" })
    if (-not $merged.ContainsKey($key)) { $merged[$key] = @{ Type = $r.Type; Path = $r.Path; Pattern = $r.Pattern; Names = (New-Object 'System.Collections.Generic.List[string]') } }
    foreach ($n in $r.Names) { if (-not (Test-SnapListContainsCi $merged[$key].Names $n)) { $merged[$key].Names.Add($n) } }
  }
  $rules = New-Object 'System.Collections.Generic.List[object]'
  foreach ($k in (Get-SnapSortedStrings @($merged.Keys)).A) {
    $m = $merged[$k]
    $o = [ordered]@{ Type = $m.Type }
    if ($m.Type -eq 'pattern') { $o['Pattern'] = $m.Pattern } else { $o['Path'] = $m.Path }
    $o['Names'] = (Get-SnapSortedStrings $m.Names.ToArray()).A
    $rules.Add($o)
  }
  @{ R = $rules.ToArray() }
}

function Read-SnapEngineText([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
  try { return (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { return [Text.Encoding]::Default.GetString($bytes) }
}

function Get-SnapEngineVersion([string]$Path) {
  try {
    $gui = Join-Path (Split-Path -Parent (Split-Path -Parent $Path)) 'gui\DeltaForceBooster-GUI.ps1'
    if ([IO.File]::Exists($gui)) {
      $t = [IO.File]::ReadAllText($gui, [Text.Encoding]::UTF8)
      if ($t -match '(?m)^\$script:GuiVersion\s*=\s*''(\d+\.\d+\.\d+)''\s*$') { return $Matches[1] }
    }
  } catch {}
  $head = Read-SnapEngineText $Path
  if ($head.Length -gt 400) { $head = $head.Substring(0, 400) }
  if ($head -match '\bv(\d+\.\d+\.\d+)\b') { return $Matches[1] }
  $null
}

function Get-SnapStaticGlobalString($Ctx, [string]$Name) {
  if (-not $Ctx.Globals.ContainsKey($Name)) { return $null }
  $v = $Ctx.Globals[$Name]
  if ($v -is [string] -and $v) { return $v }
  $null
}

# 把一条操作里本机特有的游戏位置换成模板，导出的目录才与机器无关；快照时再按本机枚举展开
function ConvertTo-SnapCatalogueOp($Op, [string]$GamePathUsed, $ExeNames) {
  $o = [ordered]@{}
  if ($Op -is [Collections.IDictionary]) {
    foreach ($k in @($Op.Keys)) { if ($null -ne $Op[$k]) { $o["$k"] = $Op[$k] } }
  } else {
    foreach ($p in $Op.PSObject.Properties) { if ($null -ne $p.Value) { $o[$p.Name] = $p.Value } }
  }
  if (-not $o.Contains('Template')) {
    $path = "$($o['Path'])"; $name = "$($o['Name'])"
    if ($GamePathUsed -and (@('reg', 'kvstr') -contains "$($o['Kind'])") -and $name -ieq $GamePathUsed) {
      $o['Name'] = '[GAME_EXE_PATH]'; $o['Template'] = 'game-path'
    } elseif ($path -match '^(HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\)([^\\]+)(\\PerfOptions)$' -and
              (@($ExeNames) -icontains $Matches[2])) {
      $o['Path'] = $Matches[1] + '[GAME_EXE_NAME]' + $Matches[3]; $o['Template'] = 'game-exe'
    }
  }
  $o
}

# 只保留与机器无关的项目字段（Default 会随台式机 / 笔记本变化，Note / Effect 是长文案，都不收）
function ConvertTo-SnapCatalogueItem($Item, [string]$GamePathUsed, $ExeNames) {
  $o = [ordered]@{}
  foreach ($f in @('Id', 'Name', 'Kind', 'Tier', 'Admin', 'RequiresGame', 'Reboot', 'Check', 'OpsRuntime', 'OpsUnresolved')) {
    $v = Get-SnapField $Item $f
    if ($null -ne $v) { $o[$f] = $v }
  }
  $ops = New-Object 'System.Collections.Generic.List[object]'
  $raw = Get-SnapField $Item 'Ops'
  foreach ($op in @($raw)) { if ($null -ne $op) { $ops.Add((ConvertTo-SnapCatalogueOp $op $GamePathUsed $ExeNames)) } }
  $o['Ops'] = $ops.ToArray()
  $o
}

# 只读解析一个引擎文件，得到与内置目录同形的目录文档。返回 @{ Ok; Reason; Doc; Issues; Functions }
function Get-SnapStaticCatalogue([string]$Path) {
  $res = [ordered]@{ Ok = $false; Reason = $null; Doc = $null; Issues = [string[]]@(); Functions = [string[]]@() }
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput((Read-SnapEngineText $Path), $Path, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) { $res.Reason = "引擎脚本语法解析失败：$($errors[0].Message)"; return $res }
  $ctx = New-SnapStaticContext $ast
  if (-not $ctx.Defs.ContainsKey('Get-OptItems')) { $res.Reason = '引擎里找不到 Get-OptItems'; return $res }
  $issues = New-Object 'System.Collections.Generic.List[string]'
  $fns = New-Object 'System.Collections.Generic.List[string]'
  Initialize-SnapStaticGlobals $ctx
  # 游戏路径允许的主程序名（引擎入口校验用的常量）
  $gp = @()
  if ($ctx.Defs.ContainsKey('Resolve-ValidatedGamePath')) {
    $fns.Add('Resolve-ValidatedGamePath')
    $gp = @($ctx.Defs['Resolve-ValidatedGamePath'].Body.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^[A-Za-z0-9][A-Za-z0-9_.-]*\.exe$' }, $true) | ForEach-Object { $_.Value })
  }
  $ctx.GamePathExeNames = (Get-SnapSortedStrings @($gp | Sort-Object -Unique)).A
  # IFEO 会写的全部游戏主程序名（含历史上的 DeltaForceClient.exe）
  $exe = @()
  if ($ctx.Defs.ContainsKey('Get-BoosterIfeoResiduePaths')) {
    $fns.Add('Get-BoosterIfeoResiduePaths')
    $r = Invoke-SnapStaticFunction 'Get-BoosterIfeoResiduePaths' @() $ctx
    foreach ($x in $r.Out) { if ($x -is [string] -and $x) { $exe += [IO.Path]::GetFileName($x) } }
  }
  if ($exe.Count -eq 0) { $exe = @($ctx.GamePathExeNames); $issues.Add('Get-BoosterIfeoResiduePaths 不可静态确定，IFEO 只按游戏路径允许的主程序名采集') }
  $exeNames = (Get-SnapSortedStrings @($exe | Sort-Object -Unique)).A
  $fns.Add('Test-AllowedBackupRegTarget')
  $rules = (Get-SnapStaticWhitelist $ctx $issues).R
  # 代入一个占位游戏路径求 Get-OptItems：按游戏路径落地的操作由此变成模板
  $ship = @($ctx.GamePathExeNames | Where-Object { $_ -match '(?i)shipping' })
  $leaf = $(if ($ship.Count) { $ship[0] } elseif ($ctx.GamePathExeNames.Count) { $ctx.GamePathExeNames[0] } else { 'DeltaForceClient-Win64-Shipping.exe' })
  $sentinel = "Z:\DFB-E2E-GAME-PATH\$leaf"
  $fns.Add('Get-OptItems')
  $call = Invoke-SnapStaticFunction 'Get-OptItems' @($sentinel) $ctx
  $norm = (ConvertTo-SnapStaticItems $call.Out $call.Env $ctx $rules $issues).Items
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($it in $norm) {
    $items.Add((ConvertTo-SnapCatalogueItem $it $sentinel $exeNames))
    if ($it['OpsRuntime'] -and $it['OpsRuntime'] -ne 'unknown' -and -not $fns.Contains("$($it['OpsRuntime'])")) { $fns.Add("$($it['OpsRuntime'])") }
  }
  if ($items.Count -eq 0) { $res.Reason = 'Get-OptItems 静态求值没有得到任何优化项'; $res.Issues = $issues.ToArray(); return $res }
  $consts = [ordered]@{}
  foreach ($c in @('ToolSchemeName', 'UltimateGuid', 'LockTaskPrefix', 'PowerCleanupTaskPrefix')) {
    $consts[$c] = Get-SnapStaticGlobalString $ctx $c
    if (-not $consts[$c]) { $issues.Add("引擎常量 `$script:$c 不可静态确定") }
  }
  $res.Doc = [ordered]@{
    Schema = $script:SnapCatalogueSchema
    EngineVersion = Get-SnapEngineVersion $Path
    EngineSha256 = Get-SnapSha256Hex ([IO.File]::ReadAllBytes($Path))
    ToolSchemeName = $consts.ToolSchemeName
    UltimateGuid = $consts.UltimateGuid
    LockTaskPrefix = $consts.LockTaskPrefix
    CleanupTaskPrefix = $consts.PowerCleanupTaskPrefix
    TaskNamePrefix = $(if ($consts.LockTaskPrefix) { ("$($consts.LockTaskPrefix)" -split '-')[0] } else { $null })
    GameExeNames = $exeNames
    GamePathExeNames = $ctx.GamePathExeNames
    Items = $items.ToArray()
    RestoreWhitelist = $rules
    StaticIssues = $issues.ToArray()
  }
  $res.Issues = $issues.ToArray()
  $res.Functions = (Get-SnapSortedStrings $fns.ToArray()).A
  $res.Ok = $true
  $res
}

# ---------- 优化项目录：找引擎、静态解析、或用内置目录 ----------

function Find-SnapEngine {
  if ($EnginePath) {
    $p = Resolve-SnapUserPath $EnginePath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "-EnginePath 指向的文件不存在：$p" }
    return [pscustomobject]@{ Path = $p; How = '参数 -EnginePath' }
  }
  $cands = New-Object 'System.Collections.Generic.List[object]'
  foreach ($pf in @([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles), $env:ProgramW6432)) {
    if ($pf) { $cands.Add([pscustomobject]@{ Path = (Join-Path $pf 'DeltaForceBooster\scripts\delta-booster.ps1'); How = '%ProgramFiles% 默认安装位置' }) }
  }
  foreach ($d in [IO.DriveInfo]::GetDrives()) {
    $ok = $false
    try { $ok = ($d.DriveType -eq [IO.DriveType]::Fixed -and $d.IsReady) } catch { $ok = $false }
    if ($ok) { $cands.Add([pscustomobject]@{ Path = (Join-Path $d.RootDirectory.FullName 'DeltaForceBooster\app\scripts\delta-booster.ps1'); How = "固定盘 $($d.Name) 的其他盘安装位置" }) }
  }
  if ($PSScriptRoot) {
    $cands.Add([pscustomobject]@{ Path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\delta-booster.ps1')); How = '本文件所在仓库' })
  }
  foreach ($c in $cands) { if (Test-Path -LiteralPath $c.Path -PathType Leaf) { return $c } }
  $null
}

function Get-SnapEmbeddedCatalogue {
  $doc = $null
  try { $doc = $script:SnapEmbeddedCatalogueJson | ConvertFrom-Json } catch { return $null }
  if ("$($doc.Schema)" -ne $script:SnapCatalogueSchema) { return $null }
  $doc
}

# 只对「决定采集范围」的部分求哈希（各项的 Id / Kind / Ops 与复原白名单）
function Get-SnapCatalogueHash($Doc) {
  $clean = New-Object 'System.Collections.Generic.List[object]'
  foreach ($it in @($Doc.Items)) { if ($null -ne $it) { $clean.Add([ordered]@{ Id = "$($it.Id)"; Kind = "$($it.Kind)"; Ops = $it.Ops }) } }
  $basis = [ordered]@{ Items = $clean.ToArray(); RestoreWhitelist = $Doc.RestoreWhitelist }
  Get-SnapSha256Hex ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SnapJson $basis -Compress)))
}

# 返回 @{ Engine; Source; Doc（与内置目录同形的 PSCustomObject）; Load; Issues; Functions }
function Get-SnapCatalogue($Embedded) {
  $engine = Find-SnapEngine
  $src = [ordered]@{ Engine = $engine; Source = $null; Doc = $null; Load = 'not-found'; Issues = [string[]]@(); Functions = [string[]]@() }
  if ($engine) {
    $st = $null
    try { $st = Get-SnapStaticCatalogue $engine.Path }
    catch { $script:SnapNotes.Add("静态解析引擎失败（$($_.Exception.Message.Trim())），改用内置目录") }
    if ($st -and $st.Ok) {
      $src.Source = 'live-engine'; $src.Load = 'static-parse'
      $src.Doc = (ConvertTo-SnapJson $st.Doc -Compress) | ConvertFrom-Json
      $src.Issues = $st.Issues; $src.Functions = $st.Functions
      return $src
    }
    $src.Load = 'rejected'
    if ($st) { $src.Issues = $st.Issues; $script:SnapNotes.Add("引擎无法静态解析（$($st.Reason)），改用内置目录") }
  }
  if (-not $Embedded) { throw '找不到可用的引擎，内置目录也无法解析，无法确定要采集什么' }
  $src.Source = 'embedded'; $src.Doc = $Embedded
  $src
}

# ---------- 游戏路径（与引擎 Find-GamePath 同一思路的只读查找，只看本地固定盘） ----------

function Resolve-SnapSearchRoot([string]$Candidate) {
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
  try {
    $value = "$Candidate".Trim().TrimEnd([char[]]@([char]0)).Trim()
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') { $value = $value.Substring(1, $value.Length - 2).Trim() }
    if (-not $value -or $value.StartsWith('\\') -or $value.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or -not [IO.Path]::IsPathRooted($value)) { return $null }
    $full = [IO.Path]::GetFullPath($value)
    if ($full.TrimEnd('\') -ieq ([IO.Path]::GetPathRoot($full)).TrimEnd('\')) { return $null }
    if ([IO.Directory]::Exists($full)) { return $full }
  } catch {}
  $null
}

function Get-SnapRegistryFileParent([string]$RawValue, [bool]$DisplayIcon) {
  if ([string]::IsNullOrWhiteSpace($RawValue)) { return $null }
  try {
    $text = "$RawValue".Trim().TrimEnd([char[]]@([char]0)).Trim()
    $filePath = $null
    if ($text -match '^"([^"]+)"(?:\s.*|,\s*-?\d+\s*)?$') { $filePath = $Matches[1] }
    elseif ($DisplayIcon) { $filePath = ($text -replace ',\s*-?\d+\s*$', '').Trim() }
    elseif ($text -match '^(.+?\.exe)(?:\s+(?:/|-).*)?$') { $filePath = $Matches[1] }
    if (-not $filePath -or $filePath.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or -not [IO.Path]::IsPathRooted($filePath)) { return $null }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($filePath))
    if ($parent) { return (Resolve-SnapSearchRoot $parent) }
  } catch {}
  $null
}

function Get-SnapRegString([string]$Path, [string]$Name) {
  $o = Open-SnapRegKey $Path
  if ($o.State -ne 'ok') { return $null }
  try { return "$($o.Key.GetValue($Name))" } finally { $o.Key.Close() }
}

function Find-SnapGamePath($ExeNames) {
  foreach ($pn in 'DeltaForceClient-Win64-Shipping', 'DeltaForceClient', 'DeltaForce') {
    foreach ($proc in @(Get-Process -Name $pn -ErrorAction SilentlyContinue)) {
      try { if ($proc.Path -and $proc.Path -match 'Shipping') { return @{ Path = $proc.Path; How = 'detected:running-process' } } } catch {}
    }
  }
  $roots = New-Object 'System.Collections.Generic.List[string]'
  foreach ($u in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
    $o = Open-SnapRegKey $u
    if ($o.State -ne 'ok') { continue }
    try {
      foreach ($n in $o.Key.GetSubKeyNames()) {
        $k = $null
        try { $k = $o.Key.OpenSubKey($n) } catch { $k = $null }
        if (-not $k) { continue }
        try {
          if ("$($k.GetValue('DisplayName'))" -notmatch '三角洲|Delta\s*Force|DeltaForce') { continue }
          foreach ($cand in @("$($k.GetValue('InstallLocation'))", (Get-SnapRegistryFileParent "$($k.GetValue('UninstallString'))" $false), (Get-SnapRegistryFileParent "$($k.GetValue('DisplayIcon'))" $true))) {
            $r = Resolve-SnapSearchRoot "$cand"
            if ($r) { $roots.Add($r) }
          }
        } finally { $k.Close() }
      }
    } finally { $o.Key.Close() }
  }
  foreach ($rk in 'HKLM:\SOFTWARE\WOW6432Node\Tencent\WeGame', 'HKCU:\Software\Tencent\WeGame') {
    $ip = Resolve-SnapSearchRoot (Get-SnapRegString $rk 'InstallPath')
    if ($ip) { $roots.Add($ip) }
  }
  $steam = Resolve-SnapSearchRoot (Get-SnapRegString 'HKCU:\Software\Valve\Steam' 'SteamPath')
  if ($steam) {
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if ([IO.File]::Exists($vdf)) {
      foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
        $lib = Resolve-SnapSearchRoot ($m.Groups[1].Value -replace '\\\\', '\')
        if ($lib) { $g = Resolve-SnapSearchRoot (Join-Path $lib 'steamapps\common\Delta Force'); if ($g) { $roots.Add($g) } }
      }
    }
  }
  $uniq = New-Object 'System.Collections.Generic.List[string]'
  foreach ($r in $roots) { if (-not (Test-SnapListContainsCi $uniq $r)) { $uniq.Add($r) } }
  foreach ($r in $uniq) {
    foreach ($rel in 'DeltaForce\Binaries\Win64\DeltaForceClient-Win64-Shipping.exe', 'Delta Force\DeltaForce\Binaries\Win64\DeltaForceClient-Win64-Shipping.exe', 'Binaries\Win64\DeltaForceClient-Win64-Shipping.exe') {
      $p = Join-Path $r $rel
      if ([IO.File]::Exists($p)) { return @{ Path = $p; How = 'detected:known-layout' } }
    }
  }
  foreach ($d in [IO.DriveInfo]::GetDrives()) {
    $ok = $false
    try { $ok = ($d.DriveType -eq [IO.DriveType]::Fixed -and $d.IsReady) } catch { $ok = $false }
    if (-not $ok) { continue }
    foreach ($guess in 'Delta Force', 'WeGame', 'WeGameApps', 'Program Files\WeGame') {
      $p = Resolve-SnapSearchRoot (Join-Path $d.RootDirectory.FullName $guess)
      if ($p -and -not (Test-SnapListContainsCi $uniq $p)) { $uniq.Add($p) }
    }
  }
  $found = New-Object 'System.Collections.Generic.List[string]'
  foreach ($r in $uniq) {
    foreach ($n in @($ExeNames)) {
      foreach ($f in @(Get-ChildItem -LiteralPath $r -Recurse -Depth 6 -Filter $n -File -ErrorAction SilentlyContinue)) { $found.Add($f.FullName) }
    }
    if ($found.Count -gt 0) { break }
  }
  $ship = @($found | Where-Object { $_ -match 'Shipping' })
  if ($ship.Count) { return @{ Path = $ship[0]; How = 'detected:search' } }
  if ($found.Count) { return @{ Path = $found[0]; How = 'detected:search' } }
  $null
}

# ---------- 机器信息 ----------

function Get-SnapOsBuild {
  $o = Open-SnapRegKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  if ($o.State -ne 'ok') { return @{ Build = 'unreadable'; Display = $null } }
  try {
    $k = $o.Key
    $build = '{0}.{1}.{2}.{3}' -f $k.GetValue('CurrentMajorVersionNumber'), $k.GetValue('CurrentMinorVersionNumber'), $k.GetValue('CurrentBuild'), $k.GetValue('UBR')
    $display = ("$($k.GetValue('ProductName')) $($k.GetValue('DisplayVersion'))").Trim()
  } finally { $o.Key.Close() }
  @{ Build = $build; Display = $display }
}

# ---------- 比对 ----------

$script:SnapMetaRules = @(
  @{ Field = 'SnapshotTime'; Label = '快照时间'; Class = 'expected'; Why = '每次拍摄的时间本来就不同' }
  @{ Field = 'MachineHash'; Label = '机器标识（计算机名哈希）'; Class = 'fail'; Why = '两份快照不是同一台机器拍的，没有可比性' }
  @{ Field = 'OsBuild'; Label = '系统版本号'; Class = 'fail'; Why = '两次之间系统版本变了（多半是重启时装了累积更新；测试期间请暂停 Windows 更新），差异不一定来自本软件' }
  @{ Field = 'HkcuSidHash'; Label = 'HKCU 所属用户（SID 哈希）'; Class = 'fail'; Why = '两次读的不是同一个用户的 HKCU，HKCU 下的项目没有可比性' }
  @{ Field = 'Elevated'; Label = '是否以管理员身份运行'; Class = 'fail'; Why = '两次权限不同，需要管理员才能读的项目没有可比性；请两次都用管理员身份运行' }
  @{ Field = 'RunAsSidHash'; Label = '运行脚本的账户（SID 哈希）'; Class = 'info'; Why = '只影响谁在读；HKCU 按上面那一行的用户读' }
  @{ Field = 'HkcuSource'; Label = 'HKCU 用户的确定方式'; Class = 'info'; Why = '测量方式的差别，不是系统状态' }
  @{ Field = 'EnginePath'; Label = '引擎路径'; Class = 'info'; Why = '测量工具本身的差别，不是系统状态（例如复原后已卸载软件）' }
  @{ Field = 'EngineSha256'; Label = '引擎文件 SHA256'; Class = 'info'; Why = '测量工具本身的差别，不是系统状态' }
  @{ Field = 'CatalogueSource'; Label = '优化项目录来源'; Class = 'info'; Why = '测量工具本身的差别，不是系统状态' }
  @{ Field = 'CatalogueSha256'; Label = '优化项目录（Id / Kind / Ops / 复原白名单）哈希'; Class = 'info'; Why = '目录不同时，只有一侧采集的项会显示为「无法比较」' }
  @{ Field = 'GamePath'; Label = '游戏路径'; Class = 'info'; Why = '只影响采集范围；两侧采集过的位置会合并后再读' }
  @{ Field = 'ConsoleCodePage'; Label = '控制台代码页'; Class = 'info'; Why = '只影响 powercfg 输出的解码' }
)

function Format-SnapMetaValue($Value) {
  if ($null -eq $Value -or "$Value" -eq '') { return '（无）' }
  if ($Value -is [bool]) { return $(if ($Value) { '是' } else { '否' }) }
  "$Value"
}

function Format-SnapRegData([string]$Kind, $Data) {
  switch ($Kind) {
    'DWord'        { try { return ('{0} (0x{1:X8})' -f [int64]$Data, [int64]$Data) } catch { return "$Data" } }
    'String'       { return "'$Data'" }
    'ExpandString' { return "'$Data'" }
    'MultiString'  { return ('[' + ((@($Data) | ForEach-Object { "'$_'" }) -join ', ') + ']') }
    'Binary'       { return "hex:$Data" }
  }
  "$Data"
}

function Format-SnapIdx($X) {
  if ($X -and $X.Exists) { return "$($X.Data)" }
  '未显式设置'
}

function Format-SnapValue([string]$Kind, $V) {
  if ($null -eq $V) { return '（无值）' }
  switch ($Kind) {
    'regvalue' {
      if (-not $V.Exists) { if ($V.KeyExists) { return '值不存在（键存在）' }; return '值不存在（键也不存在）' }
      return "$($V.Kind) $(Format-SnapRegData $V.Kind $V.Data)"
    }
    'regkey' {
      if (-not $V.Exists) { return '键不存在' }
      $subs = @($V.SubKeys | Where-Object { $null -ne $_ })
      $vals = @($V.Values.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.Kind) $(Format-SnapRegData $_.Value.Kind $_.Value.Data)" })
      if ($subs.Count -eq 0 -and $vals.Count -eq 0) { return '存在（空键）' }
      return "存在（子键：$(if ($subs.Count) { $subs -join '、' } else { '无' })；值：$(if ($vals.Count) { $vals -join '，' } else { '无' })）"
    }
    'pcfg-setting' {
      if (-not $V.SettingExists) { return '本机没有这个电源设置' }
      if (-not $V.Attributes.Exists) { return 'Attributes 不存在' }
      return "Attributes=$($V.Attributes.Data)（$(if ($V.Hidden) { '隐藏' } else { '可见' })）"
    }
    'pcfg-scheme' {
      if (-not $V.SchemeExists) { return '方案不存在' }
      return "AC=$(Format-SnapIdx $V.Ac)，DC=$(Format-SnapIdx $V.Dc)（设置子键$(if ($V.SettingKeyExists) { '存在' } else { '不存在' })）"
    }
    'power-active' { return "$($V.Guid)（$($V.Name)）" }
    'power-scheme' { if (-not $V.Exists) { return '不存在' }; return "存在「$($V.Name)」" }
    'powercfg-list' { if (-not $V.Listed) { return '未列出' }; if ($V.Active) { return '已列出（活动）' }; return '已列出' }
    'hiberfil' { if ($V.Exists) { return '存在' }; return '不存在' }
    'powercfg-a' { return (@($V.Lines) -join ' | ') }
    'bcd' { if ("$($V.Value)" -eq 'absent') { return '未设置（系统默认）' }; return "$($V.Value)" }
    'mmagent' { if ($V.Enabled) { return '开启' }; return '关闭' }
    'service' { if (-not $V.Exists) { return '服务不存在' }; return "启动类型 $($V.StartType)" }
    'sched' { $p = @($V.Tasks | ForEach-Object { "$($_.Path)" }); if ($p.Count -eq 0) { return '无' }; return ($p -join '、') }
    'file' { if (-not $V.Exists) { return '不存在' }; return "存在（SHA256 $($V.Sha256)）" }
  }
  ConvertTo-SnapJson $V -Compress
}

function Format-SnapPair([string]$Kind, $B, $A, [string]$BJson, [string]$AJson) {
  if ($Kind -eq 'powercfg-a' -or $Kind -eq 'sched') {
    $bl = $(if ($Kind -eq 'sched') { @($B.Tasks | ForEach-Object { ConvertTo-SnapJson $_ -Compress }) } else { @($B.Lines) })
    $al = $(if ($Kind -eq 'sched') { @($A.Tasks | ForEach-Object { ConvertTo-SnapJson $_ -Compress }) } else { @($A.Lines) })
    $onlyB = @($bl | Where-Object { $al -cnotcontains $_ })
    $onlyA = @($al | Where-Object { $bl -cnotcontains $_ })
    if ($onlyB.Count -or $onlyA.Count) {
      return @{ B = "仅之前有：$(if ($onlyB.Count) { $onlyB -join ' | ' } else { '无' })"; A = "仅之后有：$(if ($onlyA.Count) { $onlyA -join ' | ' } else { '无' })" }
    }
  }
  $fb = Format-SnapValue $Kind $B; $fa = Format-SnapValue $Kind $A
  if ($fb -ceq $fa) { $fb = $BJson; $fa = $AJson }
  @{ B = $fb; A = $fa }
}

function Format-SnapWhat($Entry) {
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($it in @($Entry.Items)) { if ($null -ne $it -and "$($it.Id)") { $parts.Add("$($it.Id)「$($it.Name)」") } }
  $label = "$($Entry.Label)"
  if ($parts.Count -gt 0) { return "项目 $($parts -join '、') — $label" }
  $label
}

function Test-SnapValuePresent([string]$Kind, $V) {
  if ($null -eq $V) { return $false }
  switch ($Kind) {
    'regvalue'      { return [bool]$V.Exists }
    'regkey'        { return [bool]$V.Exists }
    'power-scheme'  { return [bool]$V.Exists }
    'powercfg-list' { return [bool]$V.Listed }
    'pcfg-scheme'   { return [bool]($V.Ac.Exists -or $V.Dc.Exists) }
    'service'       { return [bool]$V.Exists }
    'file'          { return [bool]$V.Exists }
  }
  $true
}

function Get-SnapReadTable($Doc) {
  $t = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
  if ($Doc.Reads) { foreach ($p in $Doc.Reads.PSObject.Properties) { $t[$p.Name] = $p.Value } }
  $t
}

function Get-SnapTaskPathSet($Entry) {
  $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $list = $null
  if ("$($Entry.Status)" -eq 'ok' -and $Entry.Value) { $list = $Entry.Value.Tasks } elseif ($Entry.Info) { $list = $Entry.Info.SeenTasks }
  foreach ($t in @($list)) { if ($null -ne $t -and "$($t.Path)") { [void]$set.Add("$($t.Path)") } }
  @{ S = $set }
}

# 计划任务有一侧读不全时，两侧「确实看到」的任务仍可比较：之后新看到的任务一定是新出现的
# （两次权限相同，可见性规则相同）；之后读全了还看不到之前看到的任务，就是被删了
function Get-SnapTaskVerdict($B, $A) {
  $bSet = (Get-SnapTaskPathSet $B).S; $aSet = (Get-SnapTaskPathSet $A).S
  $appeared = @($aSet | Where-Object { -not $bSet.Contains($_) })
  $gone = @()
  if ("$($A.Status)" -eq 'ok') { $gone = @($bSet | Where-Object { -not $aSet.Contains($_) }) }
  if ($appeared.Count -eq 0 -and $gone.Count -eq 0) { return $null }
  $bl = $(if ($bSet.Count) { @($bSet) -join '、' } else { '无' }); $al = $(if ($aSet.Count) { @($aSet) -join '、' } else { '无' })
  "之前看到 $bl；之后看到 $al（有一侧任务列表读不全，但这些变化是确定的：新出现 $(if ($appeared.Count) { $appeared -join '、' } else { '无' })；消失 $(if ($gone.Count) { $gone -join '、' } else { '无' })）"
}

# 本次新建的工具方案：存在本身是预期的；方案里的 AC / DC 取值要和它的来源（卓越性能模板，同一份快照里读到的）一致，
# 否则就是复原没有把工具方案里的调优值改回去
function Get-SnapToolSchemeVerdict([string]$Kind, $Entry, $AfterTable, [string]$Ultimate, [string]$What, [string]$ToolName) {
  $T = $script:SnapTag
  if ($Kind -ne 'pcfg-scheme') {
    return @{ Fail = $false; Line = "$($T.Expected) $($What)：之前 不存在；之后 $(Format-SnapValue $Kind $Entry.Value)（工具自建方案「$ToolName」在复原后按设计保留）" }
  }
  $v = $Entry.Value
  $absent = [ordered]@{ Data = $null; Exists = $false; Kind = $null }
  $mine = ConvertTo-SnapJson ([ordered]@{ Ac = $v.Ac; Dc = $v.Dc }) -Compress
  $tplKey = "pcfg-scheme|$Ultimate|$($Entry.Spec.Sub)|$($Entry.Spec.Setting)".ToLowerInvariant()
  $tpl = $(if ($Ultimate -and $AfterTable.ContainsKey($tplKey)) { $AfterTable[$tplKey] } else { $null })
  if ($tpl -and "$($tpl.Status)" -eq 'ok' -and $tpl.Value.SchemeExists) {
    $base = ConvertTo-SnapJson ([ordered]@{ Ac = $tpl.Value.Ac; Dc = $tpl.Value.Dc }) -Compress
    $baseText = "卓越性能模板 $Ultimate 里是 AC=$(Format-SnapIdx $tpl.Value.Ac)，DC=$(Format-SnapIdx $tpl.Value.Dc)"
  } else {
    $base = ConvertTo-SnapJson ([ordered]@{ Ac = $absent; Dc = $absent }) -Compress
    $baseText = '读不到卓越性能模板，按「未显式设置」对照'
  }
  $now = "AC=$(Format-SnapIdx $v.Ac)，DC=$(Format-SnapIdx $v.Dc)"
  if ($mine -ceq $base) {
    return @{ Fail = $false; Line = "$($T.Expected) $($What)：之前 不存在；之后 $now（与$($baseText)一致；工具自建方案「$ToolName」在复原后按设计保留）" }
  }
  @{ Fail = $true; Line = "$($T.Fail) $($What)：之前 不存在（方案是这次新建的）；之后 $now（$($baseText)——复原没有把工具方案里的这一项改回去）" }
}

# 返回 @{ Lines; Failures; Same; Expected; Uncomparable; Info }
function Compare-SnapSnapshots($Before, $After) {
  $T = $script:SnapTag
  $fail = New-Object 'System.Collections.Generic.List[string]'
  $expected = New-Object 'System.Collections.Generic.List[string]'
  $unc = New-Object 'System.Collections.Generic.List[string]'
  $info = New-Object 'System.Collections.Generic.List[string]'
  $same = 0
  $bm = $Before.Meta; $am = $After.Meta
  foreach ($rule in $script:SnapMetaRules) {
    $bv = Format-SnapMetaValue $bm.($rule.Field); $av = Format-SnapMetaValue $am.($rule.Field)
    if ($bv -ceq $av) { continue }
    $line = "$($rule.Label)：之前 $bv；之后 $av（$($rule.Why)）"
    if ($rule.Class -eq 'expected') { $expected.Add("$($T.Expected) $line") }
    elseif ($rule.Class -eq 'fail') { $fail.Add("$($T.Fail) $line") }
    else { $info.Add("$($T.Info) $line") }
  }
  $bt = Get-SnapReadTable $Before; $at = Get-SnapReadTable $After
  $toolName = $(if ("$($am.ToolSchemeName)") { "$($am.ToolSchemeName)" } else { "$($bm.ToolSchemeName)" })
  $ultimate = $(if ("$($am.UltimateGuid)") { "$($am.UltimateGuid)" } else { "$($bm.UltimateGuid)" }).ToLowerInvariant()
  # 本次新出现的工具方案（之前没有它的读数，之后读到、且名称是工具专属名）。软件每次最多新建一个
  $newTool = New-Object 'System.Collections.Generic.List[string]'
  foreach ($k in $at.Keys) {
    $e = $at[$k]
    if ("$($e.Spec.Kind)" -ne 'power-scheme' -or "$($e.Status)" -ne 'ok' -or $e.Value.IsTool -ne $true) { continue }
    if ($bt.ContainsKey($k) -and ("$($bt[$k].Status)" -ne 'ok' -or $bt[$k].Value.Exists)) { continue }
    $newTool.Add("$($e.Spec.Scheme)".ToLowerInvariant())
  }
  $sortedNew = (Get-SnapSortedStrings $newTool.ToArray()).A
  $allowedTool = $(if ($sortedNew.Count -gt 0) { $sortedNew[0] } else { $null })
  $extraTool = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  for ($i = 1; $i -lt $sortedNew.Count; $i++) { [void]$extraTool.Add($sortedNew[$i]) }
  $schemeKinds = @('power-scheme', 'powercfg-list', 'pcfg-scheme')
  $bEnums = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($e in $bt.Values) { if ("$($e.Spec.Kind)" -eq 'enum' -and "$($e.Status)" -eq 'ok') { [void]$bEnums.Add("$($e.Spec.Enum)") } }
  $all = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($k in $bt.Keys) { [void]$all.Add($k) }
  foreach ($k in $at.Keys) { [void]$all.Add($k) }
  foreach ($k in (Get-SnapSortedStrings @($all)).A) {
    $hasB = $bt.ContainsKey($k); $hasA = $at.ContainsKey($k)
    $b = $(if ($hasB) { $bt[$k] } else { $null }); $a = $(if ($hasA) { $at[$k] } else { $null })
    $ref = $(if ($hasA) { $a } else { $b })
    $kind = "$($ref.Spec.Kind)"
    $what = Format-SnapWhat $ref
    $scheme = "$($ref.Spec.Scheme)".ToLowerInvariant()
    $isSchemeKind = ($scheme -and ($schemeKinds -contains $kind))
    if ($hasB -and $hasA) {
      if ("$($b.Status)" -ne 'ok' -or "$($a.Status)" -ne 'ok') {
        if ($kind -eq 'sched') {
          $sv = Get-SnapTaskVerdict $b $a
          if ($sv) { $fail.Add("$($T.Fail) $($what)：$sv"); continue }
        }
        $why = New-Object 'System.Collections.Generic.List[string]'
        if ("$($b.Status)" -ne 'ok' -and "$($a.Status)" -ne 'ok' -and "$($b.Reason)" -ceq "$($a.Reason)") { $why.Add("两次都是 unreadable: $($a.Reason)") }
        else {
          if ("$($b.Status)" -ne 'ok') { $why.Add("之前 unreadable: $($b.Reason)") }
          if ("$($a.Status)" -ne 'ok') { $why.Add("之后 unreadable: $($a.Reason)") }
        }
        $unc.Add("$($T.Unc) $($what)：$($why -join '；')")
        continue
      }
      $bj = ConvertTo-SnapJson $b.Value -Compress; $aj = ConvertTo-SnapJson $a.Value -Compress
      if ($bj -ceq $aj) { $same++; continue }
      # 枚举（成员清单）本身不出行：成员的增减由各成员自己的比较行报告，避免一处差异报两次
      if ($kind -eq 'enum') { continue }
      if ($kind -eq 'powercfg-a' -and "$($bm.ConsoleCodePage)" -ne "$($am.ConsoleCodePage)") {
        $unc.Add("$($T.Unc) $($what)：两次运行的控制台代码页不同（$($bm.ConsoleCodePage) / $($am.ConsoleCodePage)），powercfg 文字输出不可逐字比较")
        continue
      }
      $pair = Format-SnapPair $kind $b.Value $a.Value $bj $aj
      $fail.Add("$($T.Fail) $($what)：之前 $($pair.B)；之后 $($pair.A)")
      continue
    }
    if ($kind -eq 'enum') { continue }
    if ($hasA) {
      if ("$($a.Status)" -ne 'ok') { $unc.Add("$($T.Unc) $($what)：之前的快照没有采集这一项，本次也读不了（$($a.Reason)）"); continue }
      if ($isSchemeKind -and $extraTool.Contains($scheme)) {
        $fail.Add("$($T.Fail) $($what)：之前 不存在；之后 $(Format-SnapValue $kind $a.Value)（又多出一个工具方案「$toolName」：软件每次最多新建一个，多出来的是没清理掉的重复方案）")
        continue
      }
      if ($isSchemeKind -and $allowedTool -and $scheme -eq $allowedTool) {
        $v = Get-SnapToolSchemeVerdict $kind $a $at $ultimate $what $toolName
        if ($v.Fail) { $fail.Add($v.Line) } else { $expected.Add($v.Line) }
        continue
      }
      $en = "$($a.Spec.Enum)"
      if ($en -and $bEnums.Contains($en)) {
        if (Test-SnapValuePresent $kind $a.Value) { $fail.Add("$($T.Fail) $($what)：之前 不存在（之前的快照枚举时没有它）；之后 $(Format-SnapValue $kind $a.Value)") }
        else { $same++ }
        continue
      }
      $unc.Add("$($T.Unc) $($what)：之前的快照没有采集这一项")
      continue
    }
    $unc.Add("$($T.Unc) $($what)：本次快照没有采集这一项")
  }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($grp in @($fail, $expected, $unc, $info)) { foreach ($l in $grp) { $lines.Add($l) } }
  @{ Lines = $lines.ToArray(); Failures = $fail.Count; Same = $same; Expected = $expected.Count; Uncomparable = $unc.Count; Info = $info.Count }
}

# ---------- 快照主流程 ----------

function Get-SnapSidecarCheck($Embedded) {
  if (-not $PSScriptRoot) { return }
  $side = Join-Path $PSScriptRoot 'e2e-snapshot-catalogue.json'
  if (-not (Test-Path -LiteralPath $side -PathType Leaf)) { return }
  try {
    $sideDoc = [IO.File]::ReadAllText($side, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ((ConvertTo-SnapJson $sideDoc -Compress) -cne (ConvertTo-SnapJson $Embedded -Compress)) {
      $script:SnapNotes.Add('本文件的内置目录与同目录 e2e-snapshot-catalogue.json 不一致，请用 -ExportCatalogue 重新生成并同步')
    }
  } catch { $script:SnapNotes.Add("读取 e2e-snapshot-catalogue.json 失败：$($_.Exception.Message.Trim())") }
}

function Initialize-SnapContext($Doc, $Embedded) {
  $ctx = [ordered]@{}
  foreach ($f in @('ToolSchemeName', 'UltimateGuid', 'LockTaskPrefix', 'CleanupTaskPrefix', 'TaskNamePrefix')) {
    $v = "$($Doc.$f)"
    if (-not $v -and $Embedded) { $v = "$($Embedded.$f)" }
    $ctx[$f] = $v
  }
  $ctx['TaskPrefix'] = $ctx.TaskNamePrefix
  $exe = @($Doc.GameExeNames | Where-Object { $_ })
  if ($exe.Count -eq 0 -and $Embedded) { $exe = @($Embedded.GameExeNames | Where-Object { $_ }) }
  $gp = @($Doc.GamePathExeNames | Where-Object { $_ })
  if ($gp.Count -eq 0 -and $Embedded) { $gp = @($Embedded.GamePathExeNames | Where-Object { $_ }) }
  $ctx['GameExeNames'] = (Get-SnapSortedStrings $exe).A
  $ctx['GamePathExeNames'] = (Get-SnapSortedStrings $gp).A
  $ctx['GamePath'] = $null; $ctx['GamePathSource'] = 'none'
  $script:SnapCtx = $ctx
  if ($GamePath) {
    $p = Resolve-SnapUserPath $GamePath
    if ([IO.Path]::IsPathRooted($p) -and (@($ctx.GamePathExeNames) -icontains [IO.Path]::GetFileName($p))) { $ctx.GamePath = $p; $ctx.GamePathSource = 'param' }
    else { $script:SnapNotes.Add("-GamePath 不是三角洲行动主程序，已忽略：$p") }
  } else {
    $found = $null
    try { $found = Find-SnapGamePath $ctx.GamePathExeNames } catch { $script:SnapNotes.Add("查找游戏路径失败：$($_.Exception.Message.Trim())") }
    if ($found) { $ctx.GamePath = $found.Path; $ctx.GamePathSource = $found.How }
  }
}

function Get-SnapSnapshotDocument($BeforeDoc, [string]$BeforePath) {
  if (-not $script:SnapUser) { Initialize-SnapTargetUser }
  $embedded = Get-SnapEmbeddedCatalogue
  if ($embedded) { Get-SnapSidecarCheck $embedded } else { $script:SnapNotes.Add('内置目录无法解析') }
  $cat = Get-SnapCatalogue $embedded
  $doc = $cat.Doc
  Initialize-SnapContext $doc $embedded
  $catHash = Get-SnapCatalogueHash $doc
  $embHash = $(if ($embedded) { Get-SnapCatalogueHash $embedded } else { $null })
  if ($cat.Source -eq 'live-engine' -and $embHash -and $catHash -ne $embHash) {
    $script:SnapNotes.Add('已安装引擎的底层操作与本文件的内置目录不同（引擎版本可能不同）；本次以已安装引擎为准')
  }
  foreach ($iss in @($cat.Issues)) { if ($iss) { $script:SnapNotes.Add("引擎静态解析：$iss") } }

  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($it in @($doc.Items)) {
    if ($null -eq $it) { continue }
    $ci = ConvertTo-SnapCatalogueItem $it $null $script:SnapCtx.GameExeNames
    $ci['OpsSource'] = $(if ($cat.Source -eq 'embedded') { 'embedded' } elseif ($ci.Contains('OpsRuntime')) { 'static-runtime-shape' } else { 'static' })
    $items.Add($ci)
  }
  $unmapped = New-Object 'System.Collections.Generic.List[object]'
  $notApplicable = New-Object 'System.Collections.Generic.List[object]'
  $opCount = 0
  foreach ($ci in $items) {
    $ref = [ordered]@{ Id = "$($ci.Id)"; Name = "$($ci.Name)" }
    $itemKeys = New-Object 'System.Collections.Generic.List[string]'
    $kind = "$($ci.Kind)"
    if ($kind -eq 'power') {
      foreach ($k in (Request-SnapPowerSchemeReads $ref).K) { $itemKeys.Add($k) }
    } elseif ($kind -eq 'sched') {
      $itemKeys.Add((Request-SnapRead ([ordered]@{ Kind = 'sched'; Prefix = "$($script:SnapCtx.TaskPrefix)" }) "名称以 $($script:SnapCtx.TaskPrefix) 开头的计划任务（根文件夹为准，含隐藏任务）" $ref 'catalogue'))
    } elseif ($kind -eq 'check') {
      $ci['Note'] = '纯检测项：只读、不写系统，没有要采集的状态'
    } elseif ($kind -eq 'cache') {
      $ci['Note'] = '按设计不可复原：清理着色器缓存不备份、不还原（缓存由驱动自动重建），不纳入比较'
      $unmapped.Add([ordered]@{ ItemId = "$($ci.Id)"; ItemName = "$($ci.Name)"; OpIndex = $null; OpKind = $kind; Reason = $ci['Note'] })
    } elseif ($kind -eq 'npi') {
      $unmapped.Add([ordered]@{ ItemId = "$($ci.Id)"; ItemName = "$($ci.Name)"; OpIndex = $null; OpKind = $kind; Reason = 'NVIDIA Profile Inspector 导入写的是显卡驱动内部的配置数据库：没有只读的读取方式，软件也不备份、不复原它' })
    } elseif ($kind -ne 'multi' -and $ci.Ops.Count -eq 0) {
      $unmapped.Add([ordered]@{ ItemId = "$($ci.Id)"; ItemName = "$($ci.Name)"; OpIndex = $null; OpKind = $kind; Reason = "不认识的项目类型「$kind」，没有可映射的读取" })
    }
    if ("$($ci['OpsUnresolved'])") {
      $unmapped.Add([ordered]@{ ItemId = "$($ci.Id)"; ItemName = "$($ci.Name)"; OpIndex = $null; OpKind = $kind; Reason = "$($ci['OpsUnresolved'])" })
    }
    $ci['Reads'] = $itemKeys.ToArray()
    $idx = 0
    foreach ($op in $ci.Ops) {
      $op['Index'] = $idx
      $r = Get-SnapOpReadKeys $op $ref
      $op['Reads'] = $r.K
      if ($r.Unmapped) { $unmapped.Add([ordered]@{ ItemId = "$($ci.Id)"; ItemName = "$($ci.Name)"; OpIndex = $idx; OpKind = "$($op.Kind)"; Reason = $r.Unmapped }) }
      $idx++; $opCount++
    }
    if ($kind -eq 'multi' -and $ci.Ops.Count -eq 0 -and -not "$($ci['OpsUnresolved'])") {
      $why = '引擎没有为这一项生成任何底层操作'
      $ci['Note'] = $why
      $notApplicable.Add([ordered]@{ ItemId = "$($ci.Id)"; ItemName = "$($ci.Name)"; Reason = $why })
    }
  }
  $wlReads = Request-SnapWhitelistReads $doc.RestoreWhitelist

  # 之前快照里采集过的位置一律再读一遍：之前的活动方案、之前找到的游戏值等，就算本次目录里没有也不漏
  if ($BeforeDoc -and $BeforeDoc.Reads) {
    foreach ($p in $BeforeDoc.Reads.PSObject.Properties) {
      if ($script:SnapReads.Contains($p.Name)) { continue }
      $null = Request-SnapRead $p.Value.Spec "$($p.Value.Label)" $null 'before-snapshot' $p.Name
      $ne = $script:SnapReads[$p.Name]
      foreach ($it in @($p.Value.Items)) { if ($null -ne $it -and "$($it.Id)") { $ne.Items.Add([ordered]@{ Id = "$($it.Id)"; Name = "$($it.Name)" }) } }
    }
  }
  foreach ($k in @($script:SnapReads.Keys)) { Complete-SnapRead $k }

  $unreadable = 0
  $readsOut = [ordered]@{}
  foreach ($k in @($script:SnapReads.Keys)) {
    $e = $script:SnapReads[$k]
    if ($e.Status -ne 'ok') { $unreadable++ }
    $byId = @{}
    foreach ($it in $e.Items) { $byId["$($it.Id)"] = $it }
    $sortedItems = New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in (Get-SnapSortedStrings @($byId.Keys)).A) { $sortedItems.Add($byId[$id]) }
    $readsOut[$k] = [ordered]@{
      Spec = $e.Spec; Label = $e.Label; Items = $sortedItems.ToArray(); Origins = (Get-SnapSortedStrings $e.Origins.ToArray()).A
      Status = $e.Status; Reason = $e.Reason; Value = $e.Value; Info = $e.Info
    }
  }
  foreach ($ci in $items) {
    $iu = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $ci.Reads) { if ($script:SnapReads[$k].Status -ne 'ok') { $iu.Add("$($script:SnapReads[$k].Label)：$($script:SnapReads[$k].Reason)") } }
    $ci['Unreadable'] = $iu.ToArray()
    foreach ($op in $ci.Ops) {
      $u = New-Object 'System.Collections.Generic.List[string]'
      foreach ($k in $op.Reads) { if ($script:SnapReads[$k].Status -ne 'ok') { $u.Add("$($script:SnapReads[$k].Label)：$($script:SnapReads[$k].Reason)") } }
      $op['Unreadable'] = $u.ToArray()
    }
  }

  $os = Get-SnapOsBuild
  $engineSha = $null; $engineVersion = $null
  if ($cat.Engine) {
    $engineSha = Get-SnapSha256Hex ([IO.File]::ReadAllBytes($cat.Engine.Path))
    $engineVersion = Get-SnapEngineVersion $cat.Engine.Path
  }
  $pcList = $null
  if ($null -ne $script:SnapPowerCfgListCache) { $pcList = $script:SnapPowerCfgListCache.Lines }
  if ($script:SnapUser.JsonNote) { $script:SnapNotes.Add($script:SnapUser.JsonNote) }
  $meta = [ordered]@{
    ScriptVersion = $script:SnapScriptVersion
    SnapshotTime = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture)
    MachineHash = Get-SnapShortHash ("DFB-E2E|" + [Environment]::MachineName.ToUpperInvariant())
    OsBuild = $os.Build; OsDisplay = $os.Display
    Elevated = [bool]$script:SnapElevated
    HkcuSidHash = Get-SnapShortHash $script:SnapUser.Sid
    HkcuSource = $script:SnapUser.Source
    HkcuHiveLoaded = [bool]$script:SnapUser.HiveLoaded
    RunAsSidHash = Get-SnapShortHash $script:SnapUser.RunAsSid
    ConsoleCodePage = [int][Console]::OutputEncoding.CodePage
    EnginePath = $(if ($cat.Engine) { $cat.Engine.Path } else { $null })
    EngineFoundBy = $(if ($cat.Engine) { $cat.Engine.How } else { $null })
    EngineSha256 = $engineSha; EngineVersion = $engineVersion
    EngineLoad = $cat.Load
    EngineExecuted = $false
    EngineStaticFunctions = $cat.Functions
    EngineStaticIssues = $cat.Issues
    CatalogueSource = $cat.Source; CatalogueSha256 = $catHash; EmbeddedCatalogueSha256 = $embHash
    CatalogueMatchesEmbedded = [bool]($embHash -and $catHash -eq $embHash)
    GamePath = $script:SnapCtx.GamePath; GamePathSource = $script:SnapCtx.GamePathSource
    ToolSchemeName = $script:SnapCtx.ToolSchemeName
    UltimateGuid = $script:SnapCtx.UltimateGuid
    ItemCount = $items.Count; OpCount = $opCount
    RestoreWhitelistRuleCount = @($doc.RestoreWhitelist | Where-Object { $null -ne $_ }).Count; RestoreWhitelistReadCount = $wlReads
    ReadCount = $readsOut.Count; UnreadableCount = $unreadable
    PowerCfgList = $pcList
    Notes = $script:SnapNotes.ToArray()
  }
  if ($BeforeDoc) {
    $meta['Before'] = [ordered]@{ File = [IO.Path]::GetFileName($BeforePath); SnapshotTime = "$($BeforeDoc.Meta.SnapshotTime)" }
  }
  [ordered]@{
    Schema = $script:SnapSchema
    Meta = $meta
    Catalogue = [ordered]@{ Source = $cat.Source; Items = $items.ToArray(); RestoreWhitelist = $doc.RestoreWhitelist }
    Reads = $readsOut
    Unmapped = $unmapped.ToArray()
    NotApplicable = $notApplicable.ToArray()
  }
}

function Get-SnapExportDocument {
  $engine = Find-SnapEngine
  if (-not $engine) { throw '-ExportCatalogue 需要引擎（用 -EnginePath 指定）' }
  $st = Get-SnapStaticCatalogue $engine.Path
  if (-not $st.Ok) { throw "无法静态解析引擎：$($st.Reason)" }
  foreach ($iss in $st.Issues) { $script:SnapNotes.Add("静态解析：$iss") }
  $st.Doc
}

# >>> EMBEDDED-CATALOGUE-BEGIN（由 -ExportCatalogue 生成，必须与同目录 e2e-snapshot-catalogue.json 一致，勿手改）
$script:SnapEmbeddedCatalogueJson = @'
{
  "CleanupTaskPrefix": "DeltaForceBooster-RestorePowerOverride",
  "EngineSha256": "6300DCFF71FEC65D3F2ACE785B798C4C1E721178E7A7EB9D86F8193D1CDF503F",
  "EngineVersion": "0.17.1",
  "GameExeNames": [
    "DeltaForce.exe",
    "DeltaForceClient-Win64-Shipping.exe",
    "DeltaForceClient.exe"
  ],
  "GamePathExeNames": [
    "DeltaForce.exe",
    "DeltaForceClient-Win64-Shipping.exe"
  ],
  "Items": [
    {
      "Admin": true,
      "Id": "power-ultimate",
      "Kind": "power",
      "Name": "电源计划切换到「卓越性能」",
      "Ops": [],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "power-tuning",
      "Kind": "multi",
      "Name": "电源计划隐藏项深度调优（USB/调度/时间片）",
      "Ops": [
        {
          "Kind": "pcfg",
          "Label": "USB3 链路电源管理=关闭",
          "Setting": "d4e98f31-5ffe-4ce1-be31-1b38b384c009",
          "Sub": "2a737441-1930-4402-8d77-b2bebba308a3",
          "Value": 0
        },
        {
          "Kind": "pcfg",
          "Label": "处理器性能时间检查间隔=5000ms",
          "Setting": "4d2b0152-7d5c-498b-88e2-34345392a2c5",
          "Sub": "54533251-82be-4824-96c1-47b60b740d00",
          "Value": 5000
        },
        {
          "Kind": "pcfg",
          "Label": "大小核调度策略=高性能核心",
          "Optional": true,
          "Setting": "93b8b6dc-0698-4d1c-9ee4-0644e900c85d",
          "Sub": "54533251-82be-4824-96c1-47b60b740d00",
          "Value": 1
        },
        {
          "Kind": "pcfg",
          "Label": "短任务大小核调度=高性能核心",
          "Optional": true,
          "Setting": "bae08b81-2d5e-4688-ad6a-13243356654b",
          "Sub": "54533251-82be-4824-96c1-47b60b740d00",
          "Value": 1
        },
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "关闭电源节流",
          "Name": "PowerThrottlingOff",
          "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerThrottling",
          "Value": 1
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "powerplan-lock",
      "Kind": "sched",
      "Name": "锁定电源计划（防游戏偷改回去）",
      "Ops": [],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "hags",
      "Kind": "multi",
      "Name": "开启硬件加速 GPU 计划（HAGS）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "HwSchMode",
          "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
          "Value": 2
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "game-mode",
      "Kind": "multi",
      "Name": "开启 Windows 游戏模式",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "AutoGameModeEnabled",
          "Path": "HKCU:\\Software\\Microsoft\\GameBar",
          "Value": 1
        },
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "AllowAutoGameMode",
          "Path": "HKCU:\\Software\\Microsoft\\GameBar",
          "Value": 1
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "dvr-off",
      "Kind": "multi",
      "Name": "关闭 Xbox 后台录制（Game DVR）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "GameDVR_Enabled",
          "Path": "HKCU:\\System\\GameConfigStore",
          "Value": 0
        },
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "AppCaptureEnabled",
          "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\GameDVR",
          "Value": 0
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "prio-separation",
      "Kind": "multi",
      "Name": "前台程序调度权重（Win32PrioritySeparation=40）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "Win32PrioritySeparation",
          "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\PriorityControl",
          "Value": 40
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "paging-exec",
      "Kind": "multi",
      "Name": "内核代码常驻内存（DisablePagingExecutive）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "DisablePagingExecutive",
          "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management",
          "Value": 1
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "wer-off",
      "Kind": "multi",
      "Name": "关闭 Windows 错误报告",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "Disabled",
          "Path": "HKCU:\\Software\\Microsoft\\Windows\\Windows Error Reporting",
          "Value": 1
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "mem-compress-off",
      "Kind": "multi",
      "Name": "关闭内存压缩与页面合并",
      "Ops": [
        {
          "Feature": "mc",
          "Kind": "mmagent",
          "Label": "内存压缩"
        },
        {
          "Feature": "pc",
          "Kind": "mmagent",
          "Label": "页面合并"
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "transparency-off",
      "Kind": "multi",
      "Name": "关闭窗口透明特效",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "EnableTransparency",
          "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          "Value": 0
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "visualfx-perf",
      "Kind": "multi",
      "Name": "视觉效果调整为最佳性能（改变系统外观）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "VisualFXSetting",
          "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
          "Value": 2
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "mouse-accel-off",
      "Kind": "multi",
      "Name": "关闭鼠标「提高指针精确度」（电竞常规操作）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "String",
          "Name": "MouseSpeed",
          "Path": "HKCU:\\Control Panel\\Mouse",
          "Value": "0"
        },
        {
          "Kind": "reg",
          "Kind2": "String",
          "Name": "MouseThreshold1",
          "Path": "HKCU:\\Control Panel\\Mouse",
          "Value": "0"
        },
        {
          "Kind": "reg",
          "Kind2": "String",
          "Name": "MouseThreshold2",
          "Path": "HKCU:\\Control Panel\\Mouse",
          "Value": "0"
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "mpo-off",
      "Kind": "multi",
      "Name": "禁用 MPO 多平面叠加（治闪烁/卡顿）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "OverlayTestMode",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
          "Value": 5
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "net-throttling-off",
      "Kind": "multi",
      "Name": "解除多媒体网络限流",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "网络限流指数（-1 即 0xffffffff 不限流）",
          "Name": "NetworkThrottlingIndex",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile",
          "Value": -1
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "sys-responsiveness",
      "Kind": "multi",
      "Name": "提高系统响应度（MMCSS 后台保留=10%）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "后台 CPU 保留比例",
          "Name": "SystemResponsiveness",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile",
          "Value": 10
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "sysmain-off",
      "Kind": "multi",
      "Name": "禁用 SysMain 预取服务",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "SysMain 启动类型（4=禁用）",
          "Name": "Start",
          "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\SysMain",
          "Value": 4
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "wsearch-off",
      "Kind": "multi",
      "Name": "禁用 Windows Search 索引服务",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "WSearch 启动类型（4=禁用）",
          "Name": "Start",
          "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\WSearch",
          "Value": 4
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "hibernate-off",
      "Kind": "multi",
      "Name": "关闭休眠与快速启动",
      "Ops": [
        {
          "Kind": "hib",
          "Label": "休眠"
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "gpu-pstate-lock",
      "Kind": "multi",
      "Name": "禁止显卡动态降频（锁 P-State）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "DisableDynamicPstate",
          "Path": "[RUNTIME]",
          "PathPatterns": [
            "^HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Control\\\\Class\\\\\\{4d36e968-e325-11ce-bfc1-08002be10318\\}\\\\\\d{4}$"
          ],
          "Runtime": "Get-GpuClassKeyPath",
          "Template": "regpath",
          "Value": 1
        }
      ],
      "OpsRuntime": "Get-GpuClassKeyPath",
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Check": "Get-NvAutoOptStatus",
      "Id": "nv-autoopt-off",
      "Kind": "check",
      "Name": "NVIDIA App 自动优化体检（手动关闭）",
      "Ops": [],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "gpu-irq-affinity",
      "Kind": "multi",
      "Name": "显卡中断绑核（固定到高性能核）",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "中断策略=指定处理器",
          "Name": "DevicePolicy",
          "Path": "[RUNTIME]",
          "PathPatterns": [
            "^HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_(10DE|1002)&[^\\\\]+\\\\[^\\\\]+\\\\Device Parameters\\\\Interrupt Management\\\\Affinity Policy$"
          ],
          "Runtime": "Get-GpuIrqOps",
          "Template": "regpath",
          "Value": 4
        },
        {
          "Kind": "reg",
          "Kind2": "Binary",
          "Name": "AssignmentSetOverride",
          "Path": "[RUNTIME]",
          "PathPatterns": [
            "^HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_(10DE|1002)&[^\\\\]+\\\\[^\\\\]+\\\\Device Parameters\\\\Interrupt Management\\\\Affinity Policy$"
          ],
          "Runtime": "Get-GpuIrqOps",
          "Template": "regpath",
          "Value": "[RUNTIME]"
        }
      ],
      "OpsRuntime": "Get-GpuIrqOps",
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "mmcss-games",
      "Kind": "multi",
      "Name": "MMCSS 游戏任务档位拉满",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "GPU 优先级",
          "Name": "GPU Priority",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile\\Tasks\\Games",
          "Value": 8
        },
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Label": "任务优先级",
          "Name": "Priority",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile\\Tasks\\Games",
          "Value": 6
        },
        {
          "Kind": "reg",
          "Kind2": "String",
          "Label": "调度类别",
          "Name": "Scheduling Category",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile\\Tasks\\Games",
          "Value": "High"
        },
        {
          "Kind": "reg",
          "Kind2": "String",
          "Label": "文件IO优先级",
          "Name": "SFIO Priority",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile\\Tasks\\Games",
          "Value": "High"
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "windowed-opt-off",
      "Kind": "multi",
      "Name": "关闭「窗口化游戏优化」",
      "Ops": [
        {
          "Key": "SwapEffectUpgradeEnable",
          "Kind": "kvstr",
          "Label": "窗口化游戏优化",
          "Name": "DirectXUserGlobalSettings",
          "Path": "HKCU:\\Software\\Microsoft\\DirectX\\UserGpuPreferences",
          "Value": "0"
        }
      ],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Check": "Get-PcieLinkStatus",
      "Id": "pcie-check",
      "Kind": "check",
      "Name": "PCIe 通道体检（纯检测，不改设置）",
      "Ops": [],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Check": "Get-VcRedistStatus",
      "Id": "vcredist-check",
      "Kind": "check",
      "Name": "VC++ 运行库体检（纯检测，不改设置）",
      "Ops": [],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Check": "Get-MemoryXmpStatus",
      "Id": "xmp-check",
      "Kind": "check",
      "Name": "内存频率 / XMP·A-XMP·EXPO·DOCP 体检（纯检测）",
      "Ops": [],
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "shader-cache-clean",
      "Kind": "cache",
      "Name": "★ 解决掉帧：清理着色器缓存（实验功能，不保证生效）",
      "Ops": [],
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "dyntick-off",
      "Kind": "multi",
      "Name": "禁用动态计时器（bcdedit）",
      "Ops": [
        {
          "Kind": "bcd",
          "Label": "动态计时器",
          "Name": "disabledynamictick",
          "Value": "yes"
        }
      ],
      "Reboot": true,
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "fso-off",
      "Kind": "multi",
      "Name": "为游戏禁用全屏优化",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "String",
          "Name": "[GAME_EXE_PATH]",
          "Path": "HKCU:\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
          "Template": "game-path",
          "Value": "~ DISABLEDXMAXIMIZEDWINDOWEDMODE"
        }
      ],
      "RequiresGame": true,
      "Tier": "safe"
    },
    {
      "Admin": false,
      "Id": "gpu-pref",
      "Kind": "multi",
      "Name": "强制游戏使用高性能 GPU",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "String",
          "Name": "[GAME_EXE_PATH]",
          "Path": "HKCU:\\Software\\Microsoft\\DirectX\\UserGpuPreferences",
          "Template": "game-path",
          "Value": "GpuPreference=2;"
        }
      ],
      "RequiresGame": true,
      "Tier": "safe"
    },
    {
      "Admin": true,
      "Id": "game-priority",
      "Kind": "multi",
      "Name": "游戏进程 CPU/IO 优先级提到「高」",
      "Ops": [
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "CpuPriorityClass",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\[GAME_EXE_NAME]\\PerfOptions",
          "Template": "game-exe",
          "Value": 3
        },
        {
          "Kind": "reg",
          "Kind2": "DWord",
          "Name": "IoPriority",
          "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\[GAME_EXE_NAME]\\PerfOptions",
          "Template": "game-exe",
          "Value": 3
        }
      ],
      "RequiresGame": true,
      "Tier": "safe"
    }
  ],
  "LockTaskPrefix": "DeltaForceBooster-PowerPlanLock",
  "RestoreWhitelist": [
    {
      "Names": [
        "CpuPriorityClass",
        "IoPriority"
      ],
      "Pattern": "^HKLM:\\\\SOFTWARE\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Image File Execution Options\\\\(DeltaForceClient-Win64-Shipping|DeltaForceClient|DeltaForce)\\.exe\\\\PerfOptions$",
      "Type": "pattern"
    },
    {
      "Names": [
        "DisableDynamicPstate"
      ],
      "Pattern": "^HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Control\\\\Class\\\\\\{4d36e968-e325-11ce-bfc1-08002be10318\\}\\\\\\d{4}$",
      "Type": "pattern"
    },
    {
      "Names": [
        "DeviceDesc"
      ],
      "Pattern": "^HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_(10DE|1002)&[^\\\\]+\\\\[^\\\\]+$",
      "Type": "pattern"
    },
    {
      "Names": [
        "AssignmentSetOverride",
        "DevicePolicy"
      ],
      "Pattern": "^HKLM:\\\\SYSTEM\\\\CurrentControlSet\\\\Enum\\\\PCI\\\\VEN_(10DE|1002)&[^\\\\]+\\\\[^\\\\]+\\\\Device Parameters\\\\Interrupt Management\\\\Affinity Policy$",
      "Type": "pattern"
    },
    {
      "Names": [
        "MouseSpeed",
        "MouseThreshold1",
        "MouseThreshold2"
      ],
      "Path": "HKCU:\\Control Panel\\Mouse",
      "Type": "value"
    },
    {
      "Names": [
        "DirectXUserGlobalSettings",
        "[GAME_EXE_PATH]"
      ],
      "Path": "HKCU:\\Software\\Microsoft\\DirectX\\UserGpuPreferences",
      "Type": "value"
    },
    {
      "Names": [
        "AllowAutoGameMode",
        "AutoGameModeEnabled"
      ],
      "Path": "HKCU:\\Software\\Microsoft\\GameBar",
      "Type": "value"
    },
    {
      "Names": [
        "[GAME_EXE_PATH]"
      ],
      "Path": "HKCU:\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
      "Type": "value"
    },
    {
      "Names": [
        "VisualFXSetting"
      ],
      "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
      "Type": "value"
    },
    {
      "Names": [
        "AppCaptureEnabled"
      ],
      "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\GameDVR",
      "Type": "value"
    },
    {
      "Names": [
        "EnableTransparency"
      ],
      "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      "Type": "value"
    },
    {
      "Names": [
        "Disabled"
      ],
      "Path": "HKCU:\\Software\\Microsoft\\Windows\\Windows Error Reporting",
      "Type": "value"
    },
    {
      "Names": [
        "GameDVR_Enabled"
      ],
      "Path": "HKCU:\\System\\GameConfigStore",
      "Type": "value"
    },
    {
      "Names": [
        "NetworkThrottlingIndex",
        "SystemResponsiveness"
      ],
      "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile",
      "Type": "value"
    },
    {
      "Names": [
        "GPU Priority",
        "Priority",
        "SFIO Priority",
        "Scheduling Category"
      ],
      "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Multimedia\\SystemProfile\\Tasks\\Games",
      "Type": "value"
    },
    {
      "Names": [
        "OverlayTestMode"
      ],
      "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
      "Type": "value"
    },
    {
      "Names": [
        "HwSchMode"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
      "Type": "value"
    },
    {
      "Names": [
        "Attributes"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\2a737441-1930-4402-8d77-b2bebba308a3\\d4e98f31-5ffe-4ce1-be31-1b38b384c009",
      "Type": "value"
    },
    {
      "Names": [
        "Attributes"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\54533251-82be-4824-96c1-47b60b740d00\\4d2b0152-7d5c-498b-88e2-34345392a2c5",
      "Type": "value"
    },
    {
      "Names": [
        "Attributes"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\54533251-82be-4824-96c1-47b60b740d00\\93b8b6dc-0698-4d1c-9ee4-0644e900c85d",
      "Type": "value"
    },
    {
      "Names": [
        "Attributes"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerSettings\\54533251-82be-4824-96c1-47b60b740d00\\bae08b81-2d5e-4688-ad6a-13243356654b",
      "Type": "value"
    },
    {
      "Names": [
        "PowerThrottlingOff"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power\\PowerThrottling",
      "Type": "value"
    },
    {
      "Names": [
        "Win32PrioritySeparation"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\PriorityControl",
      "Type": "value"
    },
    {
      "Names": [
        "DisablePagingExecutive",
        "PagingFiles"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management",
      "Type": "value"
    },
    {
      "Names": [
        "Start"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\SysMain",
      "Type": "value"
    },
    {
      "Names": [
        "Start"
      ],
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\WSearch",
      "Type": "value"
    }
  ],
  "Schema": "dfb-e2e-catalogue/2",
  "StaticIssues": [],
  "TaskNamePrefix": "DeltaForceBooster",
  "ToolSchemeName": "三角洲优化 · 卓越性能",
  "UltimateGuid": "e9a42b02-d5df-448d-aa00-03f14749eb61"
}
'@
# <<< EMBEDDED-CATALOGUE-END

# 被点源时只定义函数，不执行（便于离线检查比对逻辑）
if ($MyInvocation.InvocationName -eq '.') { return }

try {
  if (-not $Out) { throw "缺少 -Out 参数。$($script:SnapUsage)" }
  $outFull = Resolve-SnapUserPath $Out
  if (Test-Path -LiteralPath $outFull) { throw "-Out 文件已存在，为防止覆盖已有快照，拒绝写入：$outFull" }
  $outDir = Split-Path -Parent $outFull
  if (-not $outDir -or -not (Test-Path -LiteralPath $outDir -PathType Container)) { throw "-Out 所在目录不存在（本脚本不会替你创建目录）：$outDir" }
  $script:SnapOutFullPath = $outFull

  if ($ExportCatalogue) {
    if ($Compare) { throw '-ExportCatalogue 不能和 -Compare 同时使用' }
    $doc = Get-SnapExportDocument
    Write-SnapOutFile ((ConvertTo-SnapJson $doc) + "`r`n")
    Write-Output "已导出优化项目录：$outFull（$(@($doc.Items).Count) 个优化项，$(@($doc.RestoreWhitelist).Count) 条复原白名单规则；引擎只被解析，没有执行）"
    foreach ($n in $script:SnapNotes) { Write-Output "  [提示] $n" }
    exit 0
  }

  $beforeDoc = $null; $cmpFull = $null
  if ($Compare) {
    $cmpFull = Resolve-SnapUserPath $Compare
    if (-not (Test-Path -LiteralPath $cmpFull -PathType Leaf)) { throw "-Compare 指向的文件不存在：$cmpFull" }
    if ($cmpFull -ieq $outFull) { throw '-Compare 与 -Out 不能是同一个文件' }
    $beforeDoc = [IO.File]::ReadAllText($cmpFull, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ("$($beforeDoc.Schema)" -ne $script:SnapSchema) { throw "-Compare 文件不是本版本脚本生成的快照（Schema=$($beforeDoc.Schema)，需要 $($script:SnapSchema)）" }
  }
  if (-not $script:SnapElevated) {
    Write-Warning '当前不是管理员身份：bcdedit、MMAgent、SYSTEM 计划任务等会记为 unreadable。正式测试请用管理员身份运行。'
  }
  Initialize-SnapTargetUser
  if ($script:SnapUser.Note) { Write-Warning $script:SnapUser.Note }

  $doc = Get-SnapSnapshotDocument $beforeDoc $cmpFull
  $cmp = $null; $exitCode = 0
  if ($beforeDoc) {
    # 用写盘后的同一份形状（JSON 往返）去比，比对结果连同快照一起写进 -Out（唯一的写入）
    $afterView = (ConvertTo-SnapJson $doc -Compress) | ConvertFrom-Json
    $cmp = Compare-SnapSnapshots $beforeDoc $afterView
    $exitCode = $(if ($cmp.Failures -gt 0) { 1 } else { 0 })
    $conclusion = $(if ($cmp.Failures -gt 0) { "发现 $($cmp.Failures) 处不一致 —— 系统没有完全回到之前的状态。" }
                    else { '除预期差异外完全一致 —— 系统已回到之前的状态。' })
    $doc['Comparison'] = [ordered]@{
      Before = [IO.Path]::GetFileName($cmpFull); BeforeSnapshotTime = "$($beforeDoc.Meta.SnapshotTime)"
      Lines = $cmp.Lines; Same = $cmp.Same; Expected = $cmp.Expected; Uncomparable = $cmp.Uncomparable; Info = $cmp.Info; Failures = $cmp.Failures
      Conclusion = $conclusion; ExitCode = $exitCode
    }
  }
  Write-SnapOutFile ((ConvertTo-SnapJson $doc) + "`r`n")

  $m = $doc.Meta
  Write-Output "已写入快照：$outFull"
  Write-Output "优化项目录来源：$($m.CatalogueSource)$(if ($m.EnginePath) { "（引擎 $($m.EnginePath)，$($m.EngineLoad)：只解析、不执行）" } else { '（未找到引擎）' })"
  Write-Output "共 $($m.ItemCount) 个优化项、$($m.OpCount) 条底层操作、$($m.RestoreWhitelistRuleCount) 条复原白名单规则；采集 $($m.ReadCount) 处读数，其中 $($m.UnreadableCount) 处无法读取。"
  foreach ($k in $doc.Reads.Keys) {
    $e = $doc.Reads[$k]
    if ($e.Status -ne 'ok') { Write-Output "  unreadable: $($e.Label) —— $($e.Reason)" }
  }
  foreach ($u in $doc.Unmapped) { Write-Output "  未纳入采集：$($u.ItemId)「$($u.ItemName)」$(if ($null -ne $u.OpIndex) { " 第 $($u.OpIndex) 条操作" })—— $($u.Reason)" }
  foreach ($n in $doc.NotApplicable) { Write-Output "  本机不适用：$($n.ItemId)「$($n.ItemName)」—— $($n.Reason)" }
  foreach ($n in $m.Notes) { Write-Output "  [提示] $n" }

  if (-not $cmp) { exit 0 }

  Write-Output ''
  Write-Output "比对：之前 $([IO.Path]::GetFileName($cmpFull))（$($beforeDoc.Meta.SnapshotTime)）→ 之后 $([IO.Path]::GetFileName($outFull))（$($m.SnapshotTime)）"
  foreach ($l in $cmp.Lines) { Write-Output $l }
  Write-Output "小结：一致 $($cmp.Same) 处；预期差异 $($cmp.Expected) 处；无法比较 $($cmp.Uncomparable) 处；信息 $($cmp.Info) 条；失败 $($cmp.Failures) 处。"
  if ($cmp.Failures -eq 0 -and $cmp.Uncomparable -gt 0) { Write-Output "注意：有 $($cmp.Uncomparable) 处无法比较，结论只覆盖可比较的部分。" }
  Write-Output "结论：$($doc.Comparison.Conclusion)"
  Write-Output ("RESULT: {0} (failures={1}, expected={2}, uncomparable={3}, info={4}, same={5}); the full UTF-8 report is in the 'Comparison' section of the -Out file." -f $(if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }), $cmp.Failures, $cmp.Expected, $cmp.Uncomparable, $cmp.Info, $cmp.Same)
  exit $exitCode
} catch {
  Write-Output "[错误] $($_.Exception.Message)"
  Write-Output $script:SnapUsage
  exit 2
}
