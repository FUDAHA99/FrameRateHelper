$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\delta-booster.ps1'
. $engine

# 还原记账：一条 op 一笔账。
# 这个文件钉的是同一条不变式的两面——
#   ① 没被证实写回原值的 op 绝不能被消费（否则用户再也还原不回来）；
#   ② 已经写回原值的 op 必须被消费（否则下次还原会把旧值重放一遍，
#      覆盖用户在两次还原之间做的手动修改）。
# 旧实现用一个全局闸门「只要有一条失败就全都不入账，否则全都入账」，两面同时违反。

$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("dfb-restore-accounting-test-" + [guid]::NewGuid().ToString('N'))
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

  # 注册表 fixture：记录每一次写入，测试据此断言「重试只重放失败的那一条」
  $script:RegState = @{}
  $script:RegWrites = New-Object System.Collections.Generic.List[string]
  $script:FailRegKey = ''
  function Get-TestRegKey([string]$Path, [string]$Name) { ($Path + '|' + $Name).ToLowerInvariant() }
  function Get-RegValueKind([string]$Path, [string]$Name) {
    $key = Get-TestRegKey $Path $Name
    if ($script:RegState.ContainsKey($key)) { return $script:RegState[$key].Kind }
    $null
  }
  function Get-RegValue([string]$Path, [string]$Name) {
    $key = Get-TestRegKey $Path $Name
    if ($script:RegState.ContainsKey($key)) { return $script:RegState[$key].Value }
    $null
  }
  function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Kind) {
    $key = Get-TestRegKey $Path $Name
    [void]$script:RegWrites.Add($key)
    if ($key -eq $script:FailRegKey) { throw 'fixture write failure' }
    $script:RegState[$key] = [pscustomobject]@{ Value=$Value;Kind=$Kind }
  }
  function Remove-RegValue([string]$Path, [string]$Name) {
    $key = Get-TestRegKey $Path $Name
    [void]$script:RegWrites.Add($key)
    [void]$script:RegState.Remove($key)
  }

  # 备份里的注册表目标必须过 Test-AllowedBackupRegTarget 白名单，因此 fixture 用
  # 产品真实在用的目标，不能随便编一个路径
  $hagsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
  $gameModePath = 'HKCU:\Software\Microsoft\GameBar'
  $dvrPath = 'HKCU:\System\GameConfigStore'
  $mousePath = 'HKCU:\Control Panel\Mouse'
  $mmPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
  $gamesTaskPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
  $transparencyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  $visualFxPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
  $dwmPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'

  # 每个 spec 一个项目一条 reg op，这样「哪一条被消费了」可以逐项断言
  function New-AccountingRegBackup([object[]]$Specs, [DateTime]$When = ([DateTime]::UtcNow)) {
    $doc = New-BackupDocument $When
    $doc.State = 'complete'
    $items = @(); $ops = @()
    foreach ($spec in $Specs) {
      $opId = [guid]::NewGuid().ToString('D')
      $items += [pscustomobject][ordered]@{
        ItemId=$spec.ItemId;RestoreGroupId=$spec.ItemId;DisplayName=$spec.DisplayName
        DefinitionHash=$spec.Hash;RebootRequired=[bool]$spec.RebootRequired;OpIds=@($opId)
      }
      $ops += [pscustomobject][ordered]@{
        Id=$opId;Status='applied';ApplyId=$doc.ApplyId;ItemId=$spec.ItemId;RestoreGroupId=$spec.ItemId
        OpIndex=0;Kind='reg';Path=$spec.Path;Name=$spec.Name;Existed=$true;OldValue=$spec.OldValue
        OldKind='DWord';AppliedValue=$spec.AppliedValue;AppliedKind='DWord'
      }
      $script:RegState[(Get-TestRegKey $spec.Path $spec.Name)] = [pscustomobject]@{ Value=$spec.AppliedValue;Kind='DWord' }
    }
    $doc.Items = $items; $doc.Ops = $ops
    $path = Join-Path $script:BackupDir ("backup-$($doc.BackupId).json")
    Write-BackupDocumentAtomic $path $doc
    $path
  }

  function New-AccountingPowerBackup([string]$OldGuid, [DateTime]$When = ([DateTime]::UtcNow)) {
    $doc = New-BackupDocument $When
    $doc.State = 'complete'
    $opId = [guid]::NewGuid().ToString('D')
    $doc.Items = @([pscustomobject][ordered]@{
      ItemId='power-ultimate';RestoreGroupId='power-ultimate';DisplayName='电源计划切换到「卓越性能」'
      DefinitionHash=('d' * 64);RebootRequired=$true;OpIds=@($opId)
    })
    $doc.Ops = @([pscustomobject][ordered]@{
      Id=$opId;Status='applied';ApplyId=$doc.ApplyId;ItemId='power-ultimate';RestoreGroupId='power-ultimate'
      OpIndex=0;Kind='power';Old=$OldGuid;ToolCreated=$false;NewGuid='99999999-8888-4777-8666-555555555555'
    })
    $path = Join-Path $script:BackupDir ("backup-$($doc.BackupId).json")
    Write-BackupDocumentAtomic $path $doc
    $path
  }

  Initialize-ProtectedStore

  # ---------- 0. 合并还原：v2 整份归档的闸门必须跟着「这份自己的 op」走 ----------
  # v2 没有 op 级凭证，只能整份 .restored 归档。旧实现的判据是「整次还原一条都没失败」，
  # 于是另一份备份里的一条 op 失败，会把这份自己全部成功的 v2 也扣住不归档——
  # 下次还原会把它的旧值原样再写一遍，覆盖用户在这期间做的手动修改。
  # 这一段必须跑在最前面：它用的是合并还原（不传 -BackupFile），备份目录得是干净的。
  $sysmainPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain'
  $wsearchPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch'
  $werPath = 'HKCU:\Software\Microsoft\Windows\Windows Error Reporting'
  $mergedV2Doc = [pscustomobject][ordered]@{
    SchemaVersion=2;BackupId=[guid]::NewGuid().ToString('D');CreatedUtc=[DateTime]::UtcNow.ToString('o')
    UserSid=$script:TargetUserSid;UserLocalAppData=$script:TargetLocalAppData;State='complete';Ops=@(
      [pscustomobject][ordered]@{Id=[guid]::NewGuid().ToString('D');Status='applied';Kind='reg';Path=$sysmainPath;Name='Start';Existed=$true;OldValue=2;OldKind='DWord'},
      [pscustomobject][ordered]@{Id=[guid]::NewGuid().ToString('D');Status='applied';Kind='reg';Path=$wsearchPath;Name='Start';Existed=$true;OldValue=2;OldKind='DWord'}
    );Integrity=$null
  }
  $script:RegState[(Get-TestRegKey $sysmainPath 'Start')] = [pscustomobject]@{Value=4;Kind='DWord'}
  $script:RegState[(Get-TestRegKey $wsearchPath 'Start')] = [pscustomobject]@{Value=4;Kind='DWord'}
  $mergedV2Path = Join-Path $script:BackupDir ("backup-$($mergedV2Doc.BackupId).json")
  Write-BackupDocumentAtomic $mergedV2Path $mergedV2Doc
  $mergedV3Path = New-AccountingRegBackup @(
    [pscustomobject]@{ItemId='wer-off';DisplayName='错误报告';Hash=('f'*64);RebootRequired=$false;Path=$werPath;Name='Disabled';OldValue=0;AppliedValue=1}
  )
  $script:FailRegKey = Get-TestRegKey $werPath 'Disabled'
  $merged = Invoke-Restore $null
  $script:FailRegKey = ''
  Assert-True ($merged.Failed.Count -eq 1 -and $merged.RestoredOps -eq 2 -and
    (Test-Path -LiteralPath ($mergedV2Path + '.restored')) -and
    (Get-RegValue $sysmainPath 'Start') -eq 2 -and (Get-RegValue $wsearchPath 'Start') -eq 2) `
    '同一次还原里别的备份失败，不得扣住这份自己全部成功的 v2 备份不归档'
  $mergedRepair = Invoke-Restore $mergedV3Path
  Assert-True ($mergedRepair.Failed.Count -eq 0 -and $mergedRepair.RestoredOps -eq 1) `
    '合并还原里失败的那一条必须能单独重试成功'

  # ---------- 1. 部分失败必须部分入账，重试只重放失败的那一条 ----------
  $partialPath = New-AccountingRegBackup @(
    [pscustomobject]@{ItemId='hags';DisplayName='硬件加速 GPU 计划';Hash=('a'*64);RebootRequired=$true;Path=$hagsPath;Name='HwSchMode';OldValue=1;AppliedValue=2},
    [pscustomobject]@{ItemId='game-mode';DisplayName='游戏模式';Hash=('b'*64);RebootRequired=$false;Path=$gameModePath;Name='AutoGameModeEnabled';OldValue=3;AppliedValue=4},
    [pscustomobject]@{ItemId='dvr-off';DisplayName='游戏录制';Hash=('c'*64);RebootRequired=$false;Path=$dvrPath;Name='GameDVR_Enabled';OldValue=5;AppliedValue=6}
  )
  $script:FailRegKey = Get-TestRegKey $gameModePath 'AutoGameModeEnabled'
  $partial = Invoke-Restore $partialPath
  $script:FailRegKey = ''
  Assert-True ($partial.Failed.Count -eq 1 -and $partial.RestoredOps -eq 2 -and
    $partial.Receipt -and (Test-Path -LiteralPath $partial.Receipt)) `
    '一条 op 失败时必须仍然为其余成功的 op 写入消费凭证'
  Assert-True ((Get-RegValue $hagsPath 'HwSchMode') -eq 1 -and (Get-RegValue $dvrPath 'GameDVR_Enabled') -eq 5 -and
    (Get-RegValue $gameModePath 'AutoGameModeEnabled') -eq 4) '部分失败时成功的两条必须真的写回原值，失败的那条保持现状'
  Assert-True (@($partial.RestoredItemIds) -contains 'hags' -and @($partial.RestoredItemIds) -contains 'dvr-off' -and
    @($partial.RestoredItemIds) -notcontains 'game-mode') `
    'RestoredItemIds 必须按 op 结果逐项计算，不能被一条失败整体清空'
  # 旧实现在这里返回空数组：14 项里失败 1 项，其余 13 项需要的重启提示被整体吞掉
  Assert-True (@($partial.RebootItems) -contains '硬件加速 GPU 计划' -and
    @($partial.RebootItemIds) -contains 'hags') `
    '部分失败不得吞掉已成功项目的重启提示'

  $script:RegWrites.Clear()
  $partialRetry = Invoke-Restore $partialPath
  Assert-True ($partialRetry.RestoredOps -eq 1 -and $partialRetry.Failed.Count -eq 0 -and
    (@($script:RegWrites.ToArray()) -join ',') -eq (Get-TestRegKey $gameModePath 'AutoGameModeEnabled')) `
    '重试还原只能重放失败的那一条，绝不能把已经写回的旧值再写一遍'
  Assert-True ((Get-RegValue $gameModePath 'AutoGameModeEnabled') -eq 3) '重试必须真正修好上次失败的那一条'

  # ---------- 1b. 同一个项目里一半成功一半失败：两个字段的判据必须不同 ----------
  # 「回到优化前」要求这个项目的 op 全部写回；「要重启」只要有一条真的写回去就成立，
  # 因为那条改动已经落到系统上了。把两者混成一个布尔，必然有一头说假话。
  $mixedDoc = New-BackupDocument ([DateTime]::UtcNow)
  $mixedDoc.State = 'complete'
  $mixedOpA = [guid]::NewGuid().ToString('D'); $mixedOpB = [guid]::NewGuid().ToString('D')
  $mixedDoc.Items = @([pscustomobject][ordered]@{
    ItemId='mmcss-games';RestoreGroupId='mmcss-games';DisplayName='多媒体调度';DefinitionHash=('9'*64)
    RebootRequired=$true;OpIds=@($mixedOpA,$mixedOpB)
  })
  $mixedDoc.Ops = @(
    [pscustomobject][ordered]@{Id=$mixedOpA;Status='applied';ApplyId=$mixedDoc.ApplyId;ItemId='mmcss-games'
      RestoreGroupId='mmcss-games';OpIndex=0;Kind='reg';Path=$gamesTaskPath;Name='GPU Priority'
      Existed=$true;OldValue=8;OldKind='DWord';AppliedValue=18;AppliedKind='DWord'},
    [pscustomobject][ordered]@{Id=$mixedOpB;Status='applied';ApplyId=$mixedDoc.ApplyId;ItemId='mmcss-games'
      RestoreGroupId='mmcss-games';OpIndex=1;Kind='reg';Path=$gamesTaskPath;Name='Priority'
      Existed=$true;OldValue=2;OldKind='DWord';AppliedValue=6;AppliedKind='DWord'}
  )
  $script:RegState[(Get-TestRegKey $gamesTaskPath 'GPU Priority')] = [pscustomobject]@{Value=18;Kind='DWord'}
  $script:RegState[(Get-TestRegKey $gamesTaskPath 'Priority')] = [pscustomobject]@{Value=6;Kind='DWord'}
  $mixedPath = Join-Path $script:BackupDir ("backup-$($mixedDoc.BackupId).json")
  Write-BackupDocumentAtomic $mixedPath $mixedDoc
  $script:FailRegKey = Get-TestRegKey $gamesTaskPath 'Priority'
  $mixed = Invoke-Restore $mixedPath
  $script:FailRegKey = ''
  Assert-True (@($mixed.RestoredItemIds) -notcontains 'mmcss-games') `
    '项目里还有 op 没写回时不得说它已经回到优化前'
  Assert-True (@($mixed.RebootItems) -contains '多媒体调度') `
    '项目里已经写回的那条改动需要重启才生效，重启提示不能因为同项目另一条失败就消失'
  $script:RegWrites.Clear()
  $mixedRetry = Invoke-Restore $mixedPath
  Assert-True ($mixedRetry.Failed.Count -eq 0 -and
    (@($script:RegWrites.ToArray()) -join ',') -eq (Get-TestRegKey $gamesTaskPath 'Priority') -and
    @($mixedRetry.RestoredItemIds) -contains 'mmcss-games') `
    '补齐最后一条后项目才算回到优化前，且不得重放已经写回的那一条'

  # ---------- 1c. 去重挤掉的同目标记录必须跟着一起消费 ----------
  # 同一个目标被两次优化各记了一遍：旧那份记的是真原值，新那份记的是上一轮工具写进去的
  # 中间值。合并还原只执行最旧那条（$lastIdx 去重），但**两条 wrapper 都要消费**——
  # 否则下次还原时那条中间值成了该目标唯一存活的记录，会被当成原值写回系统。
  # 这正是 Get-RestoreOpAccountingKey 与去重键同源的全部意义。
  $dedupBase = [DateTime]::UtcNow
  [void](New-AccountingRegBackup @(
    [pscustomobject]@{ItemId='transparency-off';DisplayName='透明效果';Hash=('1'*64);RebootRequired=$false;Path=$transparencyPath;Name='EnableTransparency';OldValue=1;AppliedValue=0}
  ) $dedupBase.AddMinutes(-10))
  [void](New-AccountingRegBackup @(
    [pscustomobject]@{ItemId='transparency-off';DisplayName='透明效果';Hash=('1'*64);RebootRequired=$false;Path=$transparencyPath;Name='EnableTransparency';OldValue=0;AppliedValue=0}
  ) $dedupBase)
  $script:RegWrites.Clear()
  $dedup = Invoke-Restore $null
  Assert-True ($dedup.Failed.Count -eq 0 -and $dedup.RestoredOps -eq 1 -and
    (Get-RegValue $transparencyPath 'EnableTransparency') -eq 1) `
    '同目标的多份记录必须只执行最旧那条（写回真原值），不能把中间值也写一遍'
  $script:RegWrites.Clear()
  $dedupRetryError = ''
  try { [void](Invoke-Restore $null) } catch { $dedupRetryError = $_.Exception.Message }
  Assert-True ($dedupRetryError -like '*未找到尚未还原的备份*' -and
    @($script:RegWrites.ToArray()).Count -eq 0 -and
    (Get-RegValue $transparencyPath 'EnableTransparency') -eq 1) `
    '被去重挤掉的那条中间值记录没有被消费——下次还原会把中间值当原值写回系统'

  # ---------- 2. 记账失败不是还原失败 ----------
  $originalWriteRestoreReceipt = ${function:Write-RestoreReceipt}
  try {
    function Write-RestoreReceipt($Receipt) { throw 'fixture receipt store is read-only' }
    $bookPath = New-AccountingRegBackup @(
      [pscustomobject]@{ItemId='mouse-accel-off';DisplayName='鼠标加速';Hash=('e'*64);RebootRequired=$false;Path=$mousePath;Name='MouseSpeed';OldValue=7;AppliedValue=8}
    )
    $book = Invoke-Restore $bookPath
    Assert-True ($book.Failed.Count -eq 0 -and $book.RestoredOps -eq 1 -and
      (Get-RegValue $mousePath 'MouseSpeed') -eq 7 -and @($book.BookkeepingFailed).Count -eq 1) `
      '记账失败不得被报成还原失败：系统设置确实已经写回去了'
    Assert-True ("$($book.BookkeepingFailed)" -like '*下次还原*') `
      '记账失败必须说清真正的风险是下次还原会重放同样的旧值'
    Assert-True ((Get-RestoreExitCode $book) -eq 6) '记账失败必须有自己的退出码，不能混进 4'
  } finally {
    Set-Item -LiteralPath Function:\Write-RestoreReceipt -Value $originalWriteRestoreReceipt
  }
  # 上一段的 op 没有被消费（凭证没写成），这里补一次正常还原把它收尾，
  # 顺便确认「记账失败后重试」确实能把账补上
  $bookRepair = Invoke-Restore $bookPath
  Assert-True ($bookRepair.RestoredOps -eq 1 -and @($bookRepair.BookkeepingFailed).Count -eq 0 -and
    $bookRepair.Receipt -and (Test-Path -LiteralPath $bookRepair.Receipt)) `
    '记账失败后重试还原必须能把账补上'

  # ---------- 3. 退出码分档 ----------
  Assert-True ((Get-RestoreExitCode ([pscustomobject]@{Failed=@('x');BookkeepingFailed=@()})) -eq 4 -and
    (Get-RestoreExitCode ([pscustomobject]@{Failed=@();BookkeepingFailed=@('y')})) -eq 6 -and
    (Get-RestoreExitCode ([pscustomobject]@{Failed=@('x');BookkeepingFailed=@('y')})) -eq 4 -and
    (Get-RestoreExitCode ([pscustomobject]@{Failed=@();BookkeepingFailed=@()})) -eq 0) `
    '还原退出码必须把「记账失败」和「还原失败」分成两档'
  # PowerShell 5.1 的 @($null).Count 是 1：缺字段的旧结果对象绝不能被判成记账失败
  Assert-True ((Get-RestoreExitCode ([pscustomobject]@{Failed=@()})) -eq 0) `
    '结果对象缺 BookkeepingFailed 字段时必须返回 0，不能被 @($null) 误判'

  # ---------- 4. 可重试 vs 不可重试的电源回退 ----------
  $originalGetPowerSchemes = ${function:Get-PowerSchemes}
  $originalInvokeSchemeActivate = ${function:Invoke-SchemeActivate}
  try {
    $script:FixtureOriginalGuid = '11111111-2222-4333-8444-555555555555'
    $script:FixtureActivateCalls = New-Object System.Collections.Generic.List[string]
    $script:FixtureOriginalPresent = $true
    function Get-PowerSchemes {
      $list = @([pscustomobject]@{Guid=$script:BalancedGuid;Name='平衡';Active=$false})
      if ($script:FixtureOriginalPresent) {
        $list = @([pscustomobject]@{Guid=$script:FixtureOriginalGuid;Name='用户原方案';Active=$false}) + $list
      }
      $list
    }
    # 先钉最常见的那条路径：原方案还在、也切回去了。它必须入账，否则每一次还原都会
    # 再 activate 一遍旧 GUID，把用户此后手动选的电源方案覆盖掉，界面还显示「全部还原成功」。
    function Invoke-SchemeActivate([string]$SchemeGuid) {
      [void]$script:FixtureActivateCalls.Add($SchemeGuid)
      $script:LastActivateOut = ''
      $true
    }
    $exactPath = New-AccountingPowerBackup $script:FixtureOriginalGuid
    $exact = Invoke-Restore $exactPath
    Assert-True ($exact.Failed.Count -eq 0 -and $exact.Skipped.Count -eq 0 -and $exact.RestoredOps -eq 1 -and
      (@($script:FixtureActivateCalls.ToArray()) -join ',') -eq $script:FixtureOriginalGuid -and
      $exact.Receipt -and (Test-Path -LiteralPath $exact.Receipt) -and
      @($exact.RestoredItemIds) -contains 'power-ultimate') `
      '电源方案精确切回成功后必须入账'
    $script:FixtureActivateCalls.Clear()
    $exactRetry = Invoke-Restore $exactPath
    Assert-True (@($script:FixtureActivateCalls.ToArray()).Count -eq 0 -and
      "$($exactRetry.Notes)" -like '*此前已完成还原*') `
      '已经精确切回的电源方案不得在下次还原时被再 activate 一遍'

    # 原方案还在，但每次激活都被挡回来（第三方电源管理器 / 组策略）
    function Invoke-SchemeActivate([string]$SchemeGuid) {
      [void]$script:FixtureActivateCalls.Add($SchemeGuid)
      $script:LastActivateOut = $(if ($SchemeGuid -ieq $script:BalancedGuid) { '' } else { 'fixture power manager refused' })
      $SchemeGuid -ieq $script:BalancedGuid
    }
    $script:FixtureActivateCalls.Clear()
    $retryablePath = New-AccountingPowerBackup $script:FixtureOriginalGuid
    $retryable = Invoke-Restore $retryablePath
    Assert-True ($retryable.Failed.Count -eq 0 -and $retryable.Skipped.Count -eq 1 -and
      $null -eq $retryable.Receipt) `
      '原方案仍在、只是这次激活失败时绝不能消费该记录——下次还原必须还能重试'
    $script:FixtureActivateCalls.Clear()
    $retryableAgain = Invoke-Restore $retryablePath
    Assert-True (@($script:FixtureActivateCalls.ToArray()) -contains $script:FixtureOriginalGuid -and
      $retryableAgain.Skipped.Count -eq 1 -and $null -eq $retryableAgain.Receipt) `
      '可重试的电源回退必须在下次还原时真的被重新尝试'

    # 原方案已经被删掉：再点一百次也变不回来，必须消费掉，否则每次还原都重复报同一句
    $script:FixtureOriginalPresent = $false
    $goneGuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    $gonePath = New-AccountingPowerBackup $goneGuid
    $gone = Invoke-Restore $gonePath
    Assert-True ($gone.Failed.Count -eq 0 -and $gone.Skipped.Count -eq 1 -and
      $gone.Receipt -and (Test-Path -LiteralPath $gone.Receipt) -and
      @($gone.SkippedItemIds) -contains 'power-ultimate') `
      '原方案已被删除时必须消费该记录并进入 SkippedItemIds'
    $goneRetry = Invoke-Restore $gonePath
    Assert-True ($goneRetry.Skipped.Count -eq 0 -and "$($goneRetry.Notes)" -like '*此前已完成还原*') `
      '不可重试的电源回退消费后不得再次出现'

    # 备份里根本没记原方案 GUID（早期/手工备份）：旧实现一声不吭地跳过并勾销，
    # 用户看到「全部还原成功」，系统却还停在优化时的方案上
    $blankPath = New-AccountingPowerBackup ''
    $blank = Invoke-Restore $blankPath
    Assert-True ($blank.Failed.Count -eq 0 -and $blank.Skipped.Count -eq 1 -and
      $blank.Skipped[0] -like '*没有记录优化前的电源方案*' -and
      $blank.Receipt -and (Test-Path -LiteralPath $blank.Receipt)) `
      '备份没记原电源方案时必须如实告诉用户，不能静默算成功'

    # ---------- 4b. 不可重试的判决只能勾销它自己那一条 ----------
    # 'power' 的去重键是全局裸键 'power'：同一次合并还原里，所有备份的 power op 共用一个键。
    # 最旧那份记的方案已经被卸载软件删掉（走安全回退 → 不可重试），但次旧那份记的方案
    # **仍然存在、仍然能激活**。如果「不可重试」按键连带消费，次旧那条会在一次都没被
    # 尝试过的情况下被永久销毁，用户再也回不到那个方案。
    $script:FixtureOriginalPresent = $false
    $script:FixtureSurvivingGuid = '77777777-6666-4555-8444-333333333333'
    function Get-PowerSchemes {
      @([pscustomobject]@{Guid=$script:FixtureSurvivingGuid;Name='用户后来选的方案';Active=$false},
        [pscustomobject]@{Guid=$script:BalancedGuid;Name='平衡';Active=$false})
    }
    # 存活的那个方案是真能激活的——这正是它不该被勾销的理由
    function Invoke-SchemeActivate([string]$SchemeGuid) {
      [void]$script:FixtureActivateCalls.Add($SchemeGuid)
      $script:LastActivateOut = $(if ($SchemeGuid -iin @($script:FixtureSurvivingGuid, $script:BalancedGuid)) { '' } else { 'fixture scheme is gone' })
      $SchemeGuid -iin @($script:FixtureSurvivingGuid, $script:BalancedGuid)
    }
    $crossBase = [DateTime]::UtcNow
    $crossOlder = New-AccountingPowerBackup 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff' $crossBase.AddMinutes(-10)
    $crossNewer = New-AccountingPowerBackup $script:FixtureSurvivingGuid $crossBase
    $script:FixtureActivateCalls.Clear()
    $cross = Invoke-Restore $null
    Assert-True ($cross.Failed.Count -eq 0 -and $cross.Skipped.Count -eq 1 -and
      $cross.Skipped[0] -like '*已不存在*') `
      '合并还原必须先尝试最旧那份记的方案'
    $script:FixtureActivateCalls.Clear()
    $crossRetry = Invoke-Restore $crossNewer
    Assert-True ($crossRetry.RestoredOps -eq 1 -and $crossRetry.Failed.Count -eq 0 -and
      (@($script:FixtureActivateCalls.ToArray()) -contains $script:FixtureSurvivingGuid)) `
      '「原方案已删除」这条判决把别的备份里仍然有效的电源方案也一起勾销了'

    # ---------- 4c. v2 整份归档的闸门也要认「不可重试的安全回退」 ----------
    # 闸门的判据是「这份自己的 op 全部入账」，入账包含安全回退那一半。只认成功的话，
    # 含安全回退 op 的 v2 备份永远归档不了：每次还原都把同份里那条 reg 旧值重写一遍，
    # 并且每次都重复报同一句电源回退提示。
    $v2FinalDoc = [pscustomobject][ordered]@{
      SchemaVersion=2;BackupId=[guid]::NewGuid().ToString('D');CreatedUtc=[DateTime]::UtcNow.ToString('o')
      UserSid=$script:TargetUserSid;UserLocalAppData=$script:TargetLocalAppData;State='complete';Ops=@(
        [pscustomobject][ordered]@{Id=[guid]::NewGuid().ToString('D');Status='applied';Kind='reg';Path=$visualFxPath;Name='VisualFXSetting';Existed=$true;OldValue=1;OldKind='DWord'},
        [pscustomobject][ordered]@{Id=[guid]::NewGuid().ToString('D');Status='applied';Kind='power';Old='cccccccc-dddd-4eee-8fff-000000000000';ToolCreated=$false;NewGuid=$null}
      );Integrity=$null
    }
    $script:RegState[(Get-TestRegKey $visualFxPath 'VisualFXSetting')] = [pscustomobject]@{Value=2;Kind='DWord'}
    $v2FinalPath = Join-Path $script:BackupDir ("backup-$($v2FinalDoc.BackupId).json")
    Write-BackupDocumentAtomic $v2FinalPath $v2FinalDoc
    $v2Final = Invoke-Restore $v2FinalPath
    Assert-True ($v2Final.Failed.Count -eq 0 -and $v2Final.Skipped.Count -eq 1 -and
      (Get-RegValue $visualFxPath 'VisualFXSetting') -eq 1 -and
      (Test-Path -LiteralPath ($v2FinalPath + '.restored'))) `
      '含安全回退 op 的 v2 备份必须照常归档，否则每次还原都重写同一条旧值'
  } finally {
    Set-Item -LiteralPath Function:\Get-PowerSchemes -Value $originalGetPowerSchemes
    Set-Item -LiteralPath Function:\Invoke-SchemeActivate -Value $originalInvokeSchemeActivate
  }

  # ---------- 4d. 每一类 op 都有自己的记账点，逐类都要钉 ----------
  # 把「消费」从全局闸门改成逐 op 记账，等于给每一种 Kind 都新增了一个必须写对的记账点。
  # 一份备份里放齐五类，让 reg 那条失败：其余四类必须全部入账，于是重试**只**重放 reg。
  # 任何一类漏了记账，重试都会把它再执行一遍——对 hib/bcd 这种系统级开关，
  # 等于把用户后来手动开的休眠 / 启动项再关一次。
  $originalGetTaskQueryState = ${function:Get-TaskQueryState}
  $originalGetMMAgentState = ${function:Get-MMAgentState}
  $originalSetMMAgentState = ${function:Set-MMAgentState}
  $originalGetHibernateState = ${function:Get-HibernateState}
  $originalSetHibernateEnabled = ${function:Set-HibernateEnabled}
  $originalRemoveBcdEntryValue = ${function:Remove-BcdEntryValue}
  try {
    $script:KindCalls = New-Object System.Collections.Generic.List[string]
    $script:KindMMAgent = $false; $script:KindHibernate = $false
    function Get-TaskQueryState([string]$TaskName) { [void]$script:KindCalls.Add('sched'); 'absent' }
    function Get-MMAgentState([string]$Feature) { [bool]$script:KindMMAgent }
    function Set-MMAgentState([string]$Feature,[bool]$Enabled) { [void]$script:KindCalls.Add('mmagent'); $script:KindMMAgent = $Enabled }
    function Get-HibernateState { [bool]$script:KindHibernate }
    function Set-HibernateEnabled([bool]$On) { [void]$script:KindCalls.Add('hib'); $script:KindHibernate = $On }
    function Remove-BcdEntryValue([string]$Name) { [void]$script:KindCalls.Add('bcd') }

    $kindDoc = New-BackupDocument ([DateTime]::UtcNow)
    $kindDoc.State = 'complete'
    $kindSpecs = @(
      [pscustomobject]@{ItemId='sysmain-off';Name='预读服务';Kind='sched';Fields=[ordered]@{TaskName=$script:LockTask}},
      [pscustomobject]@{ItemId='mem-compress-off';Name='内存压缩';Kind='mmagent';Fields=[ordered]@{Feature='mc';OldEnabled=$true}},
      [pscustomobject]@{ItemId='hibernate-off';Name='休眠';Kind='hib';Fields=[ordered]@{OldEnabled=$true}},
      [pscustomobject]@{ItemId='dyntick-off';Name='动态计时器';Kind='bcd';Fields=[ordered]@{Name='disabledynamictick';OldValue='absent'}},
      [pscustomobject]@{ItemId='paging-exec';Name='内核常驻内存';Kind='reg';Fields=[ordered]@{
        Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management';Name='DisablePagingExecutive'
        Existed=$true;OldValue=0;OldKind='DWord';AppliedValue=1;AppliedKind='DWord'}}
    )
    $kindItems = @(); $kindOps = @(); $kindIndex = 0
    foreach ($spec in $kindSpecs) {
      $opId = [guid]::NewGuid().ToString('D')
      $fields = [ordered]@{
        Id=$opId;Status='applied';ApplyId=$kindDoc.ApplyId;ItemId=$spec.ItemId
        RestoreGroupId=$spec.ItemId;OpIndex=0;Kind=$spec.Kind
      }
      foreach ($key in $spec.Fields.Keys) { $fields[$key] = $spec.Fields[$key] }
      $kindOps += [pscustomobject]$fields
      $kindItems += [pscustomobject][ordered]@{
        ItemId=$spec.ItemId;RestoreGroupId=$spec.ItemId;DisplayName=$spec.Name
        DefinitionHash=(('{0:x}' -f ($kindIndex + 1)) * 64).Substring(0,64);RebootRequired=$false;OpIds=@($opId)
      }
      $kindIndex++
    }
    $kindDoc.Items = $kindItems; $kindDoc.Ops = $kindOps
    $pagingPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $script:RegState[(Get-TestRegKey $pagingPath 'DisablePagingExecutive')] = [pscustomobject]@{Value=1;Kind='DWord'}
    $kindPath = Join-Path $script:BackupDir ("backup-$($kindDoc.BackupId).json")
    Write-BackupDocumentAtomic $kindPath $kindDoc

    $script:FailRegKey = Get-TestRegKey $pagingPath 'DisablePagingExecutive'
    $kindFirst = Invoke-Restore $kindPath
    $script:FailRegKey = ''
    Assert-True ($kindFirst.Failed.Count -eq 1 -and $kindFirst.RestoredOps -eq 4 -and
      (@($script:KindCalls.ToArray() | Sort-Object -Unique) -join ',') -eq 'bcd,hib,mmagent,sched') `
      '五类 op 没有各自走到自己的还原分支'
    $script:KindCalls.Clear(); $script:RegWrites.Clear()
    $kindRetry = Invoke-Restore $kindPath
    Assert-True ($kindRetry.Failed.Count -eq 0 -and $kindRetry.RestoredOps -eq 1 -and
      @($script:KindCalls.ToArray()).Count -eq 0 -and
      (@($script:RegWrites.ToArray()) -join ',') -eq (Get-TestRegKey $pagingPath 'DisablePagingExecutive')) `
      'sched / mmagent / hib / bcd 里有类型漏了记账——重试把已经还原好的系统开关又改了一遍'
  } finally {
    Set-Item -LiteralPath Function:\Get-TaskQueryState -Value $originalGetTaskQueryState
    Set-Item -LiteralPath Function:\Get-MMAgentState -Value $originalGetMMAgentState
    Set-Item -LiteralPath Function:\Set-MMAgentState -Value $originalSetMMAgentState
    Set-Item -LiteralPath Function:\Get-HibernateState -Value $originalGetHibernateState
    Set-Item -LiteralPath Function:\Set-HibernateEnabled -Value $originalSetHibernateEnabled
    Set-Item -LiteralPath Function:\Remove-BcdEntryValue -Value $originalRemoveBcdEntryValue
  }

  # ---------- 4e. 一条 op 校验没过，不得作废整份备份文档 ----------
  # 用户症状：装过老版本、用过「关闭 NVIDIA App 自动优化」的用户，那一次执行产生的
  # 整份备份作废——同一份里十几个注册表原值一起没了，还原清单里那次优化直接不出现。
  # 现在只作废那一条，其余照常还原；被拒绝的 op 仍然一条都不执行，但必须逐条报出来。
  $mixedFaultDoc = New-BackupDocument ([DateTime]::UtcNow)
  $mixedFaultDoc.State = 'complete'
  $faultOpId = [guid]::NewGuid().ToString('D')
  $goodOpA = [guid]::NewGuid().ToString('D'); $goodOpB = [guid]::NewGuid().ToString('D')
  $mixedOpId = [guid]::NewGuid().ToString('D'); $mixedFaultOpId = [guid]::NewGuid().ToString('D')
  $mixedFaultDoc.Items = @(
    [pscustomobject][ordered]@{ItemId='fso-off';RestoreGroupId='fso-off';DisplayName='全屏优化'
      DefinitionHash=('2'*64);RebootRequired=$false;OpIds=@($faultOpId)},
    [pscustomobject][ordered]@{ItemId='wsearch-off';RestoreGroupId='wsearch-off';DisplayName='Windows 搜索索引'
      DefinitionHash=('3'*64);RebootRequired=$true;OpIds=@($goodOpA,$goodOpB)},
    # 半好半坏的项目：好的那条照常还原，但它不算「回到优化前」，也不许被拿去按项目复原
    [pscustomobject][ordered]@{ItemId='mpo-off';RestoreGroupId='mpo-off';DisplayName='多平面叠加'
      DefinitionHash=('4'*64);RebootRequired=$false;OpIds=@($mixedOpId,$mixedFaultOpId)}
  )
  $mixedFaultDoc.Ops = @(
    [pscustomobject][ordered]@{Id=$faultOpId;Status='applied';ApplyId=$mixedFaultDoc.ApplyId;ItemId='fso-off'
      RestoreGroupId='fso-off';OpIndex=0;Kind='file';Path=(Join-Path $temp 'nvidia-app.cfg')
      OrigB64=[Convert]::ToBase64String([byte[]](1,2))},
    [pscustomobject][ordered]@{Id=$goodOpA;Status='applied';ApplyId=$mixedFaultDoc.ApplyId;ItemId='wsearch-off'
      RestoreGroupId='wsearch-off';OpIndex=0;Kind='reg';Path=$wsearchPath;Name='Start'
      Existed=$true;OldValue=2;OldKind='DWord';AppliedValue=4;AppliedKind='DWord'},
    [pscustomobject][ordered]@{Id=$goodOpB;Status='applied';ApplyId=$mixedFaultDoc.ApplyId;ItemId='wsearch-off'
      RestoreGroupId='wsearch-off';OpIndex=1;Kind='reg';Path=$sysmainPath;Name='Start'
      Existed=$true;OldValue=2;OldKind='DWord';AppliedValue=4;AppliedKind='DWord'},
    [pscustomobject][ordered]@{Id=$mixedOpId;Status='applied';ApplyId=$mixedFaultDoc.ApplyId;ItemId='mpo-off'
      RestoreGroupId='mpo-off';OpIndex=0;Kind='reg';Path=$dwmPath;Name='OverlayTestMode'
      Existed=$true;OldValue=0;OldKind='DWord';AppliedValue=5;AppliedKind='DWord'},
    [pscustomobject][ordered]@{Id=$mixedFaultOpId;Status='applied';ApplyId=$mixedFaultDoc.ApplyId;ItemId='mpo-off'
      RestoreGroupId='mpo-off';OpIndex=1;Kind='file';Path=(Join-Path $temp 'mpo.cfg')
      OrigB64=[Convert]::ToBase64String([byte[]](3,4))}
  )
  $script:RegState[(Get-TestRegKey $wsearchPath 'Start')] = [pscustomobject]@{Value=4;Kind='DWord'}
  $script:RegState[(Get-TestRegKey $sysmainPath 'Start')] = [pscustomobject]@{Value=4;Kind='DWord'}
  $script:RegState[(Get-TestRegKey $dwmPath 'OverlayTestMode')] = [pscustomobject]@{Value=5;Kind='DWord'}
  $mixedFaultPath = Join-Path $script:BackupDir ("backup-$($mixedFaultDoc.BackupId).json")
  Write-BackupDocumentAtomic $mixedFaultPath $mixedFaultDoc

  $faultCatalog = Get-RestoreItemCatalog
  Assert-True (@($faultCatalog.Items | Where-Object Id -eq 'wsearch-off').Count -eq 1) `
    '同一份备份里的好数据被那条校验没过的 op 一起埋掉了'
  # 全部 op 都被拒绝的项目：压根不在活动集合里，只能靠单独一条路径补进清单
  $faultItemRow = @($faultCatalog.Items | Where-Object Id -eq 'fso-off')
  Assert-True ($faultItemRow.Count -eq 1 -and $faultItemRow[0].Status -eq 'unsupported' -and
    -not $faultItemRow[0].CanRestore -and $faultItemRow[0].Reason -match '停用|白名单') `
    '被拒绝的 op 所属项目必须继续出现在清单里并说清原因，不能悄悄消失'
  # 半好半坏的项目：有活动 op，所以走主循环那条分支，必须被判成不可按项目复原
  $mixedItemRow = @($faultCatalog.Items | Where-Object Id -eq 'mpo-off')
  Assert-True ($mixedItemRow.Count -eq 1 -and $mixedItemRow[0].Status -eq 'unsupported' -and
    -not $mixedItemRow[0].CanRestore -and $mixedItemRow[0].Reason -match '停用|白名单') `
    '项目里只要有一条改动还不回去，就不能把它当成可精确复原'
  Assert-True ([int]$faultCatalog.UnrestorableOpCount -eq 2) '还不回去的改动条数没有单独回传给界面'

  $mixedFault = Invoke-Restore $mixedFaultPath
  Assert-True ($mixedFault.RestoredOps -eq 3 -and
    (Get-RegValue $wsearchPath 'Start') -eq 2 -and (Get-RegValue $sysmainPath 'Start') -eq 2 -and
    (Get-RegValue $dwmPath 'OverlayTestMode') -eq 0) `
    '一条 op 校验没过时，同一份里的其他原值必须照常写回'
  Assert-True (@($mixedFault.Failed).Count -eq 2 -and
    (@($mixedFault.Failed) -join '|') -like '*全屏优化*' -and
    (@($mixedFault.Failed) -join '|') -match '停用|白名单') `
    '被拒绝的 op 必须带人话项名和原因出现在失败清单里'
  Assert-True (@($mixedFault.RestoredItemIds) -contains 'wsearch-off' -and
    @($mixedFault.RestoredItemIds) -notcontains 'fso-off' -and
    @($mixedFault.RestoredItemIds) -notcontains 'mpo-off' -and
    @($mixedFault.RebootItems) -contains 'Windows 搜索索引') `
    '项目里还有改动永远回不去时，不得说它已经回到优化前'
  $script:RegWrites.Clear()
  $mixedFaultRetry = Invoke-Restore $mixedFaultPath
  Assert-True ($mixedFaultRetry.RestoredOps -eq 0 -and @($script:RegWrites.ToArray()).Count -eq 0 -and
    "$($mixedFaultRetry.Notes)" -like '*此前已完成还原*') `
    '好数据还原后不得因为那条被拒绝的 op 而反复重放'

  # ---------- 4f. 计划任务「查不到」不等于「不存在」 ----------
  # Schedule 服务被 debloat 脚本停掉 / 任务注册损坏 / RPC 瞬时失败时，旧写法把
  # 查询失败读成「任务已经不在了」→ 记成功 → 写消费凭证。而锁定任务活着，
  # 每分钟把刚还原好的电源方案切回优化方案，用户却看到「全部还原成功」。
  $originalSchedQueryState = ${function:Get-TaskQueryState}
  $originalSchedLockTask = ${function:Test-BoosterLockTask}
  $originalSchedPowerRestore = ${function:Invoke-RestorePowerScheme}
  try {
    $script:SchedProbe = 'unknown'
    $script:SchedIdentityOk = $true
    $script:SchedPowerCalls = 0
    function Get-TaskQueryState([string]$TaskName) { "$script:SchedProbe" }
    function Test-BoosterLockTask([string]$TaskName) { [bool]$script:SchedIdentityOk }
    function Invoke-RestorePowerScheme([string]$OriginalGuid) {
      $script:SchedPowerCalls++
      [pscustomobject]@{Guid=$OriginalGuid;Exact=$true;Retryable=$false;Message=$null}
    }

    # 同一份备份里有锁定任务和电源方案两条 op，正是真实「锁定电源计划」的组合
    function New-SchedPowerBackup {
      $doc = New-BackupDocument ([DateTime]::UtcNow)
      $doc.State = 'complete'
      $schedOpId = [guid]::NewGuid().ToString('D'); $powerOpId = [guid]::NewGuid().ToString('D')
      $doc.Items = @(
        [pscustomobject][ordered]@{ItemId='powerplan-lock';RestoreGroupId='powerplan-lock';DisplayName='电源锁定任务'
          DefinitionHash=('5'*64);RebootRequired=$false;OpIds=@($schedOpId)},
        [pscustomobject][ordered]@{ItemId='power-ultimate';RestoreGroupId='power-ultimate';DisplayName='电源计划'
          DefinitionHash=('6'*64);RebootRequired=$true;OpIds=@($powerOpId)}
      )
      $doc.Ops = @(
        [pscustomobject][ordered]@{Id=$schedOpId;Status='applied';ApplyId=$doc.ApplyId;ItemId='powerplan-lock'
          RestoreGroupId='powerplan-lock';OpIndex=0;Kind='sched';TaskName=$script:LockTask},
        [pscustomobject][ordered]@{Id=$powerOpId;Status='applied';ApplyId=$doc.ApplyId;ItemId='power-ultimate'
          RestoreGroupId='power-ultimate';OpIndex=0;Kind='power'
          Old='11111111-2222-4333-8444-555555555555';ToolCreated=$false;NewGuid=$null}
      )
      $path = Join-Path $script:BackupDir ("backup-$($doc.BackupId).json")
      Write-BackupDocumentAtomic $path $doc
      $path
    }

    $script:SchedProbe = 'unknown'
    $unknownPath = New-SchedPowerBackup
    $unknownRestore = Invoke-Restore $unknownPath
    Assert-True (@($unknownRestore.Failed).Count -eq 2 -and
      (@($unknownRestore.Failed) -join '|') -like '*无法确认*' -and
      $null -eq $unknownRestore.Receipt -and $script:SchedPowerCalls -eq 0) `
      '任务计划服务查不了时不得判定为「已删除」，更不得写消费凭证'
    Assert-True ((@($unknownRestore.Failed) -join '|') -like '*1 分钟内被它改回*') `
      '锁定任务没删掉时，电源方案还原是白写，必须说出来而不是照常写回'

    # 修好服务后重试：两条 op 都还在，能正常还原
    $script:SchedProbe = 'absent'
    $unknownRetry = Invoke-Restore $unknownPath
    Assert-True ($unknownRetry.Failed.Count -eq 0 -and $unknownRetry.RestoredOps -eq 2 -and
      $script:SchedPowerCalls -eq 1 -and $unknownRetry.Receipt -and (Test-Path -LiteralPath $unknownRetry.Receipt)) `
      '「无法确认」必须是可重试状态——修好任务计划服务后重试要能还原'

    # 任务确实在，但不是本工具建的：拒绝删除，同样不得放行电源方案
    $script:SchedProbe = 'present'; $script:SchedIdentityOk = $false
    $foreignPath = New-SchedPowerBackup
    $foreignRestore = Invoke-Restore $foreignPath
    Assert-True (@($foreignRestore.Failed).Count -eq 2 -and
      (@($foreignRestore.Failed) -join '|') -like '*不是本工具创建*' -and
      $null -eq $foreignRestore.Receipt) `
      '同名计划任务不是本工具创建时必须拒绝删除'
  } finally {
    Set-Item -LiteralPath Function:\Get-TaskQueryState -Value $originalSchedQueryState
    Set-Item -LiteralPath Function:\Test-BoosterLockTask -Value $originalSchedLockTask
    Set-Item -LiteralPath Function:\Invoke-RestorePowerScheme -Value $originalSchedPowerRestore
  }

  # ---------- 5. v2 整份归档的闸门跟着 op 走 ----------
  # v2 没有 op 级凭证，只能整份 .restored 归档。所以它的判据必须是「这份自己的 op
  # 全部入账」——只要还剩一条没入账就不能改名，否则剩下那条会随归档被永久勾销。
  $v2Doc = [pscustomobject][ordered]@{
    SchemaVersion=2;BackupId=[guid]::NewGuid().ToString('D');CreatedUtc=[DateTime]::UtcNow.ToString('o')
    UserSid=$script:TargetUserSid;UserLocalAppData=$script:TargetLocalAppData;State='complete';Ops=@(
      [pscustomobject][ordered]@{Id=[guid]::NewGuid().ToString('D');Status='applied';Kind='reg';Path=$mmPath;Name='SystemResponsiveness';Existed=$true;OldValue=11;OldKind='DWord'},
      [pscustomobject][ordered]@{Id=[guid]::NewGuid().ToString('D');Status='applied';Kind='reg';Path=$mmPath;Name='NetworkThrottlingIndex';Existed=$true;OldValue=22;OldKind='DWord'}
    );Integrity=$null
  }
  $script:RegState[(Get-TestRegKey $mmPath 'SystemResponsiveness')] = [pscustomobject]@{Value=111;Kind='DWord'}
  $script:RegState[(Get-TestRegKey $mmPath 'NetworkThrottlingIndex')] = [pscustomobject]@{Value=222;Kind='DWord'}
  $v2Path = Join-Path $script:BackupDir ("backup-$($v2Doc.BackupId).json")
  Write-BackupDocumentAtomic $v2Path $v2Doc
  $script:FailRegKey = Get-TestRegKey $mmPath 'NetworkThrottlingIndex'
  $v2Partial = Invoke-Restore $v2Path
  $script:FailRegKey = ''
  Assert-True ($v2Partial.Failed.Count -eq 1 -and -not (Test-Path -LiteralPath ($v2Path + '.restored'))) `
    'v2 备份只要还剩一条 op 没入账就不能打 .restored'
  $v2Retry = Invoke-Restore $v2Path
  Assert-True ($v2Retry.Failed.Count -eq 0 -and (Test-Path -LiteralPath ($v2Path + '.restored')) -and
    (Get-RegValue $mmPath 'NetworkThrottlingIndex') -eq 22) `
    'v2 备份补齐最后一条后必须归档'

} finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------- 6. 界面必须把「记账失败」说出来，而且不能说成「完成」 ----------
# 引擎算出来、传过去、然后被界面丢掉，是这个仓库里已经发生过的事。
$guiRaw = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'gui\DeltaForceBooster-GUI.ps1'), [Text.Encoding]::UTF8)
Assert-True ($guiRaw.Contains('$r.BookkeepingFailed')) '界面没有读取 BookkeepingFailed —— 记账失败对用户完全不可见'
Assert-True ($guiRaw.Contains('[记账失败]')) '记账失败没有进运行日志，导出的诊断报告里也就没有'
Assert-True ($guiRaw.Contains("if (`$failN -eq 0 -and `$bookN -gt 0) { `$restoreDialogTitle = '还原部分完成'")) `
  '记账失败时对话框仍然会说「还原完成」'

# CLI 同样不能让它消失：脚本化调用方（含 SKILL.md 指引 agent 跑 -Restore）只看得到输出和退出码
$engineRaw = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\delta-booster.ps1'), [Text.Encoding]::UTF8)
Assert-True ($engineRaw.Contains('foreach ($b in $r.BookkeepingFailed) { Write-Output "  [记账失败] $b" }')) `
  'CLI 文本输出丢掉了记账失败'

# ---------- 6b. 锁定任务探测必须三态，而且要认带安装根哈希的任务名 ----------
# 备份侧 Assert-BackupOperation 本来就兼容「裸前缀」和「前缀-12位哈希」两种任务名，
# 探测侧只认当前安装根算出来的那一个是不对称的：换过安装目录的老用户，任务还在跑，
# 界面却一直显示「未锁定」，点优化又会因为同名任务已存在而失败。
$originalProbeState = ${function:Get-TaskQueryState}
$originalProbeCandidates = ${function:Get-BoosterLockTaskCandidates}
$originalProbeIdentity = ${function:Test-BoosterLockTask}
try {
  $script:ProbeStates = @{}
  $script:ProbeIdentities = @{}
  $script:ProbeCandidates = @()
  function Get-TaskQueryState([string]$TaskName) {
    if ($script:ProbeStates.ContainsKey($TaskName)) { return $script:ProbeStates[$TaskName] }
    'absent'
  }
  function Get-BoosterLockTaskCandidates { @($script:ProbeCandidates) }
  function Test-BoosterLockTask([string]$TaskName) { [bool]$script:ProbeIdentities[$TaskName] }

  $orphan = "$($script:LockTaskPrefix)-aabbccdd1122"
  $script:ProbeCandidates = @($orphan)
  $script:ProbeStates = @{ $orphan = 'present' }
  $script:ProbeIdentities = @{ $orphan = $true }
  Assert-True ((Get-BoosterLockTaskState) -eq $true -and (Test-LockTaskExists)) `
    '换过安装目录后遗留的锁定任务必须被认出来，否则界面永远显示未锁定'

  $script:ProbeCandidates = @()
  $script:ProbeStates = @{}
  Assert-True ((Get-BoosterLockTaskState) -eq $false) '一个任务都查不到时必须明确返回「不存在」'

  $script:ProbeStates = @{ $script:LockTask = 'unknown' }
  Assert-True ($null -eq (Get-BoosterLockTaskState)) `
    '任务计划服务查询失败必须返回「无法确认」，不得退化成「不存在」'
  Assert-True ((Get-ItemState @{Kind='sched'}).Current -like '*无法确认*' -and
    $null -eq (Get-ItemState @{Kind='sched'}).Optimized) `
    '「无法确认」必须原样传到界面，不能被说成「未锁定」'

  # 名字不符合本工具命名的任务，即使身份校验会通过也不该被枚举进来
  $script:ProbeCandidates = @('SomeOtherVendor-PowerLock')
  $script:ProbeStates = @{ 'SomeOtherVendor-PowerLock' = 'present' }
  $script:ProbeIdentities = @{ 'SomeOtherVendor-PowerLock' = $true }
  Assert-True ((Get-BoosterLockTaskState) -eq $false) '不属于本工具命名空间的任务不得被当成本工具的锁定任务'
} finally {
  Set-Item -LiteralPath Function:\Get-TaskQueryState -Value $originalProbeState
  Set-Item -LiteralPath Function:\Get-BoosterLockTaskCandidates -Value $originalProbeCandidates
  Set-Item -LiteralPath Function:\Test-BoosterLockTask -Value $originalProbeIdentity
}

# 真机上跑一次真实 COM 探测：一个必定不存在的任务名必须得到明确的 'absent'，
# 而不是 'unknown' —— 否则三态在真实环境里退化成两态，上面的 fixture 全是空转。
$realProbe = Get-TaskQueryState ('DeltaForceBooster-NoSuchTask-' + [guid]::NewGuid().ToString('N'))
Assert-True ($realProbe -eq 'absent') `
  "真实 COM 探测把「任务不存在」报成了 $realProbe —— 三态在真机上退化了"
$realCandidatesOk = $true
try { [void](Get-BoosterLockTaskCandidates) } catch { $realCandidatesOk = $false }
Assert-True $realCandidatesOk '真实 COM 枚举锁定任务候选时抛异常了'

# ---------- 7. 自动调优回滚不得把退出码 6 当成回滚失败 ----------
# 这个消费者写在退出码只有 0/4 的年代，把「非 0 即失败」当公理。新增 6 之后它会：
# ① 对用户说「回滚失败（…）：」而冒号后一个字都没有（Failed 是空的）；
# ② 抛异常终止调用方的倒序回滚链——本份明明已经回滚完，更早的几份再也不回滚了。
$guiAstTokens = $null; $guiAstErrors = $null
$guiAst = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path (Split-Path -Parent $PSScriptRoot) 'gui\DeltaForceBooster-GUI.ps1'), [ref]$guiAstTokens, [ref]$guiAstErrors)
Assert-True ($guiAstErrors.Count -eq 0) 'GUI 解析失败'
$rollbackFn = @($guiAst.FindAll({ param($n)
  $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-TuningRollbackBackup' }, $true) |
  Select-Object -First 1)
Assert-True ($rollbackFn.Count -eq 1) '找不到 Invoke-TuningRollbackBackup'

& {
  param([string]$FunctionText)
  $script:StubReply = $null
  $script:RollbackLogs = @()
  function Write-Log([string]$Message) { $script:RollbackLogs += $Message }
  function Test-TuningBackupReference([string]$Path) { $true }
  function Invoke-ElevatedEngineAction { param([string]$Action, [string]$BackupFile) $script:StubReply }
  . ([scriptblock]::Create($FunctionText))

  # 退出码 6：系统设置已经写回去了，只是账没记上 —— 不是回滚失败
  $script:StubReply = [pscustomobject]@{
    EngineExitCode = 6; Failed = @(); RestoredOps = 3
    BookkeepingFailed = @('系统设置已按上述结果还原，但本次还原的消费凭证写入失败（磁盘只读）：下次还原会把同样的旧值再写回一遍') }
  $bookOk = $true; $bookError = ''
  try { [void](Invoke-TuningRollbackBackup 'C:\fixture\backup-x.json' '最终安全阈值触发') }
  catch { $bookOk = $false; $bookError = $_.Exception.Message }
  Assert-True ($bookOk) "记账失败让自动调优回滚链断在了这里：$bookError"
  Assert-True ((($script:RollbackLogs) -join "`n") -like '*[记账失败]*') '记账失败没有进运行日志'

  # 真失败仍然必须抛，而且要带上原因
  $script:StubReply = [pscustomobject]@{
    EngineExitCode = 4; Failed = @('内核常驻内存：需要管理员权限'); RestoredOps = 0; BookkeepingFailed = @() }
  $failThrew = $false; $failMessage = ''
  try { [void](Invoke-TuningRollbackBackup 'C:\fixture\backup-x.json' '用户停止实验') }
  catch { $failThrew = $true; $failMessage = $_.Exception.Message }
  Assert-True ($failThrew -and $failMessage -like '*需要管理员权限*') '真正的回滚失败必须抛出并带上原因'

  # 退出码看不懂、又一条失败项都没给：按失败处理，别假装成功
  $script:StubReply = [pscustomobject]@{ EngineExitCode = 9; Failed = @(); RestoredOps = 0; BookkeepingFailed = @() }
  $opaqueThrew = $false
  try { [void](Invoke-TuningRollbackBackup 'C:\fixture\backup-x.json' '未知') } catch { $opaqueThrew = $true }
  Assert-True $opaqueThrew '退出码非 0 却没有任何失败项时不得当成回滚成功'
} $rollbackFn[0].Extent.Text

Write-Output "restore-accounting-tests: PASS ($script:Assertions assertions)"
