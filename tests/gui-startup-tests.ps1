#requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
. (Join-Path $root 'scripts\delta-booster.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
  try {
    & $Action
    throw "ASSERT FAILED: $Message"
  } catch {
    if ($_.Exception.Message -like 'ASSERT FAILED:*') { throw }
  }
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI PowerShell AST parse failed: ' + (($errors | ForEach-Object Message) -join '; '))
$raw = [IO.File]::ReadAllText($guiPath, [Text.Encoding]::UTF8)
$referenceRaw = Get-Content -LiteralPath (Join-Path $root 'data\streamer-settings.json') -Raw -Encoding UTF8
$referenceData = $referenceRaw | ConvertFrom-Json

Assert-True ($raw -match '(?s)\$window\.ShowDialog\(\)\s*\|\s*Out-Null\s*#.*?Invoke-AppExit') `
  'normal main-window close does not terminate background runspaces and release the launcher session'
Assert-True ($raw.Contains("`$script:GuiVersion = '0.23.0.13'") -and
    $raw.Contains("`$script:DisplayVersion = '0.23.0.13'") -and
    $raw.Contains('Text="[ v0.23.0.13 ]"')) `
  'the unified v0.23.0.13 version is missing or inconsistent'
# 本分支删掉了服务器下载排队，界面只剩下载相位。这里改成守「排队 UI 确实已经拿掉」，
# 以及下载相位的取消文案仍在。
Assert-True ($raw.Contains("`$script:UpdUi.CancelDlTxt.Text = '取消下载'") -and
    $raw.Contains("'正在取消下载…'") -and
    -not $raw.Contains('QueueEstimatedWaitSeconds') -and
    -not $raw.Contains('正在进入服务器下载队列…') -and
    -not $raw.Contains('"前方 {0} 位 · {1}"')) `
  'download UI still carries the removed server queue, or lost its cancel wording'
Assert-True ($raw.Contains('以下内容请进入BIOS按照教程手动操作。') -and
  -not $raw.Contains('以下问题本工具改不了，但按教程手动处理并不难：')) `
  'health-check BIOS guidance still uses the old wording'
Assert-True (-not $raw.Contains('「立即更新」全程自动：')) 'obsolete inline-update explanation is still shown'
Assert-True $raw.Contains("`$script:UpdUi.InlineNote.Visibility = 'Collapsed'") 'inline-update explanation row is not collapsed'
Assert-True ($raw -match 'Start-Process\s+-FilePath\s+\$PresentMon\s+-WorkingDirectory\s+\(\[Environment\]::SystemDirectory\)') `
  'PresentMon does not use the trusted neutral working directory'
Assert-True ($raw -match 'Start-Process\s+-FilePath\s+\$SetupFile\s+-WorkingDirectory\s+\(\[Environment\]::SystemDirectory\)') `
  'inline setup still inherits the product working directory'
Assert-True ($raw.Contains('Content="导出完整诊断"') -and
  $raw.Contains("`$lines.Add('== 运行环境与显示 / 音频 ==')") -and
  $raw.Contains("`$lines.Add('== 关键环境变量（脱敏） ==')")) `
  'expanded negative-effect diagnostic collection is missing from the report button'
# 「当前问题」那 19 条清单已经搬进引擎的 Get-SymptomCatalog（优化页的症状筛选带与
# 诊断报告共用同一份数据）。这里改成断言**真实数据 + 那条接线**：只查界面源码里
# 的字面量，数据一搬家就会变成假绿——清单可能已经空了，字面量还在别处躺着。
Assert-True ($raw.Contains('function Show-DiagnosticFeedbackDialog') -and
  $raw -match '\$script:DiagnosticIssueChoices\s*=\s*@\(@\(Get-SymptomCatalog\)') `
  'diagnostic feedback dialog no longer derives its problem list from the engine symptom catalog'
$symptomLabels = @{}
foreach ($symptom in @(Get-SymptomCatalog)) { $symptomLabels["$($symptom.Id)"] = "$($symptom.Label)" }
foreach ($expected in @(
  @('frame_drops', '掉帧 / 帧率波动'),
  @('black_screen_audio', '游戏全屏黑屏，但仍有声音'),
  @('black_screen_no_audio', '游戏全屏黑屏，声音也中断'),
  @('partial_black_screen', '游戏内部分区域黑屏 / 黑块'),
  @('black_screen_alt_tab', 'Alt+Tab / 切换显示模式后黑屏'),
  @('black_screen_frame_generation', '开启帧生成后出现黑屏'),
  @('black_screen_external_display', '外接显示器 / 独显直连时黑屏'),
  @('system_lag', '电脑整体卡顿 / 响应慢'),
  @('gpu_heat', 'GPU 占用或温度过高'))) {
  Assert-True ($symptomLabels["$($expected[0])"] -eq "$($expected[1])") `
    "symptom catalog lost the diagnostic feedback choice $($expected[0])"
}
Assert-True ($raw.Contains("Id = 'fps_gain'; Label = '平均帧率提升（涨帧）'") -and
  $raw.Contains("Id = 'one_percent_gain'; Label = '1% Low 提升 / 掉帧减少'")) `
  'diagnostic feedback page is missing required multi-select improvement choices'
# 显卡型号伪装已移除，这里改成反向断言：型号选择器不得回来
Assert-True (-not $raw.Contains('Test-RecommendedGpuSpoofModel') -and
  -not $raw.Contains('$script:SelectedGpuSpoofModel') -and
  -not $raw.Contains('gpu-name-spoof')) `
  'the GPU model spoof selector is back in the GUI'
Assert-True ($raw.Contains("'Local\DeltaForceBooster.GUI'") -and
  -not $raw.Contains("'Global\DeltaForceBooster.GUI'") -and
  $raw.Contains('Title="帧率优化助手" Width="620" Height="640"')) `
  'GUI single-instance scope still crosses Windows sessions or the first-run disclaimer cannot be activated'
Assert-True ($raw.Contains("Get-XmpBiosTutorial `$script:HardwareInfo") -and
  $raw.Contains("New-HwCard 'SYSTEM' `$systemName") -and
  $raw.Contains('电脑：$($hw.ComputerBrand) $($hw.ComputerModel)')) `
  'computer brand is not displayed or the BIOS tutorial is not brand-aware'
Assert-True ($raw.Contains('Get-GpuGuideText $Hw.MainGpuVendor $Hw.MainGpuName $Hw.IsLaptop $Hw')) `
  'GPU guide does not pass detected hardware into the configuration-aware recommendation'
Assert-True ($raw.Contains('x:Name="TabFrameFixBtn" Content="掉帧修复"') -and
  $raw.Contains('x:Name="FrameFixPage"') -and
  $raw.Contains("@('framefix', 'TabFrameFixBtn', 'FrameFixPage')") -and
  $raw.Contains("`$ui.TabFrameFixBtn.Add_Click({ Select-Tab 'framefix' })")) `
  'frame-drop repair tab is not wired into the main navigation'
Assert-True ($raw.Contains('x:Name="TabTuneBtn" Style="{StaticResource TabBtn}" Tag="" IsEnabled="False" Opacity="1"') -and
  $raw.Contains('Text="AI定制优化"') -and
  $raw.Contains('Text="（敬请期待）" Foreground="{DynamicResource Gold}" FontWeight="Bold"') -and
  -not $raw.Contains("`$ui.TabTuneBtn.Add_Click({ Select-Tab 'tune' })")) `
  'AI custom optimization placeholder is not disabled or its coming-soon label is not highlighted'
Assert-True ($raw.Contains('x:Name="FrameFixCacheBtn" Content="清理着色器缓存"') -and
  $raw.Contains('x:Name="FrameFixGpuPrefBtn" Content="设置高性能 GPU"') -and
  $raw.Contains('x:Name="FrameFixVcBtn" Content="检查 VC++ 运行库"') -and
  $raw.Contains("`$ui.FrameFixCacheBtn.Add_Click({ Invoke-FrameFixCacheCleanup })") -and
  $raw.Contains("`$ui.FrameFixGpuPrefBtn.Add_Click({ Invoke-FrameFixGpuPreference })") -and
  $raw.Contains("`$ui.FrameFixVcBtn.Add_Click({ Invoke-FrameFixVcredistCheck })") -and
  $raw.Contains('x:Name="FrameFixProgressPanel"') -and
  $raw.Contains('x:Name="FrameFixProgressBar"') -and
  $raw.Contains('x:Name="FrameFixProgressText"')) `
  'frame-drop page still exposes text-only advice without direct software actions'
# 伪装项已移除，但 risky 分组的基础设施保留（$risky.Count 为 0 时 Expander 自动隐藏），
# 将来新增 risky 项时「全选」必须仍然覆盖它们，且高风险勾选仍走独立的二次确认。
# 主列表表头上那句「高风险项单独列出 · 执行前二次确认」已让位给列标题：同一句话
# RiskyGroup 自己的标题里有，而且只在真有 risky 项时才出现 —— 断言改钉那一处。
# 这条原来查的是「`@($ui.ItemPanel.Children) + @($ui.RiskyPanel.Children)` 这串字在文件里
# 存不存在」—— 而它在文件里出现 **5 次**（Update-Count、全选、套方案、存方案、执行）。
# 把 RiskyPanel 从**全选处理器**里删掉，另外四处还在，断言照样绿。改成 AST 查那个处理器
# 自己的函数体。
$selAllHandler = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_Click' -and "$($node.Expression)" -eq '$ui.SelAllChk'
}, $true) | Select-Object -First 1)
Assert-True ($selAllHandler.Count -eq 1) 'cannot locate the select-all click handler'
Assert-True ($selAllHandler[0].Extent.Text.Contains('$ui.RiskyPanel.Children')) `
  'optimization select-all no longer enumerates the risky group'
$applyHandler = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_Click' -and "$($node.Expression)" -eq '$ui.ApplyBtn'
}, $true) | Select-Object -First 1)
Assert-True ($applyHandler.Count -eq 1) 'cannot locate the apply click handler'
Assert-True ($applyHandler[0].Extent.Text.Contains('$riskyIds = @($ui.RiskyPanel.Children') -and
  $applyHandler[0].Extent.Text.Contains('AllowRisky')) `
  'apply no longer collects risky selections through the separate high-risk confirmation'
Assert-True ($raw.Contains('默认不勾选 · 执行前单独二次确认')) `
  'the risky group header no longer tells the user those items are separate and confirmed'
Assert-True ($raw.Contains("BulkSelect = [bool](-not `$Item.ContainsKey('BulkSelect') -or `$Item.BulkSelect)") -and
  $raw.Contains('$bulkSelect = [bool]($row.DataContext -and $row.DataContext.BulkSelect)') -and
  $raw.Contains('$bulkSelect -and $row.Tag -ne $true')) `
  'optimization select-all ignores the per-item bulk-selection safety boundary'
Assert-True ($raw.Contains("Show-ConfirmDialog '未选择优化项' 'NO ITEMS SELECTED'") -and
  $raw.Contains('请先勾选至少一个优化项目，再点击「执行优化」。')) `
  'execute optimization does not show a visible prompt when no item is selected'
Assert-True ($raw.Contains("`$powerRiskIds = @('power-ultimate','power-tuning','powerplan-lock')") -and
  $raw.Contains("Show-ConfirmDialog '电源计划优化风险确认' 'POWER PLAN RISK'") -and
  $raw.Contains('极少数用户修改后可能出现') -and
  $raw.Contains('游戏无法启动、无法进入或启动后崩溃') -and
  $raw.Contains("'我已了解，继续执行' -DefaultCancel") -and
  $raw.Contains('本次 $($ids.Count) 项优化均未执行')) `
  'power-plan items do not have a consolidated fail-closed compatibility confirmation'
Assert-True ($raw.Contains('[switch]$DefaultCancel') -and
  $raw.Contains("`$script:CfmDlg.FindName('OkBtn').IsDefault = `$false") -and
  $raw.Contains("`$script:CfmDlg.FindName('CancelBtn').IsDefault = `$true")) `
  'risk confirmation cannot make cancel the default action'
Assert-True ($raw.Contains("`$script:PowerRecoveryNoticeId = 'v0.23.0.8-power-plan-recovery'") -and
  $raw.Contains("Join-Path `$script:UserConfigDir 'version-notice-v0.23.0.8.json'") -and
  $raw.Contains('function Test-PowerRecoveryNoticeAcknowledged') -and
  $raw.Contains('function Set-PowerRecoveryNoticeAcknowledged') -and
  $raw.Contains('function Show-PowerRecoveryVersionNotice')) `
  'v0.23.0.8 does not persist the per-user one-time power recovery notice'
# 这条提醒是升级后强制弹一次的，看到它的正是已经出问题的用户。原文案教他们
# 「勾选三个电源项 → 复原所选项目」，而这三项根本不在按项目复原的白名单里，
# 面板上连行都不会出现、按钮因为一个都没勾而禁用——把人指进死路比不提醒更糟。
$powerNoticeFn = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $n.Name -eq 'Show-PowerRecoveryVersionNotice'},$true)|Select-Object -First 1)
Assert-True ($powerNoticeFn.Count -eq 1) 'Show-PowerRecoveryVersionNotice not found'
$powerNoticeText = $powerNoticeFn[0].Extent.Text
Assert-True ($raw.Contains("Show-ConfirmDialog '重要提醒' 'POWER RECOVERY NOTICE'") -and
  $raw.Contains('优化后出现异常：先恢复电源选项并重启电脑') -and
  $powerNoticeText.Contains('点击面板下方的「全部复原」') -and
  -not $powerNoticeText.Contains('勾选你执行过的电源项') -and
  -not $powerNoticeText.Contains('点击「复原所选项目」') -and
  $raw -match '(?s)\$window\.Add_ContentRendered\(\{\s*Show-PowerRecoveryVersionNotice\s*Initialize-LiveMetricsDashboard') `
  'the per-user power recovery notice still walks users into the disabled per-item path'
# Write-JsonStateAtomic 取代了原来来自 telemetry-client.ps1 的原子写；它调 Write-BytesAtomic，
# 那个函数在引擎里，所以从引擎源码里一并取出来，而不是打桩 —— 打桩就测不到真的落盘了。
$engineAst = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $root 'scripts\delta-booster.ps1'), [ref]$null, [ref]$null)
$bytesAtomic = $engineAst.FindAll({
  param($candidate)
  $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq 'Write-BytesAtomic'
}, $true) | Select-Object -First 1
Assert-True ($null -ne $bytesAtomic) 'missing engine function under test: Write-BytesAtomic'
. ([scriptblock]::Create($bytesAtomic.Extent.Text))
foreach ($functionName in 'Write-JsonStateAtomic','Test-PowerRecoveryNoticeAcknowledged','Set-PowerRecoveryNoticeAcknowledged','Show-PowerRecoveryVersionNotice') {
  $node = $ast.FindAll({
    param($candidate)
    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $functionName
  }, $true) | Select-Object -First 1
  Assert-True ($null -ne $node) "missing function under test: $functionName"
  . ([scriptblock]::Create($node.Extent.Text))
}
$noticeTestDir = Join-Path ([IO.Path]::GetTempPath()) ('dfb-power-notice-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $noticeTestDir -Force | Out-Null
try {
  $script:PowerRecoveryNoticeId = 'v0.23.0.8-power-plan-recovery'
  $script:PowerRecoveryNoticeStatePath = Join-Path $noticeTestDir 'notice.json'
  $script:PowerRecoveryNoticePromptedThisRun = $false
  $script:PowerRecoveryNoticePromptCount = 0
  function Show-ConfirmDialog {
    param([string]$ChipText, [string]$EnText, [string]$Message, [string]$OkText,
          [switch]$InfoOnly, [string]$Banner)
    $script:PowerRecoveryNoticePromptCount++
    return $true
  }
  function Write-Log { param([string]$Message) }
  Assert-True (-not (Test-PowerRecoveryNoticeAcknowledged)) 'a missing notice marker was treated as acknowledged'
  Show-PowerRecoveryVersionNotice
  Show-PowerRecoveryVersionNotice
  Assert-True ($script:PowerRecoveryNoticePromptCount -eq 1) 'the power recovery notice repeated in one session'
  Assert-True (Test-PowerRecoveryNoticeAcknowledged) 'acknowledging the power recovery notice did not persist its marker'
  $script:PowerRecoveryNoticePromptedThisRun = $false
  Show-PowerRecoveryVersionNotice
  Assert-True ($script:PowerRecoveryNoticePromptCount -eq 1) 'the power recovery notice repeated after a simulated restart'
} finally {
  Remove-Item -LiteralPath $noticeTestDir -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True ($raw.Contains("`$lines.Add('== 用户反馈选择 ==')") -and
  $raw.Contains('New-DiagnosticReport -Feedback $feedback') -and
  $raw.Contains("if ((`$issueChoices.Count + `$benefitChoices.Count) -eq 0)")) `
  'diagnostic feedback selection is not required and embedded in the uploaded report'
$recommended = @($referenceData.streamers | Where-Object { $_.featured -eq $true })
Assert-True ($recommended.Count -eq 1 -and $referenceData.streamers[0].featured -eq $true) `
  'game settings reference does not expose exactly one featured recommendation as the first column'
Assert-True (-not $recommended[0].platform -and -not $referenceRaw.Contains('本次推荐')) `
  'featured recommendation still shows the redundant small subtitle'
Assert-True (-not $raw.Contains('$meta = New-Text "数据更新：') -and
  -not $raw.Contains('$nt = New-WrapText "备注：$($s.notes)"') -and
  $raw.Contains('$s.captured -and $s.featured -ne $true')) `
  'reference page still shows the removed metadata/note or the recommendation capture date'
$recommendedSettings = $recommended[0].settings
foreach ($expected in @(
  @('显示模式', '全屏（频繁切屏可用无边框）'), @('武器动态模糊', '关闭'),
  @('场景视距', '极高'), @('渲染倍率', '100%'), @('纹理质量', '极高'),
  @('阴影贴图分辨率', '低'), @('DLSS 帧生成', '开启'), @('后台帧数上限', '5')
)) {
  Assert-True ("$($recommendedSettings.PSObject.Properties[$expected[0]].Value)" -eq $expected[1]) `
    "recommended game setting mismatch: $($expected[0])"
}
$referenceSchemaNames = @($referenceData.settings_schema | ForEach-Object { "$($_.name)" })
Assert-True ($referenceSchemaNames -contains '显示适配器' -and
  $referenceSchemaNames -contains 'Intel Xe 低延迟（实验性）') `
  'recommended settings are missing from the displayed reference schema'
Assert-True ($raw.Contains("'★ 推荐设置'") -and $raw.Contains('性能优先推荐 · 设备相关项请按本机调整')) `
  'featured recommendation is not visually distinguished in the game settings page'
$screenshotTerm = -join @([char]0x622A, [char]0x56FE)
Assert-True (-not $raw.Contains($screenshotTerm) -and -not $referenceRaw.Contains($screenshotTerm)) `
  'game settings reference still contains screenshot-related wording'
Assert-True ($raw.Contains('x:Name="InlineRestorePanel"') -and
  -not $raw.Contains('function Show-RestoreManagerDialog') -and
  $raw.Contains('可单选、多选或全选') -and $raw.Contains('全选可复原项目') -and
  $raw.Contains('复原所选项目') -and $raw.Contains('确认全部复原') -and
  $raw.Contains('Invoke-ElevatedEngineAction -Action Restore -ListRestoreItems') -and
  $raw.Contains('Invoke-ElevatedEngineAction -Action Restore -RestoreItemIds')) `
  'optimization page does not expose inline single/multi/select-all plus full restore through the protected engine'
Assert-True ($raw.Contains("'SystemRoot','WINDIR','ProgramData','ProgramFiles','ProgramFiles(x86)','TEMP','TMP','PATH','PSModulePath','COMSPEC','PATHEXT','__COMPAT_LAYER'") -and
  $raw.Contains('（仅记录名称，不记录值）')) `
  'diagnostic environment collection is not value-allowlisted or does not redact injection values'
Assert-True ($raw.Contains("`$lines.Add('== 分析字段（schema v3） ==')") -and
  $raw.Contains('feedback_issue_ids=') -and $raw.Contains('cpu_visible_cores=') -and
  $raw.Contains('memory_configured_mhz=') -and $raw.Contains('virtual_display_count=') -and
  $raw.Contains('gpu_panel_status=') -and $raw.Contains('pagefile_auto_managed=') -and
  $raw.Contains('main_gpu_driver_version=') -and $raw.Contains('main_gpu_model_verified=') -and
  $raw.Contains('main_gpu_pci_matched=') -and $raw.Contains('display_mode=') -and
  $raw.Contains('active_related_process_keys=') -and $raw.Contains('vbs_state=') -and
  $raw.Contains('memory_integrity_state=')) `
  'diagnostic report is missing stable machine-readable recommendation fields'
Assert-True ($raw.Contains('function Get-TelemetryAnalysisContext') -and
  $raw.Contains('function Get-TelemetryRegValue') -and
  $raw.Contains('cpuEfficiencyClasses =') -and $raw.Contains('windowsReleaseChannel =') -and
  $raw.Contains('optimizationItemIds =') -and $raw.Contains('gpuPanelInstalledKeys =') -and
  $raw.Contains('activeSoftwareKeys =') -and $raw.Contains('pendingBackupCount =') -and
  $raw.Contains('systemDriveMediaType =') -and $raw.Contains('gameDriveMediaType =')) `
  'future personalization context is missing required fixed-schema fields'
Assert-True ($raw.Contains("'GamePP'='gamepp'") -and
  $raw.Contains('processCpuAvgPct=') -and $raw.Contains('systemMemoryUsedAvgPct=') -and
  $raw.Contains('gpuDedicatedMemoryAvgMb=') -and $raw.Contains('presentedFrameTimeCvPct=') -and
  $raw.Contains('$physicalIndexByAdapter') -and
  $raw.Contains('$physicalIndexByAdapter[$gameRenderAdapterLuid]') -and
  $raw.Contains('$dedicatedCounters.Count') -and $raw.Contains('$sharedCounters.Count')) `
  'Game++-inspired runtime signals are missing from collection'
Assert-True ($raw.Contains('[math]::Max($gpuDedicatedMb.Count,$gpuSharedMb.Count)')) `
  'partial GPU process-memory counters can still be mislabeled as zero samples'
# 本分支删掉了上报，这条断言改为守「有效性判定本身还在」：session.validity 仍按
# 帧数与失焦时长打标，界面和调优的胜负判定都靠它，不能被简化掉。
Assert-True ($raw.Contains("`$session.frameCount -lt 1000") -and $raw.Contains("`$session.focusLostSec -gt 5") -and
  -not $raw.Contains('if ($session.avgFps -le 0 -and $session.gpuUtilAvg -le 0)')) `
  'performance session validity grading was weakened'
# 采样 worker 不得再有任何上报出口
foreach ($gone in 'Send-DfbTelemetryEvent', '$InstallId', '$UploadUrl', '$TelemetryConfigPath') {
  Assert-True (-not $raw.Contains($gone)) "performance capture worker regained an upload path: $gone"
}

function Find-GuiFunction([string]$Name) {
  $matches = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true))
  Assert-True ($matches.Count -eq 1) "GUI helper missing or duplicated: $Name"
  return $matches[0]
}

$getUacFunction = Find-GuiFunction 'Get-UacEnableLuaValue'
$getFilterFunction = Find-GuiFunction 'Get-UacFilterAdministratorTokenValue'
$sidFunction = Find-GuiFunction 'Test-IsBuiltInAdministratorSid'
$enableUacFunction = Find-GuiFunction 'Enable-UacForNextRestart'
$localNoBackupFunction = Find-GuiFunction 'Invoke-LocalNoBackupItems'
$validatedCandidateFunction = Find-GuiFunction 'Get-ValidatedTuningCandidateRuntime'
$restoreManagerFunction = Find-GuiFunction 'Initialize-InlineRestorePanel'
$restoreActionFunction = Find-GuiFunction 'Invoke-InlineRestoreAction'
$restoreSelectionFunction = Find-GuiFunction 'Update-InlineRestoreSelection'
$hideRestoreFunction = Find-GuiFunction 'Hide-InlineRestorePanel'
$dropFramePlanFunction = Find-GuiFunction 'Get-DropFrameRepairPlan'
$frameCacheFunction = Find-GuiFunction 'Invoke-FrameFixCacheCleanup'
$frameGpuFunction = Find-GuiFunction 'Invoke-FrameFixGpuPreference'
$frameVcFunction = Find-GuiFunction 'Invoke-FrameFixVcredistCheck'
$frameProgressFunction = Find-GuiFunction 'Set-FrameFixProgress'
$commonHighlightFunction = Find-GuiFunction 'Set-DropFrameCommonText'
$vendorLinkFunction = Find-GuiFunction 'Set-DropFrameVendorText'
$updateDropFrameFunction = Find-GuiFunction 'Update-DropFrameRepairPage'
$itemRowFunction = Find-GuiFunction 'New-ItemRow'
$protectReportFunction = Find-GuiFunction 'Protect-ReportText'
$gpuPanelInventoryFunction = Find-GuiFunction 'Get-GuiGpuPanelInventory'
$writeLogFunction = Find-GuiFunction 'Write-Log'
$runLogTailFunction = Find-GuiFunction 'Get-RunLogTail'
$runLogHistoryFunction = Find-GuiFunction 'Get-RecentRunLogHistory'
$runLogInitFunction = Find-GuiFunction 'Initialize-RunLogStore'
$runLogAppendFunction = Find-GuiFunction 'Add-PersistentRunLogLine'
$rebootFunction = Find-GuiFunction 'Invoke-SystemReboot'
$confirmedRebootFunction = Find-GuiFunction 'Start-ConfirmedSystemReboot'
$rebootDialogFunction = Find-GuiFunction 'Show-RebootDialog'

& {
  param([string]$FunctionText)
  $script:OriginalUserLocalAppData = 'C:\Users\Administrator\AppData\Local'
  Invoke-Expression $FunctionText
  $machine = [Environment]::MachineName
  $protected = Protect-ReportText "FilterAdministratorToken=1; C:\Users\Administrator\AppData\Local; user Administrator; pc $machine"
  Assert-True $protected.Contains('FilterAdministratorToken=1') `
    'diagnostic redaction corrupts an identifier containing the original user name'
  Assert-True ($protected.Contains('C:\Users\<user>\AppData\Local') -and
    $protected.Contains('user <user>') -and $protected.Contains('pc <pc>')) `
    'diagnostic redaction does not cover the authenticated original profile and machine token'
} $protectReportFunction.Extent.Text

& {
  param([string]$FunctionText)
  $script:BrokerCalls = New-Object System.Collections.ArrayList
  $script:ReturnInvalidGpuInventory = $false
  function Invoke-EngineHostUserAction([string]$Action, [string]$Payload = '') {
    [void]$script:BrokerCalls.Add([pscustomobject]@{ Action=$Action; Payload=$Payload })
    if ($script:ReturnInvalidGpuInventory) { return '[]' }
    switch ($Action) {
      'GetNvidiaPanelApps' { '[{"Key":"nv-cpl","Installed":true},{"Key":"nv-app","Installed":false}]' }
      'GetAmdPanelApps' { '[{"Key":"amd-sw","Installed":true}]' }
      'GetIntelPanelApps' { '[{"Key":"intel-gcc","Installed":true}]' }
    }
  }
  function Write-Log([string]$Message) { $script:GpuInventoryLog = $Message }
  Invoke-Expression $FunctionText
  $script:RepairOnlySession = $true
  $compatibility = Get-GuiGpuPanelInventory 'NVIDIA'
  $script:RepairOnlySession = $false
  $nvidia = Get-GuiGpuPanelInventory ' nViDiA '
  $amd = Get-GuiGpuPanelInventory 'AMD'
  $intel = Get-GuiGpuPanelInventory 'intel'
  $unknown = Get-GuiGpuPanelInventory 'Unknown'
  Assert-True (($script:BrokerCalls.Action -join ',') -eq 'GetNvidiaPanelApps,GetAmdPanelApps,GetIntelPanelApps') `
    'GPU software detection does not map vendors to fixed broker actions'
  Assert-True (@($script:BrokerCalls | Where-Object Payload).Count -eq 0) `
    'GPU software detection still sends vendor identity as a free-text broker payload'
  Assert-True ($compatibility.Status -eq 'unavailable_in_compatibility_mode' -and
    @($compatibility.Apps).Count -eq 0 -and $nvidia.Status -eq 'ok' -and
    $amd.Status -eq 'ok' -and $intel.Status -eq 'ok' -and
    $unknown.Status -eq 'unsupported_vendor' -and @($unknown.Apps).Count -eq 0) `
    "GPU software inventory status classification is inconsistent: compatibility=$($compatibility.Status), NVIDIA=$($nvidia.Status), AMD=$($amd.Status), Intel=$($intel.Status), unknown=$($unknown.Status), log=$script:GpuInventoryLog"
  $script:ReturnInvalidGpuInventory = $true
  $invalid = Get-GuiGpuPanelInventory 'NVIDIA'
  Assert-True ($invalid.Status -eq 'broker_failed' -and @($invalid.Apps).Count -eq 0) `
    'malformed GPU software inventory is treated as a successful detection'
} $gpuPanelInventoryFunction.Extent.Text
$dropFramePlanText = $dropFramePlanFunction.Extent.Text
Assert-True ($dropFramePlanText.Contains("'NVIDIA'") -and $dropFramePlanText.Contains("'AMD'") -and
  $dropFramePlanText.Contains("'Intel'") -and $dropFramePlanText.Contains('MainGpuVendor') -and
  $dropFramePlanText.Contains('MainGpuName')) `
  'frame-drop repair plan is not generated from the detected primary GPU vendor and model'
$accountTerm = -join @([char]0x8D26, [char]0x53F7)
Assert-True (-not $dropFramePlanText.Contains($accountTerm)) `
  'frame-drop repair plan still includes account-based diagnosis'
. ([scriptblock]::Create($dropFramePlanText))
$nvPlan = Get-DropFrameRepairPlan ([pscustomobject]@{ MainGpuVendor='NVIDIA'; MainGpuName='GeForce RTX 4070' })
$amdPlan = Get-DropFrameRepairPlan ([pscustomobject]@{ MainGpuVendor='AMD'; MainGpuName='Radeon RX 7800 XT' })
$intelPlan = Get-DropFrameRepairPlan ([pscustomobject]@{ MainGpuVendor='Intel'; MainGpuName='Intel Arc B580' })
Assert-True ($nvPlan.VendorTitle -eq 'NVIDIA 专项排查' -and $nvPlan.VendorText.Contains('NVIDIA 控制面板')) `
  'NVIDIA frame-drop recommendation is missing'
Assert-True ($amdPlan.VendorTitle -eq 'AMD Radeon 专项排查' -and $amdPlan.VendorText.Contains('Radeon Anti-Lag')) `
  'AMD frame-drop recommendation is missing'
Assert-True ($intelPlan.VendorTitle -eq 'Intel 显卡专项排查' -and $intelPlan.VendorText.Contains('Resizable BAR')) `
  'Intel frame-drop recommendation is missing'
Assert-True ($nvPlan.Summary.StartsWith('近期版本掉帧') -and -not $nvPlan.Summary.Contains('检测到主力显卡')) `
  'frame-drop summary still repeats the detected primary GPU sentence'
Assert-True ($nvPlan.Common.Contains('【可执行】') -and $nvPlan.Common.Contains('【可检查】') -and
  -not $nvPlan.Common.Contains('【软件可执行】') -and -not $nvPlan.Common.Contains('【软件可检查】')) `
  'frame-drop common plan does not distinguish direct actions from manual advice'
Assert-True ($commonHighlightFunction.Extent.Text.Contains('FrameFixCommonText.Inlines.Clear()') -and
  $commonHighlightFunction.Extent.Text.Contains("`$run.Background") -and
  $commonHighlightFunction.Extent.Text.Contains("`$run.FontWeight = 'Bold'")) `
  'frame-drop direct-action labels are not rendered as highlighted inline runs'
Assert-True ($vendorLinkFunction.Extent.Text.Contains('Windows.Documents.Hyperlink') -and
  $vendorLinkFunction.Extent.Text.Contains('NVIDIA 控制面板') -and
  $vendorLinkFunction.Extent.Text.Contains('NVIDIA App') -and
  $vendorLinkFunction.Extent.Text.Contains('Open-GpuPanel $this.Tag.App') -and
  $vendorLinkFunction.Extent.Text.Contains('Open-HelpLink') -and
  $vendorLinkFunction.Extent.Text.Contains("`$link.Foreground = New-Brush `$script:C.Green") -and
  $updateDropFrameFunction.Extent.Text.Contains('Set-DropFrameVendorText')) `
  'NVIDIA control panel and NVIDIA App names are not highlighted clickable direct links'
Assert-True ($frameCacheFunction.Extent.Text.Contains("Get-FrameFixActionItem 'shader-cache-clean'") -and
  $frameCacheFunction.Extent.Text.Contains('Invoke-LocalNoBackupItems') -and
  $frameGpuFunction.Extent.Text.Contains("-ItemIds @('gpu-pref')") -and
  $frameGpuFunction.Extent.Text.Contains('BackupError') -and
  $frameVcFunction.Extent.Text.Contains("Get-FrameFixActionItem 'vcredist-check'") -and
  $frameVcFunction.Extent.Text.Contains('Show-HealthDialog')) `
  'frame-drop direct actions do not reuse the protected apply/check/cache paths'
Assert-True ($frameProgressFunction.Extent.Text.Contains("IsIndeterminate = `$true") -and
  $frameProgressFunction.Extent.Text.Contains("Value = 100") -and
  $frameCacheFunction.Extent.Text.Contains('Set-FrameFixProgress') -and
  $frameGpuFunction.Extent.Text.Contains('Set-FrameFixProgress') -and
  $frameVcFunction.Extent.Text.Contains('Set-FrameFixProgress')) `
  'one or more frame-drop direct actions do not display start/completion progress'
Assert-True ($itemRowFunction.Extent.Text.Contains("`$Item.Id -eq 'xmp-check'") -and
  $itemRowFunction.Extent.Text.Contains("`$starRun.Text = '★ '") -and
  $itemRowFunction.Extent.Text.Contains('Windows.Thickness 21, 0, 0, 0') -and
  $itemRowFunction.Extent.Text.Contains("`$starRun.Foreground = New-Brush `$nameColor") -and
  $itemRowFunction.Extent.Text.Contains("`$nameRun.Foreground = New-Brush `$nameColor") -and
  $itemRowFunction.Extent.Text.Contains('Add_MouseLeftButtonUp') -and
  $itemRowFunction.Extent.Text.Contains('Show-HealthDialog')) `
  'memory frequency item is not starred and clickable through the existing health dialog'
$restoreManagerText = $restoreManagerFunction.Extent.Text
Assert-True ($restoreManagerText.Contains("`$item.Status -eq 'conflict'") -and
  $restoreManagerText.Contains('旧版本备份') -and $restoreManagerText.Contains('仅支持下方「全部复原」')) `
  'inline restore manager does not explain conflict protection or v2 full-restore-only compatibility'
Assert-True ($restoreActionFunction.Extent.Text.Contains("ValidateSet('selected_items','all')") -and
  $restoreActionFunction.Extent.Text.Contains('Invoke-ElevatedEngineAction -Action Restore -RestoreItemIds $itemIds') -and
  $restoreActionFunction.Extent.Text.Contains('Invoke-ElevatedEngineAction -Action Restore })') -and
  $raw.Contains("`$ui.InlineRestoreSelectedBtn.Add_Click({ Invoke-InlineRestoreAction 'selected_items' })") -and
  $raw.Contains("`$ui.InlineRestoreAllBtn.Add_Click({ Invoke-InlineRestoreAction 'all' })") -and
  $raw.Contains('检测到后续修改的项目不会被选择性覆盖。')) `
  'inline restore buttons are not connected to selected/full protected restore actions'
Assert-True ($restoreActionFunction.Extent.Text.Contains('@($r.RebootItems).Count') -and
  $restoreActionFunction.Extent.Text.Contains('Show-RebootDialog @($r.RebootItems)') -and
  $restoreActionFunction.Extent.Text.Contains('Start-ConfirmedSystemReboot')) `
  'restore completion no longer forwards the engine reboot item names to the confirmation dialog'
Assert-True ($rebootFunction.Extent.Text.Contains("Join-Path ([Environment]::SystemDirectory) 'shutdown.exe'") -and
  $rebootFunction.Extent.Text.Contains('& $shutdownExe /r /t 10') -and
  $rebootFunction.Extent.Text.Contains('$exitCode = $LASTEXITCODE') -and
  $rebootFunction.Extent.Text.Contains('系统未接受重启请求') -and
  -not $rebootFunction.Extent.Text.Contains('Start-Process')) `
  'restart action does not synchronously verify the trusted shutdown.exe exit code'
Assert-True ($confirmedRebootFunction.Extent.Text.Contains('Invoke-SystemReboot | Out-Null') -and
  $confirmedRebootFunction.Extent.Text.Contains("Show-ConfirmDialog '重启未启动'") -and
  $rebootDialogFunction.Extent.Text.Contains('保存好了，立即重启') -and
  $rebootDialogFunction.Extent.Text.Contains('系统将在 10 秒内重启') -and
  -not $raw.Contains("Show-ConfirmDialog '确认重启' 'CONFIRM REBOOT'")) `
  'restart button still uses a hidden second confirmation or silently ignores command failure'
& {
  param([string]$FunctionText)
  $script:RebootCalls = 0
  $script:RebootDialogCalls = 0
  $script:RebootLogs = @()
  $script:RejectReboot = $false
  function Write-Log([string]$Message) { $script:RebootLogs += $Message }
  function Invoke-SystemReboot {
    if ($script:RejectReboot) { throw 'mock shutdown rejected' }
    $script:RebootCalls++
  }
  function Show-ConfirmDialog { $script:RebootDialogCalls++; $true }
  . ([scriptblock]::Create($FunctionText))
  Start-ConfirmedSystemReboot
  Assert-True ($script:RebootCalls -eq 1 -and $script:RebootDialogCalls -eq 0) `
    'confirmed restart does not invoke the restart command directly'
  $script:RejectReboot = $true
  Start-ConfirmedSystemReboot
  Assert-True ($script:RebootDialogCalls -eq 1 -and ($script:RebootLogs -join "`n").Contains('[重启未启动]')) `
    'restart command rejection is not surfaced to the user and run log'
} $confirmedRebootFunction.Extent.Text
# 二态 → 三态：不变式确实变了。旧断言钉的是「失败要说未完成」，而漏掉的那一半是
# 「没失败 ≠ 完成」——14 项全进了安全回退时同样没有失败，用户会关掉窗口以为回到优化前了。
# 所以断言的是三个态都在、且四个信号都参与判定，不是对某个具体字符串。
$restoreActionText = $restoreActionFunction.Extent.Text
Assert-True ($restoreActionText.Contains("'还原未完成'") -and $restoreActionText.Contains("'还原部分完成'") -and
  $restoreActionText.Contains("'还原完成'") -and $restoreActionText.Contains("'RESTORE INCOMPLETE'") -and
  $restoreActionText.Contains("'RESTORE PARTIAL'") -and $restoreActionText.Contains("'RESTORE DONE'") -and
  $restoreActionText.Contains("'全部复原部分完成'")) `
  'full restore dialog lost one of the three states'
foreach ($signal in '$failN', '$skipN', '$bookN', '$unreadableN', '$unrestorableN') {
  Assert-True ($restoreActionText.Contains($signal)) "restore dialog title ignores $signal"
}
Assert-True ($raw.Contains("Join-Path `$script:UserConfigDir 'run-logs'") -and
  $raw.Contains('Initialize-RunLogStore') -and
  $runLogInitFunction.Extent.Text.Contains('New-ProtectedDirectory $script:RunLogDir $false') -and
  $runLogInitFunction.Extent.Text.Contains('Set-ProtectedFileAcl $path') -and
  $runLogInitFunction.Extent.Text.Contains('Select-Object -Skip $script:RunLogRetentionCount') -and
  $runLogHistoryFunction.Extent.Text.Contains('Test-ProtectedFileAcl $file.FullName') -and
  $writeLogFunction.Extent.Text.Contains('Add-PersistentRunLogLine $line') -and
  $raw.Contains('== 本次与最近历史运行日志 ==') -and
  $raw.Contains('关闭软件后仍保留最近运行日志；重新打开可直接复制或导出')) `
  'runtime logs are not retained in the protected per-user store or included after reopening'
& {
  param([string]$TailText, [string]$AppendText)
  . ([scriptblock]::Create($TailText))
  . ([scriptblock]::Create($AppendText))
  $temp = Join-Path ([IO.Path]::GetTempPath()) ('dfb-run-log-test-' + [guid]::NewGuid().ToString('N') + '.log')
  try {
    [IO.File]::WriteAllText($temp, ((1..200 | ForEach-Object { "line-$_" }) -join "`r`n"), [Text.Encoding]::UTF8)
    $tail = Get-RunLogTail $temp 160
    Assert-True ($tail.Contains('较早内容已截断') -and $tail.Contains('line-200') -and -not $tail.Contains('line-1' + "`r`n")) `
      'historical log tailing does not keep the newest bounded content'
    $script:CurrentRunLogPath = $temp
    $script:RunLogMaxFileBytes = 1MB
    Add-PersistentRunLogLine '[12:34:56] persisted-after-close'
    $persisted = [IO.File]::ReadAllText($temp, [Text.Encoding]::UTF8)
    Assert-True $persisted.Contains('[12:34:56] persisted-after-close') `
      'run-log append helper does not persist a completed GUI log line'
  } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
} $runLogTailFunction.Extent.Text $runLogAppendFunction.Extent.Text
$mainXamlMatch = [regex]::Match($raw, '(?s)\$xaml\s*=\s*@''\r?\n(.*?)\r?\n''@\r?\n\r?\n\$window\s*=')
Assert-True $mainXamlMatch.Success 'main window XAML block is missing'
Add-Type -AssemblyName PresentationFramework
$mainXamlWindow = [Windows.Markup.XamlReader]::Parse($mainXamlMatch.Groups[1].Value)
Assert-True ($mainXamlWindow.FindName('InlineRestorePanel') -and
  $mainXamlWindow.FindName('InlineRestoreSelectedBtn') -and $mainXamlWindow.FindName('InlineRestoreAllBtn') -and
  $mainXamlWindow.FindName('InlineRestoreSelectAllBtn') -and $mainXamlWindow.FindName('InlineRestoreClearBtn')) `
  'main optimization page XAML does not parse with all inline restore controls'
$window = $mainXamlWindow
$ui = @{}
foreach ($name in 'InlineRestorePanel','InlineRestoreItemsPanel','InlineRestoreEmptyText',
                   'InlineRestoreLegacyNotice','InlineRestoreLegacyText','InlineRestoreSelectedText','InlineRestoreAllSummary',
                   'InlineRestoreSelectAllBtn','InlineRestoreClearBtn','InlineRestoreSelectedBtn','InlineRestoreAllBtn',
                   'InlineRestoreCloseBtn','RestoreBtn') {
  $ui[$name] = $window.FindName($name)
}
$script:C = @{ LineSoft='#FF16241F'; TextPri='#FFFFFFFF'; TextMut='#FF7A8580'; Green='#FF00E884'; Danger='#FFFF6B6B'; Gold='#FFE5C46A' }
$script:Busy = $false
function New-Brush([string]$Hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }
function Test-TuningExperimentActive { $false }
. ([scriptblock]::Create($restoreSelectionFunction.Extent.Text))
. ([scriptblock]::Create($hideRestoreFunction.Extent.Text))
. ([scriptblock]::Create($restoreManagerFunction.Extent.Text))
$restoreCatalogFixture = [pscustomobject]@{
  Items = @(
    [pscustomobject]@{ Id='gpu-pref'; Name='强制游戏使用高性能 GPU'; CanRestore=$true; SettingCount=1; Status='ready'; StatusText='可精确复原'; RebootRequired=$false; Reason='' },
    [pscustomobject]@{ Id='conflict-item'; Name='后续已修改项目'; CanRestore=$false; SettingCount=1; Status='conflict'; StatusText='检测到后续修改'; RebootRequired=$false; Reason='保持当前值' }
  )
  LegacyBackupCount = 0; UnsupportedV3ItemCount = 0; ActiveItemCount = 2; ActiveOpCount = 2
  ActiveBackupCount = 1; HasActiveChanges = $true
}
Initialize-InlineRestorePanel $restoreCatalogFixture
$readyRestoreCheck = @($script:InlineRestoreChecks.ToArray() | Where-Object Tag -eq 'gpu-pref')[0]
$conflictRestoreCheck = @($script:InlineRestoreChecks.ToArray() | Where-Object Tag -eq 'conflict-item')[0]
Assert-True ($ui.InlineRestorePanel.Visibility -eq 'Visible' -and $ui.InlineRestoreItemsPanel.Children.Count -eq 2 -and
  $readyRestoreCheck.IsEnabled -and -not $conflictRestoreCheck.IsEnabled -and
  -not $ui.InlineRestoreSelectedBtn.IsEnabled -and $ui.InlineRestoreAllBtn.IsEnabled) `
  'inline restore catalog did not render directly in the optimization page with safe enablement'
$readyRestoreCheck.IsChecked = $true
Update-InlineRestoreSelection
Assert-True ($ui.InlineRestoreSelectedText.Text -eq '已选择 1 项' -and $ui.InlineRestoreSelectedBtn.IsEnabled) `
  'inline restore selection does not enable the selected restore action'
Hide-InlineRestorePanel
Assert-True ($ui.InlineRestorePanel.Visibility -eq 'Collapsed' -and $ui.RestoreBtn.Content -eq '还原设置') `
  'inline restore panel does not collapse back into the optimization page'
$repairBranches = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses.Count -gt 0 -and $node.Clauses[0].Item1.Extent.Text.Trim() -eq '$needsUacRepair'
}, $true))
Assert-True ($repairBranches.Count -eq 1) 'disabled-UAC recovery branch missing or duplicated'
$repairText = $repairBranches[0].Extent.Text
$hostAssignments = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -ieq 'Host'
}, $true))
Assert-True ($hostAssignments.Count -eq 0) 'GUI assigns PowerShell built-in read-only $Host variable'
Assert-True ($raw.Contains('$engineHostProcess = Get-CimInstance Win32_Process')) `
  'GUI bootstrap does not store the EngineHost process in a non-reserved variable'

Assert-True $raw.Contains('Test-IsBuiltInAdministratorSid $script:OriginalUserSid') `
  'startup does not identify RID-500 from the authenticated original user SID'
Assert-True (-not $raw.Contains('Test-IsBuiltInAdministratorSid $currentSidValue')) `
  'startup can mistake an OTS approval administrator for the original user'
Assert-True (-not ($raw -match '\$env:(?:USERNAME|USERDOMAIN|COMPUTERNAME)')) `
  'high GUI diagnostics still read the UAC approval account environment'
Assert-True ($raw.Contains('Split-Path -Parent $script:OriginalUserLocalAppData') -and
  $raw.Contains('[Environment]::MachineName')) `
  'diagnostic redaction is not derived from the authenticated original user context'
Assert-True $raw.Contains('if (-not $isAdminGui) { Stop-UntrustedGuiStartup') 'main GUI does not fail closed without an administrator token'
Assert-True $raw.Contains('$enableLUA = Get-UacEnableLuaValue') 'elevated startup does not inspect the real EnableLUA policy'
Assert-True $raw.Contains('$filterAdministratorToken') 'RID-500 startup does not inspect FilterAdministratorToken'
Assert-True $repairText.Contains('[Windows.MessageBoxButton]::YesNoCancel') 'UAC/net-cafe choice is not explicitly confirmed by the user'
Assert-True $repairText.Contains('Enable-UacForNextRestart -EnableBuiltInAdministratorApprovalMode:$isBuiltInAdministrator') 'confirmed recovery does not select the correct ordinary/RID-500 write set'
Assert-True $repairText.Contains('管理员审批模式') 'RID-500 recovery does not explain Administrator Approval Mode'
Assert-True $repairText.Contains('软件不会自动重启') 'UAC recovery does not state that restart timing remains with the user'
Assert-True ($repairText.Contains('$script:NetCafeCompatibilityMode = $true') -and
  $repairText.Contains('【网吧 / 公共电脑】点击「是」') -and
  $repairText.Contains('【个人电脑】点击「否」') -and
  $repairText.Contains('【暂不处理】点击「取消」') -and
  $repairText.Contains('少数辅助功能暂时关闭') -and
  $repairText.Contains("'请选择使用场景'")) `
  'repair-only session does not present the simplified usage-scenario choice'
Assert-True ($repairText -match '(?s)MessageBoxResult\]::No.*Enable-UacForNextRestart.*exit') `
  'policy-repair choice does not exit after persisting restart-required UAC settings'
Assert-True ($repairText -match '(?s)else \{ exit \}\s*\}') `
  'cancelled UAC/net-cafe choice can continue into the GUI'
Assert-True (-not $repairText.Contains('Restart-Computer') -and -not $repairText.Contains('shutdown.exe')) 'UAC recovery must not force a restart'
Assert-True ($raw -match 'NetCafeCompatibilityMode[\s\S]{0,500}Where-Object \{ \$_\.Kind -ne ''cache'' \}') `
  'net-cafe compatibility mode does not remove the medium-token cache action from the UI'

$uacWrites = @($enableUacFunction.FindAll({
  param($node)
  $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-ItemProperty'
}, $true))
Assert-True ($uacWrites.Count -eq 2) 'UAC helper must define only the EnableLUA and conditional FilterAdministratorToken writes'

# PowerShell 对 Generic.List<T> 的直接数组子表达式 `@($list)` 会抛
# System.ArgumentException: Argument types do not match。扫描每个 GUI helper 内的 List 声明，
# 禁止以后再次写回这种会在 Windows PowerShell 5.1 实机上阻断执行收尾的形式。
$genericListWrapFailures = New-Object 'System.Collections.Generic.List[string]'
$guiFunctions = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true))
foreach ($function in $guiFunctions) {
  $listAssignments = @($function.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
      $node.Right.Extent.Text -match '(?i)^\s*New-Object\s+[''"]?(?:System\.)?Collections\.Generic\.List\['
  }, $true))
  foreach ($assignment in $listAssignments) {
    $variableName = $assignment.Left.VariablePath.UserPath
    $directWrapPattern = '^@\(\s*\$' + [regex]::Escape($variableName) + '\s*\)$'
    $badWraps = @($function.FindAll({
      param($node)
      $node -is [Management.Automation.Language.ArrayExpressionAst]
    }, $true) | Where-Object { $_.Extent.Text -match $directWrapPattern })
    foreach ($badWrap in $badWraps) {
      [void]$genericListWrapFailures.Add("$($function.Name):$($badWrap.Extent.StartLineNumber) $($badWrap.Extent.Text)")
    }
  }
}
Assert-True ($genericListWrapFailures.Count -eq 0) `
  ('Generic.List must call ToArray() before @(): ' + ($genericListWrapFailures -join '; '))

# 只执行四个纯 helper，并用同名 mock 拦截注册表访问；测试不得改变测试机的真实 UAC。
$getUacFunctionText = $getUacFunction.Extent.Text
$getFilterFunctionText = $getFilterFunction.Extent.Text
$sidFunctionText = $sidFunction.Extent.Text
$enableUacFunctionText = $enableUacFunction.Extent.Text
& {
  param(
    [string]$GetFunctionText,
    [string]$GetFilterFunctionText,
    [string]$SidFunctionText,
    [string]$EnableFunctionText
  )

  $script:MockUacValues = @{ EnableLUA = 0; FilterAdministratorToken = 0 }
  $script:MockUacReadFailureName = ''
  $script:MockUacWriteFailureName = ''
  $script:MockUacHoldWriteName = ''
  $script:MockUacWrites = New-Object 'System.Collections.Generic.List[object]'
  $script:MockUacReads = New-Object 'System.Collections.Generic.List[string]'

  function Reset-MockUac([int]$EnableLUA = 0, [int]$FilterAdministratorToken = 0) {
    $script:MockUacValues = @{ EnableLUA = $EnableLUA; FilterAdministratorToken = $FilterAdministratorToken }
    $script:MockUacReadFailureName = ''
    $script:MockUacWriteFailureName = ''
    $script:MockUacHoldWriteName = ''
    $script:MockUacWrites.Clear()
    $script:MockUacReads.Clear()
  }

  function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, [object]$ErrorAction)
    [void]$script:MockUacReads.Add($Name)
    if ($script:MockUacReadFailureName -eq $Name) { throw 'simulated registry read failure' }
    if ($Name -eq 'EnableLUA') {
      return [pscustomobject]@{ EnableLUA = $script:MockUacValues.EnableLUA }
    }
    if ($Name -eq 'FilterAdministratorToken') {
      return [pscustomobject]@{ FilterAdministratorToken = $script:MockUacValues.FilterAdministratorToken }
    }
    throw "unexpected registry read: $Name"
  }

  function New-ItemProperty {
    param(
      [string]$LiteralPath,
      [string]$Name,
      [object]$Value,
      [string]$PropertyType,
      [switch]$Force,
      [object]$ErrorAction
    )
    [void]$script:MockUacWrites.Add([pscustomobject]@{
      LiteralPath = $LiteralPath
      Name = $Name
      Value = $Value
      PropertyType = $PropertyType
      Force = [bool]$Force
    })
    if ($script:MockUacWriteFailureName -eq $Name) { throw 'simulated registry write failure' }
    if ($script:MockUacHoldWriteName -ne $Name) { $script:MockUacValues[$Name] = $Value }
  }

  Invoke-Expression $GetFunctionText
  Invoke-Expression $GetFilterFunctionText
  Invoke-Expression $SidFunctionText
  Invoke-Expression $EnableFunctionText

  Assert-True (Test-IsBuiltInAdministratorSid 'S-1-5-21-111-222-333-500') 'RID-500 SID was not identified'
  Assert-True (-not (Test-IsBuiltInAdministratorSid 'S-1-5-21-111-222-333-5000')) 'non-RID-500 SID was misidentified'
  Assert-True (-not (Test-IsBuiltInAdministratorSid '')) 'empty SID was misidentified'

  Reset-MockUac 0 0
  Assert-True ((Get-UacEnableLuaValue) -eq 0) 'EnableLUA=0 was not detected'
  Assert-True ((Get-UacFilterAdministratorTokenValue) -eq 0) 'FilterAdministratorToken=0 was not detected'
  $script:MockUacReadFailureName = 'EnableLUA'
  Assert-True ($null -eq (Get-UacEnableLuaValue)) 'unreadable EnableLUA was guessed instead of returning unknown'
  $script:MockUacReadFailureName = 'FilterAdministratorToken'
  Assert-True ($null -eq (Get-UacFilterAdministratorTokenValue)) 'unreadable FilterAdministratorToken was guessed instead of returning unknown'

  # 普通管理员只写 EnableLUA=1，并复读确认；FilterAdministratorToken 必须保持不变。
  Reset-MockUac 0 0
  Enable-UacForNextRestart
  Assert-True ($script:MockUacWrites.Count -eq 1) 'ordinary administrator recovery wrote more than EnableLUA'
  Assert-True (($script:MockUacReads -join ',') -eq 'EnableLUA') 'ordinary administrator recovery read back values other than EnableLUA'
  $ordinaryWrite = $script:MockUacWrites[0]
  Assert-True ($ordinaryWrite.LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System') 'ordinary UAC writer targeted the wrong registry path'
  Assert-True ($ordinaryWrite.Name -eq 'EnableLUA' -and $ordinaryWrite.Value -eq 1) 'ordinary UAC writer did not write only EnableLUA=1'
  Assert-True ($ordinaryWrite.PropertyType -eq 'DWord' -and $ordinaryWrite.Force) 'ordinary UAC writer did not persist a forced DWORD'
  Assert-True ($script:MockUacValues.FilterAdministratorToken -eq 0) 'ordinary administrator recovery changed FilterAdministratorToken'

  # RID-500 账户还必须开启并复验内置 Administrator 的管理员审批模式。
  Reset-MockUac 0 0
  Enable-UacForNextRestart -EnableBuiltInAdministratorApprovalMode
  Assert-True ($script:MockUacWrites.Count -eq 2) 'RID-500 recovery did not perform exactly two writes'
  Assert-True ((@($script:MockUacWrites | ForEach-Object Name) -join ',') -eq 'FilterAdministratorToken,EnableLUA') 'RID-500 recovery did not write approval mode before enabling UAC'
  Assert-True (($script:MockUacReads -join ',') -eq 'FilterAdministratorToken,EnableLUA') 'RID-500 recovery did not immediately read back each policy in safe order'
  Assert-True (@($script:MockUacWrites | Where-Object { $_.Value -ne 1 -or $_.PropertyType -ne 'DWord' -or -not $_.Force }).Count -eq 0) 'RID-500 recovery did not write both policies as forced DWORD 1'

  # 写入报错和写后读回未生效都必须失败，由启动守卫统一退出。
  Reset-MockUac 0 0
  $script:MockUacWriteFailureName = 'EnableLUA'
  Assert-Throws { Enable-UacForNextRestart } 'ordinary EnableLUA write failure was ignored'
  Reset-MockUac 0 0
  $script:MockUacHoldWriteName = 'EnableLUA'
  Assert-Throws { Enable-UacForNextRestart } 'ordinary EnableLUA readback failure was ignored'
  Reset-MockUac 0 0
  $script:MockUacWriteFailureName = 'FilterAdministratorToken'
  Assert-Throws { Enable-UacForNextRestart -EnableBuiltInAdministratorApprovalMode } 'RID-500 FilterAdministratorToken write failure was ignored'
  Assert-True (($script:MockUacWrites.Count -eq 1) -and $script:MockUacValues.EnableLUA -eq 0) 'RID-500 approval-mode write failure still enabled UAC'
  Reset-MockUac 0 0
  $script:MockUacHoldWriteName = 'FilterAdministratorToken'
  Assert-Throws { Enable-UacForNextRestart -EnableBuiltInAdministratorApprovalMode } 'RID-500 FilterAdministratorToken readback failure was ignored'
  Assert-True (($script:MockUacWrites.Count -eq 1) -and $script:MockUacValues.EnableLUA -eq 0) 'RID-500 approval-mode readback failure still enabled UAC'
  Reset-MockUac 0 0
  $script:MockUacWriteFailureName = 'EnableLUA'
  Assert-Throws { Enable-UacForNextRestart -EnableBuiltInAdministratorApprovalMode } 'RID-500 EnableLUA write failure was ignored after approval-mode success'
  Assert-True ($script:MockUacValues.FilterAdministratorToken -eq 1 -and $script:MockUacValues.EnableLUA -eq 0) 'RID-500 EnableLUA write failure corrupted the safe partial state'
  Reset-MockUac 0 0
  $script:MockUacHoldWriteName = 'EnableLUA'
  Assert-Throws { Enable-UacForNextRestart -EnableBuiltInAdministratorApprovalMode } 'RID-500 EnableLUA readback failure was ignored after approval-mode success'
  Assert-True ($script:MockUacValues.FilterAdministratorToken -eq 1 -and $script:MockUacValues.EnableLUA -eq 0) 'RID-500 EnableLUA readback failure corrupted the safe partial state'

  Remove-Variable MockUacValues,MockUacReadFailureName,MockUacWriteFailureName,MockUacHoldWriteName,MockUacWrites,MockUacReads -Scope Script -ErrorAction SilentlyContinue
} $getUacFunctionText $getFilterFunctionText $sidFunctionText $enableUacFunctionText

$localNoBackupFunctionText = $localNoBackupFunction.Extent.Text
& {
  param([string]$FunctionText)

  function Get-MockHealthyCheck { [pscustomobject]@{ Ok = $true; Text = 'healthy' } }
  function Get-MockAttentionCheck { [pscustomobject]@{ Ok = $false; Text = 'attention' } }
  function Invoke-EngineHostUserAction([string]$Action) {
    if ($Action -ne 'ClearShaderCache') { throw "unexpected broker action: $Action" }
    '{"Cleared":["mock cache cleared"],"Failed":[]}'
  }

  Invoke-Expression $FunctionText
  $items = @(
    [pscustomobject]@{ Id = 'check-ok'; Name = 'check ok'; Kind = 'check'; Check = 'Get-MockHealthyCheck' }
    [pscustomobject]@{ Id = 'check-attention'; Name = 'check attention'; Kind = 'check'; Check = 'Get-MockAttentionCheck' }
    [pscustomobject]@{ Id = 'cache'; Name = 'cache'; Kind = 'cache'; Check = $null }
  )
  $results = @(Invoke-LocalNoBackupItems $items)
  Assert-True ($results.Count -eq 3) 'local no-backup runner did not return every result under Windows PowerShell 5.1'
  Assert-True (($results.Id -join ',') -eq 'check-ok,check-attention,cache') 'local no-backup results changed order or identity'
  Assert-True ($results[0].Ok -and -not $results[0].Attention) 'healthy local check result was misclassified'
  Assert-True (-not $results[1].Ok -and $results[1].Attention) 'attention local check result was misclassified'
  Assert-True ($results[2].Ok -and -not $results[2].Skipped) 'local cache result was misclassified'

  $noItems = @()
  Assert-True (@(Invoke-LocalNoBackupItems $noItems).Count -eq 0) 'empty local no-backup batch did not return an empty result set'
} $localNoBackupFunctionText

$validatedCandidateFunctionText = $validatedCandidateFunction.Extent.Text
& {
  param([string]$FunctionText)

  $previousTargetExe = $script:TargetExe
  try {
    $script:TargetExe = 'C:\Games\DeltaForceClient-Win64-Shipping.exe'
    function Get-TuningCandidate([string]$GroupId) {
      [pscustomobject]@{
        GroupId = $GroupId; Source = 'rules'; RiskLevel = 'low'; RequiresReboot = $false
        ItemIds = @('candidate-a', 'candidate-b')
      }
    }
    function Get-OptItems([string]$GamePath) {
      @(
        [pscustomobject]@{ Id = 'candidate-a'; Tier = 'safe'; Reboot = $false; Kind = 'multi'
          RequiresGame = $false; Ops = @([pscustomobject]@{ Kind = 'reg' }) }
        [pscustomobject]@{ Id = 'candidate-b'; Tier = 'safe'; Reboot = $false; Kind = 'multi'
          RequiresGame = $false; Ops = @([pscustomobject]@{ Kind = 'kvstr' }) }
      )
    }
    function Test-AllowedGameExecutable([string]$GamePath) { $true }

    Invoke-Expression $FunctionText
    $runtime = Get-ValidatedTuningCandidateRuntime 'G1'
    Assert-True (@($runtime.Items).Count -eq 2) 'validated tuning candidate lost Generic.List items under Windows PowerShell 5.1'
    Assert-True (($runtime.Items.Id -join ',') -eq 'candidate-a,candidate-b') 'validated tuning candidate changed item order or identity'
  } finally {
    $script:TargetExe = $previousTargetExe
  }
} $validatedCandidateFunctionText

# ---------------------------------------------------------------------------
#  $ui 绑定完整性：代码引用的每一个控件都必须真的被取出来
# ---------------------------------------------------------------------------
#
# 这条是用一次「软件整个打不开」换来的。
#
# 提交 4af7401 往 XAML 里加了 <Button x:Name="ResidueBtn">，也写了
# `$ui.ResidueBtn.Add_Click({ Show-ToolResidueDialog })`，**但忘了把 'ResidueBtn'
# 加进 $ui 的注册清单**。于是 $ui.ResidueBtn 恒为 $null，那一行在脚本顶层抛
# 「不能对 Null 值表达式调用方法」，而文件头有 $ErrorActionPreference='Stop' ——
# 脚本死在 $window.ShowDialog() 之前，界面一次都没出现过。
#
# 当时的测试是绿的，因为它断言的是 `$guiRaw.Contains('$ui.ResidueBtn.Add_Click')`：
# 只证明了那行**字**存在，没证明那行**能跑**。静态文本断言在这里正好是最坏的一种，
# 它给的是虚假的安心。
#
# 所以这里改成查关系，而不是查字符串：
#   ① 代码里出现的每个 $ui.X，X 必须在注册清单里（否则 $null，调方法即炸）
#   ② 注册清单里的每个名字，XAML 里必须真有这个 x:Name（否则 FindName 返回 $null，同上）
$uiListMatch = [regex]::Match($raw, "(?s)foreach \(\`$n in ('.*?')\) \{\r?\n\s*\`$ui\[\`$n\] = \`$window\.FindName\(\`$n\)")
Assert-True ($uiListMatch.Success) '找不到 $ui 的注册清单（foreach ($n in …) { $ui[$n] = $window.FindName($n) }）'
$uiRegistered = @([regex]::Matches($uiListMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
Assert-True ($uiRegistered.Count -gt 50) "注册清单只解析出 $($uiRegistered.Count) 个名字，正则多半失配了"


$uiReferenced = @([regex]::Matches($raw, '\$ui\.([A-Za-z_][A-Za-z0-9_]*)') |
                  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-True ($uiReferenced.Count -gt 50) "只解析出 $($uiReferenced.Count) 个 `$ui 引用，正则多半失配了"

$uiUnregistered = @($uiReferenced | Where-Object { $uiRegistered -notcontains $_ })
Assert-True ($uiUnregistered.Count -eq 0) `
  ("这些控件被代码用了却没进 `$ui 注册清单，`$ui.X 恒为 `$null —— 只要有一行调它的方法，" +
   "界面就会在 ShowDialog 之前整个死掉：$($uiUnregistered -join '、')")

# 这一半刻意走**真的 FindName**，而不是在 XAML 文本里搜 x:Name：定义在 ControlTemplate
# 内部的名字属于模板的名称作用域，window.FindName 根本找不到它 —— 文本比对会放过这种，
# 真调一次 FindName 不会。
$uiGhost = @($uiRegistered | Where-Object { $null -eq $mainXamlWindow.FindName($_) })
Assert-True ($uiGhost.Count -eq 0) `
  ("注册清单里这些名字 `$window.FindName 取不到（XAML 里没有，或者被定义在 ControlTemplate 的名称作用域里），" +
   "`$ui.X 同样恒为 `$null：$($uiGhost -join '、')")

# 上面那两条是静态关系；这一条**真的把 38 处事件接线在真控件上执行一遍**。
#
# 关系对得上还不够：把 Add_Click 挂到一个 TextBlock 上，名字在清单里、FindName 也取得到，
# 照样在启动时抛「找不到方法」。而这类错误发生在脚本顶层，$ErrorActionPreference='Stop'
# 会让界面在 ShowDialog 之前整个死掉——和 ResidueBtn 那次是同一种死法。
#
# 启动网关（父进程必须是安装根下的 EngineHost.exe + 管理员令牌 + ProgramData 会话临时
# 目录）刻意无法伪造，所以跑不了完整启动；但坏掉的从来不是网关，是网关之后这段接线。
$wiringCalls = @($ast.FindAll({
  param($node)
  if ($node -isnot [Management.Automation.Language.InvokeMemberExpressionAst]) { return $false }
  if ("$($node.Member)" -notlike 'Add_*') { return $false }
  $target = $node.Expression
  ($target -is [Management.Automation.Language.MemberExpressionAst]) -and ("$($target.Expression)" -eq '$ui')
}, $true))
Assert-True ($wiringCalls.Count -gt 30) "只解析出 $($wiringCalls.Count) 处 `$ui 事件接线，AST 匹配多半失配了"

$wiringFailures = New-Object Collections.Generic.List[string]
foreach ($wiringCall in $wiringCalls) {
  $controlName = "$($wiringCall.Expression.Member)"
  $eventName = "$($wiringCall.Member)"
  $control = $mainXamlWindow.FindName($controlName)
  if ($null -eq $control) {
    [void]$wiringFailures.Add("$controlName.$eventName —— `$ui.$controlName 是 `$null")
    continue
  }
  try { $control.$eventName({ }) }
  catch { [void]$wiringFailures.Add("$controlName.$eventName —— $($_.Exception.Message)") }
}
Assert-True ($wiringFailures.Count -eq 0) `
  ("这些事件接线在真控件上执行会抛异常，启动时会让界面在 ShowDialog 之前整个死掉：" +
   ($wiringFailures -join '；'))


# ---------------------------------------------------------------------------
#  忙碌闸门：提权往返期间界面是「活的」
# ---------------------------------------------------------------------------
#
# Invoke-ElevatedEngineAction 等提权子进程时跑的是 DoEvents 轮询，而且用的是
# DispatcherPriority::Background —— 它**低于** Input，所以待处理的鼠标/键盘事件会被
# 派发进来。复核用真 Win32 键盘消息复现过：引擎正在写注册表时，用户能照常点勾选框和
# 「全选」，被取消勾选又与当前症状筛选无关的那一行会当场从屏幕上消失，而它正在被写入。
#
# 所以这里钉三件事，任何一件单独失守都不够安全：
#   ① 整张勾选表在忙碌期间禁用
#   ② 按钮**自己**要有 $script:Busy 闸门（IsEnabled 会被普通刷新函数撤销，
#      而 RaiseEvent 根本不看 IsEnabled）
#   ③ 每一次真实的提权往返都必须被 Set-BusyState 包住 —— 启动那次原来没有
foreach ($busyGuard in 'ItemPanel', 'RiskyPanel', 'SelAllChk', 'SymptomPanel', 'SymptomClearBtn',
                       'SymptomAdviceActions', 'ResidueBtn', 'ApplyBtn', 'RestoreBtn', 'ReportBtn') {
  $busyFn = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-BusyState'
  }, $true) | Select-Object -First 1)
  Assert-True ($busyFn.Count -eq 1) 'cannot locate Set-BusyState'
  Assert-True ($busyFn[0].Extent.Text.Contains("'$busyGuard'")) `
    "Set-BusyState 的禁用清单漏了 $busyGuard —— 执行期间它仍然可点"
}
# chip 是代码手搭的 Border，禁用父面板不会自动改它的外观，Set-BusyState 必须主动刷一遍。
# （外观本身在 symptom-entry-tests 里用真控件验，这里只钉「置忙这条路会走到刷新」。）
$busyStateFn = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-BusyState'
}, $true) | Select-Object -First 1)
$busyChipRefresh = @($busyStateFn[0].FindAll({
  param($node)
  $node -is [Management.Automation.Language.CommandAst] -and
  "$($node.GetCommandName())" -eq 'Set-SymptomChipVisual'
}, $true))
Assert-True ($busyChipRefresh.Count -ge 1) `
  'Set-BusyState 没有刷新症状 chip 的外观 —— 禁用父面板不会改手搭 Border 的一个像素，用户点下去只会觉得卡死了'

$applyClick = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_Click' -and "$($node.Expression)" -eq '$ui.ApplyBtn'
}, $true) | Select-Object -First 1)
Assert-True ($applyClick.Count -eq 1) 'cannot locate the apply click handler'
Assert-True ($applyClick[0].Extent.Text.Contains('if ($script:Busy)')) `
  '「执行优化」按钮自己没有 $script:Busy 闸门 —— 它只靠 IsEnabled，而启动那次提权往返期间它是启用的'
# 钉的是**中止分支**，不是那个变量名：只查变量名的话，把赋值改个名、比较照留，
# 断言仍然绿。
Assert-True ($applyClick[0].Extent.Text.Contains('ApplySelectionSnapshot') -and
  $applyClick[0].Extent.Text.Contains('SELECTION CHANGED')) `
  '「执行优化」没有在置忙之后重新核对勾选并在不一致时中止 —— $ids 是在四个模态确认框之前采的，期间用户可以改勾选'
# 启动块里那次真实提权往返必须被 Set-BusyState 包住
# 锚点必须唯一：'Invoke-ElevatedEngineAction -Action Restore -ListRestoreItems' 在文件里
# 出现 6 次，IndexOf 命中的是第一处（还原面板那条），根本不是启动块。
$startupAnchor = $raw.IndexOf('$startupCatalog = Invoke-ElevatedEngineAction')
Assert-True ($startupAnchor -gt 0) 'cannot locate the startup catalog round-trip'
$startupSection = $raw.Substring($startupAnchor - 900, 1500)
Assert-True ($startupSection.Contains('Set-BusyState $true') -and $startupSection.Contains('finally { Set-BusyState $false }')) `
  '启动时那次提权往返全程 $script:Busy=false —— 所有以 Busy 为闸门的防线在那段时间一起敞开'
# 「预设方案」下拉和方案说明是界面对用户做的一个断言（「你现在勾的就是★主推全套」）。
# 手动改勾选、点「全选」两条路径本来就会把它清掉（注释原话：勾选已不再等于该方案）。
# Update-ItemList 把整张表推倒重建、勾选回到各项默认值，是同一件事的更彻底版本 ——
# 原来唯独它不清，于是下拉继续写着「★ 主推全套」（27 项）、方案说明继续描述它的收益
# 和代价，而实际勾上的只有默认集（17 项），10 项静默消失。
$presetClearFn = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Clear-PresetSelection'
}, $true) | Select-Object -First 1)
Assert-True ($presetClearFn.Count -eq 1) '方案指示器没有统一的失效出口 Clear-PresetSelection'
Assert-True ($presetClearFn[0].Extent.Text.Contains('SelectedIndex = -1') -and
             $presetClearFn[0].Extent.Text.Contains('PresetNote')) `
  'Clear-PresetSelection 没有把下拉和方案说明一起清掉 —— 清一半等于换个地方继续误导'
# 钉的是「三条改勾选的路径都调了它」，不是「文件里出现过这个词」
foreach ($presetClearScope in 'Update-ItemList', 'New-ItemRow') {
  $wantedPresetScope = $presetClearScope
  $presetScopeAst = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wantedPresetScope
  }, $true) | Select-Object -First 1)
  Assert-True ($presetScopeAst.Count -eq 1) "找不到函数 $presetClearScope"
  $presetClearCalls = @($presetScopeAst[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    "$($node.GetCommandName())" -eq 'Clear-PresetSelection'
  }, $true))
  Assert-True ($presetClearCalls.Count -ge 1) `
    "$presetClearScope 改了勾选却没让方案指示器失效 —— 下拉会继续写着一个已经不成立的方案名"
}
$selAllPresetClick = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_Click' -and "$($node.Expression)" -eq '$ui.SelAllChk'
}, $true) | Select-Object -First 1)
Assert-True ($selAllPresetClick.Count -eq 1) 'cannot locate the select-all click handler'
$selAllPresetCalls = @($selAllPresetClick[0].FindAll({
  param($node)
  $node -is [Management.Automation.Language.CommandAst] -and
  "$($node.GetCommandName())" -eq 'Clear-PresetSelection'
}, $true))
Assert-True ($selAllPresetCalls.Count -ge 1) '「全选」改了勾选却没让方案指示器失效'
# 启动时那次自动套用不能被自己清掉：重建整张表的那处必须挡在 $script:ApplyingPreset 后面
$updateItemListAst = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-ItemList'
}, $true) | Select-Object -First 1)
$presetGuardedCall = @($updateItemListAst[0].FindAll({
  param($node)
  $node -is [Management.Automation.Language.IfStatementAst] -and
  $node.Clauses[0].Item1.Extent.Text.Contains('ApplyingPreset') -and
  $node.Extent.Text.Contains('Clear-PresetSelection')
}, $true))
Assert-True ($presetGuardedCall.Count -ge 1) `
  'Update-ItemList 里清方案的那步没有挡在 $script:ApplyingPreset 后面 —— 套用方案本身会重建表，会把刚选中的方案立刻清掉'

# 刷新函数不能把忙碌期的禁用撤销掉
Assert-True ($raw.Contains('$ui.SymptomClearBtn.IsEnabled = ($active.Count -gt 0) -and -not $script:Busy')) `
  'Update-SymptomFilterUi 会在忙碌期把 SymptomClearBtn 重新启用 —— 普通刷新不该能撤销 Set-BusyState'

# 自绘标题栏（WindowStyle="None"）没有系统的最大化按钮，补出来的那个必须同时带上
# 工作区约束：无边框窗口一旦 Maximized，默认会铺满整个屏幕**连任务栏一起盖掉**。
# 这条约束是纯 interop，界面上看不出来，最容易在后续重构里被当成「没人用的代码」删掉。
Assert-True ($raw.Contains('x:Name="MaxBtn"')) '标题栏没有最大化按钮'
Assert-True ($raw.Contains('0x0024')) `
  '最大化没有处理 WM_GETMINMAXINFO —— 最大化后会盖住任务栏'
# 钉**调用点**连同那个 flag，不是钉「MonitorFromWindow 这个词出现过」：
# 只查词的话，把 DllImport 删掉、函数体里的调用留着，断言照样绿。
# 2 = MONITOR_DEFAULTTONEAREST：窗口跨屏时取重叠最多的那台。
Assert-True ($raw.Contains('MonitorFromWindow(hwnd, 2)') -and $raw.Contains('rcWork')) `
  '工作区约束没有按**窗口所在的那台显示器**算 —— 多屏用户在副屏最大化会错位'
Assert-True ($raw.Contains('if ($_.ClickCount -eq 2)')) '双击标题栏不能最大化/还原'
# 图标必须是画出来的 Path：☐(U+2610) 和 ❐(U+2750) 在 Microsoft YaHei UI 里**都没有字形**
# （实测 CharacterToGlyphMap 里两个码位都不存在），靠字体回退两态很可能落到同一个方框上，
# 用户看不出自己在哪个状态。这条不查源码里有没有那两个 Path，而是把 StateChanged
# 处理器**真的跑一遍**再读渲染出来的可见性 —— 写了却 FindName 打错名字，查源码看不出来。
$stateChangedCall = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_StateChanged'
}, $true) | Select-Object -First 1)
Assert-True ($stateChangedCall.Count -eq 1) `
  '最大化后按钮图标不跟着变 —— 用户不知道怎么退出最大化'
$stateChangedBody = $stateChangedCall[0].Arguments[0].ScriptBlock.GetScriptBlock()
& {
  $window = $mainXamlWindow
  $ui = @{ MaxBtn = $mainXamlWindow.FindName('MaxBtn') }
  Assert-True ($null -ne $ui.MaxBtn) '标题栏没有最大化按钮'
  $maximizeGlyph = $window.FindName('MaxGlyphMaximize')
  $restoreGlyph = $window.FindName('MaxGlyphRestore')
  Assert-True ($null -ne $maximizeGlyph -and $null -ne $restoreGlyph) `
    '最大化按钮的两态图标不是画出来的 Path —— ☐/❐ 在微软雅黑里都没有字形，别指望字体回退'
  Assert-True ("$($maximizeGlyph.Data)" -ne "$($restoreGlyph.Data)") `
    '最大化态和还原态画的是同一个图形 —— 用户看不出自己在哪个状态'
  foreach ($glyphCase in @(
    @{ State='Maximized'; Shown=$restoreGlyph; Hidden=$maximizeGlyph; Tip='向下还原' },
    @{ State='Normal'; Shown=$maximizeGlyph; Hidden=$restoreGlyph; Tip='最大化' })) {
    $window.WindowState = $glyphCase.State
    & $stateChangedBody
    Assert-True ($glyphCase.Shown.Visibility -eq 'Visible' -and $glyphCase.Hidden.Visibility -eq 'Collapsed') `
      "窗口切到 $($glyphCase.State) 之后按钮上画的还是另一个状态的图形"
    Assert-True ("$($ui.MaxBtn.ToolTip)" -eq $glyphCase.Tip) `
      "窗口切到 $($glyphCase.State) 之后按钮提示还写着「$($ui.MaxBtn.ToolTip)」"
  }
  $window.WindowState = 'Normal'
}

# 工作区约束必须**成对**夹住 ptMaxSize 和 ptMinTrackSize：WPF 的 MinHeight（XAML 里
# 写死 640）会盖过 ptMaxSize，于是在工作区高度小于 640 的屏幕（1024x600 上网本、
# 竖屏、1366x768 缩放 150%）上，「已最大化」的窗口反而比工作区还高，底部整行主操作
# 按钮掉到屏幕外 —— 而最大化状态下用户没法拖窗口把它拽回来。
# 这条不查源码里有没有那两行 clamp，而是把这段 C# 原样编译出来**真的调一次**：
# 喂一个 ptMinTrackSize = 99999 的 MINMAXINFO 进去，看它出来时有没有被夹到工作区以内。
$chromeSource = [regex]::Match($raw,
  "(?s)Add-Type @'\r?\n(using System;\r?\nusing System\.Runtime\.InteropServices;\r?\npublic static class DfbWindowChrome.*?)\r?\n'@")
Assert-True $chromeSource.Success '找不到自绘标题栏的 interop 源码'
Add-Type -TypeDefinition $chromeSource.Groups[1].Value
# MINMAXINFO = 5 个 POINT：ptReserved 0 / ptMaxSize 8 / ptMaxPosition 16 / ptMinTrackSize 24 / ptMaxTrackSize 32
$mmiBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(40)
try {
  for ($mmiOffset = 0; $mmiOffset -lt 40; $mmiOffset += 4) {
    [Runtime.InteropServices.Marshal]::WriteInt32($mmiBuffer, $mmiOffset, 0)
  }
  # 模拟 WPF 按 XAML 里写死的 MinWidth/MinHeight 填进来的下限
  [Runtime.InteropServices.Marshal]::WriteInt32($mmiBuffer, 24, 99999)
  [Runtime.InteropServices.Marshal]::WriteInt32($mmiBuffer, 28, 99999)
  [DfbWindowChrome]::ApplyWorkArea([IntPtr]::Zero, $mmiBuffer)
  $mmiMaxW = [Runtime.InteropServices.Marshal]::ReadInt32($mmiBuffer, 8)
  $mmiMaxH = [Runtime.InteropServices.Marshal]::ReadInt32($mmiBuffer, 12)
  $mmiMinW = [Runtime.InteropServices.Marshal]::ReadInt32($mmiBuffer, 24)
  $mmiMinH = [Runtime.InteropServices.Marshal]::ReadInt32($mmiBuffer, 28)
  Assert-True ($mmiMaxW -gt 0 -and $mmiMaxH -gt 0) `
    "工作区约束整个没生效（最大尺寸仍是 $mmiMaxW x $mmiMaxH）—— 最大化会盖住任务栏"
  # 夹不住 ptMinTrackSize 的话，WPF 的 MinHeight（XAML 里写死 640）会盖过 ptMaxSize：
  # 工作区高度小于 640 的屏幕（1024x600 上网本、竖屏、1366x768 缩放 150%）上，
  # 「已最大化」的窗口反而比工作区还高，底部整行主操作按钮掉到屏幕外 ——
  # 而最大化状态下用户没法拖窗口把它拽回来。
  Assert-True ($mmiMinW -le $mmiMaxW -and $mmiMinH -le $mmiMaxH) `
    "最小尺寸下限（$mmiMinW x $mmiMinH）没有跟着夹到工作区（$mmiMaxW x $mmiMaxH）以内 —— 小屏上最大化后底部整行按钮会掉到屏幕外"
} finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($mmiBuffer) }

# 最大化状态下拖标题栏：必须**先**还原、**再**按光标位置重放窗口坐标。顺序反了的话
# WindowState 的还原会把刚算好的 Left/Top 一起冲掉，窗口按还原前的旧坐标落回去，
# 光标可能完全不在标题栏上 —— 手感是「窗口被甩走了」。
$titleBarDrag = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_MouseLeftButtonDown' -and "$($node.Expression)" -eq '$ui.TitleBar'
}, $true) | Select-Object -First 1)
Assert-True ($titleBarDrag.Count -eq 1) '找不到标题栏拖拽处理器'
$dragAssignments = @($titleBarDrag[0].FindAll({
  param($node) $node -is [Management.Automation.Language.AssignmentStatementAst]
}, $true))
$dragRestoreState = @($dragAssignments | Where-Object { "$($_.Left)" -eq '$window.WindowState' } |
  Select-Object -First 1)
$dragReplayLeft = @($dragAssignments | Where-Object { "$($_.Left)" -eq '$window.Left' } |
  Select-Object -First 1)
Assert-True ($dragRestoreState.Count -eq 1 -and $dragReplayLeft.Count -eq 1) `
  '最大化状态下拖标题栏没有按光标位置重放窗口坐标 —— 窗口会落回还原前的旧位置，光标够不着标题栏'
Assert-True ($dragReplayLeft[0].Extent.StartOffset -gt $dragRestoreState[0].Extent.EndOffset) `
  '重放窗口坐标排在还原 WindowState 之前 —— 还原会把刚算好的 Left/Top 冲掉，等于没写'
$dragCursor = @($dragAssignments | Where-Object { $_.Right.Extent.Text.Contains('PointToScreen') } |
  Select-Object -First 1)
Assert-True ($dragCursor.Count -eq 1) '重放的坐标不是按光标实际位置算的'
Assert-True ($dragReplayLeft[0].Right.Extent.Text.Contains("$($dragCursor[0].Left)")) `
  '重放的横坐标没有用到光标位置 —— 窗口还是会落到一个和光标无关的地方'

# ---------------------------------------------------------------------------
#  禁用态必须看得出来
# ---------------------------------------------------------------------------
#
# 执行优化/还原期间有近二十个控件被 Set-BusyState 禁用，而 Ghost / Primary / TacCheck
# 三个样式原来**一个都没有** IsEnabled=False 的视觉状态 —— 禁用按钮和能点的长得一模一样，
# 用户点下去毫无反应，读起来就是「软件卡死了」。而「没反应 / 打不开」正是这个项目
# 最高频的故障描述。（TabBtn / TacCombo / MetricHistoryButton 本来就有，
# 调色板里也早就备好了 DisabledText —— 只是没铺到主按钮上。）
#
# 这条不查 XAML 里有没有那段触发器，而是**真的切一次 IsEnabled 再读渲染出来的值**：
# 触发器写了但被 hover 触发器盖掉、或者 TargetName 打错，查源码都看不出来。
$disabledProbeWindow = [Windows.Markup.XamlReader]::Parse($mainXamlMatch.Groups[1].Value)
$disabledProbeContent = $disabledProbeWindow.Content
$disabledProbeWindow.Content = $null
$disabledProbeContent.Measure((New-Object Windows.Size 1200, 1400))
$disabledProbeContent.Arrange((New-Object Windows.Rect 0, 0, 1200, 1400))
$disabledProbeContent.UpdateLayout()

function Get-DisabledProbeOpacity($Control, [string]$PartName) {
  [void]$Control.ApplyTemplate()
  if ($PartName) {
    $part = $Control.Template.FindName($PartName, $Control)
    if ($null -eq $part) { return $null }
    return [double]$part.Opacity
  }
  [double]$Control.Opacity
}

# TacCombo 那条注意：模板里的 IsMouseOver 触发器挂在**内部 ToggleButton** 上，
# 只改它的话淡化的是右边那个箭头，选中项的文字照常是亮的 —— 实测切 IsEnabled
# 前后整个控件 Opacity 恒为 1。所以这里读的是控件自身的 Opacity（Part=''）。
foreach ($disabledProbe in @(
  @{ Name='RefreshBtn'; Style='Ghost'; Part='B' },
  @{ Name='ApplyBtn'; Style='Primary'; Part='Bg' },
  @{ Name='SelAllChk'; Style='TacCheck'; Part='' },
  @{ Name='PresetBox'; Style='TacCombo'; Part='' })) {
  $probeControl = $disabledProbeWindow.FindName($disabledProbe.Name)
  Assert-True ($null -ne $probeControl) "找不到控件 $($disabledProbe.Name)"
  $probeControl.IsEnabled = $true
  $disabledProbeContent.UpdateLayout()
  $enabledOpacity = Get-DisabledProbeOpacity $probeControl $disabledProbe.Part
  Assert-True ($null -ne $enabledOpacity) "$($disabledProbe.Style) 模板里找不到部件 $($disabledProbe.Part)"
  $probeControl.IsEnabled = $false
  $disabledProbeContent.UpdateLayout()
  $disabledOpacity = Get-DisabledProbeOpacity $probeControl $disabledProbe.Part
  Assert-True ($disabledOpacity -lt $enabledOpacity) `
    ("$($disabledProbe.Style) 样式的禁用态和启用态长得一模一样（$disabledOpacity vs $enabledOpacity）—— " +
     '执行期间用户会以为软件卡死了')
  $probeControl.IsEnabled = $true
}

Write-Host 'PASS: GUI UAC recovery and WinPS5.1 Generic.List result paths are regression covered'
