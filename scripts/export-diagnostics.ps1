#requires -Version 5.1
param([string]$OutputPath = '')

# 独立诊断导出器。
#
# 存在的理由：主界面打不开时，用户唯一的报障通道是主界面里的「上传完整诊断」——
# 要用打不开的软件去上报软件打不开。这个脚本解开那个死锁。
#
# 三条设计约束：
#   1. 不提权。「提权被拒」本身就是要诊断的故障之一，要求管理员等于死锁。
#      读不到的东西如实写「需要管理员权限，未包含」，不去尝试提权。
#   2. 不依赖主程序的任何组件。不点源 delta-booster.ps1，不碰 EngineHost，
#      不读任何需要会话上下文的东西 —— 那些恰恰可能是坏掉的部分。
#   3. 任何一节失败都不能中断整体。每节独立 try/catch，失败就在报告里写明原因。
#      一份缺几节的报告远胜于一个异常堆栈。

$ErrorActionPreference = 'Continue'
$lines = New-Object Collections.ArrayList

function Add-Line([string]$Text = '') { [void]$lines.Add($Text) }
function Add-Section([string]$Title) {
  Add-Line ''
  Add-Line ('=' * 64)
  Add-Line "  $Title"
  Add-Line ('=' * 64)
}
# 每一节的统一包装：失败只影响本节
function Add-Probe([string]$Title, [scriptblock]$Body) {
  Add-Section $Title
  try { & $Body } catch { Add-Line "（本节采集失败：$($_.Exception.Message)）" }
}

$root = Split-Path -Parent $PSScriptRoot
$programData = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'DeltaForceBooster'

Add-Line '帧率优化助手 · 诊断信息'
Add-Line ("生成时间：{0:yyyy-MM-dd HH:mm:ss K}" -f [DateTimeOffset]::Now)
Add-Line '这份文件用于排查「软件打不开」。可以直接发给维护者。'
Add-Line '内容只有系统环境、安装状态与启动日志，不含账号密码、注册表内容或游戏文件。'

Add-Probe '运行环境' {
  Add-Line ("操作系统    {0}" -f [Environment]::OSVersion.VersionString)
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Add-Line ("系统版本    {0} (Build {1})" -f $os.Caption, $os.BuildNumber)
    Add-Line ("系统语言    {0}" -f $os.OSLanguage)
  } catch { Add-Line "系统版本    读取失败：$($_.Exception.Message)" }
  Add-Line ("区域设置    {0} / 系统默认 {1}" -f
    [Globalization.CultureInfo]::CurrentCulture.Name, (Get-Culture).Name)
  Add-Line ("PowerShell  {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
  Add-Line (".NET CLR    {0}" -f [Environment]::Version)
  Add-Line ("64 位系统   {0} / 64 位进程 {1}" -f [Environment]::Is64BitOperatingSystem, [Environment]::Is64BitProcess)
  try { Add-Line ("执行策略    {0}" -f (Get-ExecutionPolicy)) } catch {}
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
  Add-Line ("当前会话提权 {0}（本工具刻意不提权）" -f $(if ($isAdmin) { '是' } else { '否' }))
}

Add-Probe '安装状态' {
  Add-Line "安装目录    $root"
  Add-Line ("目录存在    {0}" -f (Test-Path -LiteralPath $root -PathType Container))
  foreach ($rel in '启动优化工具.exe', 'EngineHost.exe', 'install.identity',
                   'gui\DeltaForceBooster-GUI.ps1', 'scripts\delta-booster.ps1') {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      $f = Get-Item -LiteralPath $p -Force
      Add-Line ("  [有] {0,-34} {1,10} 字节  {2:yyyy-MM-dd HH:mm}" -f $rel, $f.Length, $f.LastWriteTime)
    } else {
      Add-Line ("  [缺] {0}" -f $rel)
    }
  }
  $identity = Join-Path $root 'install.identity'
  if (Test-Path -LiteralPath $identity -PathType Leaf) {
    Add-Line 'install.identity 内容（哈希值本身不敏感）：'
    foreach ($l in (Get-Content -LiteralPath $identity -ErrorAction SilentlyContinue)) { Add-Line "  $l" }
  }
  try {
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root)))
    Add-Line ("所在卷        {0}  类型 {1}  文件系统 {2}  剩余 {3:N1} GB" -f
      $drive.Name, $drive.DriveType, $drive.DriveFormat, ($drive.AvailableFreeSpace / 1GB))
  } catch {}
}

Add-Probe '受保护数据目录' {
  Add-Line "路径        $programData"
  if (-not (Test-Path -LiteralPath $programData -PathType Container)) {
    Add-Line '状态        不存在 —— 说明这台机器还没有成功启动过一次，或该目录被清理过。'
    return
  }
  Add-Line '状态        存在'
  try {
    $acl = Get-Acl -LiteralPath $programData
    Add-Line ("所有者      {0}" -f $acl.Owner)
    Add-Line '权限：'
    foreach ($r in $acl.Access) {
      Add-Line ("  {0,-44} {1}" -f $r.IdentityReference, $r.FileSystemRights)
    }
  } catch { Add-Line "权限        读取失败（通常就是权限不足本身）：$($_.Exception.Message)" }
  foreach ($sub in 'startup-logs', 'backup', 'users', 'logs') {
    $p = Join-Path $programData $sub
    Add-Line ("  子目录 {0,-14} {1}" -f $sub, $(if (Test-Path -LiteralPath $p) { '存在' } else { '不存在' }))
  }
}

Add-Probe '启动日志（最近 3 次）' {
  $logDir = Join-Path $programData 'startup-logs'
  if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    Add-Line '没有 startup-logs 目录。可能是这台机器还没运行过带启动日志的版本。'
    return
  }
  $files = @(Get-ChildItem -LiteralPath $logDir -Filter 'startup-*.log' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 3)
  if (-not $files.Count) {
    Add-Line '目录存在但没有日志文件。若这里本该有内容，说明启动在写日志之前就失败了。'
    return
  }
  foreach ($f in $files) {
    Add-Line ''
    Add-Line ("----- {0}  ({1:yyyy-MM-dd HH:mm:ss}) -----" -f $f.Name, $f.LastWriteTime)
    try {
      foreach ($l in (Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop)) { Add-Line "  $l" }
    } catch { Add-Line "  读取失败：$($_.Exception.Message)（多半是权限不足，需要管理员权限才能读取）" }
  }
}

Add-Probe '相关进程' {
  $names = 'DeltaForceBooster-GUI', 'EngineHost', '启动优化工具', 'powershell', 'PresentMon'
  $found = $false
  foreach ($n in $names) {
    foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
      $found = $true
      $path = ''
      try { $path = $p.Path } catch { $path = '（读不到路径，通常是其他用户或更高完整性的进程）' }
      Add-Line ("  PID {0,-7} {1,-26} {2}" -f $p.Id, $p.ProcessName, $path)
    }
  }
  if (-not $found) { Add-Line '没有检测到相关进程在运行。' }
}

Add-Probe '安全软件' {
  # 杀软拦截是「打不开」最常见的外部原因之一
  try {
    $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    if (-not $av.Count) { Add-Line '未检测到已注册的杀毒软件。' }
    foreach ($a in $av) { Add-Line ("  {0}   (状态码 {1})" -f $a.displayName, $a.productState) }
  } catch { Add-Line "读取失败：$($_.Exception.Message)" }
  foreach ($n in 'HipsTray', 'HipsDaemon', '360tray', 'ZhuDongFangYu', 'QQPCTray', 'MsMpEng') {
    if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count) { Add-Line "  进程在运行：$n" }
  }
}

Add-Probe '系统事件日志（最近 7 天的相关错误）' {
  try {
    $since = [DateTime]::Now.AddDays(-7)
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $since } -ErrorAction Stop |
      Where-Object { "$($_.Message)" -match 'DeltaForceBooster|EngineHost|优化工具|powershell' } |
      Select-Object -First 12)
    if (-not $events.Count) { Add-Line '最近 7 天没有相关的应用程序错误事件。' }
    foreach ($e in $events) {
      Add-Line ("  {0:yyyy-MM-dd HH:mm}  {1}  ID {2}" -f $e.TimeCreated, $e.ProviderName, $e.Id)
      Add-Line ("     {0}" -f ("$($e.Message)" -split "`r?`n" | Select-Object -First 1))
    }
  } catch { Add-Line "读取失败：$($_.Exception.Message)" }
}

# ---- 落盘 ----
if (-not $OutputPath) {
  $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
  if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) { $desktop = [IO.Path]::GetTempPath() }
  $OutputPath = Join-Path $desktop ('帧率优化助手-诊断-{0:yyyyMMdd-HHmmss}.txt' -f [DateTime]::Now)
}
try {
  [IO.File]::WriteAllText($OutputPath, ($lines -join [Environment]::NewLine), (New-Object Text.UTF8Encoding($true)))
  Write-Host ''
  Write-Host '诊断信息已导出：' -ForegroundColor Green
  Write-Host "  $OutputPath"
  Write-Host ''
  Write-Host '把这个文件发给维护者即可。文件是纯文本，可以自己先打开看一遍。'
} catch {
  Write-Host ''
  Write-Host "写入失败：$($_.Exception.Message)" -ForegroundColor Red
  Write-Host '下面直接输出全部内容，可以手动复制：'
  Write-Host ''
  $lines | ForEach-Object { Write-Host $_ }
}
