#requires -Version 5.1
param()

# 本文件含中文，必须带 UTF-8 BOM —— PS 5.1 会把无 BOM 文件按系统 ANSI（这里是 GBK）读。
#
# 上游这套东西叫「优化遥测」，作用是把用户装了哪些优化项上报给服务端。
# 本分支删掉了上报，但保留了同一份上下文的**本地**计算：诊断报告要写清楚
# 「这台机器现在被工具管成什么样」，界面要知道当前处于哪一档。
# 所以这个文件测的是上下文本身，以及「它绝不再产生任何匿名标识」。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
$enginePath = Join-Path $root 'scripts\delta-booster.ps1'
$script:Assertions = 0

function Assert-True([bool]$Condition,[string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}
function Assert-Equal($Expected,$Actual,[string]$Message) {
  $script:Assertions++
  if ("$Expected" -cne "$Actual") { throw "ASSERT: $Message (expected=$Expected actual=$Actual)" }
}

$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($guiPath,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI parse failed: '+(($errors|ForEach-Object Message)-join '; '))
$functions=@{}
foreach($name in 'ConvertTo-TelemetryOptimizationItemIds','Get-TelemetryOptimizationItemSetHash',
  'Get-SelectedTelemetryConfigTier','Get-TelemetryOptimizationContext','Set-TelemetryOptimizationContext',
  'Update-TelemetryOptimizationContextFromCatalog','Write-JsonStateAtomic') {
  $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)|Select-Object -First 1)
  Assert-True ($node.Count -eq 1) "missing GUI function: $name"
  $functions[$name]=$node[0].Extent.Text
}
# Write-JsonStateAtomic 调引擎里的 Write-BytesAtomic。取真函数而不是打桩，
# 否则「确实原子落盘」这件事就没被测到。
$engineAst=[Management.Automation.Language.Parser]::ParseFile($enginePath,[ref]$null,[ref]$null)
$bytesAtomic=@($engineAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-BytesAtomic'},$true)|Select-Object -First 1)
Assert-True ($bytesAtomic.Count -eq 1) 'missing engine function: Write-BytesAtomic'
Invoke-Expression $bytesAtomic[0].Extent.Text

foreach($name in 'ConvertTo-TelemetryOptimizationItemIds','Get-TelemetryOptimizationItemSetHash',
  'Get-SelectedTelemetryConfigTier','Write-JsonStateAtomic','Get-TelemetryOptimizationContext',
  'Set-TelemetryOptimizationContext','Update-TelemetryOptimizationContextFromCatalog') {
  Invoke-Expression $functions[$name]
}

$script:OptimizationContextFileName = 'optimization-context.json'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('dfb-optimization-context-'+[guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $temp -Force|Out-Null
  $script:UserConfigDir=$temp
  $contextPath=Join-Path $temp $script:OptimizationContextFileName

  # 从上游迁过来的用户，文件里可能还带着 Enabled / InstallId / DeviceToken。
  # 这些字段现在应当被无视，而不是让解析失败。
  [IO.File]::WriteAllText($contextPath,(@{
    Enabled=$true;InstallId=[guid]::NewGuid().ToString();CreatedAt=[DateTime]::UtcNow.ToString('o')
    ConfigTier='full';DeviceToken='v1.legacy';TokenExpiresAt=99
  }|ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
  $legacy=Get-TelemetryOptimizationContext
  Assert-Equal 'full' $legacy.ConfigTier 'legacy tier was not preserved'
  Assert-Equal 'legacy-unknown' $legacy.Scheme 'legacy optimization context was misclassified'
  Assert-True (-not $legacy.ItemsComplete) 'legacy item attribution was treated as complete'

  $ids=@('dvr-off','fso-off','game-mode','game-priority','gpu-pref','mpo-off','paging-exec','prio-separation','transparency-off','wer-off')
  Set-TelemetryOptimizationContext -ItemIds $ids -Scheme balanced -ItemsComplete $true
  $context=Get-TelemetryOptimizationContext
  Assert-Equal 'balanced' $context.ConfigTier 'active item count did not determine current tier'
  Assert-Equal 'balanced' $context.Scheme 'local scheme category was not persisted'
  Assert-Equal 10 $context.ItemIds.Count 'active item ids were not persisted'
  Assert-Equal (Get-TelemetryOptimizationItemSetHash $ids) $context.ItemSetHash 'item set hash is not canonical'

  # 【核心】一次写入之后，磁盘上不得再出现任何稳定追踪标识。
  # 上游在 Set 里无条件铸造 InstallId 并把 Enabled 写成 true；本分支必须把它们彻底写没。
  $written=[IO.File]::ReadAllText($contextPath,[Text.Encoding]::UTF8)
  foreach($gone in 'InstallId','DeviceToken','TokenExpiresAt','Enabled'){
    Assert-True (-not $written.Contains($gone)) "optimization context regained a reporting field: $gone"
  }
  $bytes=[IO.File]::ReadAllBytes($contextPath)
  Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'optimization context lost its UTF-8 BOM'

  Update-TelemetryOptimizationContextFromCatalog -Catalog ([pscustomobject]@{
    ActiveItemIds=@('gpu-pref');HasActiveChanges=$true;LegacyBackupCount=0
  }) -RequestedScheme frame-fix -RequestedItemIds @('gpu-pref')
  $frameFix=Get-TelemetryOptimizationContext
  Assert-Equal 'light' $frameFix.ConfigTier 'partial restore/current activity did not lower the tier'
  Assert-Equal 'frame-fix' $frameFix.Scheme 'frame-fix scheme was not attributed'

  Set-TelemetryOptimizationContext -ItemIds @() -Scheme baseline -ItemsComplete $true
  Update-TelemetryOptimizationContextFromCatalog -Catalog ([pscustomobject]@{
    ActiveItemIds=@();HasActiveChanges=$false;LegacyBackupCount=0
  }) -RequestedScheme frame-fix -RequestedItemIds @('gpu-pref') -KnownChangedItemIds @('gpu-pref') -MutationIncomplete
  $backupFailure=Get-TelemetryOptimizationContext
  Assert-Equal 'light' $backupFailure.ConfigTier 'known changed item was lost after backup failure'
  Assert-Equal 'frame-fix' $backupFailure.Scheme 'backup failure lost the known scheme category'
  Assert-True (-not $backupFailure.ItemsComplete) 'backup failure was treated as an exact item set'

  Update-TelemetryOptimizationContextFromCatalog -Catalog ([pscustomobject]@{
    ActiveItemIds=@();HasActiveChanges=$false;LegacyBackupCount=0
  })
  $afterRestart=Get-TelemetryOptimizationContext
  Assert-Equal 'light' $afterRestart.ConfigTier 'empty restore catalog erased an incomplete context on restart'
  Assert-Equal 'gpu-pref' ($afterRestart.ItemIds -join ',') 'known incomplete item was erased on restart'
  Assert-True (-not $afterRestart.ItemsComplete) 'restart promoted incomplete context to baseline'

  # 上下文丢失会自愈：文件删掉后回到 baseline，不抛异常。
  Remove-Item -LiteralPath $contextPath -Force
  $reset=Get-TelemetryOptimizationContext
  Assert-Equal 'baseline' $reset.ConfigTier 'a missing context file did not fall back to baseline'
  Assert-Equal 'baseline' $reset.Scheme 'a missing context file did not fall back to baseline scheme'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------- 上报链路必须整条消失 ----------

$guiRaw=Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
foreach($gone in 'Send-AnonymousTelemetry','New-OptimizationTelemetryOperation','ConvertTo-OptimizationTelemetryIds',
  'Get-TelemetryInstallId','Clear-CompletedTelemetryJobs','TelemetryUploadUrl','TelemetryClientPath',
  'Send-DfbTelemetryEvent','Register-DfbTelemetryDevice'){
  Assert-True (-not $guiRaw.Contains($gone)) "reporting path came back into the GUI: $gone"
}
Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'scripts\telemetry-client.ps1'))) 'the telemetry client script came back'

# 性能采样 worker 仍然记录本地归属字段（诊断报告要用），但不得有上报出口。
$performanceWorker=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:PerformanceCaptureWorker'},$true)|Select-Object -First 1)
Assert-True ($performanceWorker.Count -eq 1) 'performance capture worker is missing'
$workerText=$performanceWorker[0].Extent.Text
foreach($needle in 'optimizationScheme','optimizationItemSetHash','optimizationItemIds','optimizationItemsComplete') {
  Assert-True $workerText.Contains($needle) "local performance attribution is missing $needle"
}
foreach($gone in 'installId','UploadUrl','Send-Dfb') {
  Assert-True (-not $workerText.Contains($gone)) "performance capture worker regained an upload path: $gone"
}

# 还原引擎仍须回传项目归属：上下文是靠它回推的。
$engineRaw=Get-Content -LiteralPath $enginePath -Raw -Encoding UTF8
foreach($needle in 'ActiveItemIds','RestoredItemIds','RebootItemIds','ApplyIds') {
  Assert-True $engineRaw.Contains($needle) "restore engine output is missing $needle"
}

Write-Host "optimization context tests passed: $script:Assertions assertions"
