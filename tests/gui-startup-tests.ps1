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
# StateChanged 处理器会调 Set-ResizeAffordanceVisible，两段测试都要跑它，先在脚本作用域导入
$affordanceFn = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-ResizeAffordanceVisible'
}, $true) | Select-Object -First 1)
Assert-True ($affordanceFn.Count -eq 1) '找不到 Set-ResizeAffordanceVisible'
Invoke-Expression $affordanceFn[0].Extent.Text

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

# ---------------------------------------------------------------------------
#  诊断报告第 1 页的两个「全选」
# ---------------------------------------------------------------------------
#
# 「遇到的问题」有 19 项、「优化后已有改善」有 10 项，原来一个全选入口都没有：
# 想说明情况复杂的用户得点 19 下，而这一页还硬性要求至少勾一项才能继续。
#
# 这一整段都不查源码里有没有那个按钮，而是把对话框那段 XAML 原样解析出来、
# 把**真的接线上去的那个处理器**跑一遍，再读真控件的状态和布局。
$feedbackFn = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'Show-DiagnosticFeedbackDialog'
}, $true) | Select-Object -First 1)
Assert-True ($feedbackFn.Count -eq 1) '找不到诊断反馈对话框'
$feedbackXaml = [regex]::Match($feedbackFn[0].Extent.Text, '(?s)\$fxaml\s*=\s*@''\r?\n(.*?)\r?\n''@')
Assert-True $feedbackXaml.Success '找不到诊断反馈对话框的 XAML'
$feedbackDlgProbe = [Windows.Markup.XamlReader]::Parse($feedbackXaml.Groups[1].Value)

$script:FeedbackIssuePanel = $feedbackDlgProbe.FindName('IssuePanel')
$script:FeedbackBenefitPanel = $feedbackDlgProbe.FindName('BenefitPanel')
$script:FeedbackIssueAllBtn = $feedbackDlgProbe.FindName('IssueAllBtn')
$script:FeedbackBenefitAllBtn = $feedbackDlgProbe.FindName('BenefitAllBtn')
Assert-True ($null -ne $script:FeedbackIssueAllBtn -and $null -ne $script:FeedbackBenefitAllBtn) `
  '诊断反馈对话框的两列没有全选按钮 —— 「遇到的问题」19 项要一项一项点'
# 真代码给这两个按钮套的是主窗口的 Ghost 样式，量布局就得照着套，否则量的是另一个东西
foreach ($feedbackStyled in @($script:FeedbackIssueAllBtn, $script:FeedbackBenefitAllBtn)) {
  $feedbackStyled.Style = $mainXamlWindow.FindResource('Ghost')
}

foreach ($feedbackFnName in 'Test-FeedbackGroupAllChecked', 'Update-FeedbackSelectAllButtons',
                            'Switch-FeedbackGroupSelection') {
  $wantedFeedbackFn = $feedbackFnName
  $feedbackHelper = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wantedFeedbackFn
  }, $true) | Select-Object -First 1)
  Assert-True ($feedbackHelper.Count -eq 1) "找不到函数 $feedbackFnName"
  Invoke-Expression $feedbackHelper[0].Extent.Text
}

# 空组不能算「已全选」：@($null).Count 在 PS 5.1 里是 1，这里判错的话按钮一开始
# 就写着「全不选」，点一下什么也不会发生。
Assert-True (-not (Test-FeedbackGroupAllChecked $script:FeedbackIssuePanel)) `
  '空的选择组被当成了「已全部勾选」'

foreach ($feedbackRowCount in @(@{ Panel=$script:FeedbackIssuePanel; N=19 },
                                @{ Panel=$script:FeedbackBenefitPanel; N=10 })) {
  for ($fi = 0; $fi -lt $feedbackRowCount.N; $fi++) {
    $feedbackRowCount.Panel.Children.Add((New-Object Windows.Controls.CheckBox)) | Out-Null
  }
}
Update-FeedbackSelectAllButtons
Assert-True ("$($script:FeedbackIssueAllBtn.Content)" -eq '全选') '一项没勾时按钮不该写着「全不选」'

# 跑的是**真的挂到按钮上的那个**处理器，不是测试自己写的一份
$feedbackAllClicks = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_Click' -and
  "$($node.Expression)" -like '$script:Feedback*AllBtn'
}, $true))
Assert-True ($feedbackAllClicks.Count -eq 2) `
  "两列的全选按钮只接线了 $($feedbackAllClicks.Count) 个 —— 按钮在屏幕上，点下去没反应"
$feedbackIssueClick = @($feedbackAllClicks | Where-Object {
  "$($_.Expression)" -eq '$script:FeedbackIssueAllBtn' } | Select-Object -First 1)
Assert-True ($feedbackIssueClick.Count -eq 1) '「遇到的问题」那列的全选按钮没有接线'
$feedbackIssueHandler = $feedbackIssueClick[0].Arguments[0].ScriptBlock.GetScriptBlock()

& $feedbackIssueHandler
Assert-True (@($script:FeedbackIssuePanel.Children | Where-Object { $_.IsChecked -eq $true }).Count -eq 19) `
  '点「全选」之后 19 项没有全部勾上'
Assert-True ("$($script:FeedbackIssueAllBtn.Content)" -eq '全不选') `
  '全部勾上之后按钮还写着「全选」—— 用户想一键清空只能一项一项点回去'
# 两组语义完全不同（「我遇到了什么」vs「我获得了什么改善」），一列的全选不能波及另一列
Assert-True (@($script:FeedbackBenefitPanel.Children | Where-Object { $_.IsChecked -eq $true }).Count -eq 0) `
  '「遇到的问题」的全选把「优化后已有改善」也一起勾了 —— 等于替用户声称他获得了全部改善'
Assert-True ("$($script:FeedbackBenefitAllBtn.Content)" -eq '全选') '另一列的按钮文字被带着改了'

& $feedbackIssueHandler
Assert-True (@($script:FeedbackIssuePanel.Children | Where-Object { $_.IsChecked -eq $true }).Count -eq 0) `
  '再点一次没有全部取消 —— 这个按钮必须是开关，不是一次性动作'
Assert-True ("$($script:FeedbackIssueAllBtn.Content)" -eq '全选') '全部取消之后按钮还写着「全不选」'

# 另一列的按钮也得**自己**跑一遍：两个按钮接到同一个面板上，只驱动其中一个是看不出来的
$feedbackBenefitClick = @($feedbackAllClicks | Where-Object {
  "$($_.Expression)" -eq '$script:FeedbackBenefitAllBtn' } | Select-Object -First 1)
Assert-True ($feedbackBenefitClick.Count -eq 1) '「优化后已有改善」那列的全选按钮没有接线'
$feedbackBenefitHandler = $feedbackBenefitClick[0].Arguments[0].ScriptBlock.GetScriptBlock()
& $feedbackBenefitHandler
Assert-True (@($script:FeedbackBenefitPanel.Children | Where-Object { $_.IsChecked -eq $true }).Count -eq 10) `
  '点「优化后已有改善」的全选之后 10 项没有全部勾上'
Assert-True (@($script:FeedbackIssuePanel.Children | Where-Object { $_.IsChecked -eq $true }).Count -eq 0) `
  '「优化后已有改善」的全选把「遇到的问题」也一起勾了 —— 两个按钮接到了同一个面板上'
Assert-True ("$($script:FeedbackBenefitAllBtn.Content)" -eq '全不选' -and
             "$($script:FeedbackIssueAllBtn.Content)" -eq '全选') '两列的按钮文字串了'
& $feedbackBenefitHandler
Assert-True (@($script:FeedbackBenefitPanel.Children | Where-Object { $_.IsChecked -eq $true }).Count -eq 0) `
  '「优化后已有改善」再点一次没有全部取消'

# 手动勾满最后一项时按钮文字也要跟上：代码改 IsChecked 不触发 Click，反过来手点会。
$feedbackRowClick = @($feedbackFn[0].FindAll({
  param($node)
  $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
  "$($node.Member)" -eq 'Add_Click' -and "$($node.Expression)" -eq '$cb'
}, $true) | Select-Object -First 1)
Assert-True ($feedbackRowClick.Count -eq 1) `
  '逐项勾选没有通知全选按钮 —— 手动勾满 19 项之后按钮仍写着「全选」，再点一下反而全清了'
$feedbackRowHandler = $feedbackRowClick[0].Arguments[0].ScriptBlock.GetScriptBlock()
foreach ($feedbackRow in @($script:FeedbackIssuePanel.Children)) { $feedbackRow.IsChecked = $true }
& $feedbackRowHandler
Assert-True ("$($script:FeedbackIssueAllBtn.Content)" -eq '全不选') `
  '手动勾满之后按钮文字没跟上 —— 点下去会全清，和它写的字正好相反'
foreach ($feedbackRow in @($script:FeedbackIssuePanel.Children)) { $feedbackRow.IsChecked = $false }
Update-FeedbackSelectAllButtons

# 列宽：这个对话框是写死的 700 宽、ResizeMode=NoResize，所以量一次就够。
# 标题「优化后已有改善（可多选）」比按钮先占位，挤不下时 WPF 不会报错，只会让两者重叠。
$feedbackDlgContent = $feedbackDlgProbe.Content
$feedbackDlgProbe.Content = $null
foreach ($feedbackLabelState in '全选', '全不选') {
  $script:FeedbackIssueAllBtn.Content = $feedbackLabelState
  $script:FeedbackBenefitAllBtn.Content = $feedbackLabelState
  $feedbackDlgContent.Measure((New-Object Windows.Size 700, 650))
  $feedbackDlgContent.Arrange((New-Object Windows.Rect 0, 0, 700, 650))
  $feedbackDlgContent.UpdateLayout()
  foreach ($feedbackPair in @(
    @{ Btn=$script:FeedbackIssueAllBtn; Title='遇到的问题（可多选）' },
    @{ Btn=$script:FeedbackBenefitAllBtn; Title='优化后已有改善（可多选）' })) {
    $feedbackBtn = $feedbackPair.Btn
    $feedbackTitle = @($feedbackBtn.Parent.Children | Where-Object {
      $_ -is [Windows.Controls.TextBlock] -and "$($_.Text)" -eq $feedbackPair.Title })[0]
    Assert-True ($null -ne $feedbackTitle) "找不到列标题「$($feedbackPair.Title)」"
    # 标题和按钮分属两列，压不到一起；真正剩下的风险是标题被挤成省略号。
    # 拿一个同样字体字号的离屏 TextBlock 量出这行字的自然宽度再比。
    $feedbackRuler = New-Object Windows.Controls.TextBlock
    $feedbackRuler.Text = $feedbackPair.Title
    $feedbackRuler.FontSize = $feedbackTitle.FontSize
    $feedbackRuler.FontWeight = $feedbackTitle.FontWeight
    $feedbackRuler.FontFamily = $feedbackTitle.FontFamily
    $feedbackRuler.Measure((New-Object Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    # 先钉结构：标题和按钮必须各占一列。同在一格时 TextBlock 会拉伸占满整格、
    # 直接压在按钮底下画，而今天这几个字恰好还没长到撞上按钮 —— 也就是说
    # 「有没有被裁」这条查不出来，得量它们各自**分到**的宽度加起来有没有超格。
    $feedbackHeaderGrid = $feedbackBtn.Parent
    $feedbackAllotted = $feedbackTitle.ActualWidth + $feedbackBtn.ActualWidth + $feedbackBtn.Margin.Left
    Assert-True ($feedbackAllotted -le $feedbackHeaderGrid.ActualWidth + 0.5) `
      ("列标题「$($feedbackPair.Title)」和全选按钮挤在同一格里（两者分到 " +
       "$([math]::Round($feedbackAllotted,1))，整格只有 $([math]::Round($feedbackHeaderGrid.ActualWidth,1))）—— " +
       '标题一变长就会直接压在按钮上，WPF 不报错也不截断')
    Assert-True ($feedbackTitle.ActualWidth -ge $feedbackRuler.DesiredSize.Width) `
      ("按钮写「$feedbackLabelState」时把列标题「$($feedbackPair.Title)」挤成了省略号" +
       "（给了 $([math]::Round($feedbackTitle.ActualWidth,1))，这行字要 $([math]::Round($feedbackRuler.DesiredSize.Width,1))）")
    # 按钮宽度是写死的 64，而「全不选」比「全选」宽一个字。24 = Ghost 模板里
    # ContentPresenter 的左右 Margin（12,0），文字能用的只有 64-24。
    $feedbackBtnRuler = New-Object Windows.Controls.TextBlock
    $feedbackBtnRuler.Text = $feedbackLabelState
    $feedbackBtnRuler.FontSize = $feedbackBtn.FontSize
    $feedbackBtnRuler.FontFamily = $feedbackBtn.FontFamily
    $feedbackBtnRuler.Measure((New-Object Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    Assert-True ($feedbackBtn.ActualWidth -ge $feedbackBtnRuler.DesiredSize.Width + 24) `
      ("按钮写「$feedbackLabelState」时它自己的文字被裁掉了" +
       "（宽 $([math]::Round($feedbackBtn.ActualWidth,1))，这三个字加模板留白要 $([math]::Round($feedbackBtnRuler.DesiredSize.Width + 24,1))）")
  }
}

# ---------------------------------------------------------------------------
#  回车必须仍然归「下一步」
# ---------------------------------------------------------------------------
#
# Button 的静态构造把 KeyboardNavigation.AcceptsReturn 设成 True，而鼠标按下时
# ButtonBase 会 Focus() 自己 —— 于是用户点完「全选」，焦点就留在这个按钮上
# （Ghost 样式的 FocusVisualStyle 是 {x:Null}，屏幕上还看不出来）。这一刻
# IsDefault 的「下一步」让位，回车触发的是全选按钮自己，而它是个**开关**：
# 刚勾上的 19 项被这一下回车全部清空，页面纹丝不动。再按一次又全勾上，来回翻，
# 不用鼠标或 Tab 把焦点移走就永远进不了第 2 页。
#
# 这条必须真的把窗口 Show 出来：IsDefaulted 是 WPF 在真实焦点范围内算出来的，
# 不 Show 的窗口没有焦点范围，读出来的值没有意义。
$enterProbeWindow = [Windows.Markup.XamlReader]::Parse($feedbackXaml.Groups[1].Value)
$enterProbeNext = $enterProbeWindow.FindName('NextBtn')
$enterProbeCheck = New-Object Windows.Controls.CheckBox
$enterProbeWindow.FindName('IssuePanel').Children.Add($enterProbeCheck) | Out-Null
$enterProbeWindow.ShowInTaskbar = $false
$enterProbeWindow.Left = -32000
$enterProbeWindow.Top = -32000
$enterProbeWindow.Show()
try {
  $enterProbeWindow.UpdateLayout()
  [void]$enterProbeCheck.Focus()
  $enterProbeWindow.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render)
  Assert-True ($enterProbeNext.IsDefaulted) `
    '基准就不成立：焦点在复选框上时回车都没有归「下一步」—— 这条探针本身坏了'
  foreach ($enterProbeName in 'IssueAllBtn', 'BenefitAllBtn') {
    $enterProbeBtn = $enterProbeWindow.FindName($enterProbeName)
    [void]$enterProbeBtn.Focus()
    $enterProbeWindow.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render)
    Assert-True ($enterProbeNext.IsDefaulted) `
      ("焦点落在 $enterProbeName 上之后回车不再归「下一步」—— 用户点完全选直接按回车，" +
       '刚勾上的整列会被这一下回车清空，而页面不会前进')
    Assert-True ($enterProbeBtn.Focusable) `
      "$enterProbeName 变得不可聚焦了 —— 键盘用户再也 Tab 不到这个按钮"
  }
} finally { $enterProbeWindow.Close() }

# ---------------------------------------------------------------------------
#  Id 列表不能被切出半个 Id
# ---------------------------------------------------------------------------
#
# 单字段上限 256 原来是按**字符**硬切的。19 条症状拼起来 306 字符、全套 32 个
# 优化项 424 字符，都会被切，而切口正好落在某个 Id 中间：报告里那一行结尾变成
# 「...,gpu_heat,no」。少掉的几条还能从上方人眼清单里补回来，凭空多出来的
# 「症状 no」查不出来 —— 它和真 Id 在字面上没有任何区别。
foreach ($idListFn in 'ConvertTo-DiagnosticFieldValue', 'ConvertTo-DiagnosticIdListValue') {
  $wantedIdListFn = $idListFn
  $idListAst = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wantedIdListFn
  }, $true) | Select-Object -First 1)
  Assert-True ($idListAst.Count -eq 1) "找不到函数 $idListFn"
  Invoke-Expression $idListAst[0].Extent.Text
}
$script:DiagnosticFieldMaxLength = 256

# 短列表原样输出，一个字都不能改
$shortIdList = @('input_latency', 'stutter', 'low_fps')
Assert-True ((ConvertTo-DiagnosticIdListValue $shortIdList) -eq ($shortIdList -join ',')) `
  '没超上限的 Id 列表被改动了'
Assert-True ((ConvertTo-DiagnosticIdListValue @()) -eq '') '空列表应该输出空串'

# 造一组必然被切、且切口落在词中间的 Id
$longIdList = @(1..24 | ForEach-Object { 'symptom_number_{0:00}' -f $_ })
$longIdJoined = $longIdList -join ','
Assert-True ($longIdJoined.Length -gt 256) "构造的样本只有 $($longIdJoined.Length) 字符，根本触发不了截断"
$longIdOut = ConvertTo-DiagnosticIdListValue $longIdList
Assert-True ($longIdOut.Length -le 256) "截断之后仍有 $($longIdOut.Length) 字符，超过单字段上限"
$longIdParts = @($longIdOut -split ',')
$longIdMarkers = @($longIdParts | Where-Object { $_.StartsWith('~') })
Assert-True ($longIdMarkers.Count -eq 1) '截断了却没有留下标记 —— 读报告的人无从知道这一行是不完整的'
$longIdReal = @($longIdParts | Where-Object { -not $_.StartsWith('~') })
$longIdBogus = @($longIdReal | Where-Object { @($longIdList) -notcontains $_ })
Assert-True ($longIdBogus.Count -eq 0) `
  ("截断切出了原列表里根本不存在的 Id：$($longIdBogus -join ' / ') —— " +
   '半个 Id 和真 Id 在字面上没有区别，机读这一段的人会当成真的')
Assert-True ($longIdReal.Count -lt $longIdList.Count) '这个样本本来就该丢掉一些，一条没丢说明没走截断分支'
Assert-True ("$($longIdMarkers[0])" -eq "~truncated:$($longIdList.Count - $longIdReal.Count)") `
  "标记里的条数和实际丢掉的对不上：$($longIdMarkers[0])，实际丢了 $($longIdList.Count - $longIdReal.Count) 条"
# 保留的那些必须是**前缀**的完整若干条，不能跳着留
for ($idListI = 0; $idListI -lt $longIdReal.Count; $idListI++) {
  Assert-True ($longIdReal[$idListI] -eq $longIdList[$idListI]) '保留的 Id 不是原列表开头的连续若干条'
}
# 报告里所有 Id 列表字段都必须走这个函数，不能有漏网的
foreach ($idListField in 'feedback_issue_ids', 'feedback_benefit_ids', 'optimization_item_ids',
                         'active_related_process_keys', 'chassis_types', 'display_connectors',
                         'gpu_panel_installed_keys', 'gpu_panel_missing_keys') {
  $idListLine = @($raw -split "`n" | Where-Object { $_.Contains("`"$idListField=") })
  Assert-True ($idListLine.Count -eq 1) "报告里找不到字段 $idListField"
  Assert-True ($idListLine[0].Contains('ConvertTo-DiagnosticIdListValue')) `
    "$idListField 仍按字符硬切 —— 超长时会切出半个 Id"
}

# ---------------------------------------------------------------------------
#  窗口缩放：热区不能压住任何可点控件
# ---------------------------------------------------------------------------
#
# 无边框窗口默认那条可抓带只有 11 物理像素（200% 缩放折合 5.5 逻辑像素），屏幕上
# 又没有任何提示，实际表现就是「这窗口不能改大小」。加宽它本来该用 WM_NCHITTEST，
# 但 PowerShell 脚本块转成委托之后 ref 参数 $handled 到手是个普通 [bool]，赋值直接
# 抛「找不到属性 Value」—— PowerShell 挂的钩子永远接管不了消息。所以改用 WPF 元素
# 占位，按下时把窗口交给系统的缩放拖拽循环。
#
# 代价是这五块透明矩形**盖在真实控件上面**：位置算错一点，边上的按钮就点不动了，
# 而这正是这个项目最高频的故障描述。所以这条在真控件上逐个量。
$resizeZoneNames = @('ResizeLeft', 'ResizeRight', 'ResizeBottom', 'ResizeCornerBL', 'ResizeCornerBR')
function Get-VisualDescendants($Root) {
  $stack = New-Object Collections.Generic.Stack[object]
  $stack.Push($Root)
  while ($stack.Count -gt 0) {
    $node = $stack.Pop()
    $node
    $childCount = [Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
    for ($ci = 0; $ci -lt $childCount; $ci++) {
      $stack.Push([Windows.Media.VisualTreeHelper]::GetChild($node, $ci))
    }
  }
}
# 780 是窗口的 MinWidth，也是最危险的一档：再窄主操作那行就会顶出去
foreach ($resizeWidth in 780, 1100, 1900) {
  $zoneWindow = [Windows.Markup.XamlReader]::Parse($mainXamlMatch.Groups[1].Value)
  $zoneContent = $zoneWindow.Content
  $zoneWindow.Content = $null
  $zoneContent.Measure((New-Object Windows.Size ([double]$resizeWidth), 1000.0))
  $zoneContent.Arrange((New-Object Windows.Rect 0, 0, ([double]$resizeWidth), 1000.0))
  $zoneContent.UpdateLayout()

  $zoneRects = @()
  foreach ($zoneName in $resizeZoneNames) {
    $zoneEl = $zoneWindow.FindName($zoneName)
    Assert-True ($null -ne $zoneEl) "找不到缩放热区 $zoneName"
    Assert-True ($zoneEl.ActualWidth -gt 0 -and $zoneEl.ActualHeight -gt 0) `
      "缩放热区 $zoneName 在 $($resizeWidth)px 下没有被布局出来 —— 抓不到就等于没做"
    $zoneTopLeft = $zoneEl.TransformToAncestor($zoneContent).Transform((New-Object Windows.Point 0, 0))
    $zoneRects += [pscustomobject]@{ Name = $zoneName
      Rect = New-Object Windows.Rect $zoneTopLeft.X, $zoneTopLeft.Y, $zoneEl.ActualWidth, $zoneEl.ActualHeight }
  }
  # 上边缘归系统默认那条窄带：最小化/最大化/关闭三个按钮贴着右边缘（CloseBtn 宽 34、
  # 没有右边距），热区一旦盖到 Row 0 就会把关闭按钮压掉一条。
  foreach ($zoneRect in $zoneRects) {
    Assert-True ($zoneRect.Rect.Y -gt 8) `
      "缩放热区 $($zoneRect.Name) 顶到了标题栏（Y=$([math]::Round($zoneRect.Rect.Y,1))）—— 会把关闭按钮压掉一条"
  }

  $zoneCollisions = New-Object Collections.Generic.List[string]
  foreach ($zoneCandidate in (Get-VisualDescendants $zoneContent)) {
    if ($zoneCandidate -isnot [Windows.Controls.Control]) { continue }
    $zoneClickable = ($zoneCandidate -is [Windows.Controls.Primitives.ButtonBase]) -or
                     ($zoneCandidate -is [Windows.Controls.ComboBox]) -or
                     ($zoneCandidate -is [Windows.Controls.TextBox])
    if (-not $zoneClickable) { continue }
    if (-not $zoneCandidate.IsHitTestVisible) { continue }
    if ($zoneCandidate.ActualWidth -le 0 -or $zoneCandidate.ActualHeight -le 0) { continue }
    $zoneVisible = $true
    $zoneParent = $zoneCandidate
    while ($zoneParent) {
      if (($zoneParent -is [Windows.UIElement]) -and $zoneParent.Visibility -ne 'Visible') { $zoneVisible = $false; break }
      $zoneParent = [Windows.Media.VisualTreeHelper]::GetParent($zoneParent)
    }
    if (-not $zoneVisible) { continue }
    $zoneCandTopLeft = $zoneCandidate.TransformToAncestor($zoneContent).Transform((New-Object Windows.Point 0, 0))
    $zoneCandRect = New-Object Windows.Rect $zoneCandTopLeft.X, $zoneCandTopLeft.Y,
      $zoneCandidate.ActualWidth, $zoneCandidate.ActualHeight
    foreach ($zoneRect in $zoneRects) {
      $zoneHit = [Windows.Rect]::Intersect($zoneCandRect, $zoneRect.Rect)
      if (-not $zoneHit.IsEmpty -and $zoneHit.Width -gt 0.5 -and $zoneHit.Height -gt 0.5) {
        $zoneWho = $(if ($zoneCandidate.Name) { $zoneCandidate.Name } else { $zoneCandidate.GetType().Name })
        [void]$zoneCollisions.Add("$zoneWho 被 $($zoneRect.Name) 压住 $([math]::Round($zoneHit.Width,1))x$([math]::Round($zoneHit.Height,1))px")
      }
    }
  }
  Assert-True ($zoneCollisions.Count -eq 0) `
    ("$($resizeWidth)px 下缩放热区压住了可点控件，这些按钮会点不动：" + ($zoneCollisions -join '；'))
}

# MinWidth 不是随手定的：主操作那行是固定宽度的水平 StackPanel（230+118+132+104+104
# 加四个 9px 间距 = 724），而水平 StackPanel 从不压缩子元素 —— 窗口再窄，「显卡指引」
# 就会被推出去，且 Grid 不裁剪子元素，它会画在窗口外面。
# 这里钉的是「在 MinWidth 下，这一行整个还在窗口里」，不是去对那 29px 边距的账
# （设计宽度 780 比这行需要的 782 少 2px，显卡指引一直吃掉 2px 右边距，是观感问题）。
$mainMinWidth = [double][regex]::Match($mainXamlMatch.Groups[1].Value, 'MinWidth="(\d+)"').Groups[1].Value
Assert-True ($mainMinWidth -gt 0) '主窗口没有设 MinWidth —— 能一直拖到几十像素，整个布局塌掉'
$actionRowWindow = [Windows.Markup.XamlReader]::Parse($mainXamlMatch.Groups[1].Value)
$actionRowContent = $actionRowWindow.Content
$actionRowWindow.Content = $null
$actionRowContent.Measure((New-Object Windows.Size $mainMinWidth, 1000.0))
$actionRowContent.Arrange((New-Object Windows.Rect 0, 0, $mainMinWidth, 1000.0))
$actionRowContent.UpdateLayout()
$guideBtn = $actionRowWindow.FindName('GuideBtn')
Assert-True ($null -ne $guideBtn) '找不到主操作那行最右边的「显卡指引」'
$guideRight = $guideBtn.TransformToAncestor($actionRowContent).Transform(
  (New-Object Windows.Point $guideBtn.ActualWidth, 0)).X
Assert-True ($guideRight -le $mainMinWidth) `
  ("MinWidth=$mainMinWidth 下「显卡指引」的右沿在 $([math]::Round($guideRight,0))，已经在窗口外面 —— " +
   'Grid 不裁剪子元素，这个按钮会被画到窗口之外')

# ---------------------------------------------------------------------------
#  缩放热区的接线
# ---------------------------------------------------------------------------
#
# 五块热区共用一个处理器，边缘代号放在 Tag 上（循环里挂的处理器不能闭包引用循环变量）。
# 代号错了的表现是「往左拖窗口往右长」，比不能拖更让人摸不着头脑。
$resizeEdgeExpect = @{ ResizeLeft = 1; ResizeRight = 2; ResizeBottom = 6; ResizeCornerBL = 7; ResizeCornerBR = 8 }
foreach ($resizeZoneName in $resizeZoneNames) {
  $wantedZone = $resizeZoneName
  $tagAssign = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    "$($node.Left)" -eq "`$ui.$wantedZone.Tag"
  }, $true) | Select-Object -First 1)
  Assert-True ($tagAssign.Count -eq 1) "缩放热区 $resizeZoneName 没有设置边缘代号"
  Assert-True ([int]$tagAssign[0].Right.Extent.Text.Trim() -eq $resizeEdgeExpect[$resizeZoneName]) `
    ("$resizeZoneName 的边缘代号是 $($tagAssign[0].Right.Extent.Text.Trim())，应为 " +
     "$($resizeEdgeExpect[$resizeZoneName]) —— 代号错了会变成「往左拖窗口往右长」")
}

# 处理器真的跑一遍：窗口没 Show 过，Handle 是 IntPtr.Zero，SendMessage 到空句柄直接返回，
# 不会进系统的模态缩放循环把测试挂住。
# 五块必须**逐个显式**接线：写成 foreach $ui.$name 的话，上面那条「每个 $ui.X 都在
# 真控件上执行一次」的自检只能看到字面量 "$resizeZoneName"，这五处等于没被验过。
foreach ($resizeZoneName in $resizeZoneNames) {
  $wantedZoneWire = $resizeZoneName
  $zoneWire = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    "$($node.Member)" -eq 'Add_MouseLeftButtonDown' -and "$($node.Expression)" -eq "`$ui.$wantedZoneWire"
  }, $true) | Select-Object -First 1)
  Assert-True ($zoneWire.Count -eq 1) `
    "缩放热区 $resizeZoneName 没有接线 —— 光标会变成缩放箭头而按下去毫无反应"
}
$resizeHandlerAssign = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
  "$($node.Left)" -eq '$script:ResizeZoneHandler'
}, $true) | Select-Object -First 1)
Assert-True ($resizeHandlerAssign.Count -eq 1) '找不到缩放热区共用的那个处理器'
$resizeHandler = ([scriptblock]::Create($resizeHandlerAssign[0].Right.Extent.Text)).Invoke()[0]
& {
  $window = [Windows.Markup.XamlReader]::Parse($mainXamlMatch.Groups[1].Value)
  function Write-Log([string]$Message) {}
  $resizeProbeZone = $window.FindName('ResizeCornerBR')
  $resizeProbeZone.Tag = 8
  $resizeProbeZone.Add_MouseLeftButtonDown($resizeHandler)
  foreach ($resizeCase in @(
    @{ State = 'Maximized'; Expect = $false; Why = '最大化时窗口不该被拖动缩放，事件必须原样放过' },
    @{ State = 'Normal'; Expect = $true; Why = '普通状态下按住热区没有接管事件 —— 拖不动' })) {
    $window.WindowState = $resizeCase.State
    $resizeArgs = New-Object Windows.Input.MouseButtonEventArgs(
      [Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
    $resizeArgs.RoutedEvent = [Windows.UIElement]::MouseLeftButtonDownEvent
    $resizeProbeZone.RaiseEvent($resizeArgs)
    Assert-True ($resizeArgs.Handled -eq $resizeCase.Expect) $resizeCase.Why
  }
  $window.WindowState = 'Normal'
}

# 最大化之后热区和那个手柄要一起收起来：留着的话光标变成缩放箭头而按下去毫无反应
& {
  $window = $mainXamlWindow
  $ui = @{ MaxBtn = $mainXamlWindow.FindName('MaxBtn') }
  foreach ($resizeVisualName in $resizeZoneNames + @('ResizeGrip')) {
    $ui[$resizeVisualName] = $mainXamlWindow.FindName($resizeVisualName)
  }
  foreach ($affordanceCase in @(
    @{ State = 'Maximized'; Expect = 'Collapsed' }, @{ State = 'Normal'; Expect = 'Visible' })) {
    $window.WindowState = $affordanceCase.State
    & $stateChangedBody
    foreach ($resizeVisualName in $resizeZoneNames + @('ResizeGrip')) {
      Assert-True ("$($ui[$resizeVisualName].Visibility)" -eq $affordanceCase.Expect) `
        ("窗口切到 $($affordanceCase.State) 之后 $resizeVisualName 仍是 $($ui[$resizeVisualName].Visibility) —— " +
         '最大化时留着热区，光标会变成缩放箭头而按下去毫无反应')
    }
  }
  $window.WindowState = 'Normal'
}

# 手柄纯粹是画给人看的：它要是吃掉命中判定，底下那块角落热区就抓不到了
Assert-True (-not $mainXamlWindow.FindName('ResizeGrip').IsHitTestVisible) `
  '缩放手柄吃掉了命中判定 —— 右下角那块热区会抓不到'

# ---------------------------------------------------------------------------
#  旧版用户数据迁移：一条不在清单里的记录不能掀掉整批
# ---------------------------------------------------------------------------
#
# 这条路径**原来一个测试都没有**（21/21 全绿也覆盖不到），而它是升级用户的第一印象。
# 出事的机制：采集端 scripts\user-context-worker.ps1 按固定顺序打包旧文件，而
# Import-ProtectedLegacyState 有自己的一份允许清单 —— 两份清单在两个进程、两个文件里，
# 必然会漂移。原来清单外的条目走的是 throw，于是**第一条**不认识的记录就让整批停摆：
# $imported 停在 0，用户自存的优化方案、性能历史、原始电源方案记录一项都过不来，
# 而失败只写进一个当时根本没有任何地方读的变量，界面一声不吭。
$migrateFn = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
  $node.Name -eq 'Import-ProtectedLegacyState'
}, $true) | Select-Object -First 1)
Assert-True ($migrateFn.Count -eq 1) '找不到 Import-ProtectedLegacyState'

& {
  Invoke-Expression $migrateFn[0].Extent.Text
  # 只桩掉落盘与 ACL 这几件与本条无关的事，判定逻辑用的是产品代码本身
  $script:MigrateWritten = New-Object Collections.Generic.List[string]
  $script:ProtectedUserStateRoot = Join-Path ([IO.Path]::GetTempPath()) ('dfb-mig-' + [guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($script:ProtectedUserStateRoot)
  function New-ProtectedDirectory($Path, $UsersRead) { [void][IO.Directory]::CreateDirectory($Path) }
  function Test-ProtectedDirectoryAclExact($Path, $UsersRead) { $true }
  function Test-PathHasReparsePoint($Path) { $false }
  function Set-ProtectedFileAcl($Path) { }
  function Test-ProtectedFileAcl($Path) { $true }
  function Assert-ExactProperties($Object, $Required, $Optional, $Label) {
    foreach ($r in @($Required)) {
      if (-not $Object.PSObject.Properties[$r]) { throw "$Label 缺少属性 $r" }
    }
  }

  function New-MigrationEntry([string]$Relative, [string]$Content) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $sha = [BitConverter]::ToString(
      ([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes)).Replace('-', '')
    [pscustomobject]@{ RelativePath = $Relative; Length = $bytes.Length
      Sha256 = $sha; ContentBase64 = [Convert]::ToBase64String($bytes) }
  }

  # 采集端的真实顺序：上游遗留的 telemetry.json 排在最前面
  $migratePackage = [pscustomobject]@{
    SchemaVersion = 1
    Skipped = @()
    Files = @(
      (New-MigrationEntry 'config\telemetry.json' '{"installId":"upstream"}'),
      (New-MigrationEntry 'config\disclaimer.json' '{"accepted":true}'),
      (New-MigrationEntry 'config\updater.json' '{"skip":"0.1.0"}'),
      (New-MigrationEntry 'config\performance-sessions.json' '{"sessions":[]}'),
      (New-MigrationEntry 'config\power-scheme.json' '{"guid":"x"}'),
      (New-MigrationEntry 'profiles\我的方案.json' '{"name":"mine"}')
    )
  }
  $migrateResult = Import-ProtectedLegacyState ($migratePackage | ConvertTo-Json -Depth 5 -Compress)

  # 清单外的那一条只该让**它自己**落空，不该带走其余五条
  Assert-True ($migrateResult.Imported -eq 5) `
    ("清单外的一条记录让整批迁移停摆了，只迁进 $($migrateResult.Imported) 项 —— " +
     '升级用户的自存方案、性能历史、原始电源方案记录会一起丢，而他不知道东西还在原处')
  Assert-True ($migrateResult.UnknownSkipped -eq 1) `
    "跳过的条数记成了 $($migrateResult.UnknownSkipped)，应为 1"
  Assert-True (-not (Test-Path (Join-Path $script:ProtectedUserStateRoot 'config\telemetry.json'))) `
    '上游的 telemetry.json 被迁进了受保护目录 —— 它装着上游的稳定追踪标识'
  foreach ($migrateExpect in 'config\disclaimer.json', 'config\updater.json',
                             'config\performance-sessions.json', 'config\power-scheme.json',
                             'profiles\我的方案.json') {
    Assert-True (Test-Path (Join-Path $script:ProtectedUserStateRoot $migrateExpect)) `
      "清单内的 $migrateExpect 没有被迁过来"
  }

  # 哈希格式非法是篡改信号，必须抛，不能跟「不认识的路径」一样被跳过
  $migrateBad = [pscustomobject]@{
    SchemaVersion = 1; Skipped = @()
    Files = @((New-MigrationEntry 'config\updater.json' '{"a":1}'))
  }
  $migrateBad.Files[0].Sha256 = 'not-a-hash'
  $migrateThrew = $false
  try { Import-ProtectedLegacyState ($migrateBad | ConvertTo-Json -Depth 5 -Compress) }
  catch { $migrateThrew = $true }
  Assert-True $migrateThrew '哈希格式非法的迁移记录被放过了 —— 那是篡改信号，不是「不认识的路径」'

  Remove-Item -LiteralPath $script:ProtectedUserStateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 采集端和这里的清单必然会漂移，但**采集端不能再送上游的遥测文件**：
# 它装着上游的稳定追踪标识（InstallId / DeviceToken），迁过来等于让一个本该随遥测
# 一起消失的标识永久留在新安装里。
$workerRaw = [IO.File]::ReadAllText((Join-Path $root 'scripts\user-context-worker.ps1'), [Text.Encoding]::UTF8)
foreach ($workerBanned in 'telemetry.json', 'tuning-telemetry-outbox.json') {
  Assert-True (-not $workerRaw.Contains("Name='$workerBanned'")) `
    "采集端仍在打包 $workerBanned —— 上游的追踪标识会被搬进新安装"
}

# 迁移结果必须真的说给用户听：这个变量原来赋了值却没有任何地方读
$noticeReads = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.VariableExpressionAst] -and
  "$($node.VariablePath)" -eq 'script:LegacyMigrationNotice'
}, $true))
$noticeAssigned = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
  "$($node.Left)" -eq '$script:LegacyMigrationNotice'
}, $true))
Assert-True ($noticeReads.Count -gt $noticeAssigned.Count) `
  '旧版数据迁移的结果只被赋值、从来没被读出来 —— 整批迁移失败时界面一声不吭'

# 这个分支一个字节都不往外发，界面不能说反话。
# 查的是 AST 里的**字符串字面量**，不是全文 —— 全文查会把解释这次修改的注释本身
# 也算进去（本会话已经在这个坑上栽过三次）。
$uploadClaims = @($ast.FindAll({
  param($node)
  ($node -is [Management.Automation.Language.StringConstantExpressionAst] -or
   $node -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
  "$($node.Value)".Contains('匿名上报')
}, $true))
Assert-True ($uploadClaims.Count -eq 0) `
  ("界面上还有 $($uploadClaims.Count) 处「匿名上报」的说法：" +
   (@($uploadClaims | ForEach-Object { "$($_.Value)" }) -join '；') +
   ' —— 本分支把上游那套遥测整个删了，设置页和安装向导都写着「不收集、不上报」，说「已上报」是在骗用户')

Write-Host 'PASS: GUI UAC recovery and WinPS5.1 Generic.List result paths are regression covered'
