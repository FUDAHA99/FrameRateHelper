#requires -Version 5.1
param()

# 本文件含中文，必须带 UTF-8 BOM —— PS 5.1 会把无 BOM 文件按系统 ANSI（这里是 GBK）读。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI 解析失败：' + (($errors | ForEach-Object Message) -join '; '))
$gui = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8

# ---------- 1. 上传链路必须彻底消失 ----------

Assert-True (-not $gui.Contains('ReportUploadUrl')) '诊断报告仍引用服务端上传地址'
Assert-True (-not $gui.Contains('Invoke-ReportUpload')) '上传函数仍然存在'
Assert-True (-not $gui.Contains('report/upload')) 'GUI 里仍有 /report/upload 端点'

# 注释里可以提到这些词，但不能有真的调用。用 token 流排除注释后再看。
$codeTokens = @($tokens | Where-Object { $_.Kind -ne [Management.Automation.Language.TokenKind]::Comment })
$codeText = ($codeTokens | ForEach-Object { $_.Text }) -join ' '
Assert-True (-not $codeText.Contains('report/upload')) '非注释代码里仍有诊断上传端点'
# 诊断按钮的整个处理程序里不得再有任何网络调用。
$handlerStart = $gui.IndexOf('$ui.ReportBtn.Add_Click', [StringComparison]::Ordinal)
Assert-True ($handlerStart -ge 0) '找不到诊断按钮处理程序'
$handlerText = $gui.Substring($handlerStart, [Math]::Min(4000, $gui.Length - $handlerStart))
foreach ($net in 'Invoke-WebRequest', 'Invoke-RestMethod', 'HttpWebRequest', 'WebClient') {
  Assert-True (-not $handlerText.Contains($net)) "诊断按钮处理程序里仍有网络调用：$net"
}

# ---------- 2. 导出函数存在且可单独求值 ----------

foreach ($name in 'Get-DiagnosticExportDir', 'Save-DiagnosticReportFile') {
  $fn = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true))
  Assert-True ($fn.Count -eq 1) "缺少导出函数：$name"
  . ([ScriptBlock]::Create($fn[0].Extent.Text))
}

# ---------- 3. 高权限进程不得用自己的桌面 ----------

# GetFolderPath(Desktop) 在提权进程里返回的是 UAC 审批账户的桌面，
# 不是当前登录用户的。导出目录推导过程绝不能碰它。
$exportFn = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DiagnosticExportDir' }, $true))[0]
$exportText = $exportFn.Extent.Text
foreach ($forbidden in 'SpecialFolder]::Desktop', 'SpecialFolder]::DesktopDirectory', '$env:USERPROFILE', '$env:USERNAME') {
  Assert-True (-not $exportText.Contains($forbidden)) "导出目录推导用了高权限进程自身的身份：$forbidden"
}
Assert-True ($exportText.Contains('$script:OriginalUserLocalAppData') -and $exportText.Contains('$script:OriginalUserSid')) `
  '导出目录没有从已认证的原登录用户身份推导'

# ---------- 4. 桌面重定向：注册表值优先于默认路径 ----------

$temp = Join-Path ([IO.Path]::GetTempPath()) ('dfb-export-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
  $fakeProfile = Join-Path $temp 'Users\tester'
  $redirected  = Join-Path $fakeProfile 'OneDrive\桌面'
  $plainDesktop = Join-Path $fakeProfile 'Desktop'
  [void][IO.Directory]::CreateDirectory($redirected)
  [void][IO.Directory]::CreateDirectory($plainDesktop)

  $script:OriginalUserLocalAppData = Join-Path $fakeProfile 'AppData\Local'
  $script:OriginalUserSid = 'S-1-5-21-0-0-0-1001'
  $script:ReportExportPrefix = '帧率优化助手-诊断报告'

  # 用本地函数遮蔽 cmdlet，模拟 User Shell Folders 的 Desktop 值。
  $script:FakeShellDesktop = $redirected
  function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, $ErrorAction)
    if ($LiteralPath -notlike "*HKEY_USERS\$script:OriginalUserSid*") { throw '读到了错误的注册表配置单元' }
    if ($Name -ne 'Desktop') { throw "读了不该读的值：$Name" }
    if (-not $script:FakeShellDesktop) { throw '没有 Desktop 值' }
    [pscustomobject]@{ Desktop = $script:FakeShellDesktop }
  }

  Assert-True ((Get-DiagnosticExportDir) -eq $redirected) '桌面被重定向时没有优先使用 User Shell Folders 的值'

  # %USERPROFILE% 必须换成原用户的 profile，而不是提权进程的
  $script:FakeShellDesktop = '%USERPROFILE%\OneDrive\桌面'
  Assert-True ((Get-DiagnosticExportDir) -eq $redirected) '%USERPROFILE% 没有替换成原登录用户的 profile'

  # 注册表读不到时退回 <profile>\Desktop
  $script:FakeShellDesktop = ''
  Assert-True ((Get-DiagnosticExportDir) -eq $plainDesktop) '注册表不可用时没有退回默认桌面路径'

  # ---------- 5. 写出的文件必须带 BOM ----------

  $script:FakeShellDesktop = $redirected
  $written = Save-DiagnosticReportFile "第一行`r`n第二行"
  Assert-True ([IO.Path]::GetDirectoryName($written) -eq $redirected) '报告没有写进解析出来的导出目录'
  Assert-True ([IO.Path]::GetExtension($written) -eq '.txt') '报告扩展名不是 .txt'
  $bytes = [IO.File]::ReadAllBytes($written)
  Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
    '报告没有 UTF-8 BOM —— 记事本会把中文显示成乱码'
  $text = [IO.File]::ReadAllText($written, [Text.Encoding]::UTF8)
  Assert-True ($text -eq "第一行`r`n第二行") '报告内容被改写了'

  # 文件名带时间戳，同一秒内不重名即可；两次调用之间隔一秒验证不覆盖
  Assert-True ((Split-Path -Leaf $written).StartsWith('帧率优化助手-诊断报告-')) '报告文件名前缀不对'
}
finally {
  try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

# ---------- 6. 按钮文案不得再承诺上传 ----------

Assert-True ($gui.Contains('Content="导出完整诊断"')) '诊断按钮文案仍是上传语义'
# 上游历史更新日志里提到过取件码，那是注释、不改写；看的是非注释代码。
Assert-True (-not $codeText.Contains('取件码')) '仍在向用户承诺服务端取件码'

Write-Host "diagnostic export tests passed: $script:Assertions assertions"
