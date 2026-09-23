#requires -Version 5.1
param()

# 本文件含中文，必须带 UTF-8 BOM —— PS 5.1 会把无 BOM 文件按系统 ANSI（这里是 GBK）读。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$updaterPath = Join-Path $root 'scripts\updater.ps1'
$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}

$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($updaterPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('updater 解析失败：' + (($errors | ForEach-Object Message) -join '; '))

$script:BoosterUserConfigDir = Join-Path ([IO.Path]::GetTempPath()) ('dfb-updsrc-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:BoosterUserConfigDir)
try {
  . $updaterPath

  # ---------- 1. 更新源指向 GitHub Releases ----------

  $manifestUri = [uri]$script:BoosterManifestUrl
  Assert-True ($manifestUri.Scheme -eq 'https') '清单地址必须是 https'
  Assert-True ($manifestUri.Host -eq 'github.com') '清单地址不在 github.com 上'
  Assert-True ($script:BoosterManifestUrl -like '*/releases/latest/download/*') `
    '清单地址不是 releases/latest/download 形式，发新版后旧客户端会一直读到旧清单'

  # ---------- 2. 域名白名单 ----------

  # 允许：主域名本身，以及 GitHub 的资源 CDN 子域。
  # GitHub 把这个子域从 objects. 改成过 release-assets.，两者都必须放行。
  foreach ($ok in 'github.com', 'GitHub.COM', 'release-assets.githubusercontent.com',
                  'objects.githubusercontent.com', 'raw.githubusercontent.com') {
    Assert-True (Test-BoosterAllowedDownloadHost $ok) "应放行的下载域名被拒：$ok"
  }

  # 拒绝：最关键的是后缀匹配不能少了前导点，否则攻击者注册
  # evilgithubusercontent.com 就能冒充资源 CDN。
  foreach ($bad in 'evilgithubusercontent.com', 'notgithubusercontent.com', 'githubusercontent.com',
                   'github.com.evil.cn', 'release-assets.githubusercontent.com.evil.cn',
                   'not-our-host.example', 'localhost', '', '   ') {
    Assert-True (-not (Test-BoosterAllowedDownloadHost $bad)) "应拒绝的下载域名被放行：[$bad]"
  }

  # ---------- 3. setupUrl 安检 ----------

  $allowUrls = @(
    'https://github.com/FUDAHA99/FrameRateHelper/releases/download/v1.0/DeltaForceBooster-Setup.exe',
    'https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sig=x'
  )
  foreach ($u in $allowUrls) {
    $v = Test-BoosterSetupUrl $u
    Assert-True $v.Allowed "合法下载地址被拒：$u（$($v.Reason)）"
  }

  $denyUrls = @(
    'http://github.com/x/y/releases/download/v1/a.exe',
    'https://evilgithubusercontent.com/a.exe',
    'https://github.com.evil.cn/a.exe',
    'file:///C:/a.exe',
    'C:\a.exe',
    'releases/download/v1/a.exe',
    ''
  )
  foreach ($u in $denyUrls) {
    $v = Test-BoosterSetupUrl $u
    Assert-True (-not $v.Allowed) "非法下载地址被放行：$u"
    Assert-True ([bool]"$($v.Reason)") "拒绝 $u 时没有给出原因，界面就无法告诉用户为什么被拦"
  }

  # ---------- 4. 服务器下载排队必须已经删干净 ----------

  foreach ($gone in 'Get-BoosterDownloadQueueEndpoints', 'Invoke-BoosterQueueJsonRequest',
                    'Wait-BoosterDownloadQueue', 'Stop-BoosterDownloadQueueTicket') {
    Assert-True (-not (Get-Command $gone -ErrorAction SilentlyContinue)) "排队函数仍然存在：$gone"
  }
}
finally {
  try { Remove-Item -LiteralPath $script:BoosterUserConfigDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

$raw = Get-Content -LiteralPath $updaterPath -Raw -Encoding UTF8
# 头部变更说明里会提到这两个词，那是注释、不算残留；看的是非注释代码。
$codeText = (($tokens | Where-Object { $_.Kind -ne [Management.Automation.Language.TokenKind]::Comment }) |
  ForEach-Object { $_.Text }) -join ' '
Assert-True (-not $codeText.Contains('download-queue')) 'updater 非注释代码里仍有排队端点路径'
# 原来这里是一条负向断言：「不得含上游旧端点的域名」。那要求把第三方的生产主机名
# 写进一个即将公开的仓库，而且只能挡住那一个写法。改成正向断言：白名单
# 必须**恰好**是这两项。这比原来强——任何第三方域名溢进来都会被接住，
# 不只是那一个历史端点，而且不用在公开仓库里点名任何人。
Assert-True (@($script:BoosterDownloadHosts).Count -eq 1 -and
  "$(@($script:BoosterDownloadHosts)[0])" -eq 'github.com') `
  "下载域名白名单不再是只有 github.com：$(@($script:BoosterDownloadHosts) -join ', ')"
Assert-True (@($script:BoosterDownloadHostSuffixes).Count -eq 1 -and
  "$(@($script:BoosterDownloadHostSuffixes)[0])" -eq '.githubusercontent.com') `
  "白名单后缀不再是只有 .githubusercontent.com：$(@($script:BoosterDownloadHostSuffixes) -join ', ')"

# ---------- 5. 重定向必须再过一次同一道闸 ----------

# 这一条是整个内置下载最关键的不变式：GitHub 会 302 到 CDN，只查初始 URL 等于白名单形同虚设。
# 行为层在 tests/updater-download-tests.ps1（真 302、被拒 origin、续传那一跳才重定向）。
# 这里用 AST 守结构，注释进不了 AST：原来的 $raw.Contains 会被
# 「$redirectVerdict = @{ Allowed = $true } # Test-BoosterSetupUrl "$($resp.ResponseUri...)"」骗过（复核变异 13）。
# 结构要求：复查紧跟 GetResponse、在同一个语句块里（不嵌在条件里，每次尝试都做）、下一条语句就是
# 「不 Allowed 就 throw」，而且都在 GetResponseStream 之前（先拒绝，再读字节）。
$updaterAst = [Management.Automation.Language.Parser]::ParseInput($raw, [ref]$null, [ref]$null)
$downloadFn = @($updaterAst.FindAll({ param($n)
  $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-BoosterSetupDownload' }, $true))
Assert-True ($downloadFn.Count -eq 1) "AST 里没有唯一的 Invoke-BoosterSetupDownload（$($downloadFn.Count) 个）"
$redirectChecks = @($downloadFn[0].FindAll({ param($n)
  $n -is [Management.Automation.Language.CommandAst] -and "$($n.GetCommandName())" -eq 'Test-BoosterSetupUrl' -and
  @($n.CommandElements | Select-Object -Skip 1 | Where-Object { $_.Extent.Text -match '\$resp\.ResponseUri\.AbsoluteUri' }).Count -eq 1
}, $true))
Assert-True ($redirectChecks.Count -eq 1) '下载没有对重定向后的最终地址（$resp.ResponseUri）复查白名单'
$checkStmt = $redirectChecks[0]
while ($checkStmt -and -not ($checkStmt.Parent -is [Management.Automation.Language.StatementBlockAst])) { $checkStmt = $checkStmt.Parent }
Assert-True ($checkStmt -is [Management.Automation.Language.AssignmentStatementAst] -and
  $checkStmt.Parent.Parent -is [Management.Automation.Language.TryStatementAst] -and
  [object]::ReferenceEquals($checkStmt.Parent.Parent.Body, $checkStmt.Parent)) `
  '最终地址复查没有直接写在下载 try 块里（被包进条件就不是每次尝试都复查）'
$block = @($checkStmt.Parent.Statements)
$checkIndex = [array]::IndexOf($block, $checkStmt)
function Get-StatementIndexCalling([object[]]$Statements, [string]$Member) {
  for ($k = 0; $k -lt $Statements.Count; $k++) {
    $hit = $Statements[$k].Find({ param($n)
      $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member)" -eq $Member }, $true)
    if ($hit) { return $k }
  }
  -1
}
$responseIndex = Get-StatementIndexCalling $block 'GetResponse'
$streamIndex = Get-StatementIndexCalling $block 'GetResponseStream'
Assert-True ($responseIndex -ge 0 -and $responseIndex -lt $checkIndex -and $streamIndex -gt $checkIndex + 1) `
  "最终地址复查不在 GetResponse 与 GetResponseStream 之间（GetResponse=$responseIndex 复查=$checkIndex 读流=$streamIndex）"
$verdictVar = "$($checkStmt.Left.Extent.Text)"
$denyIf = $block[$checkIndex + 1]
$denyThrows = @()
if ($denyIf -is [Management.Automation.Language.IfStatementAst] -and $denyIf.Clauses.Count -eq 1 -and -not $denyIf.ElseClause) {
  $denyCond = ([regex]::Replace("$($denyIf.Clauses[0].Item1.Extent.Text)", '\s+', ' ')).Trim()
  if ($denyCond -ieq "-not $verdictVar.Allowed") {
    $denyThrows = @($denyIf.Clauses[0].Item2.Statements | Select-Object -First 1 |
      Where-Object { $_ -is [Management.Automation.Language.ThrowStatementAst] })
  }
}
Assert-True ($denyThrows.Count -eq 1) `
  "最终地址复查的下一条语句不是「if (-not $verdictVar.Allowed) { throw … }」，拒绝没有真正中止下载"

# ---------- 6. 构建出的清单也必须指向 GitHub ----------

$mk = Get-Content -LiteralPath (Join-Path $root 'build\make-installer.ps1') -Raw -Encoding UTF8
Assert-True ($mk.Contains('$releaseRepo') -and $mk.Contains('releases/download/v$ver/DeltaForceBooster-Setup.exe')) `
  '构建脚本生成的 setupUrl 没有指向本版 tag 的 release 资源'
# 同理改成正向：构建脚本生成的两个 URL 必须都在 github.com 上。
foreach ($mkUrlMatch in [regex]::Matches($mk, 'https?://[^"''\s)]+')) {
  $mkHost = ([uri]$mkUrlMatch.Value).Host
  if (-not $mkHost) { continue }
  Assert-True ($mkHost -eq 'github.com' -or $mkHost.EndsWith('.githubusercontent.com')) `
    "构建脚本里出现了非 GitHub 的地址：$($mkUrlMatch.Value)"
}
# setupUrl 必须带版本 tag：清单里的 sha256 是这一个文件的，指向 latest 会在发版
# 竞态下让老清单配新安装包，校验必然失败。
Assert-True (-not $mk.Contains('releases/latest/download/DeltaForceBooster-Setup.exe')) `
  'setupUrl 指向了 latest 而不是本版 tag'

Write-Host "updater source tests passed: $script:Assertions assertions"
