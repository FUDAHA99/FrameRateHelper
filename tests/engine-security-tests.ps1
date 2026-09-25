$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\delta-booster.ps1'
. $engine

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("dfb-engine-test-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
  # 把所有写入导向测试临时目录；ACL API 仍真实执行，但不会触碰产品或系统目录。
  $script:ProgramDataRoot = Join-Path $temp 'programdata'
  $script:BackupDir = Join-Path $script:ProgramDataRoot 'backup'
  $script:IpcDir = Join-Path $script:ProgramDataRoot 'ipc'
  $script:BackupKeyFile = Join-Path $script:ProgramDataRoot 'backup.key'
  $legacyRoot = Join-Path $temp '.DeltaForceBooster.migrated-0123456789abcdef0123456789abcdef'
  $script:LegacyBackupDir = Join-Path $legacyRoot 'backup'
  $script:LegacyRootsFile = Join-Path $script:ProgramDataRoot 'legacy-roots.json'
  function Test-Admin { $true }
  $precreated = Join-Path $temp 'precreated-by-user'
  [void][IO.Directory]::CreateDirectory($precreated)
  $unsafeDirRejected = $false
  try { New-ProtectedDirectory $precreated $false } catch { $unsafeDirRejected = ($_.Exception.Message -like '*权限不安全*') }
  Assert-True $unsafeDirRejected '预先由普通用户创建的 ProgramData 目录必须关闭失败，不得接管后继续'
  $readAce = [pscustomobject]@{ FileSystemRights=[Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize' }
  $writeAce = [pscustomobject]@{ FileSystemRights=[Security.AccessControl.FileSystemRights]::FullControl }
  Assert-True (-not (Test-AclRuleAllowsWrite $readAce)) '只读 ACE 不得被误判为可写'
  Assert-True (Test-AclRuleAllowsWrite $writeAce) 'FullControl ACE 必须被判定为可写'
  # 真函数留一份：下面马上把它桁成「只建目录」，Lane C 的 JA-NPD 行还要用真函数验父路径联接检查。
  $realNewProtectedDirectory = ${function:New-ProtectedDirectory}
  function New-ProtectedDirectory([string]$Path, [bool]$UsersRead) {
    if (-not (Test-Path -LiteralPath $Path)) { [void][IO.Directory]::CreateDirectory($Path) }
  }
  function Set-ProtectedFileAcl([string]$Path) {}
  function Test-ProtectedFileAcl([string]$Path) { $true }

  $currentSid = 'S-1-5-21-1000000000-1000000001-1000000002-1001'
  $script:TargetUserSid = $currentSid
  $script:TargetLocalAppData = $temp
  $script:UseExplicitUserHive = $true
  $regBase, $regSub = Split-RegPath 'HKCU:\Software\DeltaForceBooster-Test'
  Assert-True ($regBase.Name -eq 'HKEY_USERS' -and $regSub -eq "$currentSid\Software\DeltaForceBooster-Test") 'HKCU 必须映射到显式目标用户 HKEY_USERS\SID'
  $badContext = $false
  try { Set-TargetUserContext $currentSid $null } catch { $badContext = $true }
  Assert-True $badContext 'UserSid/UserLocalAppData 必须成对传入'
  Assert-True ($env:PSModulePath -notmatch '(?i)\\Users\\[^\\]+\\Documents\\WindowsPowerShell\\Modules') '提权引擎必须从 PSModulePath 移除用户可写模块目录'

  Initialize-ProtectedStore
  $doc = New-BackupDocument (Get-Date)
  $doc.State = 'complete'
  $path = Join-Path $script:BackupDir ("backup-$($doc.BackupId).json")
  Write-BackupDocumentAtomic $path $doc
  $read = Read-ValidatedBackup $path
  Assert-True ($read.Document.BackupId -eq $doc.BackupId -and $read.Document.SchemaVersion -eq 3 -and
    $read.Document.ApplyId -eq $doc.ApplyId -and $read.Document.AppVersion -eq $script:AppVersion) `
    'schema v3 签名备份应可读并记录与 GUI 一致的 AppVersion/ApplyId'

  # v2 没有项目归属，继续使用整份 .restored 归档，保证旧版显式备份回滚幂等。
  $idempotentDoc = [pscustomobject][ordered]@{
    SchemaVersion=2;BackupId=[guid]::NewGuid().ToString('D');CreatedUtc=[DateTime]::UtcNow.ToString('o')
    UserSid=$script:TargetUserSid;UserLocalAppData=$script:TargetLocalAppData;State='complete';Ops=@();Integrity=$null
  }
  $idempotentPath = Join-Path $script:BackupDir ("backup-$($idempotentDoc.BackupId).json")
  Write-BackupDocumentAtomic $idempotentPath $idempotentDoc
  $firstRestore = Invoke-Restore $idempotentPath
  $secondRestore = Invoke-Restore $idempotentPath
  Assert-True ((-not (Test-Path -LiteralPath $idempotentPath)) -and
    (Test-Path -LiteralPath ($idempotentPath + '.restored')) -and $firstRestore.Failed.Count -eq 0) 'v2 显式备份还原成功后必须写入 consumed 标记'
  Assert-True ($secondRestore.RestoredOps -eq 0 -and $secondRestore.Failed.Count -eq 0 -and
    "$($secondRestore.Notes)" -like '*此前已完成还原*') '显式备份在 GUI 落盘前崩溃后重试必须幂等成功'

  $entra = New-BackupDocument (Get-Date)
  $entra.UserSid = 'S-1-12-1-1-2-3-4'; $entra.State = 'complete'
  $entraPath = Join-Path $script:BackupDir ("backup-$($entra.BackupId).json")
  Write-BackupDocumentAtomic $entraPath $entra
  Assert-True ((Read-ValidatedBackup $entraPath).Document.UserSid -eq $entra.UserSid) 'Entra/Azure AD 用户 SID 必须被备份 schema 接受'

  $tampered = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  $tampered.State = 'pending'
  [IO.File]::WriteAllText($path, ($tampered | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
  $rejected = $false
  try { [void](Read-ValidatedBackup $path) } catch { $rejected = ($_.Exception.Message -like '*完整性校验失败*') }
  Assert-True $rejected '篡改后的 HMAC 备份必须拒绝'

  # ---- op 级 vs 文档级：这三条是分界线本身 ----
  # op 级判据（目标白名单、值域、字段集）只作废那一条 op —— 被拒绝的 op 仍然一条都
  # 不会被执行，变的只是它不再株连同一份备份里的其他原值。
  # 文档级判据（未知字段、schema、上限、映射、HMAC）继续整份 throw，一个字都没放宽。
  $badLegacy = [pscustomobject]@{ Time = (Get-Date).ToString('s'); Ops = @(
    [pscustomobject]@{ Kind = 'file'; Path = (Join-Path $temp 'outside.txt'); OrigB64 = [Convert]::ToBase64String([byte[]](1,2,3)) },
    [pscustomobject]@{ Kind='reg'; Path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name='HwSchMode'
      Existed=$true; OldValue=2; OldKind='DWord' }
  ) }
  $badLegacyFaults = @(Assert-BackupDocument $badLegacy $false)
  Assert-True ($badLegacyFaults.Count -eq 1 -and "$($badLegacyFaults[0].Kind)" -eq 'file' -and
    [int]$badLegacyFaults[0].Index -eq 0 -and $badLegacyFaults[0].Reason -match '停用|白名单') `
    '旧备份的用户文件操作必须被拒绝（现在是 op 级拒绝，同一份里的其他原值不再陪葬）'

  $badRegValue = [pscustomobject]@{ Time = (Get-Date).ToString('s'); Ops = @([pscustomobject]@{
    Kind='reg'; Path='HKLM:\SYSTEM\CurrentControlSet\Services\SysMain'; Name='Start'
    Existed=$true; OldValue=99; OldKind='DWord'
  }) }
  $badRegFaults = @(Assert-BackupDocument $badRegValue $false)
  Assert-True ($badRegFaults.Count -eq 1 -and $badRegFaults[0].Reason -like '*启动类型*') `
    '未签名旧备份的旧值也必须经过目标特定值域校验'

  # 文档级：一个字都不许放宽
  $unknown = [pscustomobject]@{ Time = (Get-Date).ToString('s'); Ops = @(); Extra = 'x' }
  $rejected = $false
  try { [void](Assert-BackupDocument $unknown $false) } catch { $rejected = ($_.Exception.Message -like '*未知字段*') }
  Assert-True $rejected '未知 schema 字段必须整份拒绝'

  $tooMany = [pscustomobject]@{ Time = (Get-Date).ToString('s'); Ops = @(1..257 | ForEach-Object {
    [pscustomobject]@{ Kind='reg'; Path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name='HwSchMode'
      Existed=$true; OldValue=2; OldKind='DWord' } }) }
  $rejected = $false
  try { [void](Assert-BackupDocument $tooMany $false) } catch { $rejected = ($_.Exception.Message -like '*256*') }
  Assert-True $rejected '操作数量上限必须整份拒绝，不得被 op 级收集绕过'

  # HMAC 永远最后做、对全文复验：有 fault 收集也绝不能成为绕过完整性校验的旁路
  $faultyDoc = New-BackupDocument (Get-Date)
  $faultyDoc.State = 'complete'
  $faultyOpId = [guid]::NewGuid().ToString('D')
  $faultyDoc.Items = @([pscustomobject][ordered]@{
    ItemId='fso-off';RestoreGroupId='fso-off';DisplayName='全屏优化';DefinitionHash=('a'*64)
    RebootRequired=$false;OpIds=@($faultyOpId) })
  $faultyDoc.Ops = @([pscustomobject][ordered]@{
    Id=$faultyOpId;Status='applied';ApplyId=$faultyDoc.ApplyId;ItemId='fso-off';RestoreGroupId='fso-off'
    OpIndex=0;Kind='file';Path=(Join-Path $temp 'outside.txt');OrigB64=[Convert]::ToBase64String([byte[]](1,2,3)) })
  $faultyPath = Join-Path $script:BackupDir ("backup-$($faultyDoc.BackupId).json")
  Write-BackupDocumentAtomic $faultyPath $faultyDoc
  $faultyRead = Read-ValidatedBackup $faultyPath
  Assert-True (@($faultyRead.OpFaults).Count -eq 1 -and $faultyRead.OpFaults[0].Reason -match '停用|白名单') `
    '签名文档里的 op 级 fault 必须随读取结果一起回传'
  $faultyTampered = Get-Content -LiteralPath $faultyPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $faultyTampered.State = 'pending'
  [IO.File]::WriteAllText($faultyPath, ($faultyTampered | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
  $rejected = $false
  try { [void](Read-ValidatedBackup $faultyPath) } catch { $rejected = ($_.Exception.Message -like '*完整性校验失败*') }
  Assert-True $rejected '带 op fault 的文档被篡改后仍必须整份拒绝，fault 收集不得成为 HMAC 旁路'
  Remove-Item -LiteralPath $faultyPath -Force

  [void][IO.Directory]::CreateDirectory($script:LegacyBackupDir)
  [IO.File]::WriteAllText($script:LegacyRootsFile, (([ordered]@{ SchemaVersion=1; Roots=@($legacyRoot) }) | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  $legacyPath = Join-Path $script:LegacyBackupDir 'backup-20260810-000000.json'
  $safeLegacy = [pscustomobject]@{ Time = '2026-08-10T00:00:00'; Ops = @([pscustomobject]@{
    Kind='reg'; Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Name='SystemResponsiveness'; Existed=$true; OldValue=20; OldKind='DWord'
  }) }
  [IO.File]::WriteAllText($legacyPath, ($safeLegacy | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  $migrated = Read-ValidatedBackup $legacyPath
  Assert-True ($migrated.Document.SchemaVersion -eq 2 -and $migrated.Document.Ops[0].Status -eq 'applied') '安全旧备份应迁移为签名 schema v2'
  Assert-True ((Test-Path -LiteralPath $migrated.Path) -and (Test-Path -LiteralPath $legacyPath)) '旧备份迁移应保留受保护副本，提权进程不得写用户可写旧源'
  Assert-True ((Read-ValidatedBackup $migrated.Path).Document.Ops[0].Kind -eq 'reg') '迁移后带操作记录的 HMAC 必须可复验'
  $sameMigration = Read-ValidatedBackup $legacyPath
  Assert-True ($sameMigration.Path -eq $migrated.Path) '同一旧备份重试必须复用确定性受保护副本'
  Rename-Item -LiteralPath $migrated.Path -NewName ((Split-Path -Leaf $migrated.Path) + '.restored')
  Assert-True ((Read-ValidatedBackup $legacyPath).Consumed) '已还原的旧备份必须由受保护标记识别，不得再次消费'

  # 混合旧备份：一条已停用的 file op + 一条合法 reg op。
  # 旧写法整份拒绝，那次执行的全部原值一起没了；现在只剔掉 file 那条，其余照常迁移。
  # 签名副本里**只能有可信数据** —— 这个文件是工具自己盖章的，把校验没过的 op 写进去
  # 等于替它背书。
  $mixedLegacyPath = Join-Path $script:LegacyBackupDir 'backup-20260811-000000.json'
  $mixedLegacy = [pscustomobject]@{ Time = '2026-08-11T00:00:00'; Ops = @(
    [pscustomobject]@{ Kind='file'; Path=(Join-Path $temp 'nvidia-app.cfg'); OrigB64=[Convert]::ToBase64String([byte[]](9,9)) },
    [pscustomobject]@{ Kind='reg'; Path='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
      Name='HwSchMode'; Existed=$true; OldValue=1; OldKind='DWord' },
    [pscustomobject]@{ Kind='hib'; OldEnabled=$true }
  ) }
  [IO.File]::WriteAllText($mixedLegacyPath, ($mixedLegacy | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  $mixedMigrated = Read-ValidatedBackup $mixedLegacyPath
  $mixedKinds = @(@($mixedMigrated.Document.Ops) | ForEach-Object { "$($_.Kind)" })
  Assert-True (($mixedKinds -join ',') -eq 'reg,hib') `
    '一条已停用的 file op 仍然作废了同一份旧备份里的其他原值'
  Assert-True (@($mixedMigrated.LegacyDroppedOps).Count -eq 1 -and
    "$($mixedMigrated.LegacyDroppedOps[0].Kind)" -eq 'file') '被剔除的 op 必须随迁移结果上报，不能静默丢掉'
  Assert-True ((Read-ValidatedBackup $mixedMigrated.Path).Document.Ops.Count -eq 2) '剔除 fault op 后的签名副本必须可复验'

  $older = [pscustomobject]@{ Path='backup-ffffffff.json'; Document=[pscustomobject]@{ CreatedUtc='2026-08-01T00:00:00Z' } }
  $newer = [pscustomobject]@{ Path='backup-00000000.json'; Document=[pscustomobject]@{ CreatedUtc='2026-08-02T00:00:00Z' } }
  $sorted = @(Sort-BackupRecordsNewestFirst @($older,$newer))
  Assert-True ($sorted[0].Path -eq $newer.Path -and $sorted[1].Path -eq $older.Path) 'GUID 文件名不得决定备份合并时间顺序'

  function Get-CpuCoreTopology {
    @([pscustomobject]@{ Class = 1; Mask = [uint64]2 }, [pscustomobject]@{ Class = 1; Mask = [uint64]4 })
  }
  $hw = [pscustomobject]@{
    Threads = 8; MainGpuPnp = 'PCI\VEN_10DE&DEV_MAIN\GPU0'
    Gpus = @([pscustomobject]@{ Vendor='AMD'; Pnp='PCI\VEN_1002&DEV_IGPU\GPU0' },
             [pscustomobject]@{ Vendor='NVIDIA'; Pnp='PCI\VEN_10DE&DEV_MAIN\GPU0' })
  }
  $irq = @(Get-GpuIrqOps $hw)
  Assert-True ($irq.Count -eq 2 -and $irq[0].Path -like '*VEN_10DE&DEV_MAIN*') 'IRQ 必须精确使用 MainGpuPnp'
  $multi = [pscustomobject]@{
    Threads=8; MainGpuPnp='PCI\VEN_10DE&DEV_A\GPU0'; MainGpuPciMatched=$false
    Gpus=@([pscustomobject]@{Vendor='NVIDIA';Pnp='PCI\VEN_10DE&DEV_A\GPU0'},[pscustomobject]@{Vendor='NVIDIA';Pnp='PCI\VEN_10DE&DEV_B\GPU0'})
  }
  Assert-True ($null -eq (Get-GpuIrqOps $multi)) '多 NVIDIA 未按 PCI BDF 匹配时必须禁用 IRQ 写入'
  [void](Get-PciBusLocation 'PCI\NONEXISTENT')
  Assert-True ([bool]('DfbPciLocation' -as [type])) 'PCI BDF 映射 helper 应可加载'

  $portable = Resolve-FormFactor @(9) $true $true
  $desktopWithUps = Resolve-FormFactor @(3) $true $false
  $batteryOnly = Resolve-FormFactor @() $true $false
  Assert-True ($portable.FormFactor -eq 'laptop' -and $portable.Confidence -eq 'high') `
    'SMBIOS 笔记本机箱类型应优先于启发式判断'
  Assert-True ($desktopWithUps.FormFactor -eq 'desktop' -and $desktopWithUps.Confidence -eq 'high' -and
    $desktopWithUps.IsUpsAmbiguous) '带 UPS 电池的台式机不得误判为笔记本'
  Assert-True ($batteryOnly.FormFactor -eq 'unknown') '只有电池、没有内屏证据时不得猜测机型'

  $mainPreset = Get-BuiltinPresets | Where-Object Id -eq 'main'
  Assert-True ($mainPreset.Items -notcontains 'nvidia-profile') 'NPI 不得进入主推方案'
  Assert-True ($mainPreset.Items -notcontains 'nv-autoopt-off') '用户可写 NVIDIA 配置文件不得进入提权主推方案'
  Assert-True ($mainPreset.Items -notcontains 'gpu-name-spoof') '显卡型号伪装已移除，不得回到主推方案'
  # 伪装功能已移除，下面的 spoof 函数断言一并删除。
  # 这一条留着：它守的是「PCI 厂商 ID 必须优先于显示名」这条独立规则 ——
  # Win32_VideoController.Name 本来就可能被 OEM 或其他调优工具改写，
  # 按名字判厂商会让双显卡机器的主卡识别退化，进而影响 gpu-pref / gpu-irq-affinity。
  Assert-True ((Get-GpuVendor 'PCI\VEN_1002&DEV_744C\GPU0' 'NVIDIA GeForce RTX 2060') -eq 'AMD') 'PCI 厂商 ID 必须优先于显示名判定真实厂商'

  $originalGetRegValue = ${function:Get-RegValue}
  try {
    $script:TestGpuClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
    function Get-RegValue([string]$Path, [string]$Name) {
      if ($Name -eq 'ClassGUID') { return $script:TestGpuClassGuid }
      if ($Name -eq 'Driver') { return '{4d36e968-e325-11ce-bfc1-08002be10318}\0007' }
      if ($Name -eq 'DriverDesc') { return 'AMD Radeon RX 7900 XTX' }
      $null
    }
    $amdHw = [pscustomobject]@{
      MainGpuVendor='AMD'; MainGpuPnp='PCI\VEN_1002&DEV_744C\GPU0'; MainGpuPciMatched=$false
      Gpus=@([pscustomobject]@{Vendor='AMD';Pnp='PCI\VEN_1002&DEV_744C\GPU0'})
    }
    Assert-True ((Get-GpuDriverDescription $amdHw.MainGpuPnp 'AMD') -eq 'AMD Radeon RX 7900 XTX') 'AMD 真实型号必须从对应显示驱动 Class 键恢复'
  } finally {
    Set-Item -LiteralPath Function:\Get-RegValue -Value $originalGetRegValue
  }
  # 【绝不能删】伪装功能虽已移除，DeviceDesc 仍必须留在备份白名单里。
  # 备份校验走 Read-ValidatedBackup -> Assert-BackupDocument -> Assert-BackupOperation，
  # 任何一条 op 不过白名单就整份 throw，而 Get-ValidatedRestoreRecords 是
  # ForEach-Object + ErrorActionPreference='Stop' —— 一条炸等于整次还原炸。
  # 删掉它，从上游迁过来、做过伪装的用户连还原电源计划都会失败。
  Assert-True (Test-AllowedBackupRegTarget ([pscustomobject]@{Path='HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\VEN_1002&DEV_744C\GPU0';Name='DeviceDesc'})) '旧备份里的 DeviceDesc 记录必须仍能通过备份校验，否则老用户的任何还原都会失败'
  $legacyPriorityPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeltaForceClient.exe\PerfOptions'
  Assert-True (Test-AllowedBackupRegTarget ([pscustomobject]@{Path=$legacyPriorityPath;Name='CpuPriorityClass'})) `
    '早期版本写入的 DeltaForceClient.exe CPU 优先级必须保留精确还原兼容'
  Assert-True (Test-AllowedBackupRegTarget ([pscustomobject]@{Path=$legacyPriorityPath;Name='IoPriority'})) `
    '早期版本写入的 DeltaForceClient.exe IO 优先级必须保留精确还原兼容'
  Assert-True (-not (Test-AllowedBackupRegTarget ([pscustomobject]@{Path=$legacyPriorityPath;Name='Debugger'})) -and
    -not (Test-AllowedBackupRegTarget ([pscustomobject]@{
      Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeltaForceClientHelper.exe\PerfOptions'
      Name='CpuPriorityClass'
    }))) '历史 IFEO 兼容不得扩大到其他值名或相似进程名'

  $thinkPad = Resolve-ComputerBrand 'LENOVO' 'ThinkPad X1 Carbon' 'LENOVO'
  $hp = Resolve-ComputerBrand 'HP' 'OMEN 16' 'HP'
  $asusBoard = Resolve-ComputerBrand 'To Be Filled By O.E.M.' 'System Product Name' 'ASUSTeK COMPUTER INC.'
  Assert-True ($thinkPad.Key -eq 'thinkpad' -and (Get-BiosEntryInstruction $thinkPad.Key $true) -like '*F1*') 'ThinkPad BIOS 教程必须提示 F1'
  Assert-True ($hp.Key -eq 'hp' -and (Get-BiosEntryInstruction $hp.Key $true) -like '*Esc*F10*') '惠普 BIOS 教程必须提示 Esc 后 F10'
  Assert-True ($asusBoard.Key -eq 'asus' -and (Get-BiosEntryInstruction $asusBoard.Key $false) -like '*Del*') '华硕台式机/主板 BIOS 教程必须提示 Del'
  $brandTutorial = Get-XmpBiosTutorial ([pscustomobject]@{ComputerBrand='惠普';ComputerModel='OMEN 16';ComputerBrandKey='hp';IsLaptop=$true})
  Assert-True ($brandTutorial -like '*检测到电脑：惠普 · OMEN 16*' -and $brandTutorial -like '*Esc*F10*') 'XMP/EXPO 教程必须显示检测品牌和对应 BIOS 进入步骤'
  $msiTutorial = Get-XmpBiosTutorial ([pscustomobject]@{
    ComputerBrand='微星';ComputerModel='MS-7B84';ComputerBrandKey='msi';IsLaptop=$false
    CpuVendor='AMD';CPU='AMD Ryzen 5';MemoryType='DDR4'
  })
  Assert-True ($msiTutorial -like '*OC → A-XMP*' -and $msiTutorial -like '*不叫 EXPO 或 DOCP*') `
    'MSI AMD DDR4 教程必须指向 A-XMP，不能继续让用户寻找 EXPO/DOCP'
  $rogTutorial = Get-XmpBiosTutorial ([pscustomobject]@{
    ComputerBrand='华硕 ROG';ComputerModel='ROG Strix G15 / 魔霸';ComputerBrandKey='asus';IsLaptop=$true
    CpuVendor='AMD';CPU='AMD Ryzen 9';MemoryType='DDR4'
  })
  Assert-True ($rogTutorial -like '*包括魔霸系列*' -and $rogTutorial -like '*若没有 Ai Tweaker*' -and
    $rogTutorial -like '*不需要继续找*') 'ROG 魔霸笔记本教程必须明确许多机型没有可用内存档位菜单'

  # ConfiguredClockSpeed 已达到 SMBIOS Speed 时没有降频证据；旧逻辑仅因为 2667 <=
  # DDR4 JEDEC 上限就弹“XMP/EXPO 未开启”，会让没有性能档位的整机用户白找 BIOS 菜单。
  $script:MockMemoryRatedMHz = 2667
  function Get-CimInstance {
    [CmdletBinding()] param([Parameter(Position=0)][string]$ClassName)
    if ($ClassName -eq 'Win32_PhysicalMemory') {
      return [pscustomobject]@{ ConfiguredClockSpeed=2667;Speed=$script:MockMemoryRatedMHz;SMBIOSMemoryType=26 }
    }
    throw "unexpected CIM class: $ClassName"
  }
  try {
    $ratedState = Get-MemoryXmpStatus
    Assert-True ($ratedState.Ok -eq $true -and $ratedState.Text -like '*已达到 SMBIOS 标称 2667 MHz*' -and
      $ratedState.Text -like '*找不到相关菜单属于正常情况*') '达到标称频率的 DDR4-2667 不得误报性能档位未开启'
    $script:MockMemoryRatedMHz = 3200
    $underclockedState = Get-MemoryXmpStatus
    Assert-True ($underclockedState.Ok -eq $false -and $underclockedState.Text -like '*低于 SMBIOS 标称 3200 MHz*' -and
      $underclockedState.Text -like '*A-XMP*') '确实低于标称频率时必须保留多种厂商菜单名与限频原因'
  } finally {
    Remove-Item -LiteralPath Function:\Get-CimInstance -Force
    Remove-Variable MockMemoryRatedMHz -Scope Script -ErrorAction SilentlyContinue
  }
  Assert-True ((Get-AmdGpuPerformanceClass 'AMD Radeon RX 7900 XTX') -eq 'high') 'RX 7900 XTX 应归入高性能 A 卡'
  Assert-True ((Get-AmdGpuPerformanceClass 'AMD Radeon RX 7600') -eq 'mid') 'RX 7600 应归入主流 A 卡'
  Assert-True ((Get-AmdGpuPerformanceClass 'AMD Radeon RX 6500 XT') -eq 'entry') 'RX 6500 XT 应归入入门 A 卡'
  Assert-True ((Get-AmdGpuPerformanceClass 'AMD Radeon 780M Graphics') -eq 'integrated-or-legacy') 'Radeon 780M 应归入核显/较早型号'
  $amdHighGuide = Get-GpuGuideText 'AMD' 'AMD Radeon RX 7900 XTX' $false ([pscustomobject]@{
    DisplayWidth=1920;DisplayHeight=1080;DisplayRefreshHz=240;RamGB=32
  })
  Assert-True ($amdHighGuide -like '*【方案一：原推荐方案】*' -and
    $amdHighGuide -like '*Radeon Anti-Lag = 开*' -and
    $amdHighGuide -like '*纹理过滤质量 = 性能*') 'AMD 原推荐方案必须原样保留'
  Assert-True ($amdHighGuide -like '*【方案二：按本机配置推荐】*' -and
    $amdHighGuide -like '*1920×1080 @ 240Hz*' -and
    $amdHighGuide -like '*Anti-Lag = 开；Chill / Boost = 关*' -and
    $amdHighGuide -like '*VSR 2560×1440*' -and
    $amdHighGuide -like '*237 FPS*') '高性能 A 卡的 1080P/高刷配置推荐不正确'
  $amdMidGuide = Get-AmdConfiguredGuideText ([pscustomobject]@{
    DisplayWidth=2560;DisplayHeight=1440;DisplayRefreshHz=165;RamGB=16
  }) 'AMD Radeon RX 7600' $false
  Assert-True ($amdMidGuide -like '*主流 A 卡*' -and
    $amdMidGuide -like '*纹理过滤质量 = 标准*' -and
    $amdMidGuide -like '*RSR / VSR = 关*') '主流 A 卡配置推荐不正确'
  $amdLaptopGuide = Get-AmdConfiguredGuideText ([pscustomobject]@{
    DisplayWidth=1920;DisplayHeight=1080;DisplayRefreshHz=60;RamGB=8
  }) 'AMD Radeon 780M Graphics' $true
  Assert-True ($amdLaptopGuide -like '*入门、核显或较早型号*' -and
    $amdLaptopGuide -like '*纹理过滤质量 = 性能*' -and
    $amdLaptopGuide -like '*笔记本补充*' -and
    $amdLaptopGuide -like '*少于 16 GB*') '核显低内存笔记本配置推荐不正确'
  $noChange = [pscustomobject]@{ Ok=$true; Skipped=$false; Msg='已写入' }
  [void](Set-ApplyResultChangeState $noChange $false)
  Assert-True (-not $noChange.Changed -and $noChange.Skipped -and $noChange.Msg -like '无需修改*') '0 个 applied WAL 的成功项必须标记 Changed=false/Skipped=true'
  $didChange = [pscustomobject]@{ Ok=$true; Skipped=$false; Msg='已写入' }
  [void](Set-ApplyResultChangeState $didChange $true)
  Assert-True ($didChange.Changed -and -not $didChange.Skipped) '真实变更项必须标记 Changed=true'
  Assert-True ($null -ne (Get-Command Get-ToolSchemeGuid -ErrorAction SilentlyContinue)) `
    '诊断脚本依赖的工具专属电源方案只读入口缺失'

  $originalGetTaskXml = ${function:Get-TaskXml}
  try {
    $script:TaskCommandForTest = (Join-Path $temp 'powercfg.exe')
    function Get-TaskXml([string]$TaskName) {
      [xml]("<Task><Actions><Exec><Command>$script:TaskCommandForTest</Command><Arguments>/setactive 11111111-1111-1111-1111-111111111111</Arguments></Exec></Actions></Task>")
    }
    Assert-True (-not (Test-BoosterLockTask $script:LockTask)) '用户路径中的同名 powercfg.exe 不得被认为本工具计划任务'
    $script:TaskCommandForTest = $script:PowerCfgExe
    Assert-True (Test-BoosterLockTask $script:LockTask) '仅 System32 powercfg.exe + 严格 GUID 参数的任务可被认领'

    $cleanupTaskName = "$script:PowerCleanupTaskPrefix-$('a' * 32)"
    $cleanupScheme = '11111111-1111-4111-8111-111111111111'
    $cleanupSetting = '4d2b0152-7d5c-498b-88e2-34345392a2c5'
    $cleanupRegPath = "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$cleanupScheme\$script:SubProc\$cleanupSetting"
    $script:CleanupTaskCommandForTest = $script:RegExe
    $script:CleanupTaskArgsForTest = "delete `"$cleanupRegPath`" /v ACSettingIndex /f"
    $script:CleanupTaskUserForTest = 'S-1-5-18'
    function Get-TaskXml([string]$TaskName) {
      [xml]("<Task><Principals><Principal><UserId>$script:CleanupTaskUserForTest</UserId></Principal></Principals>" +
        "<Actions><Exec><Command>$script:CleanupTaskCommandForTest</Command><Arguments>$script:CleanupTaskArgsForTest</Arguments></Exec></Actions></Task>")
    }
    Assert-True (Test-PowerOverrideCleanupTask $cleanupTaskName $cleanupRegPath) `
      'SYSTEM 电源还原任务必须只认 System32 reg.exe、SYSTEM 主体和精确 ACSettingIndex 删除参数'
    $script:CleanupTaskCommandForTest = Join-Path $temp 'reg.exe'
    Assert-True (-not (Test-PowerOverrideCleanupTask $cleanupTaskName $cleanupRegPath)) '用户路径 reg.exe 不得被 SYSTEM 清理任务认领'
    $script:CleanupTaskCommandForTest = $script:RegExe
    $unknownRegPath = "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$cleanupScheme\$script:SubProc\aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    Assert-True (-not (Test-PowerOverrideCleanupTask $cleanupTaskName $unknownRegPath)) 'SYSTEM 清理任务不得接受产品白名单外的电源项'
  } finally { Set-Item -Path Function:\Get-TaskXml -Value $originalGetTaskXml }
  $wrongExe = Join-Path $temp 'not-the-game.exe'
  [IO.File]::WriteAllText($wrongExe,'fixture')
  $gamePathRejected = $false
  try { [void](Resolve-ValidatedGamePath $wrongExe) } catch { $gamePathRejected = ($_.Exception.Message -like '*三角洲行动主程序*') }
  Assert-True $gamePathRejected '任意 exe 必须在生成 AppCompat/GPU/IFEO 操作前被拒绝'
  $validExe = Join-Path $temp 'DeltaForceClient-Win64-Shipping.exe'
  [IO.File]::WriteAllText($validExe,'fixture')
  Assert-True ((Resolve-ValidatedGamePath $validExe) -eq [IO.Path]::GetFullPath($validExe)) '允许的游戏主程序应返回规范绝对路径'

  # 第三方平台偶尔会把 REG_SZ 写成带尾随 NUL；WinPS 5.1 原先会在 Find-GamePath 的
  # Test-Path 直接抛 Illegal characters in path，GUI 因而停在“检测失败 / 定位中”。
  $searchRoot = Join-Path $temp 'game-search-fixture'
  $searchExe = Join-Path $searchRoot 'DeltaForce\Binaries\Win64\DeltaForceClient-Win64-Shipping.exe'
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $searchExe))
  [IO.File]::WriteAllText($searchExe,'fixture')
  $uninstaller = Join-Path $searchRoot 'uninstall.exe'
  [IO.File]::WriteAllText($uninstaller,'fixture')
  Assert-True ((Resolve-RegistryFileParent ('"' + $uninstaller + '" /S') $false) -eq $searchRoot) '带引号和参数的 UninstallString 应只解析 EXE 父目录'
  Assert-True ((Resolve-RegistryFileParent ('"' + $uninstaller + '",0') $true) -eq $searchRoot) 'DisplayIcon 的引号和资源索引不得混进目录'
  Assert-True ((Resolve-RegistryFileParent ($uninstaller + ' /quiet') $false) -eq $searchRoot) '未加引号且路径含空格的卸载命令应解析到首个完整 EXE'
  Assert-True ($null -eq (Resolve-ExistingGameSearchRoot ([IO.Path]::GetPathRoot($searchRoot)))) '损坏候选不得把整盘根加入递归扫描'
  Assert-True ($null -eq (Resolve-ExistingGameSearchRoot ("C:\bad" + [char]0 + 'embedded'))) '含内嵌 NUL 的损坏候选应跳过'

  $originalGetRegValue = ${function:Get-RegValue}
  try {
    $script:MockGameSearchRoot = $searchRoot + [char]0
    $script:ObservedGameSearchRoots = New-Object System.Collections.Generic.List[string]
    function Get-RegValue([string]$Path, [string]$Name) {
      if ($Path -match 'Tencent\\WeGame') { return $script:MockGameSearchRoot }
      $null
    }
    function Get-Process { [CmdletBinding()]param([string[]]$Name) @() }
    function Get-ItemProperty { [CmdletBinding()]param([object[]]$Path) @() }
    function Get-PSDrive { [CmdletBinding()]param([string[]]$PSProvider) @() }
    function Get-ChildItem {
      [CmdletBinding()]param([string]$LiteralPath,[switch]$Recurse,[int]$Depth,[string]$Filter,[switch]$File)
      if ($LiteralPath) { [void]$script:ObservedGameSearchRoots.Add($LiteralPath) }
      @()
    }
    Assert-True ((Find-GamePath) -eq $searchExe) '尾随 NUL 应被清理，合法 WeGame 根仍须自动定位游戏'
    $script:MockGameSearchRoot = [IO.Path]::GetPathRoot($searchRoot)
    $script:ObservedGameSearchRoots.Clear()
    Assert-True ($null -eq (Find-GamePath)) '只有整盘根候选时应返回未定位而不是递归整盘'
    Assert-True ($script:ObservedGameSearchRoots.Count -eq 0) 'Get-ChildItem 不得收到文件系统根候选'
    $script:MockGameSearchRoot = "C:\bad" + [char]0 + 'embedded'
    Assert-True ($null -eq (Find-GamePath)) '坏平台注册表候选不得使自动定位抛异常'
  } finally {
    Set-Item -Path Function:\Get-RegValue -Value $originalGetRegValue
    foreach ($fn in 'Get-Process','Get-ItemProperty','Get-PSDrive','Get-ChildItem') {
      Remove-Item -Path ("Function:\" + $fn) -Force -ErrorAction SilentlyContinue
    }
  }

  $noGameItems = @(Get-OptItems $null)
  $nonGameItem = $noGameItems | Where-Object Id -eq 'game-mode' | Select-Object -First 1
  $gameOnlyItem = $noGameItems | Where-Object Id -eq 'fso-off' | Select-Object -First 1
  Assert-True (@($nonGameItem.Ops).Count -gt 0) '未定位游戏时，非游戏系统项仍应保留可执行操作'
  Assert-True ($gameOnlyItem.RequiresGame -and -not $gameOnlyItem.Ops) '未定位游戏时，只应让依赖路径的项目进入明确跳过分支'
  $engineText = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
  Assert-True ($engineText -notmatch '(?i)705\s*Ti') '引擎参数、注册表目标字符串及文案不得残留错误型号 705 Ti'
  Assert-True ($engineText -match "Name = 'SystemResponsiveness'; Value = 10") 'SystemResponsiveness 必须使用有效最低值 10'
  $partial = [pscustomobject]@{ BackupError=$null; Results=@([pscustomobject]@{Ok=$false;Skipped=$false;Attention=$false}) }
  $backupFail = [pscustomobject]@{ BackupError='disk'; Results=@() }
  Assert-True ((Get-ApplyExitCode $partial) -eq 2 -and (Get-ApplyExitCode $backupFail) -eq 3) 'Apply 失败必须返回约定的 2/3'
  Assert-True ((Get-RestoreExitCode ([pscustomobject]@{Failed=@('x')})) -eq 4) 'Restore 不完整必须返回 4'
  Assert-True ($engineText.Contains("`$definition.Principal.UserId = 'SYSTEM'") -and
    $engineText.Contains('$action.Path = $script:RegExe') -and
    $engineText.Contains('Test-PowerOverrideCleanupTask $taskName $registryPath') -and
    $engineText.Contains('$taskRoot.DeleteTask($taskName, 0)')) `
    'SYSTEM 电源清理必须固定 SYSTEM 主体/System32 reg.exe，并在运行前校验、运行后删除任务'

  # ---- 缓存扫描：reparse point 必须被拒绝，且必须真的停止下探 ----------------
  #
  # 旧写法把「创建 junction / 调用产品 / 断言」三件事一起包进 try-catch，
  # Assert-True 抛出的 ASSERT 被 catch 打成 SKIP，产品放行 junction 时测试照样
  # PASS 退出 0。现在拆成两段：A 纯桁单元测（不依赖任何文件系统特性，永远执行，
  # 是本条的主力覆盖）；B 真实 junction 端到端（只有「创建」一步允许被 catch）。
  #
  # 夹具的形状是被攻击驱动的：最初的方案用一个**扁平且全是目录型**的夹具，
  # 实测下两种真实破坏能完整绕过：
  #   ① 把判断加个 `-and ($dir -ieq $rootFull)`（伪装成「只查根的直接子项」的优化）
  #     —— 第二层的 junction 就会被放行，根外文件混进 Files。
  #   ② 加个 `-and $entry.PSIsContainer`（伪装成「文件链接没危险」）
  #     —— 文件型 reparse point 直接进 Files。
  # 所以夹具必须**嵌套**（junction 放在第二层）且**含文件型 reparse point**。
  # 改这个夹具前先想清楚：你是不是又把某一维度折成了常量。

  # ---- Lane A：直接跑真函数 Get-SafeFilesUnderRoot，只桁掉目录枚举与根判定 ----
  # 夹具树（路径不需要真实存在，产品在这条路径上只做字符串运算 + Get-ChildItem）：
  #   root\plain.bin        普通文件        → 应进 Files
  #   root\filelink.bin     文件型 reparse    → 应进 Rejected（堵②）
  #   root\linked\         目录型 reparse    → 应进 Rejected，且不得枚举
  #   root\sub\deep.bin    第二层普通文件  → 应进 Files（证明确实会下探普通目录）
  #   root\sub\deeplink\  第二层目录型 reparse → 应进 Rejected，且不得枚举（堵①）
  $fakeRoot  = Join-Path $temp 'scan-unit'
  $fakeSub   = Join-Path $fakeRoot 'sub'
  $fakeLink  = Join-Path $fakeRoot 'linked'
  $fakeDeep  = Join-Path $fakeSub 'deeplink'
  $fakePlain = Join-Path $fakeRoot 'plain.bin'
  $fakeFileLink = Join-Path $fakeRoot 'filelink.bin'
  $fakeDeepFile = Join-Path $fakeSub 'deep.bin'
  $dirReparse  = [IO.FileAttributes]'Directory, ReparsePoint'
  $fileReparse = [IO.FileAttributes]::ReparsePoint
  function New-ScanEntry($Path, $IsDir, $Attrs) {
    [pscustomobject]@{ FullName = $Path; PSIsContainer = $IsDir; Length = 4L; Attributes = $Attrs }
  }
  function Get-ScanKey($Path) { ([IO.Path]::GetFullPath($Path)).TrimEnd('\') }
  $script:ScanVisited = New-Object System.Collections.Generic.List[string]
  $script:ScanTree = @{}
  $script:ScanTree[(Get-ScanKey $fakeRoot)] = @(
    (New-ScanEntry $fakePlain    $false ([IO.FileAttributes]::Normal)),
    (New-ScanEntry $fakeFileLink $false $fileReparse),
    (New-ScanEntry $fakeLink     $true  $dirReparse),
    (New-ScanEntry $fakeSub      $true  ([IO.FileAttributes]::Directory))
  )
  # junction 之下的文件用字符串路径看仍然「在根之内」，前缀校验挡不住它，
  # 只有 ReparsePoint 判定 + 停止下探能挡住 —— 这正是本条要守的东西。
  $script:ScanTree[(Get-ScanKey $fakeLink)] = @(
    (New-ScanEntry (Join-Path $fakeLink 'across1.bin') $false ([IO.FileAttributes]::Normal)))
  $script:ScanTree[(Get-ScanKey $fakeSub)] = @(
    (New-ScanEntry $fakeDeepFile $false ([IO.FileAttributes]::Normal)),
    (New-ScanEntry $fakeDeep     $true  $dirReparse))
  $script:ScanTree[(Get-ScanKey $fakeDeep)] = @(
    (New-ScanEntry (Join-Path $fakeDeep 'across2.bin') $false ([IO.FileAttributes]::Normal)))

  $originalTestReparse = ${function:Test-PathHasReparsePoint}
  try {
    function Get-ChildItem {
      [CmdletBinding()]param([string]$LiteralPath, [switch]$Force, [switch]$Recurse, [string]$Filter)
      $key = Get-ScanKey $LiteralPath
      [void]$script:ScanVisited.Add($key)
      if ($script:ScanTree.ContainsKey($key)) { foreach ($e in $script:ScanTree[$key]) { $e } }
    }
    # A1：根不是 reparse point 时，每一层的 reparse 项都必须被拒绝且不得下探
    function Test-PathHasReparsePoint([string]$Path) { $false }
    $script:ScanVisited.Clear()
    $unit = Get-SafeFilesUnderRoot $fakeRoot
    $unitRejected = @(@($unit.Rejected) | ForEach-Object { (Get-ScanKey $_) } | Sort-Object)
    $unitFiles = @(@($unit.Files) | ForEach-Object { (Get-ScanKey $_.FullName) } | Sort-Object)
    $expectRejected = @((Get-ScanKey $fakeFileLink), (Get-ScanKey $fakeLink), (Get-ScanKey $fakeDeep)) | Sort-Object
    $expectFiles = @((Get-ScanKey $fakePlain), (Get-ScanKey $fakeDeepFile)) | Sort-Object
    # 消息前缀的 ASCII 标签（JA-A1 ...）供变异 harness 匹配：子进程控制台是 GBK，中文正文不可靠。
    Assert-True (($unitRejected -join '|') -ieq (($expectRejected) -join '|')) `
      ("JA-A1 [rejected set] 拒绝集不对：每一层的 reparse point（含文件型、含第二层）都必须进 Rejected。实际=" +
       ($unitRejected -join '；'))
    Assert-True (($unitFiles -join '|') -ieq (($expectFiles) -join '|')) `
      ("JA-A1 [files] Files 不对：跨越 reparse point 的文件一个都不许进，普通目录里的文件一个都不许漏。实际=" +
       ($unitFiles -join '；'))
    foreach ($mustNot in $fakeLink, $fakeDeep) {
      Assert-True (-not (@($script:ScanVisited) -contains (Get-ScanKey $mustNot))) `
        "JA-A1 [no descent] 拒绝 reparse point 之后必须真的停止下探：产品对 $mustNot 发起了目录枚举"
    }
    Assert-True (@($script:ScanVisited) -contains (Get-ScanKey $fakeSub)) `
      'JA-A1 [descent] 普通子目录必须照常下探 —— 拒绝 reparse point 不得退化成「整棵树都不进」'
    # A2：根本身是 reparse point 时，必须「立即返回」，而不只是「做过判断」
    function Test-PathHasReparsePoint([string]$Path) { $true }
    $script:ScanVisited.Clear()
    $unitRoot = Get-SafeFilesUnderRoot $fakeRoot
    Assert-True (@($unitRoot.Files).Count -eq 0 -and @($unitRoot.Rejected).Count -eq 1 -and
      ((Get-ScanKey @($unitRoot.Rejected)[0]) -ieq (Get-ScanKey $fakeRoot))) `
      'JA-A2 [root gate] 扫描根是 reparse point 时必须整根拒绝且不返回任何文件'
    Assert-True ($script:ScanVisited.Count -eq 0) `
      'JA-A2 [no enumeration] 扫描根被判定为 reparse point 后必须立即返回，一次目录枚举都不得发生'
  } finally {
    Remove-Item -Path Function:\Get-ChildItem -Force -ErrorAction SilentlyContinue
    Set-Item -Path Function:\Test-PathHasReparsePoint -Value $originalTestReparse
  }

  # ---- Lane B：真实 junction 端到端（加强，不是主力） --------------------
  $cacheRoot = Join-Path $temp 'cache'
  $outside = Join-Path $temp 'outside'
  [void][IO.Directory]::CreateDirectory($cacheRoot); [void][IO.Directory]::CreateDirectory($outside)
  [IO.File]::WriteAllText((Join-Path $outside 'keep.bin'), 'keep')
  [IO.File]::WriteAllText((Join-Path $cacheRoot 'plain.bin'), 'plain')
  $nestDir = Join-Path $cacheRoot 'nest'
  [void][IO.Directory]::CreateDirectory($nestDir)
  $linkPath = Join-Path $nestDir 'deeplink'   # 故意放在第二层
  $junctionReady = $false
  $junctionSkipReason = ''
  try {
    New-Item -ItemType Junction -Path $linkPath -Target $outside -ErrorAction Stop | Out-Null
    # 用 .NET 原生属性判定环境是否真的造出了 reparse point，不借产品函数做这个判断
    $junctionReady = ((([IO.File]::GetAttributes($linkPath)) -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    if (-not $junctionReady) { $junctionSkipReason = '目录联接创建成功但文件系统未生成 reparse point' }
  } catch {
    # 安全网：本 catch 只允许吞「创建失败」。若日后有人把断言挪进来，立刻原样抛出。
    if ("$($_.Exception.Message)" -like 'ASSERT:*') { throw }
    $junctionSkipReason = $_.Exception.Message
  }
  if ($junctionReady) {
    # 下面全部在 catch 之外：产品放行 junction 必须直接让测试红
    Assert-True (Test-PathHasReparsePoint $linkPath) 'JA-B1 [real junction] 真实 junction 必须被 reparse point 检测识别'
    Assert-True (-not (Test-PathHasReparsePoint $cacheRoot)) 'JA-B1 [plain dir] 普通目录不得被判为 reparse point：检测不得退化为恒真'
    $scan = Get-SafeFilesUnderRoot $cacheRoot
    Assert-True (@($scan.Rejected).Count -eq 1 -and
      ([IO.Path]::GetFullPath(@($scan.Rejected)[0]) -ieq [IO.Path]::GetFullPath($linkPath))) `
      'JA-B2 [nested rejected] 缓存扫描必须把第二层的 junction 列为唯一拒绝项'
    Assert-True (@($scan.Files).Count -eq 1 -and
      ([IO.Path]::GetFullPath(@($scan.Files)[0].FullName) -ieq [IO.Path]::GetFullPath((Join-Path $cacheRoot 'plain.bin')))) `
      'JA-B2 [nested files] 缓存扫描只能收集 junction 之外的本地文件，越界文件一个都不许进 Files'
    $scanLink = Get-SafeFilesUnderRoot $linkPath
    Assert-True (@($scanLink.Files).Count -eq 0 -and @($scanLink.Rejected).Count -eq 1) `
      'JA-B3 [junction root] 直接以 junction 作为扫描根时必须整根拒绝且不返回任何文件'
    Assert-True ((Get-Content -LiteralPath (Join-Path $outside 'keep.bin') -Raw) -eq 'keep') 'JA-B3 [outside untouched] 越界文件不得被修改'
    # 只删 junction 本身、不跟随到目标；这里只能用 finally 之外的收尾，出现 catch 就是回到旧 bug
    [IO.Directory]::Delete($linkPath)
  } else {
    # 注意措辞：Lane A 已经覆盖了行为，这里缺的只是真实文件系统那一层
    Write-Output "SKIP junction(环境造不出 reparse point，Lane A 已覆盖行为)：$junctionSkipReason"
  }
  # ---- Lane C：扫描根的「祖先」是真实 junction（复核 R2 junction-ancestor） --------
  # Lane A 桁掉了 Test-PathHasReparsePoint，Lane B 的扫描根要么就是 junction 本身、要么是普通
  # 目录里嵌套 junction —— 没有一个扫描根位于 junction 之下。于是把逐段检查退化成只查最终路径
  # （foreach ($part in @($rest))）全套照绿，而真实扫描 junction\普通子目录 会把联接目标里的
  # 文件放进 Files。产品里对应的形状：%LOCALAPPDATA%\NVIDIA 被做成联接，扫描 NVIDIA\DXCache。
  # 本段零桁：Lane A 的 finally 已还原真函数、删掉 Get-ChildItem 桁。
  # 夹具（联接目标都放在 $temp 之内：任何收尾即使跟随联接也逃不出 $temp）：
  #   anc\outside\l1\a.bin
  #   anc\outside\l1\l2\b.bin
  #   anc\outside\l1\l2\l3\c.bin
  #   anc\outside\q\q\...\q\deep.bin          （q 共 24 层）
  #   anc\host\jct              ->  anc\outside     （目录联接，普通用户可建）
  #   anc\dh\h\...\h\jct        ->  anc\outside     （h 共 16 层：离盘符很远的联接）
  #   anc\lad\D3DSCache\local.bin                   （7 字节；lad 充当目标用户的 LocalAppData）
  #   anc\lad\NVIDIA            ->  anc\nv-outside  （nv-outside\DXCache、GLCache 各放 1000 字节）
  #   anc\hid\jct               ->  anc\outside     （Hidden|System 的联接；lad\NVIDIA 同样加 Hidden|System）
  #   anc\hidplain\l1                               （Hidden|System 的普通目录：[hidden] 行的反例锚点）
  #   anc\swap\c                                    （先是普通目录，查过之后换成联接：JA-M1 [re-check]）
  #   （JA-BK 直接复用 l1\a.bin：经 host\jct 访问它 = 备份密钥路径上有联接；经 outside 访问 = 反例锚点）
  #   anc\cs\cache\keep.bin、cache\sub\victim.bin、outside\victim.bin、stray\stray.bin（JA-CS：清理时的 TOCTOU）
  # 深度 1/2/3 = 扫描根位于联接之下 1/2/3 层；深度 2、3 就是「联接是隔一层以上的中间祖先」。
  # 两条 deep 行是被攻击驱动的：从叶子往上只查 N 层（封顶的 walk-up），或从盘符往下只查前 N 段
  # （Select-Object -First N），都能让 1/2/3 层全绿。deep leaf 把联接放在叶子之上 24 层，
  # deep host 把联接放在离盘符 16 层以上 —— 小于这两个数的任何上限都会红。
  # 反例锚点：同一物理目录走不经联接的真实路径，必须不被判定、且必须扫出钉死的文件集 ——
  # 否则「经联接扫出 0 个文件」可能只是因为目录本来就空。
  $ancBase     = Join-Path $temp 'anc'
  $ancOutside  = Join-Path $ancBase 'outside'
  $ancHost     = Join-Path $ancBase 'host'
  $ancJct      = Join-Path $ancHost 'jct'
  $ancDeepRel  = 'q' + ('\q' * 23)
  $ancDeepLevels = @($ancDeepRel -split '\\').Count
  $ancDeepHost = Join-Path $ancBase ('dh' + ('\h' * 16))
  $ancDeepJct  = Join-Path $ancDeepHost 'jct'
  $ancLad      = Join-Path $ancBase 'lad'
  $ancNvOut    = Join-Path $ancBase 'nv-outside'
  $ancNvJct    = Join-Path $ancLad 'NVIDIA'
  $ancHidJct   = Join-Path $ancBase 'hid\jct'
  $ancHidPlain = Join-Path $ancBase 'hidplain'
  $ancL1Files  = @('l1\a.bin', 'l1\l2\b.bin', 'l1\l2\l3\c.bin')
  $ancCases = @(
    @{ Label = 'depth 1'; Via = (Join-Path $ancJct 'l1');       Direct = (Join-Path $ancOutside 'l1');       Files = $ancL1Files },
    @{ Label = 'depth 2'; Via = (Join-Path $ancJct 'l1\l2');    Direct = (Join-Path $ancOutside 'l1\l2');    Files = @('l1\l2\b.bin', 'l1\l2\l3\c.bin') },
    @{ Label = 'depth 3'; Via = (Join-Path $ancJct 'l1\l2\l3'); Direct = (Join-Path $ancOutside 'l1\l2\l3'); Files = @('l1\l2\l3\c.bin') }
  )
  $ancReady = $false
  $ancSkipReason = ''
  try {
    [void][IO.Directory]::CreateDirectory((Join-Path $ancOutside 'l1\l2\l3'))
    [void][IO.Directory]::CreateDirectory($ancHost)
    foreach ($ancRel in $ancL1Files) {
      [IO.File]::WriteAllText((Join-Path $ancOutside $ancRel), $ancRel)
    }
    New-Item -ItemType Junction -Path $ancJct -Target $ancOutside -ErrorAction Stop | Out-Null
    foreach ($ancNvRel in 'DXCache', 'GLCache') {
      [void][IO.Directory]::CreateDirectory((Join-Path $ancNvOut $ancNvRel))
      [IO.File]::WriteAllBytes((Join-Path $ancNvOut ($ancNvRel + '\outside.bin')), (New-Object byte[] 1000))
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $ancLad 'D3DSCache'))
    [IO.File]::WriteAllBytes((Join-Path $ancLad 'D3DSCache\local.bin'), (New-Object byte[] 7))
    New-Item -ItemType Junction -Path $ancNvJct -Target $ancNvOut -ErrorAction Stop | Out-Null
    # 夹具是否就绪只用 .NET 原生 API 判定、不借产品函数：联接是 reparse point，且确实重定向到目标
    $ancReady = (((([IO.File]::GetAttributes($ancJct)) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and
      [IO.File]::Exists((Join-Path $ancJct 'l1\l2\l3\c.bin')) -and
      ((([IO.File]::GetAttributes($ancNvJct)) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and
      [IO.File]::Exists((Join-Path $ancNvJct 'DXCache\outside.bin')))
    if (-not $ancReady) { $ancSkipReason = 'junction was created but is not a redirecting reparse point' }
  } catch {
    # 与 Lane B 同一条安全网：这个 catch 只允许吞「创建夹具失败」
    if ("$($_.Exception.Message)" -like 'ASSERT:*') { throw }
    $ancSkipReason = $_.Exception.Message
  }
  # deep 夹具单独判定就绪：%TEMP% 特别长的机器上可能撞 MAX_PATH，那时只跳过 deep 行，浅行照常执行。
  $ancDeepReady = $false
  $ancDeepSkipReason = ''
  $ancDeepSegments = 0
  if ($ancReady) {
    try {
      [void][IO.Directory]::CreateDirectory((Join-Path $ancOutside $ancDeepRel))
      [IO.File]::WriteAllText((Join-Path $ancOutside ($ancDeepRel + '\deep.bin')), 'deep')
      [void][IO.Directory]::CreateDirectory($ancDeepHost)
      New-Item -ItemType Junction -Path $ancDeepJct -Target $ancOutside -ErrorAction Stop | Out-Null
      $ancDeepReady = (((([IO.File]::GetAttributes($ancDeepJct)) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and
        [IO.File]::Exists((Join-Path $ancJct ($ancDeepRel + '\deep.bin'))) -and
        [IO.File]::Exists((Join-Path $ancDeepJct 'l1\a.bin')))
      if (-not $ancDeepReady) { $ancDeepSkipReason = 'deep junction fixture was created but does not redirect' }
      # 只用于消息：deep host 联接离盘符有几段（决定能杀掉多大的「前 N 段」上限）
      $ancDeepSegments = @(([IO.Path]::GetFullPath($ancDeepJct)).Split([char[]]'\', [StringSplitOptions]::RemoveEmptyEntries)).Count - 1
    } catch {
      if ("$($_.Exception.Message)" -like 'ASSERT:*') { throw }
      $ancDeepSkipReason = $_.Exception.Message
    }
    if (-not $ancDeepReady) {
      Write-Output "SKIP junction-ancestor-deep (deep fixture unavailable; shallow rows still run): $ancDeepSkipReason"
    }
  }
  # 隐藏联接夹具（复核 H0/H1）：Windows 自带的兼容性联接（Application Data 等）就是 Hidden|System。
  # 读属性若改成 Get-Item 不带 -Force，对隐藏项要么什么也拿不到（返回 false = 放行），要么在 Stop 下抛异常；
  # 旧夹具里没有任何隐藏项，两种退化都照绿。这里给 hid\jct 与 lad\NVIDIA（C5 生产形状）加 Hidden|System，
  # 再放一个 Hidden|System 的普通目录做反例锚点（证明判定靠的是 reparse 位、不是「隐藏」位）。
  # 就绪同样只用 .NET 判定，并确认属性加在链接本身、没有跟随到目标上。
  $ancHidReady = $false
  $ancHidSkipReason = ''
  if ($ancReady) {
    try {
      $ancHS = [IO.FileAttributes]'Hidden, System'
      $ancHSR = $ancHS -bor [IO.FileAttributes]::ReparsePoint
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ancHidJct))
      New-Item -ItemType Junction -Path $ancHidJct -Target $ancOutside -ErrorAction Stop | Out-Null
      [void][IO.Directory]::CreateDirectory((Join-Path $ancHidPlain 'l1'))
      foreach ($ancHidItem in $ancHidJct, $ancHidPlain, $ancNvJct) {
        $ancHidDi = New-Object IO.DirectoryInfo $ancHidItem
        $ancHidDi.Attributes = $ancHidDi.Attributes -bor $ancHS
      }
      $ancHidReady = ((([IO.File]::GetAttributes($ancHidJct)) -band $ancHSR) -eq $ancHSR -and
        (([IO.File]::GetAttributes($ancNvJct)) -band $ancHSR) -eq $ancHSR -and
        (([IO.File]::GetAttributes($ancHidPlain)) -band $ancHSR) -eq $ancHS -and
        (([IO.File]::GetAttributes($ancOutside)) -band $ancHS) -eq 0 -and
        (([IO.File]::GetAttributes($ancNvOut)) -band $ancHS) -eq 0 -and
        [IO.File]::Exists((Join-Path $ancHidJct 'l1\a.bin')))
      if (-not $ancHidReady) { $ancHidSkipReason = 'Hidden|System could not be set on the link itself (or it followed to the target)' }
    } catch {
      if ("$($_.Exception.Message)" -like 'ASSERT:*') { throw }
      $ancHidSkipReason = $_.Exception.Message
    }
    if (-not $ancHidReady) {
      Write-Output "SKIP junction-hidden (hidden-link fixture unavailable; other rows still run): $ancHidSkipReason"
    }
  }
  if ($ancReady) {
    # 下面全部在 catch 之外：产品放过祖先联接必须直接让测试红
    # C1：直接检查 Test-PathHasReparsePoint。顺序有意为之（深度 1 -> 2 -> 3 -> 叶子不存在 -> 正斜杠 ->
    #     deep leaf -> deep host），第一个红的断言就指出是哪一维退化了。
    foreach ($ancCase in $ancCases) {
      Assert-True (Test-PathHasReparsePoint $ancCase.Via) `
        ("JA-C1 [" + $ancCase.Label + "] ancestor junction not detected: '" + $ancCase.Via + "' must be flagged")
      Assert-True (-not (Test-PathHasReparsePoint $ancCase.Direct)) `
        ("JA-C1 [" + $ancCase.Label + "] anchor: '" + $ancCase.Direct + "' is the same directory without a junction on the path and must not be flagged")
    }
    $ancMissingVia = Join-Path $ancJct 'l1\not-created\x.bin'
    $ancMissingDirect = Join-Path $ancOutside 'l1\not-created\x.bin'
    Assert-True (-not (Test-Path -LiteralPath $ancMissingDirect)) 'JA-C1 [missing leaf] fixture: the probe path must not exist'
    Assert-True (Test-PathHasReparsePoint $ancMissingVia) `
      ("JA-C1 [missing leaf] '" + $ancMissingVia + "' does not exist yet but an existing ancestor is a junction; it must be flagged")
    Assert-True (-not (Test-PathHasReparsePoint $ancMissingDirect)) `
      ("JA-C1 [missing leaf] anchor: '" + $ancMissingDirect + "' must not be flagged")
    $ancSlashVia = (Join-Path $ancJct 'l1\l2').Replace('\', '/')
    Assert-True (Test-PathHasReparsePoint $ancSlashVia) `
      ("JA-C1 [separator] '" + $ancSlashVia + "' spells the same path with '/' and must still be flagged")
    if ($ancDeepReady) {
      $ancDeepVia = Join-Path $ancJct $ancDeepRel
      $ancDeepDirect = Join-Path $ancOutside $ancDeepRel
      Assert-True (Test-PathHasReparsePoint $ancDeepVia) `
        ("JA-C1 [deep leaf] a junction " + $ancDeepLevels + " levels above the leaf must be flagged (a capped walk up from the leaf misses it): '" + $ancDeepVia + "'")
      Assert-True (-not (Test-PathHasReparsePoint $ancDeepDirect)) `
        ("JA-C1 [deep leaf] anchor: '" + $ancDeepDirect + "' has no junction on the path and must not be flagged")
      $ancDeepHostVia = Join-Path $ancDeepJct 'l1'
      $ancDeepHostDirect = Join-Path $ancDeepHost 'not-created\x.bin'
      Assert-True (Test-PathHasReparsePoint $ancDeepHostVia) `
        ("JA-C1 [deep host] a junction at path segment " + $ancDeepSegments + " below the drive root must be flagged (a walk capped at the first N segments misses it): '" + $ancDeepHostVia + "'")
      Assert-True (-not (Test-PathHasReparsePoint $ancDeepHostDirect)) `
        ("JA-C1 [deep host] anchor: '" + $ancDeepHostDirect + "' walks the same long chain without a junction and must not be flagged")
    }
    if ($ancHidReady) {
      # [hidden]：调用包在 try/catch 里，「读不到属性 → 返回 false」(H1) 与「对隐藏项抛异常」(H0) 都落在这一条 ASSERT 上，
      # 消息里 got=/error=<...> 区分是哪一种。反例锚点是 Hidden|System 的普通目录，同样包 try/catch。
      $ancHidVia = Join-Path $ancHidJct 'l1'
      $ancHidGot = $null; $ancHidErr = ''
      try { $ancHidGot = Test-PathHasReparsePoint $ancHidVia } catch { $ancHidErr = "$($_.Exception.Message)" }
      Assert-True ($ancHidGot -eq $true -and $ancHidErr -eq '') `
        ("JA-C1 [hidden] a junction carrying the Hidden|System attributes must still be flagged (an attribute read that skips hidden items misses it or throws): '" +
         $ancHidVia + "' got=" + $ancHidGot + " error=<" + $ancHidErr + ">")
      $ancHidPlainVia = Join-Path $ancHidPlain 'l1'
      $ancHidPlainGot = $null; $ancHidPlainErr = ''
      try { $ancHidPlainGot = Test-PathHasReparsePoint $ancHidPlainVia } catch { $ancHidPlainErr = "$($_.Exception.Message)" }
      Assert-True ($ancHidPlainGot -eq $false -and $ancHidPlainErr -eq '') `
        ("JA-C1 [hidden] anchor: '" + $ancHidPlainVia + "' lies below a Hidden|System directory that is not a reparse point and must not be flagged: got=" +
         $ancHidPlainGot + " error=<" + $ancHidPlainErr + ">")
    }
    # C2：真实扫描。先用不经联接的路径钉住「目录里确实有这些文件」，再断言经联接时整根拒绝、一个文件都不给。
    $ancScanCases = New-Object System.Collections.Generic.List[object]
    foreach ($ancCase in $ancCases) { $ancScanCases.Add($ancCase) }
    if ($ancDeepReady) {
      $ancScanCases.Add(@{ Label = 'deep leaf'; Via = (Join-Path $ancJct $ancDeepRel); Direct = (Join-Path $ancOutside $ancDeepRel); Files = @($ancDeepRel + '\deep.bin') })
      $ancScanCases.Add(@{ Label = 'deep host'; Via = (Join-Path $ancDeepJct 'l1'); Direct = (Join-Path $ancOutside 'l1'); Files = $ancL1Files })
    }
    if ($ancHidReady) {
      $ancScanCases.Add(@{ Label = 'hidden'; Via = (Join-Path $ancHidJct 'l1'); Direct = (Join-Path $ancOutside 'l1'); Files = $ancL1Files })
    }
    $ancScanned = 0
    foreach ($ancCase in $ancScanCases) {
      $ancExpect = @($ancCase.Files | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $ancOutside $_)) } | Sort-Object)
      $ancScanDirect = Get-SafeFilesUnderRoot $ancCase.Direct
      $ancGotDirect = @(@($ancScanDirect.Files) | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) } | Sort-Object)
      Assert-True ($ancExpect.Count -gt 0 -and @($ancScanDirect.Rejected).Count -eq 0 -and
        (($ancGotDirect -join '|') -ieq ($ancExpect -join '|'))) `
        ("JA-C2 [" + $ancCase.Label + "] anchor: scanning '" + $ancCase.Direct + "' directly must return exactly " + $ancExpect.Count +
         " fixture file(s); got=" + ($ancGotDirect -join ';'))
      $ancScanVia = Get-SafeFilesUnderRoot $ancCase.Via
      Assert-True (@($ancScanVia.Files).Count -eq 0 -and @($ancScanVia.Rejected).Count -eq 1 -and
        [string]::Equals(([IO.Path]::GetFullPath(@($ancScanVia.Rejected)[0])).TrimEnd('\'),
          ([IO.Path]::GetFullPath($ancCase.Via)).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) `
        ("JA-C2 [" + $ancCase.Label + "] scan root below a junction must be rejected whole with no files: root='" +
         $ancCase.Via + "' files=" + (@(@($ancScanVia.Files) | ForEach-Object { $_.FullName }) -join ';') +
         " rejected=" + (@($ancScanVia.Rejected) -join ';'))
      $ancScanned++
    }
    Assert-True ($ancScanned -ge 3 -and $ancScanned -eq $ancScanCases.Count) 'JA-C2 must have scanned every root below the junction (at least the 3 shallow ones)'
    # C5：生产形状端到端（只读，零桁）：真实 Get-ShaderCacheDirs -> Get-ShaderCacheScan -> Get-SafeFilesUnderRoot ->
    #     Test-PathHasReparsePoint。目标用户的 LocalAppData 指向 lad（本身不含联接，与 Set-TargetUserContext 的校验一致），
    #     lad\NVIDIA 是联接。系统级条目改指向不存在的目录，免得去读本机真实的 NV_Cache。
    #     期望值从产品自己的目录表推出：表里落在 lad\NVIDIA 之下、且存在的用户级目录必须逐个进 Rejected、一个字节都不计；
    #     D3DSCache 不经联接，它的 7 字节必须照常计入 —— 这一项同时证明扫描是活的（非空洞）。
    #     已知脆性：产品目录表不再列出 LocalAppData\NVIDIA\* 或 D3DSCache 时，premise 断言会红，按消息改夹具即可。
    $ancSavedLocal = $script:TargetLocalAppData
    $ancSavedCommon = $script:CommonAppData
    $script:TargetLocalAppData = $ancLad
    $script:CommonAppData = Join-Path $ancBase 'no-common-appdata'
    $ancNvPrefix = ([IO.Path]::GetFullPath($ancNvJct)).TrimEnd('\') + '\'
    $ancLocalCache = ([IO.Path]::GetFullPath((Join-Path $ancLad 'D3DSCache'))).TrimEnd('\')
    $ancUserDirs = @(@(Get-ShaderCacheDirs) | Where-Object { $_.Scope -eq 'user' } |
      ForEach-Object { ([IO.Path]::GetFullPath($_.Path)).TrimEnd('\') })
    $ancExpectRejected = @($ancUserDirs | Where-Object {
        $_.StartsWith($ancNvPrefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($_) } | Sort-Object)
    Assert-True ($ancExpectRejected.Count -ge 1 -and @($ancUserDirs | Where-Object { $_ -ieq $ancLocalCache }).Count -eq 1) `
      ("JA-C5 premise: Get-ShaderCacheDirs must list at least one existing user cache dir under '" + $ancNvPrefix +
       "' and exactly one '" + $ancLocalCache + "'; user dirs=" + ($ancUserDirs -join ';'))
    $ancShader = Get-ShaderCacheScan
    $ancGotRejected = @(@($ancShader.Rejected) | ForEach-Object { ([IO.Path]::GetFullPath("$_")).TrimEnd('\') } | Sort-Object)
    Assert-True (($ancGotRejected -join '|') -ieq ($ancExpectRejected -join '|')) `
      ("JA-C5 [production shape] with LocalAppData\NVIDIA replaced by a junction, Get-ShaderCacheScan must report exactly the NVIDIA cache roots as rejected: expected=" +
       ($ancExpectRejected -join ';') + " got=" + ($ancGotRejected -join ';'))
    Assert-True ([long]$ancShader.Bytes -eq 7) `
      ("JA-C5 [production shape] Get-ShaderCacheScan must count the 7 local bytes and none of the 1000-byte files behind the junction: bytes=" + $ancShader.Bytes)
    $script:TargetLocalAppData = $ancSavedLocal
    $script:CommonAppData = $ancSavedCommon
    # JA-ACL（复核 ACL1）：Test-DirectoryAclSafe 必须因为「路径是 reparse point」拒绝联接目录，哪怕联接跟随到的目标
    #   所有者与 ACL 全部受信。受信集在运行时从目标自身的 ACL 推出，并先证明目标这个普通目录能通过（非空洞锚点）。
    $ancAclSec = [IO.Directory]::GetAccessControl($ancOutside, [Security.AccessControl.AccessControlSections]'Owner, Access')
    $ancAclTrusted = @(@(@($ancAclSec.GetOwner([Security.Principal.SecurityIdentifier]).Value) +
      @($ancAclSec.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })) | Sort-Object -Unique)
    Assert-True ($ancAclTrusted.Count -ge 1 -and (Test-DirectoryAclSafe $ancOutside $ancAclTrusted $ancAclTrusted)) `
      ("JA-ACL anchor: the plain directory '" + $ancOutside + "' must pass Test-DirectoryAclSafe when its owner and every ACE SID are trusted; trusted=" + ($ancAclTrusted -join ','))
    Assert-True (-not (Test-DirectoryAclSafe $ancJct $ancAclTrusted $ancAclTrusted)) `
      ("JA-ACL [reparse] Test-DirectoryAclSafe must reject a reparse-point directory even when its target's owner and ACL are trusted: '" + $ancJct + "'")
    # JA-M1（复核 M1）：某目录被判定「无 reparse」之后换成联接，再查必须重新判定，不得吃到过期的（缓存的）结论。
    #   Clear-ShaderCache 删除前的逐文件复检（TOCTOU）依赖的正是「每次都重新读」。
    $ancSwapC = Join-Path $ancBase 'swap\c'
    [void][IO.Directory]::CreateDirectory($ancSwapC)
    $ancSwapProbe = Join-Path $ancSwapC 'x.bin'
    Assert-True (-not (Test-PathHasReparsePoint $ancSwapProbe)) `
      ("JA-M1 [re-check] anchor: '" + $ancSwapProbe + "' lies below a plain directory and must not be flagged before the swap")
    [IO.Directory]::Delete($ancSwapC)
    New-Item -ItemType Junction -Path $ancSwapC -Target $ancOutside -ErrorAction Stop | Out-Null
    Assert-True (((([IO.File]::GetAttributes($ancSwapC)) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) `
      ("JA-M1 fixture: '" + $ancSwapC + "' must now be a junction")
    Assert-True (Test-PathHasReparsePoint $ancSwapProbe) `
      ("JA-M1 [re-check] a directory checked as reparse-free and then replaced by a junction must be re-detected, not served from a stale verdict: '" + $ancSwapProbe + "'")
    [IO.Directory]::Delete($ancSwapC)
    # JA-NPD：真 New-ProtectedDirectory 在父路径含联接时，必须在建任何东西之前拒绝（产品消息「父路径包含目录联接」）。
    $ancNpdPath = Join-Path $ancJct 'l1\npd'
    $ancNpdErr = ''
    try { & $realNewProtectedDirectory $ancNpdPath $false } catch { $ancNpdErr = "$($_.Exception.Message)" }
    Assert-True ($ancNpdErr -like '*父路径*' -and -not [IO.Directory]::Exists($ancNpdPath)) `
      ("JA-NPD [parent reparse] New-ProtectedDirectory must refuse, before creating anything, a protected directory whose parent path contains a junction: '" +
       $ancNpdPath + "' created=" + [IO.Directory]::Exists($ancNpdPath) + " error=<" + $ancNpdErr + ">")
    # JA-BK：备份完整性密钥文件的路径上有联接时 Initialize-ProtectedStore 必须拒绝；同一个文件走真实路径时必须接受（锚点）。
    $ancBkSaved = $script:BackupKeyFile
    $ancBkDirect = Join-Path $ancOutside 'l1\a.bin'
    $ancBkVia = Join-Path $ancJct 'l1\a.bin'
    $ancBkDirectErr = ''; $ancBkViaErr = ''
    try {
      $script:BackupKeyFile = $ancBkDirect
      try { Initialize-ProtectedStore } catch { $ancBkDirectErr = "$($_.Exception.Message)" }
      $script:BackupKeyFile = $ancBkVia
      try { Initialize-ProtectedStore } catch { $ancBkViaErr = "$($_.Exception.Message)" }
    } finally { $script:BackupKeyFile = $ancBkSaved }
    Assert-True ($ancBkDirectErr -eq '') `
      ("JA-BK anchor: a backup key file with no junction on its path ('" + $ancBkDirect + "') must be accepted: error=<" + $ancBkDirectErr + ">")
    Assert-True ($ancBkViaErr -like '*备份完整性密钥*') `
      ("JA-BK [reparse] Initialize-ProtectedStore must refuse a backup key file reached through a junction: '" + $ancBkVia + "' error=<" + $ancBkViaErr + ">")

    # ---- JA-CS（复核 CS1）：Clear-ShaderCache 删除每个候选之前必须逐个复检 reparse point（扫描 -> 删除之间的 TOCTOU）----
    # 不改产品也能走到删除路径：桁掉 Get-ShaderCacheDirs（只给夹具目录）与 Test-Admin（普通权限），把目标用户设成当前
    # 用户 + 真实 LocalAppData 以通过身份门；Get-SafeFilesUnderRoot 桁成「先跑真扫描，返回前把 cache\sub 换成联接」
    # 来模拟竞态，并夹带一个根外文件（模拟扫描器越界）。Remove-Item 桁成只放行 $temp 之内的路径、记录越界企图 ——
    # 第二道保险：日后产品即使不再经 Get-ShaderCacheDirs 取目录，也删不到真实用户文件。
    # 断言只看文件系统结果、不钉 Remove-Item 的调用次数，所以改用 [IO.File]::Delete 的合法重构照绿。
    $csBase = Join-Path $ancBase 'cs'
    $csRoot = Join-Path $csBase 'cache'
    $csKeep = Join-Path $csRoot 'keep.bin'
    $csSub = Join-Path $csRoot 'sub'
    $csOut = Join-Path $csBase 'outside'
    $csVictim = Join-Path $csOut 'victim.bin'
    $csStray = Join-Path $csBase 'stray\stray.bin'
    foreach ($csDir in $csSub, $csOut, (Split-Path -Parent $csStray)) { [void][IO.Directory]::CreateDirectory($csDir) }
    [IO.File]::WriteAllText($csKeep, 'keep')
    [IO.File]::WriteAllText((Join-Path $csSub 'victim.bin'), 'plain')
    [IO.File]::WriteAllText($csVictim, 'victim')
    [IO.File]::WriteAllText($csStray, 'stray')
    $script:CsState = @{ Root = $csRoot; Sub = $csSub; Out = $csOut; Stray = $csStray; Swapped = $false; Scans = 0
      Guard = ([IO.Path]::GetFullPath($temp)).TrimEnd('\') + '\'; Outside = (New-Object System.Collections.Generic.List[string])
      RealScan = ${function:Get-SafeFilesUnderRoot} }
    $csSaved = @{ Dirs = ${function:Get-ShaderCacheDirs}; Admin = ${function:Test-Admin}; Sid = $script:TargetUserSid; Local = $script:TargetLocalAppData }
    $csResult = $null
    try {
      function Get-ShaderCacheDirs { @(@{ Label = 'JA-CS fixture cache'; Path = $script:CsState.Root; Scope = 'user' }) }
      function Test-Admin { $false }
      function Get-SafeFilesUnderRoot([string]$Root) {
        $script:CsState.Scans++
        $csReal = & $script:CsState.RealScan $Root
        if (-not $script:CsState.Swapped) {
          [IO.File]::Delete((Join-Path $script:CsState.Sub 'victim.bin'))
          [IO.Directory]::Delete($script:CsState.Sub)
          New-Item -ItemType Junction -Path $script:CsState.Sub -Target $script:CsState.Out -ErrorAction Stop | Out-Null
          $script:CsState.Swapped = ((([IO.File]::GetAttributes($script:CsState.Sub)) -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        }
        [pscustomobject]@{ Files = @(@($csReal.Files) + @(New-Object IO.FileInfo $script:CsState.Stray)); Rejected = @($csReal.Rejected) }
      }
      function Remove-Item {
        [CmdletBinding()]param([string[]]$LiteralPath, [switch]$Force)
        foreach ($csP in $LiteralPath) {
          $csFull = [IO.Path]::GetFullPath($csP)
          if (-not $csFull.StartsWith($script:CsState.Guard, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$script:CsState.Outside.Add($csFull)
            throw "JA-CS guard refused a delete outside the test directory: $csFull"
          }
          Microsoft.PowerShell.Management\Remove-Item -LiteralPath $csP -Force:$Force -ErrorAction Stop
        }
      }
      $script:TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      $script:TargetLocalAppData = ([IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData))).TrimEnd('\')
      $csDirs = @(Get-ShaderCacheDirs)
      Assert-True ($csDirs.Count -eq 1 -and "$($csDirs[0].Path)" -ieq $csRoot) `
        ("JA-CS safety: Get-ShaderCacheDirs must be the fixture stub before Clear-ShaderCache runs; got=" + (@($csDirs | ForEach-Object { $_.Path }) -join ';'))
      $csResult = Clear-ShaderCache
    } finally {
      Microsoft.PowerShell.Management\Remove-Item -Path Function:\Remove-Item -Force -ErrorAction SilentlyContinue
      Set-Item -Path Function:\Get-SafeFilesUnderRoot -Value $script:CsState.RealScan
      Set-Item -Path Function:\Get-ShaderCacheDirs -Value $csSaved.Dirs
      Set-Item -Path Function:\Test-Admin -Value $csSaved.Admin
      $script:TargetUserSid = $csSaved.Sid
      $script:TargetLocalAppData = $csSaved.Local
    }
    $csSummary = (@($csResult.Cleared) + @($csResult.Failed)) -join ' / '
    Assert-True ($script:CsState.Outside.Count -eq 0) `
      ("JA-CS guard: Clear-ShaderCache tried to delete outside the test directory: " + ($script:CsState.Outside -join ';'))
    Assert-True ($script:CsState.Scans -eq 1 -and $script:CsState.Swapped) `
      ("JA-CS1 [scan wiring] Clear-ShaderCache must take its candidates from one Get-SafeFilesUnderRoot scan of the cache root: scans=" +
       $script:CsState.Scans + " swapped=" + $script:CsState.Swapped)
    Assert-True ([IO.File]::Exists($csVictim) -and [IO.File]::ReadAllText($csVictim) -eq 'victim') `
      ("JA-CS1 [toctou] a cache subdirectory swapped for a junction between the scan and the delete must not be followed: '" + $csVictim +
       "' was deleted through '" + (Join-Path $csSub 'victim.bin') + "'; result=" + $csSummary)
    Assert-True ([IO.File]::Exists($csStray)) `
      ("JA-CS2 [prefix] a candidate outside the cache root must never be deleted: '" + $csStray + "'; result=" + $csSummary)
    Assert-True (-not [IO.File]::Exists($csKeep)) `
      ("JA-CS anchor: the plain cache file '" + $csKeep + "' must be deleted (proves the delete loop is live); result=" + $csSummary)
    # 只删联接本身、不跟随到目标（与 Lane B 同样不用 catch 收尾；断言失败时由最外层 finally 清 $temp）
    [IO.Directory]::Delete($csSub)
    if ([IO.Directory]::Exists($ancHidJct)) { [IO.Directory]::Delete($ancHidJct) }
    if ($ancDeepReady) { [IO.Directory]::Delete($ancDeepJct) }
    [IO.Directory]::Delete($ancNvJct)
    [IO.Directory]::Delete($ancJct)
  } else {
    Write-Output "SKIP junction-ancestor (cannot create a real junction here; Lane A covers the scan logic with stubs): $ancSkipReason"
  }

  # ---- Lane W：联接就在盘符根正下方（复核 W1/W2） ------------------------------------------------
  # Lane C 的联接都埋在 %TEMP% 深处（第 7 段以下）。「从叶子往上走、在盘符根下一层就停」（少走一层的 walk-up）
  # 与「从盘符往下走、跳过第一段」（下标守卫差一）都够不到 X:\jct 这种形状，却能全套照绿；而用户在数据盘根下
  # 建的游戏/工具目录正是这种形状。用 subst 把一个 $temp 里的夹具目录映射成一个空闲盘符（按登录会话生效、
  # 不需要管理员），联接就落在 X:\jct（第 1 段）。
  # 规则同其他 Lane：夹具 catch 只吞「建不出来」并原样抛出 ASSERT:*；断言全部在夹具 try 之外，放在 try/finally
  # （无 catch）里 —— finally 只负责 subst /d，断言失败绝不会被降级成 SKIP。
  # 已知残余：测试进程被硬杀（finally 没跑）时映射会留到注销，手动 `subst X: /d` 即可。
  $wRoot  = Join-Path $temp 'wsubst'
  $wOut   = Join-Path $wRoot 'out'
  $wJct   = Join-Path $wRoot 'jct'
  $wReady = $false
  $wSkipReason = ''
  $wLetter = $null
  $wMapped = $false
  try {
    [void][IO.Directory]::CreateDirectory((Join-Path $wOut 'l1'))
    [IO.File]::WriteAllText((Join-Path $wOut 'l1\a.bin'), 'a')
    [void][IO.Directory]::CreateDirectory((Join-Path $wRoot 'plain\l1'))
    [IO.File]::WriteAllText((Join-Path $wRoot 'plain\l1\p.bin'), 'p')
    New-Item -ItemType Junction -Path $wJct -Target $wOut -ErrorAction Stop | Out-Null
    $wUsed = @([IO.Directory]::GetLogicalDrives() | ForEach-Object { "$_".Substring(0, 1).ToUpperInvariant() })
    $wLetter = @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G') |
      Where-Object { $wUsed -notcontains $_ } | Select-Object -First 1
    if (-not $wLetter) {
      $wSkipReason = 'no free drive letter for subst'
    } else {
      & subst.exe "$($wLetter):" $wRoot | Out-Null
      $wExit = $LASTEXITCODE
      # 退出码 0 才算映射成功；只有自己映射成功的盘符才会在 finally 里 subst /d（绝不删别人的映射）
      $wMapped = ($wExit -eq 0)
      if (-not $wMapped) {
        $wSkipReason = "subst $($wLetter): failed (exit $wExit)"
      } else {
        # 就绪只用 .NET 判定（外加 PowerShell 提供程序能否看见新盘符：产品走的是 Test-Path）
        $wReady = ([IO.File]::Exists("$($wLetter):\jct\l1\a.bin") -and [IO.File]::Exists("$($wLetter):\plain\l1\p.bin") -and
          ((([IO.File]::GetAttributes("$($wLetter):\jct")) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and
          (Test-Path -LiteralPath "$($wLetter):\plain\l1\p.bin"))
        if (-not $wReady) { $wSkipReason = "subst $($wLetter): mapped but the fixture is not visible through it" }
      }
    }
  } catch {
    if ("$($_.Exception.Message)" -like 'ASSERT:*') { throw }
    $wSkipReason = $_.Exception.Message
  }
  try {
    if ($wReady) {
      $wVia = "$($wLetter):\jct\l1"
      $wPlain = "$($wLetter):\plain\l1"
      # W1：直接检查
      Assert-True (Test-PathHasReparsePoint $wVia) `
        ("JA-W1 [top segment] a junction directly below the drive root must be flagged (a walk that stops before, or skips, the first segment misses it): '" + $wVia + "'")
      Assert-True (-not (Test-PathHasReparsePoint $wPlain)) `
        ("JA-W1 [top segment] anchor: '" + $wPlain + "' sits directly below the same drive root without a junction and must not be flagged")
      # W2：真实扫描。先钉住不经联接的同盘符目录能扫出它的文件，再断言经顶层联接时整根拒绝、一个文件都不给。
      $wScanPlain = Get-SafeFilesUnderRoot $wPlain
      $wPlainGot = @(@($wScanPlain.Files) | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) })
      Assert-True ($wPlainGot.Count -eq 1 -and $wPlainGot[0] -ieq "$($wLetter):\plain\l1\p.bin" -and @($wScanPlain.Rejected).Count -eq 0) `
        ("JA-W2 [top segment scan] anchor: scanning '" + $wPlain + "' must return exactly p.bin; files=" + ($wPlainGot -join ';') + " rejected=" + (@($wScanPlain.Rejected) -join ';'))
      $wScan = Get-SafeFilesUnderRoot $wVia
      Assert-True (@($wScan.Files).Count -eq 0 -and @($wScan.Rejected).Count -eq 1 -and
        [string]::Equals(([IO.Path]::GetFullPath(@($wScan.Rejected)[0])).TrimEnd('\'), $wVia, [StringComparison]::OrdinalIgnoreCase)) `
        ("JA-W2 [top segment scan] a scan root below a top-level junction must be rejected whole with no files: root='" + $wVia +
         "' files=" + (@(@($wScan.Files) | ForEach-Object { $_.FullName }) -join ';') + " rejected=" + (@($wScan.Rejected) -join ';'))
    } else {
      Write-Output "SKIP junction-top (cannot map a subst drive onto the fixture; Lane C covers deeper ancestors): $wSkipReason"
    }
  } finally {
    if ($wMapped) {
      & subst.exe "$($wLetter):" /d | Out-Null
      if (@([IO.Directory]::GetLogicalDrives()) -contains "$($wLetter):\") {
        Write-Output "WARN junction-top: 'subst $($wLetter): /d' did not remove the mapping; remove it by hand"
      }
    }
  }

  # ---- Lane D：reparse 判定必须与「链接种类」无关（复核 R2 攻击 B） ----------------
  # 只拿 junction 做夹具时，把属性位判定换成 (Get-Item).LinkType -eq 'Junction'（或 -in Junction/SymbolicLink、
  # 或只认带 .Target 的链接、或只认目录）照样全绿，而生产里的符号链接祖先、文件型链接会被放行。
  # 符号链接要管理员或开发者模式才建得出来，所以这里改用普通用户就能打的第三方 reparse tag
  # （0x20001234：非微软 tag、带 name-surrogate 位；PowerShell 的 LinkType 对它为空），
  # 分别打在一个空目录和一个文件上。name-surrogate 位让 RemoveDirectory/DeleteFile/Remove-Item
  # 只删链接本身，所以断言失败时最外层 finally 也能把 $temp 清干净。
  # 夹具：
  #   kind\host\plain\keep.bin   普通目录里的普通文件        -> 应进 Files
  #   kind\host\plain.bin        普通文件                    -> 应进 Files
  #   kind\host\tagged\          目录型第三方 reparse point  -> 应进 Rejected（目录型 reparse point 下建不出子项）
  #   kind\host\tagged.bin       文件型第三方 reparse point  -> 应进 Rejected
  $kindHost      = Join-Path $temp 'kind\host'
  $kindPlainDir  = Join-Path $kindHost 'plain'
  $kindPlainFile = Join-Path $kindHost 'plain.bin'
  $kindDir       = Join-Path $kindHost 'tagged'
  $kindFile      = Join-Path $kindHost 'tagged.bin'
  $kindReady = $false
  $kindSkipReason = ''
  try {
    [void][IO.Directory]::CreateDirectory($kindPlainDir)
    [void][IO.Directory]::CreateDirectory($kindDir)
    [IO.File]::WriteAllText((Join-Path $kindPlainDir 'keep.bin'), 'keep')
    [IO.File]::WriteAllText($kindPlainFile, 'plain')
    [IO.File]::WriteAllText($kindFile, 'tagged')
    if (-not ('DfbTestReparseTag' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class DfbTestReparseTag {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, int inputLength, IntPtr output, int outputLength, out int returned, IntPtr overlapped);
  // Third-party tag 0x20001234 (Microsoft bit clear, name-surrogate bit set) with an 8-byte GUID payload.
  public static void Set(string path) {
    // GENERIC_WRITE | FILE_READ_ATTRIBUTES, share all, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS
    using (SafeFileHandle handle = CreateFileW(path, 0x40000080u, 7u, IntPtr.Zero, 3u, 0x02200000u, IntPtr.Zero)) {
      if (handle.IsInvalid) throw new IOException("CreateFile failed: " + Marshal.GetLastWin32Error());
      byte[] buffer = new byte[32];
      BitConverter.GetBytes(0x20001234u).CopyTo(buffer, 0);
      BitConverter.GetBytes((ushort)8).CopyTo(buffer, 4);
      new Guid("6d1f5b1e-3c1a-4b7e-9f0e-1a2b3c4d5e6f").ToByteArray().CopyTo(buffer, 8);
      int returned;
      if (!DeviceIoControl(handle, 0x000900A4u, buffer, buffer.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero))
        throw new IOException("FSCTL_SET_REPARSE_POINT failed: " + Marshal.GetLastWin32Error());
    }
  }
}
'@
    }
    foreach ($kindTarget in $kindDir, $kindFile) { [DfbTestReparseTag]::Set($kindTarget) }
    # 就绪只用 .NET 原生属性判定，不借产品函数
    $kindReady = (((([IO.File]::GetAttributes($kindDir)) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and
      ((([IO.File]::GetAttributes($kindFile)) -band [IO.FileAttributes]::ReparsePoint) -ne 0))
    if (-not $kindReady) { $kindSkipReason = 'the reparse tag was set but the ReparsePoint attribute is not visible' }
  } catch {
    if ("$($_.Exception.Message)" -like 'ASSERT:*') { throw }
    $kindSkipReason = $_.Exception.Message
  }
  if ($kindReady) {
    # 非空洞锚点：夹具必须真的「不是 junction、也不是符号链接」，否则按种类收窄的判定照样能认出它
    foreach ($kindTarget in $kindDir, $kindFile) {
      $kindLinkType = "$((Get-Item -LiteralPath $kindTarget -Force).LinkType)"
      Assert-True ($kindLinkType -ne 'Junction' -and $kindLinkType -ne 'SymbolicLink') `
        ("JA-D fixture: '" + $kindTarget + "' must be a reparse point of another kind than Junction/SymbolicLink; LinkType='" + $kindLinkType + "'")
    }
    # D1：非 junction 的目录型 reparse point 作为祖先（叶子尚不存在）
    $kindViaDir = Join-Path $kindDir 'DXCache\x.bin'
    $kindPlainVia = Join-Path $kindPlainDir 'DXCache\x.bin'
    Assert-True (Test-PathHasReparsePoint $kindViaDir) `
      ("JA-D1 [dir ancestor] a non-junction reparse point above '" + $kindViaDir + "' must be flagged: detection must not depend on the link kind")
    Assert-True (-not (Test-PathHasReparsePoint $kindPlainVia)) `
      ("JA-D1 anchor: '" + $kindPlainVia + "' has no reparse point on the path and must not be flagged")
    # D2：文件型 reparse point 本身（备份文件、密钥文件等调用方检查的就是文件路径）
    Assert-True (Test-PathHasReparsePoint $kindFile) `
      ("JA-D2 [file leaf] the file-type reparse point '" + $kindFile + "' must be flagged: detection must not be limited to directories")
    Assert-True (-not (Test-PathHasReparsePoint $kindPlainFile)) `
      ("JA-D2 anchor: '" + $kindPlainFile + "' must not be flagged")
    # D3：以它为扫描根时整根拒绝
    $kindRootScan = Get-SafeFilesUnderRoot $kindDir
    Assert-True (@($kindRootScan.Files).Count -eq 0 -and @($kindRootScan.Rejected).Count -eq 1 -and
      [string]::Equals(([IO.Path]::GetFullPath(@($kindRootScan.Rejected)[0])).TrimEnd('\'),
        ([IO.Path]::GetFullPath($kindDir)).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) `
      ("JA-D3 [scan root] a non-junction reparse point used as the scan root must be rejected whole: rejected=" + (@($kindRootScan.Rejected) -join ';'))
    # D4：真实枚举（Lane A 用桁测过同一件事，这里是真实属性）：两个 tagged 进 Rejected，普通文件一个不漏
    $kindScan = Get-SafeFilesUnderRoot $kindHost
    $kindGotFiles = @(@($kindScan.Files) | ForEach-Object { [IO.Path]::GetFullPath($_.FullName) } | Sort-Object)
    $kindGotRejected = @(@($kindScan.Rejected) | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object)
    $kindExpectFiles = @(@([IO.Path]::GetFullPath($kindPlainFile), [IO.Path]::GetFullPath((Join-Path $kindPlainDir 'keep.bin'))) | Sort-Object)
    $kindExpectRejected = @(@([IO.Path]::GetFullPath($kindDir), [IO.Path]::GetFullPath($kindFile)) | Sort-Object)
    Assert-True ($kindExpectFiles.Count -eq 2 -and $kindExpectRejected.Count -eq 2 -and
      (($kindGotFiles -join '|') -ieq ($kindExpectFiles -join '|')) -and
      (($kindGotRejected -join '|') -ieq ($kindExpectRejected -join '|'))) `
      ("JA-D4 [scan entries] a real scan must reject exactly the tagged dir and file and return exactly the 2 plain files: files=" +
       ($kindGotFiles -join ';') + " rejected=" + ($kindGotRejected -join ';'))
    # 只删链接本身（name-surrogate：不跟随）
    [IO.File]::Delete($kindFile)
    [IO.Directory]::Delete($kindDir)
  } else {
    Write-Output "SKIP reparse-kind (cannot set a non-junction reparse tag here; JA-C3 below still pins the attribute-bit check): $kindSkipReason"
  }

  # ---- JA-C3：结构兜底（夹具 SKIP 时上面的行为断言都不执行，这一段仍然执行） ------------
  # 行为够得到时由 Lane D 先红；这里只兜「夹具建不出来」的环境：那时把属性位判定换成按链接种类判断
  # 会悄无声息地通过。读的是当前生效的函数定义（Lane A 已在 finally 里还原），并锚定它来自产品引擎文件。
  # 钉的是语法树：字符串常量（含成员名与裸词，如 Where-Object LinkType -eq Junction）与数值常量，注释满足不了它。
  # 「读了属性位」接受三种等价写法：[IO.FileAttributes]::ReparsePoint、[IO.FileAttributes]'ReparsePoint'、0x400。
  # 已知脆性：死代码能满足第一条（所以主力是 Lane D）；用字符串拼出来的成员名/种类名（.('Link'+'Type')）
  # 看不见，只有 Lane D 能抓。合法重构若用这三种以外的写法读属性位（例如从变量里取掩码），按消息改钉即可。
  $tprAst = (Get-Command Test-PathHasReparsePoint -CommandType Function -ErrorAction Stop).ScriptBlock.Ast
  $tprFile = "$($tprAst.Extent.File)"
  Assert-True ($tprAst -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $tprAst.Name -eq 'Test-PathHasReparsePoint' -and $tprFile -ne '' -and
    ([IO.Path]::GetFullPath($tprFile) -ieq [IO.Path]::GetFullPath($engine))) `
    ("JA-C3 anchor: the structural check must read the live Test-PathHasReparsePoint defined in '" + $engine + "'; got '" + $tprFile + "'")
  $tprWords = @($tprAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
    ForEach-Object { $_.Value })
  $tprBitConsts = @($tprAst.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.ConstantExpressionAst] -and
      $n -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $n.Value -is [int] -and $n.Value -eq 0x400 }, $true))
  $tprKindWords = @($tprWords | Where-Object { @('LinkType', 'Target', 'Junction', 'SymbolicLink', 'Symlink') -contains $_ } | Sort-Object -Unique)
  Assert-True ((@($tprWords | Where-Object { $_ -eq 'ReparsePoint' }).Count + $tprBitConsts.Count) -gt 0) `
    'JA-C3 structural: Test-PathHasReparsePoint must read the ReparsePoint FileAttributes bit (kind-agnostic)'
  Assert-True ($tprKindWords.Count -eq 0) `
    ("JA-C3 structural: Test-PathHasReparsePoint must not narrow to a link kind; found: " + ($tprKindWords -join ','))

  # ---- JA-F1（复核 F1）：判不出来必须 fail-closed。不依赖任何夹具，无条件执行 ------------------------
  # 把函数体包进 try { ... } catch { $false } 的「兜底」会把「读不出来」当成「没有联接」放行。含非法字符的路径
  # 在干净产品里由 [IO.Path]::GetFullPath 抛异常；抛异常或返回 true 都算安全，只有静默返回 false 不行。
  $f1Path = 'C:\a|b\x.bin'
  $f1Threw = $false; $f1Got = $null
  try { $f1Got = Test-PathHasReparsePoint $f1Path } catch { $f1Threw = $true }
  Assert-True ($f1Threw -or $f1Got -eq $true) `
    ("JA-F1 [malformed] a path the check cannot evaluate must fail closed (throw or return true), not silently return false: path='" +
     $f1Path + "' threw=" + $f1Threw + " got=" + $f1Got)
  Remove-Item -Path Function:\New-ScanEntry, Function:\Get-ScanKey -Force -ErrorAction SilentlyContinue

  $invalidIdRejected = $false
  try { Write-IpcResult '..\bad' 'Detect' $null 1 'x' } catch { $invalidIdRejected = $true }
  Assert-True $invalidIdRejected 'IPC 只接受标准 GUID'

  # 另一个引擎实例占着全局 mutex 时这里会抛（产品消息是中文）；先打一行 ASCII 标记再原样抛出，
  # 让外部 harness 能可靠识别「mutex 忙、稍后重试」而不是把它算成失败或击杀。
  try { $m1 = Enter-EngineMutex } catch { Write-Output 'ENGINE-MUTEX-BUSY'; throw }
  try {
    $job = Start-Job -ScriptBlock {
      param($Engine)
      . $Engine
      try { $m = Enter-EngineMutex; Exit-EngineMutex $m; 'acquired' } catch { 'locked' }
    } -ArgumentList $engine
    $jobResult = Receive-Job -Job $job -Wait
    Remove-Job -Job $job -Force
    Assert-True ($jobResult -contains 'locked') '核心全局 mutex 必须阻止第二个进程'
  } finally { Exit-EngineMutex $m1 }

  Write-Output 'engine-security-tests: PASS'
} finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
