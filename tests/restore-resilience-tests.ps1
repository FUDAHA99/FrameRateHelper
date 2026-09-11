$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\delta-booster.ps1'
. $engine

# 本文件含中文，必须带 UTF-8 BOM —— PS 5.1 会把无 BOM 文件按系统 ANSI（这里是 GBK）读。
#
# ============================================================================
#  还原链路的影响范围（blast radius）
# ============================================================================
#
# 这个文件守一条不变式：**一份坏数据只能淘汰它自己。**
#
# 注意它守的不是「宽松接受」。Read-ValidatedBackup 对 HMAC 不符、op 不在白名单、
# schema 不认识的备份抛异常是正确的安全响应，那个行为不许放宽。要防的是株连：
# 原先一份坏备份会 throw 掉整次枚举，于是用户的「还原设置」整页报错，
# 另外十几份完好的备份跟着一起用不了。
#
# 同一类问题在这个仓库里已经出现过三次（gpu-name-spoof 的 DeviceDesc 白名单、
# legacy-roots 条目、备份文件本身），所以值得单独一个文件钉住。
#
# 还有一条同样重要：**绝不静默。** 读不了的备份必须带着原因出现在用户眼前。
# 「看起来没事、其实回不去了」是这个工具最不该有的失败方式 —— 用户不会来报 bug，
# 他会相信系统是干净的。

$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Expect, [string]$Message) {
  $script:Assertions++
  try { & $Action } catch {
    if ("$($_.Exception.Message)" -like "*$Expect*") { return }
    throw "ASSERT: $Message（实际异常：$($_.Exception.Message)）"
  }
  throw "ASSERT: $Message（没有抛出异常）"
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("dfb-restore-resilience-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
  $script:ProgramDataRoot = Join-Path $temp 'programdata'
  $script:BackupDir = Join-Path $script:ProgramDataRoot 'backup'
  $script:IpcDir = Join-Path $script:ProgramDataRoot 'ipc'
  $script:BackupKeyFile = Join-Path $script:ProgramDataRoot 'backup.key'
  $script:LegacyBackupDir = Join-Path $temp 'legacy\backup'
  $script:LegacyRootsFile = Join-Path $script:ProgramDataRoot 'legacy-roots.json'
  $script:TargetUserSid = 'S-1-5-21-1000000000-1000000001-1000000002-1001'
  $script:TargetLocalAppData = $temp
  function Test-Admin { $true }
  function New-ProtectedDirectory([string]$Path, [bool]$UsersRead) {
    if (-not (Test-Path -LiteralPath $Path)) { [void][IO.Directory]::CreateDirectory($Path) }
  }
  function Set-ProtectedFileAcl([string]$Path) {}
  function Test-ProtectedFileAcl([string]$Path) { $true }

  function New-GoodBackup([string]$ItemId) {
    $doc = New-BackupDocument ([DateTime]::UtcNow)
    $doc.State = 'complete'
    $opId = [guid]::NewGuid().ToString('D')
    $doc.Items = @([pscustomobject][ordered]@{
      ItemId=$ItemId;RestoreGroupId=$ItemId;DisplayName="夹具 $ItemId";DefinitionHash=('a' * 64)
      RebootRequired=$false;OpIds=@($opId)
    })
    $doc.Ops = @([pscustomobject][ordered]@{
      Id=$opId;Status='applied';ApplyId=$doc.ApplyId;ItemId=$ItemId;RestoreGroupId=$ItemId
      OpIndex=0;Kind='reg';Path='HKCU:\Software\Microsoft\GameBar';Name='AutoGameModeEnabled'
      Existed=$true;OldValue=1;OldKind='DWord';AppliedValue=1;AppliedKind='DWord'
    })
    $path = Join-Path $script:BackupDir ("backup-$($doc.BackupId).json")
    Write-BackupDocumentAtomic $path $doc
    $path
  }

  Initialize-ProtectedStore

  # ---------- 1. 一份坏备份不得株连其余备份 ----------

  $goodA = New-GoodBackup 'game-mode'
  $goodB = New-GoodBackup 'dvr-off'
  # 篡改：改掉正文但不重算 HMAC —— 这正是完整性校验要挡住的那种情况
  $tampered = New-GoodBackup 'fso-off'
  $raw = [IO.File]::ReadAllText($tampered, [Text.Encoding]::UTF8)
  [IO.File]::WriteAllText($tampered, $raw.Replace('"OpIndex":  0', '"OpIndex":  7'), (New-Object Text.UTF8Encoding($false)))
  # 彻底不是 JSON 的一份
  $garbage = Join-Path $script:BackupDir ('backup-' + [guid]::NewGuid().ToString('D') + '.json')
  [IO.File]::WriteAllText($garbage, 'this is not json at all', (New-Object Text.UTF8Encoding($false)))

  $state = Get-ValidatedRestoreRecords $null $true
  $paths = @($state.Records | ForEach-Object { "$($_.Path)" })
  Assert-True ($paths -contains $goodA -and $paths -contains $goodB) '一份坏备份株连了其余完好的备份 —— 影响范围没有被限制住'
  Assert-True ($paths -notcontains $tampered) '被篡改的备份仍然通过了完整性校验 —— 这条是安全边界，不许放宽'
  Assert-True ($paths -notcontains $garbage) '非 JSON 的文件被当成了有效备份'
  Assert-True ([int]$state.UnreadableCount -eq 2) "读取失败的备份份数不对：期望 2，实际 $($state.UnreadableCount)"

  # 绝不静默：每一份读不了的都要带着原因出现在 Notes 里
  $noteText = @($state.Notes) -join ' || '
  Assert-True ($noteText -like '*已跳过读取失败的备份*') '读取失败的备份没有进入 Notes —— 用户会以为它不存在'
  Assert-True ($noteText -like "*$(Split-Path -Leaf $tampered)*") 'Notes 里没有指出是哪一份备份读取失败'
  Assert-True ($noteText -match '完整性|已被修改|HMAC|签名|损坏|JSON') 'Notes 里没有给出读取失败的原因，用户无法判断该怎么办'

  # ---------- 2. 指名要还原某一份时，读不了必须如实报错 ----------

  # 降级成「没找到备份」是最坏的处理：用户指名了这一份，他需要知道它坏了。
  Assert-Throws { Get-ValidatedRestoreRecords $tampered $false } '指定备份无法读取' `
    '指名还原一份坏备份时没有如实报错'
  Assert-Throws { Get-ValidatedRestoreRecords $garbage $false } '指定备份无法读取' `
    '指名还原一份损坏文件时没有如实报错'

  # ---------- 3. 全部读不了 ≠ 一份都没有 ----------

  # 「本来就没改过」和「改过但回不去了」对用户是完全不同的两件事。
  foreach ($p in $goodA, $goodB) { Remove-Item -LiteralPath $p -Force }
  Assert-Throws { Get-ValidatedRestoreRecords $null $false } '全部无法读取' `
    '所有备份都读不了时，错误信息把它说成了「没有备份」'

  $allBad = Get-ValidatedRestoreRecords $null $true
  Assert-True (@($allBad.Records).Count -eq 0 -and [int]$allBad.UnreadableCount -eq 2) `
    'AllowEmpty 模式下没有回报「有备份但全读不了」'

  # ---------- 4. SearchedRoots：空列表必须说清楚搜过哪里 ----------

  Assert-True (@($allBad.SearchedRoots) -contains ([IO.Path]::GetFullPath($script:BackupDir).TrimEnd('\')) -or
               @($allBad.SearchedRoots) -contains $script:BackupDir) `
    '没有回传搜索过的备份目录 —— 用户看到空列表时无法判断是没有还是没找到'

  # ---------- 5. legacy-roots：一条坏条目不得让整个还原入口瘫痪 ----------

  $legacyGood = Join-Path $temp ('.DeltaForceBooster.migrated-' + ([guid]::NewGuid().ToString('N')))
  [void][IO.Directory]::CreateDirectory((Join-Path $legacyGood 'backup'))
  $doc = [pscustomobject]@{
    SchemaVersion = 1
    Roots = @(
      'not-even-a-path'                                  # 格式不符
      'X:\.DeltaForceBooster.migrated-' + ('0' * 32)     # 盘不存在
      $legacyGood                                        # 合法
      'C:\SomeOtherFolder'                               # leaf schema 不符
    )
  }
  [IO.File]::WriteAllText($script:LegacyRootsFile, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

  $roots = @(Get-LegacyRoots)
  Assert-True ($roots.Count -eq 1 -and $roots[0] -eq ([IO.Path]::GetFullPath($legacyGood).TrimEnd('\'))) `
    '坏的 legacy-roots 条目让合法条目一起失效了 —— 一条陈旧条目就能让还原入口永久瘫痪'
  $warn = @($script:LegacyRootWarnings) -join ' || '
  Assert-True ($warn -like '*格式无效*') '格式不符的条目被静默丢弃，没有警告'
  Assert-True ($warn -like '*固定磁盘*' -or $warn -like '*不存在*') '不可用磁盘上的条目没有产生警告'
  Assert-True (@($script:LegacyRootWarnings).Count -ge 3) "坏条目应各自产生一条警告，实际只有 $(@($script:LegacyRootWarnings).Count) 条"

  # 整个目录枚举也不能因此 throw
  $dirs = $null
  try { $dirs = @(Get-LegacyBackupDirs) } catch { throw "ASSERT: 坏的 legacy-roots 条目让 Get-LegacyBackupDirs 抛了异常：$($_.Exception.Message)" }
  $script:Assertions++
  Assert-True ($dirs.Count -ge 1) 'legacy 备份目录枚举丢掉了合法的旧安装根'

  # ---------- 5b. legacy-roots.json 整份不合格：拒绝全部旧根，但不得 throw ----------
  # 「这份清单坏了」和「受保护目录里的备份没了」是两件毫不相干的事。
  # 原先文档级校验一律 throw，于是前者会连累后者 —— 而后者才是绝大多数用户
  # 唯一的回退依据（旧根只有从上游迁移过来的人才有）。

  $goodC = New-GoodBackup 'mpo-off'
  foreach ($bad in @(
    @{ Name = '非 JSON';        Body = 'not json at all' }
    @{ Name = '结构多字段';      Body = '{"SchemaVersion":1,"Roots":[],"Extra":1}' }
    @{ Name = '版本不支持';      Body = '{"SchemaVersion":99,"Roots":[]}' }
  )) {
    [IO.File]::WriteAllText($script:LegacyRootsFile, $bad.Body, (New-Object Text.UTF8Encoding($false)))
    $r = $null
    try { $r = @(Get-LegacyRoots) }
    catch { throw "ASSERT: legacy-roots.json「$($bad.Name)」让 Get-LegacyRoots 抛了异常：$($_.Exception.Message)" }
    $script:Assertions++
    Assert-True ($r.Count -eq 0) "legacy-roots.json「$($bad.Name)」时仍然信任了旧根 —— 不合格必须一条都不信"
    Assert-True ((@($script:LegacyRootWarnings) -join ' ') -like '*已拒绝读取全部旧备份位置*') `
      "legacy-roots.json「$($bad.Name)」被静默丢弃，没有告诉用户"

    $st = Get-ValidatedRestoreRecords $null $true
    Assert-True (@($st.Records | ForEach-Object { "$($_.Path)" }) -contains $goodC) `
      "legacy-roots.json「$($bad.Name)」连累了受保护目录里完好的备份"
  }

  # ACL 校验的回归网。这条测试在修好括号之前根本写不出来 ——
  # 原写法 `Test-PathHasReparsePoint $f -or -not (Test-ProtectedFileAcl $f)` 被
  # PowerShell 当成命令调用，-or / -not / (ACL 结果) 全变成参数被丢弃，
  # ACL 返回什么都不影响判定。
  [IO.File]::WriteAllText($script:LegacyRootsFile, '{"SchemaVersion":1,"Roots":[]}', (New-Object Text.UTF8Encoding($false)))
  function Test-ProtectedFileAcl([string]$Path) { $false }
  $aclRejected = @(Get-LegacyRoots)
  Assert-True ($aclRejected.Count -eq 0) 'legacy-roots.json 的 ACL 校验没有参与判定'
  Assert-True ((@($script:LegacyRootWarnings) -join ' ') -like '*类型或权限异常*') 'ACL 不合格时没有给出原因'
  function Test-ProtectedFileAcl([string]$Path) { $true }

  # ---------- 5c. 坏的还原凭证：目录照常打开，但执行必须被拦住 ----------
  #
  # 这一条和上面几条**方向相反**，别改错。凭证读不到时不能"跳过继续"：
  # 已消费集合不完整 = 早已还原过的 op 会被重新列为可复原并重放，
  # 用旧值覆盖用户之后的手动修改。所以是 fail-closed。
  #
  # 但 fail-closed 的正确形态是「面板能打开 + 按钮禁用 + 说清是哪个文件」，
  # 不是「三条入口一起抛一句看不懂的底层异常」。两半都要验。

  [IO.File]::WriteAllText($script:LegacyRootsFile, '{"SchemaVersion":1,"Roots":[]}', (New-Object Text.UTF8Encoding($false)))
  $receiptPath = Join-Path $script:BackupDir ('restore-receipt-' + [guid]::NewGuid().ToString('D') + '.json')
  [IO.File]::WriteAllText($receiptPath, '{"SchemaVersion":1,"ConsumedOps":[]}', (New-Object Text.UTF8Encoding($false)))

  $consumed = Get-ConsumedRestoreOpSet
  Assert-True ([bool]$consumed.Blocked) '读不了的还原凭证没有触发 fail-closed —— 已消费集合不完整时还原会重放旧值'
  Assert-True (@($consumed.Unreadable).Count -eq 1) '读不了的凭证份数不对'
  Assert-True ((Get-ConsumedRestoreBlockReason $consumed) -like "*$(Split-Path -Leaf $receiptPath)*") `
    '拦截原因里没有指出是哪个凭证文件，用户不知道该删哪个'
  Assert-True ((Get-ConsumedRestoreBlockReason $consumed) -like '*覆盖你之后的手动调整*') `
    '拦截原因没有解释为什么要拦，用户只会觉得工具坏了'

  # 前一半：目录照常构建，用户看得见清单和原因
  $blockedCatalog = $null
  try { $blockedCatalog = Get-RestoreItemCatalog }
  catch { throw "ASSERT: 一份读不了的凭证让整个还原目录抛了异常：$($_.Exception.Message)" }
  $script:Assertions++
  Assert-True ([bool]$blockedCatalog.RestoreBlocked) '目录没有把 RestoreBlocked 带给界面'
  Assert-True ([int]$blockedCatalog.UnreadableReceiptCount -eq 1) '目录没有回报读不了的凭证份数'
  Assert-True ((@($blockedCatalog.Notes) -join ' ') -like "*$(Split-Path -Leaf $receiptPath)*") `
    '目录的 Notes 里没有凭证文件名'

  # 后一半：执行入口确实被拦住，且报的是人话
  Assert-Throws { Invoke-Restore } "$(Split-Path -Leaf $receiptPath)" `
    '凭证读不了时「全部复原」没有被拦住，或报的不是带文件名的人话'

  Remove-Item -LiteralPath $receiptPath -Force
  $script:Assertions++
  if ((Get-ConsumedRestoreOpSet).Blocked) { throw 'ASSERT: 删掉坏凭证之后仍然处于拦截状态' }

  # ---------- 6. 目录本身也必须把这些信息带给界面 ----------

  $catalog = Get-RestoreItemCatalog
  Assert-True ($null -ne $catalog.PSObject.Properties['SearchedRoots']) '还原目录没有把搜索范围回传给界面'
  Assert-True ($null -ne $catalog.PSObject.Properties['UnreadableBackupCount']) '还原目录没有把读取失败份数回传给界面'
  Assert-True ([int]$catalog.UnreadableBackupCount -eq 2) "目录回报的读取失败份数不对：$($catalog.UnreadableBackupCount)"
  Assert-True ((@($catalog.Notes) -join ' ') -like '*已跳过读取失败的备份*') '还原目录的 Notes 丢掉了读取失败信息'
}
finally {
  try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

# ---------- 7. 界面侧必须真的把这些显示出来 ----------
# 引擎算出来、传过去、然后被界面丢掉，是这个仓库里已经发生过的事
# （Catalog.Notes 原先就传了，但渲染函数从没读过它）。

$guiRaw = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'gui\DeltaForceBooster-GUI.ps1'), [Text.Encoding]::UTF8)
Assert-True ($guiRaw.Contains('foreach ($n in @($Catalog.Notes))')) '界面没有渲染还原目录的 Notes —— 引擎算出来的警告又被丢掉了'
Assert-True ($guiRaw.Contains('$Catalog.UnreadableBackupCount')) '界面没有显示读取失败的备份份数'
Assert-True ($guiRaw.Contains('@($Catalog.SearchedRoots)')) '空列表时没有显示搜索过的目录'
Assert-True ($guiRaw.Contains('已搜索：')) '空态文案没有把搜索范围写出来'
Assert-True ($guiRaw.Contains('$Catalog.RestoreBlocked')) '界面没有读取 RestoreBlocked'
Assert-True ($guiRaw.Contains('$script:InlineRestoreCatalog.RestoreBlocked')) '界面没有用 RestoreBlocked 禁用还原按钮 —— 用户点下去只会吃一个底层异常'

Write-Host "restore resilience tests passed: $script:Assertions assertions"
