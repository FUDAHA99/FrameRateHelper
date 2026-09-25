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
# 先按 AST 变量节点选出「实参用到 $resp」的那次策略调用（不按源码文本），再逐节点核对实参形状。
$redirectChecks = @($downloadFn[0].FindAll({ param($n)
  $n -is [Management.Automation.Language.CommandAst] -and "$($n.GetCommandName())" -eq 'Test-BoosterSetupUrl' -and
  $null -ne $n.Find({ param($v)
    $v -is [Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.UserPath -eq 'resp' }, $true)
}, $true))
Assert-True ($redirectChecks.Count -eq 1) "下载没有对重定向后的最终地址（`$resp.ResponseUri）复查白名单（找到 $($redirectChecks.Count) 处用到 `$resp 的策略调用）"
# 最终地址必须原样交给策略（复核 R5）：原来只要求实参文本里含 $resp.ResponseUri.AbsoluteUri，
# "$($resp.ResponseUri.AbsoluteUri -replace '^http:', 'https:')" 照样过——http 最终地址先被改写成 https 再判，
# 生产策略就放行了明文下载。现在按 AST 前序逐节点比对实参，只接受两种等价写法：
# "$($resp.ResponseUri.AbsoluteUri)" 与裸 $resp.ResponseUri.AbsoluteUri。任何运算符（-replace）、方法（.Replace()）、
# 类型转换、管道、子表达式里的第二条语句都会多出或换掉节点；双引号串里在 $() 之外加字面量前后缀由 Value 与嵌套表达式原文不等接住。
function Get-AstShape([Management.Automation.Language.Ast]$Node) {
  @($Node.FindAll({ $true }, $true) | ForEach-Object {
    $label = $_.GetType().Name
    if ($_ -is [Management.Automation.Language.VariableExpressionAst]) { $label += ':$' + $_.VariablePath.UserPath.ToLowerInvariant() }
    elseif ($_ -is [Management.Automation.Language.StringConstantExpressionAst]) { $label += ':' + $_.Value.ToLowerInvariant() }
    elseif ($_ -is [Management.Automation.Language.MemberExpressionAst] -and $_.Static) { $label += ':static' }
    $label
  }) -join ' > '
}
$redirectArgs = @($redirectChecks[0].CommandElements | Select-Object -Skip 1)
$bareUriShape = 'MemberExpressionAst > MemberExpressionAst > VariableExpressionAst:$resp > ' +
  'StringConstantExpressionAst:responseuri > StringConstantExpressionAst:absoluteuri'
$quotedUriShape = 'ExpandableStringExpressionAst > SubExpressionAst > StatementBlockAst > PipelineAst > CommandExpressionAst > ' + $bareUriShape
$redirectArgShape = $(if ($redirectArgs.Count -eq 1) { Get-AstShape $redirectArgs[0] } else { "<$($redirectArgs.Count) arguments>" })
$redirectArgNoLiteral = ($redirectArgs.Count -eq 1) -and (
  -not ($redirectArgs[0] -is [Management.Automation.Language.ExpandableStringExpressionAst]) -or
  ($redirectArgs[0].NestedExpressions.Count -eq 1 -and
   [string]::Equals($redirectArgs[0].Value, $redirectArgs[0].NestedExpressions[0].Extent.Text, [StringComparison]::Ordinal)))
Assert-True ($redirectChecks[0].Redirections.Count -eq 0 -and $redirectArgNoLiteral -and
  ([string]::Equals($redirectArgShape, $bareUriShape, [StringComparison]::Ordinal) -or
   [string]::Equals($redirectArgShape, $quotedUriShape, [StringComparison]::Ordinal))) `
  "final-URL verdict argument is not exactly `$resp.ResponseUri.AbsoluteUri: [$($redirectArgs.Extent.Text)] AST: $redirectArgShape"
$checkStmt = $redirectChecks[0]
while ($checkStmt -and -not ($checkStmt.Parent -is [Management.Automation.Language.StatementBlockAst])) { $checkStmt = $checkStmt.Parent }
Assert-True ($checkStmt -is [Management.Automation.Language.AssignmentStatementAst] -and
  $checkStmt.Parent.Parent -is [Management.Automation.Language.TryStatementAst] -and
  [object]::ReferenceEquals($checkStmt.Parent.Parent.Body, $checkStmt.Parent)) `
  '最终地址复查没有直接写在下载 try 块里（被包进条件就不是每次尝试都复查）'
# 判定变量必须就是策略调用本身的返回值：`= Test-BoosterSetupUrl <实参>`，管道里没有第二段、没有类型约束、不是 +=。
# 否则 `... | ForEach-Object { $_.Allowed = $true; $_ }` 这类写法实参原样、调用也在，结果却被丢掉换成放行。
$verdictPipe = $checkStmt.Right
Assert-True ($checkStmt.Operator -eq [Management.Automation.Language.TokenKind]::Equals -and
  $checkStmt.Left -is [Management.Automation.Language.VariableExpressionAst] -and
  $verdictPipe -is [Management.Automation.Language.PipelineAst] -and $verdictPipe.PipelineElements.Count -eq 1 -and
  [object]::ReferenceEquals($verdictPipe.PipelineElements[0], $redirectChecks[0])) `
  "final-URL verdict variable is not assigned straight from the policy call: $($checkStmt.Extent.Text)"
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
# 实参形状对了还不够：$resp 必须就是紧挨着的上一条语句里 $req.GetResponse() 的返回值——那个 try 体只有这一条赋值，
# 两条语句之间不插任何东西。否则 `$resp | Add-Member ResponseUri ... -Force` 换掉最终地址，上面的实参形状原样不动。
$getResponseCall = $block[$responseIndex].Find({ param($n)
  $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member)" -eq 'GetResponse' }, $true)
$respAssign = $getResponseCall
while ($respAssign -and -not ($respAssign -is [Management.Automation.Language.AssignmentStatementAst])) { $respAssign = $respAssign.Parent }
$respWrites = @($block[$responseIndex].FindAll({ param($n)
  $n -is [Management.Automation.Language.AssignmentStatementAst] -and
  $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'resp' }, $true))
Assert-True ($responseIndex -eq $checkIndex - 1 -and $null -ne $respAssign -and $respWrites.Count -eq 1 -and
  [object]::ReferenceEquals($respWrites[0], $respAssign) -and
  $respAssign.Right -is [Management.Automation.Language.CommandExpressionAst] -and
  [object]::ReferenceEquals($respAssign.Right.Expression, $getResponseCall) -and
  @($respAssign.Parent.Statements).Count -eq 1) `
  "final-URL verdict does not read `$resp straight from the preceding `$req.GetResponse() (GetResponse=$responseIndex verdict=$checkIndex resp-writes=$($respWrites.Count))"
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
