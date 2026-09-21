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
    Assert-True (($unitRejected -join '|') -ieq (($expectRejected) -join '|')) `
      ("拒绝集不对：每一层的 reparse point（含文件型、含第二层）都必须进 Rejected。实际=" +
       ($unitRejected -join '；'))
    Assert-True (($unitFiles -join '|') -ieq (($expectFiles) -join '|')) `
      ("Files 不对：跨越 reparse point 的文件一个都不许进，普通目录里的文件一个都不许漏。实际=" +
       ($unitFiles -join '；'))
    foreach ($mustNot in $fakeLink, $fakeDeep) {
      Assert-True (-not (@($script:ScanVisited) -contains (Get-ScanKey $mustNot))) `
        "拒绝 reparse point 之后必须真的停止下探：产品对 $mustNot 发起了目录枚举"
    }
    Assert-True (@($script:ScanVisited) -contains (Get-ScanKey $fakeSub)) `
      '普通子目录必须照常下探 —— 拒绝 reparse point 不得退化成「整棵树都不进」'
    # A2：根本身是 reparse point 时，必须「立即返回」，而不只是「做过判断」
    function Test-PathHasReparsePoint([string]$Path) { $true }
    $script:ScanVisited.Clear()
    $unitRoot = Get-SafeFilesUnderRoot $fakeRoot
    Assert-True (@($unitRoot.Files).Count -eq 0 -and @($unitRoot.Rejected).Count -eq 1 -and
      ((Get-ScanKey @($unitRoot.Rejected)[0]) -ieq (Get-ScanKey $fakeRoot))) `
      '扫描根是 reparse point 时必须整根拒绝且不返回任何文件'
    Assert-True ($script:ScanVisited.Count -eq 0) `
      '扫描根被判定为 reparse point 后必须立即返回，一次目录枚举都不得发生'
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
    Assert-True (Test-PathHasReparsePoint $linkPath) '真实 junction 必须被 reparse point 检测识别'
    Assert-True (-not (Test-PathHasReparsePoint $cacheRoot)) '普通目录不得被判为 reparse point：检测不得退化为恒真'
    $scan = Get-SafeFilesUnderRoot $cacheRoot
    Assert-True (@($scan.Rejected).Count -eq 1 -and
      ([IO.Path]::GetFullPath(@($scan.Rejected)[0]) -ieq [IO.Path]::GetFullPath($linkPath))) `
      '缓存扫描必须把第二层的 junction 列为唯一拒绝项'
    Assert-True (@($scan.Files).Count -eq 1 -and
      ([IO.Path]::GetFullPath(@($scan.Files)[0].FullName) -ieq [IO.Path]::GetFullPath((Join-Path $cacheRoot 'plain.bin')))) `
      '缓存扫描只能收集 junction 之外的本地文件，越界文件一个都不许进 Files'
    $scanLink = Get-SafeFilesUnderRoot $linkPath
    Assert-True (@($scanLink.Files).Count -eq 0 -and @($scanLink.Rejected).Count -eq 1) `
      '直接以 junction 作为扫描根时必须整根拒绝且不返回任何文件'
    Assert-True ((Get-Content -LiteralPath (Join-Path $outside 'keep.bin') -Raw) -eq 'keep') '越界文件不得被修改'
    # 只删 junction 本身、不跟随到目标；这里只能用 finally 之外的收尾，出现 catch 就是回到旧 bug
    [IO.Directory]::Delete($linkPath)
  } else {
    # 注意措辞：Lane A 已经覆盖了行为，这里缺的只是真实文件系统那一层
    Write-Output "SKIP junction(环境造不出 reparse point，Lane A 已覆盖行为)：$junctionSkipReason"
  }
  Remove-Item -Path Function:\New-ScanEntry, Function:\Get-ScanKey -Force -ErrorAction SilentlyContinue

  $invalidIdRejected = $false
  try { Write-IpcResult '..\bad' 'Detect' $null 1 'x' } catch { $invalidIdRejected = $true }
  Assert-True $invalidIdRejected 'IPC 只接受标准 GUID'

  $m1 = Enter-EngineMutex
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
