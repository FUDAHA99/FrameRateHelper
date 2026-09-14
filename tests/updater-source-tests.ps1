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
# 上游遥测端点的域名片段。只存片段、不写完整主机名：断言要的是「别退回旧端点」
# 这个保护，而本仓库即将公开，没必要把第三方的生产主机名一并发出去。
$LegacyUpstreamHostFragment = 'upstream-host'
Assert-True (-not $codeText.Contains($LegacyUpstreamHostFragment)) 'updater 非注释代码里仍有旧服务端域名'

# ---------- 5. 重定向必须再过一次同一道闸 ----------

# 这一条是整个内置下载最关键的不变式：GitHub 会 302 到 CDN，
# 只查初始 URL 等于白名单形同虚设。
Assert-True ($raw.Contains('Test-BoosterSetupUrl "$($resp.ResponseUri.AbsoluteUri)"')) `
  '下载没有对重定向后的最终地址复查白名单'

# ---------- 6. 构建出的清单也必须指向 GitHub ----------

$mk = Get-Content -LiteralPath (Join-Path $root 'build\make-installer.ps1') -Raw -Encoding UTF8
Assert-True ($mk.Contains('$releaseRepo') -and $mk.Contains('releases/download/v$ver/DeltaForceBooster-Setup.exe')) `
  '构建脚本生成的 setupUrl 没有指向本版 tag 的 release 资源'
Assert-True (-not $mk.Contains($LegacyUpstreamHostFragment)) '构建脚本里仍有旧服务端域名'
# setupUrl 必须带版本 tag：清单里的 sha256 是这一个文件的，指向 latest 会在发版
# 竞态下让老清单配新安装包，校验必然失败。
Assert-True (-not $mk.Contains('releases/latest/download/DeltaForceBooster-Setup.exe')) `
  'setupUrl 指向了 latest 而不是本版 tag'

Write-Host "updater source tests passed: $script:Assertions assertions"
