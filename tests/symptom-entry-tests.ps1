#requires -Version 5.1
param()

# 按症状入口（P0-3）的回归网。
#
# 这一整块是**纯呈现层**：不写系统、不碰备份、不经过提权。所以这里守的不是安全边界，
# 而是三件会让用户被误导的事：
#   1. 症状指向一个不存在的优化项 —— 那条症状会静默地筛不出东西，看起来像「本工具
#      治不了」，实际只是拼错了一个字。
#   2. 某个优化项没有被任何症状覆盖 —— 它在按症状找功能的人眼里等于不存在。
#   3. **筛选把一个已勾选的项藏起来** —— 这条最严重：「执行优化」会去写用户在屏幕上
#      看不见的设置。可见性不变式就是为它存在的。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
. (Join-Path $root 'scripts\delta-booster.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:Assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
  $script:Assertions++
  if (-not $Condition) { throw "ASSERT: $Message" }
}

# ---------- 1. 症状目录本身 ----------

$catalog = @(Get-SymptomCatalog)
Assert-True ($catalog.Count -eq 19) "症状目录应有 19 条，实际 $($catalog.Count)"
Assert-True (@(Get-SymptomCatalogFaults $null).Count -eq 0) `
  "症状目录自检不干净：$((Get-SymptomCatalogFaults $null) -join '；')"

$optList = @(Get-OptItems $null)
$knownItemIds = @{}
foreach ($optItem in $optList) { $knownItemIds["$($optItem.Id)"] = $true }

$seenSymptomIds = @{}
foreach ($symptom in $catalog) {
  Assert-True (-not $seenSymptomIds.ContainsKey("$($symptom.Id)")) "症状 Id 重复：$($symptom.Id)"
  $seenSymptomIds["$($symptom.Id)"] = $true
  Assert-True ("$($symptom.Label)" -ne '') "症状缺少标签：$($symptom.Id)"
  Assert-True ("$($symptom.Note)" -ne '') "症状缺少说明：$($symptom.Id)"
  # 一条既没有优化项、也没有去处的症状，点下去只会得到一张空列表
  Assert-True ((@($symptom.Items).Count + @($symptom.Pages).Count) -gt 0) `
    "症状 $($symptom.Id) 既没有优化项也没有去处，等于一条死路"
  foreach ($itemId in @($symptom.Items)) {
    Assert-True ($knownItemIds.ContainsKey("$itemId")) `
      "症状 $($symptom.Id) 指向不存在的优化项 $itemId —— 这条症状会静默地筛不出任何东西"
  }
  foreach ($page in @($symptom.Pages)) {
    Assert-True ($script:SymptomPageLabels.Contains("$page")) "症状 $($symptom.Id) 指向未知页面：$page"
  }
}

# 每个优化项至少能被一条症状找到：按症状找功能的人看不见没被覆盖的项
$coveredItemIds = @{}
foreach ($symptom in $catalog) { foreach ($itemId in @($symptom.Items)) { $coveredItemIds["$itemId"] = $true } }
$uncovered = @($optList | Where-Object { -not $coveredItemIds.ContainsKey("$($_.Id)") } | ForEach-Object { "$($_.Id)" })
Assert-True ($uncovered.Count -eq 0) "以下优化项没有被任何症状覆盖，按症状检索时等于不存在：$($uncovered -join '、')"

# 反向索引与正向目录必须一致
foreach ($symptom in $catalog) {
  foreach ($itemId in @($symptom.Items)) {
    Assert-True ((@(Get-SymptomIdsForItem $itemId)) -contains "$($symptom.Id)") `
      "反向索引漏了 $itemId → $($symptom.Id)"
  }
}
Assert-True (@(Get-SymptomIdsForItem '不存在的项目').Count -eq 0) '反向索引对未知项目应返回空集'

# 升温/耗电三条症状必须**没有**优化项：本工具的电源类项目全是往更高功耗走的，
# 把它们列在「温度过高」下面等于推荐用户去做让症状更重的事
foreach ($heatSymptomId in 'cpu_heat','gpu_heat','noise_power') {
  $heatSymptom = @($catalog | Where-Object { $_.Id -eq $heatSymptomId })[0]
  Assert-True ($null -ne $heatSymptom) "缺少症状 $heatSymptomId"
  Assert-True (@($heatSymptom.Items).Count -eq 0) `
    "$heatSymptomId 不该推荐任何优化项：电源类优化本身就是用更高功耗换性能"
  Assert-True (@($heatSymptom.Pages) -contains 'restore') `
    "$heatSymptomId 必须指向复原入口 —— 高温如果是执行优化之后出现的，唯一的处置就是撤回"
}

# ---------- 2. 每一项的「现在 → 执行后 → 重启」 ----------

foreach ($optItem in $optList) {
  Assert-True ("$($optItem.Effect)" -ne '') "优化项 $($optItem.Id) 没有说明执行后会变成什么"
  if ($optItem.Kind -eq 'check') {
    # 对一个什么都不写的体检项说「执行后……」是假话
    Assert-True ("$($optItem.Effect)".StartsWith('本项只读：')) `
      "体检项 $($optItem.Id) 的说明必须以「本项只读：」开头，不能写成「执行后」"
    Assert-True (-not $optItem.Reboot) "体检项 $($optItem.Id) 不该标记需要重启"
  } else {
    Assert-True ("$($optItem.Effect)".StartsWith('执行后：')) `
      "写入项 $($optItem.Id) 的说明必须以「执行后：」开头"
  }
}
# Reboot 是结构化字段（Note 文案会改，字段不会漂）；界面的重启列读的就是它
Assert-True (@($optList | Where-Object { $_.Reboot }).Count -ge 5) `
  'Reboot 字段像是被清空了：一个需要重启的优化项都没有'
Assert-True (@($optList | Where-Object { $_.Kind -eq 'check' }).Count -ge 3) '体检项不见了'

# ---------- 3. 目录自检确实会响 ----------

$originalCatalog = $script:SymptomCatalog
try {
  $script:SymptomCatalog = @(
    [ordered]@{ Id = 'x'; Label = 'X'; Items = @('根本没有这个项目'); Pages = @(); Note = 'n' }
  )
  Assert-True (@(Get-SymptomCatalogFaults $null).Count -gt 0) '指向不存在的优化项时自检必须报错'

  $script:SymptomCatalog = @([ordered]@{ Id = 'x'; Label = 'X'; Items = @('hags'); Pages = @('没这个页'); Note = 'n' })
  Assert-True (@(Get-SymptomCatalogFaults $null).Count -gt 0) '指向未知页面时自检必须报错'

  $script:SymptomCatalog = @([ordered]@{ Id = 'x'; Label = 'X'; Items = @(); Pages = @(); Note = 'n' })
  Assert-True (@(Get-SymptomCatalogFaults $null).Count -gt 0) '既无优化项也无去处的症状必须被报出来'

  $script:SymptomCatalog = @(
    [ordered]@{ Id = 'x'; Label = 'X'; Items = @('hags'); Pages = @(); Note = 'n' }
    [ordered]@{ Id = 'x'; Label = 'Y'; Items = @('hags'); Pages = @(); Note = 'n' }
  )
  Assert-True (@(Get-SymptomCatalogFaults $null).Count -gt 0) '重复的症状 Id 必须被报出来'

  $script:SymptomCatalog = @([ordered]@{ Id = 'x'; Label = 'X'; Items = @('hags','hags'); Pages = @(); Note = 'n' })
  Assert-True (@(Get-SymptomCatalogFaults $null).Count -gt 0) '同一条症状重复列出同一个优化项必须被报出来'

  $script:SymptomCatalog = @([ordered]@{ Id = 'x'; Label = ''; Items = @('hags'); Pages = @(); Note = 'n' })
  Assert-True (@(Get-SymptomCatalogFaults $null).Count -gt 0) '缺少标签的症状必须被报出来'
} finally {
  $script:SymptomCatalog = $originalCatalog
}
Assert-True (@(Get-SymptomCatalogFaults $null).Count -eq 0) '目录恢复后自检应重新变干净'

# ---------- 4. 界面：真跑筛选逻辑 ----------

$guiRaw = [IO.File]::ReadAllText($guiPath, [Text.Encoding]::UTF8)
$guiErrors = $null
$guiAst = [Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$null, [ref]$guiErrors)
Assert-True (@($guiErrors).Count -eq 0) 'GUI 脚本解析失败'

function Import-GuiFunction([string]$Name) {
  $wanted = $Name
  $found = @($guiAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wanted
  }, $true) | Select-Object -First 1)
  if ($found.Count -ne 1) { throw "ASSERT: 界面里找不到函数 $Name" }
  $found[0].Extent.Text
}

& {
  $script:C = @{
    Panel='#FF0E1B17';PanelDeep='#FF0B1713';Line='#FF1B2E28';LineSoft='#FF16241F';LineHi='#FF2C443B'
    TextPri='#FFFFFFFF';TextSec='#FF9AA5A0';TextMut='#FF7A8580';Gray='#FF7A8580'
    Green='#FF00E884';GreenDark='#FF04241B';Gold='#FFE5C46A';GoldDark='#FF3A2C0C';AccentPanel='#FF0E2A21'
  }
  function New-Brush([string]$Hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }
  $script:LogLines = New-Object Collections.Generic.List[string]
  function Write-Log([string]$Message) { [void]$script:LogLines.Add("$Message") }
  $script:TargetExe = $null
  $script:CheckHelp = @{}
  function Show-HealthDialog($Entries) {}
  function Select-Tab([string]$Tab) { [void]$script:LogLines.Add("TAB:$Tab") }
  function Show-ToolResidueDialog { [void]$script:LogLines.Add('RESIDUE') }
  $window = New-Object psobject
  $window | Add-Member -MemberType ScriptMethod -Name FindResource -Value { param($Key) $null }

  foreach ($functionName in 'New-Text','New-Pill','Get-ItemRowTooltip','New-ItemRow',
                            'Get-SymptomById','Set-SymptomChipVisual','Initialize-SymptomFilterPanel',
                            'Switch-SymptomFilter','Clear-SymptomFilter','Update-SymptomRowVisibility',
                            'Invoke-SymptomPageAction','Update-SymptomFilterUi','Update-Count') {
    Invoke-Expression (Import-GuiFunction $functionName)
  }

  $ui = @{
    ItemPanel = New-Object Windows.Controls.StackPanel
    RiskyPanel = New-Object Windows.Controls.StackPanel
    RiskyGroup = New-Object Windows.Controls.Expander
    CountText = New-Object Windows.Controls.TextBlock
    SelAllChk = New-Object Windows.Controls.CheckBox
    SymptomPanel = New-Object Windows.Controls.WrapPanel
    SymptomSummary = New-Object Windows.Controls.TextBlock
    SymptomClearBtn = New-Object Windows.Controls.Button
    SymptomAdviceBox = New-Object Windows.Controls.Border
    SymptomAdviceText = New-Object Windows.Controls.TextBlock
    SymptomAdviceActions = New-Object Windows.Controls.WrapPanel
    SymptomEmptyText = New-Object Windows.Controls.TextBlock
    PresetBox = $null
    InlineRestorePanel = New-Object Windows.Controls.Border
    RestoreBtn = New-Object Windows.Controls.Button
    ReportBtn = New-Object Windows.Controls.Button
  }
  $script:ActiveSymptomIds = @()
  $script:SymptomChips = @{}

  # ---- 4a. 行的结构：四列 / 共享列宽 / 悬浮完整状态 / 重启列 / 只读徽标 ----
  $hagsItem = @($optList | Where-Object { $_.Id -eq 'hags' })[0]
  $hagsRow = New-ItemRow $hagsItem @{ Optimized = $false; Current = 'HwSchMode=1；另一条=2' } $false
  $grid = $hagsRow.Child
  Assert-True ($grid.ColumnDefinitions.Count -eq 4) '行不是四列（优化项/当前状态/重启/优化状态），表头就无从对齐'
  Assert-True ("$($grid.ColumnDefinitions[2].SharedSizeGroup)" -eq 'ItemRebootCol' -and
               "$($grid.ColumnDefinitions[3].SharedSizeGroup)" -eq 'ItemStatusCol') `
    '后两列没有走 SharedSizeGroup —— 每行各算各的宽度，表头会标到别的列上'
  Assert-True ($grid.Children[0] -is [Windows.Controls.CheckBox]) '行的第一个子元素必须仍是勾选框（全选/套方案/执行都按下标 0 取它）'
  $hagsDetail = @($grid.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and $_.FontFamily.Source -eq 'Consolas' -and "$($_.Text)" -like 'HwSchMode*' })[0]
  Assert-True ($null -ne $hagsDetail) '找不到当前状态列'
  Assert-True ($hagsDetail.TextTrimming -eq 'CharacterEllipsis') '当前状态列没有省略号截断'
  Assert-True ("$($hagsDetail.ToolTip)" -eq "HwSchMode=1`n另一条=2") `
    '当前状态被截断后没有悬浮出完整的多行内容 —— 这正是社区那条 issue 的原话'
  $hagsReboot = @($grid.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and "$($_.Text)" -eq '需重启' })[0]
  Assert-True ($null -ne $hagsReboot) 'hags 需要重启，重启列却没有标出来'
  $hagsTooltip = "$($grid.Children[0].ToolTip)"
  foreach ($needle in '现在：','执行后：','重启：') {
    Assert-True ($hagsTooltip.Contains($needle)) "行提示缺少「$needle」这一句"
  }
  Assert-True ($hagsTooltip.Contains('HwSchMode=1')) '行提示没有说出当前状态'
  Assert-True ($hagsRow.DataContext.OffFilterMark.Visibility -eq 'Collapsed') '「不在筛选内」标记默认就不该出现'

  $checkItem = @($optList | Where-Object { $_.Id -eq 'vcredist-check' })[0]
  $checkRow = New-ItemRow $checkItem @{ Optimized = $true; Current = '已安装' } $false
  $checkPills = @($checkRow.Child.Children | Where-Object { $_ -is [Windows.Controls.StackPanel] })[0]
  $checkTexts = @($checkPills.Children | Where-Object { $_ -is [Windows.Controls.Border] } | ForEach-Object { "$($_.Child.Text)" })
  Assert-True ($checkTexts -contains '只读') `
    '体检项没有「只读」徽标 —— 「纯检测，不改设置」原来只是手写在项名里的字，项名一改就没了'
  $checkTooltip = "$($checkRow.Child.Children[0].ToolTip)"
  Assert-True (-not $checkTooltip.Contains('重启：')) '体检项不写系统，不该谈重启'
  Assert-True ($checkTooltip.Contains('本项只读：')) '体检项的行提示没说清它只读'

  # ---- 4b. 筛选带 ----
  Initialize-SymptomFilterPanel
  Assert-True ($ui.SymptomPanel.Children.Count -eq 19) "筛选带应有 19 个症状，实际 $($ui.SymptomPanel.Children.Count)"
  Assert-True (@($script:LogLines | Where-Object { $_ -like '*[症状目录]*' }).Count -eq 0) '真实目录不该产生自检告警'

  # 造一批行喂给筛选：每行的结构与 New-ItemRow 一致
  $ui.ItemPanel.Children.Clear()
  foreach ($rowItem in @($optList | Where-Object { $_.Id -in @('hags','mouse-accel-off','shader-cache-clean','wsearch-off') })) {
    $ui.ItemPanel.Children.Add((New-ItemRow $rowItem @{ Optimized = $false; Current = "$($rowItem.Id) 当前状态" } $false)) | Out-Null
  }
  $rowsById = @{}
  foreach ($row in @($ui.ItemPanel.Children)) { $rowsById["$($row.DataContext.ItemId)"] = $row }
  foreach ($row in @($ui.ItemPanel.Children)) { $row.Child.Children[0].IsChecked = $false }

  Update-Count
  Assert-True (@($ui.ItemPanel.Children | Where-Object { $_.Visibility -eq 'Collapsed' }).Count -eq 0) '未筛选时不该隐藏任何行'
  Assert-True ($ui.SymptomEmptyText.Visibility -eq 'Collapsed') '未筛选时不该出现空列表提示'
  Assert-True (-not $ui.SymptomClearBtn.IsEnabled) '未筛选时「显示全部」不该可点'

  # 选一条症状：不相关的行被隐藏
  Switch-SymptomFilter 'input_latency'
  Assert-True ($rowsById['mouse-accel-off'].Visibility -eq 'Visible') '与所选症状相关的项没有显示'
  Assert-True ($rowsById['wsearch-off'].Visibility -eq 'Collapsed') '与所选症状无关的项没有被筛掉'
  Assert-True ($ui.SymptomClearBtn.IsEnabled) '筛选生效后「显示全部」必须可点'
  Assert-True ($ui.SymptomAdviceBox.Visibility -eq 'Visible' -and "$($ui.SymptomAdviceText.Text)".Contains('输入延迟')) '筛选后没有给出这条症状的说明'
  Assert-True ($ui.CountText.Text -like '*筛选内*') '计数条没有说明当前处于筛选状态'

  # 不变式：勾上的行绝不隐藏（这条最重要 —— 否则执行优化写的是看不见的项目）
  $rowsById['wsearch-off'].Child.Children[0].IsChecked = $true
  Update-Count
  Assert-True ($rowsById['wsearch-off'].Visibility -eq 'Visible') `
    '已勾选的行被筛选隐藏了 —— 「执行优化」会去写用户在屏幕上看不见的设置'
  Assert-True ($rowsById['wsearch-off'].DataContext.OffFilterMark.Visibility -eq 'Visible') `
    '勾了却与筛选无关的行没有打上「不在筛选内」标记，用户不知道它为什么还在'
  Assert-True ("$($ui.SymptomSummary.Text)".Contains('已勾选但与所选症状无关')) '摘要没有说出「有项目被勾选但不在筛选内」'
  $rowsById['wsearch-off'].Child.Children[0].IsChecked = $false
  Update-Count
  Assert-True ($rowsById['wsearch-off'].Visibility -eq 'Collapsed') '取消勾选后该行应重新被筛掉'
  Assert-True ($rowsById['wsearch-off'].DataContext.OffFilterMark.Visibility -eq 'Collapsed') '标记没有跟着收起来'

  # 多选症状取并集
  Switch-SymptomFilter 'stutter'
  Assert-True ($rowsById['shader-cache-clean'].Visibility -eq 'Visible' -and
               $rowsById['mouse-accel-off'].Visibility -eq 'Visible') '多选症状时应取并集'
  Switch-SymptomFilter 'stutter'
  Assert-True ($rowsById['shader-cache-clean'].Visibility -eq 'Collapsed') '再点一次症状应取消它'

  # 治不了的症状：列表空掉时必须明说，而不是显示一张看起来坏掉的空表
  Clear-SymptomFilter
  Switch-SymptomFilter 'cpu_heat'
  Assert-True (@($ui.ItemPanel.Children | Where-Object { $_.Visibility -ne 'Collapsed' }).Count -eq 0) 'cpu_heat 不该匹配到任何优化项'
  Assert-True ($ui.SymptomEmptyText.Visibility -eq 'Visible' -and
               "$($ui.SymptomEmptyText.Text)".Contains('没有对应的优化项')) `
    '所选症状没有对应优化项时，必须明说「本工具治不了这条」，而不是丢一张空表'
  Assert-True ($ui.SymptomAdviceActions.Children.Count -ge 1) '治不了的症状必须给出该去的地方'
  $restoreButton = @($ui.SymptomAdviceActions.Children | Where-Object { "$($_.Tag)" -eq 'restore' })[0]
  Assert-True ($null -ne $restoreButton) 'cpu_heat 没有给出复原入口'

  # 去处按钮真的把人送到那一页
  # 五个去处**逐个**验。原来只验了 framefix 和 residue 两个，把 restore / report / ref
  # 任意一条改坏，测试都照样绿 —— 而那三条恰恰是走 RaiseEvent 的，最容易挂错按钮。
  $script:LogLines.Clear()
  $script:PageActionHits = New-Object Collections.Generic.List[string]
  $ui.RestoreBtn.Add_Click({ [void]$script:PageActionHits.Add('restore') })
  $ui.ReportBtn.Add_Click({ [void]$script:PageActionHits.Add('report') })
  $ui.InlineRestorePanel.Visibility = 'Collapsed'
  foreach ($pageCase in @(
    @{ Page='framefix'; Check={ @($script:LogLines) -contains 'TAB:framefix' }; Msg='「去掉帧修复页」没有真的切页' },
    @{ Page='ref'; Check={ @($script:LogLines) -contains 'TAB:ref' }; Msg='「去游戏内设置参考页」没有真的切页' },
    @{ Page='residue'; Check={ @($script:LogLines) -contains 'RESIDUE' }; Msg='「检查工具残留」没有真的打开' },
    @{ Page='restore'; Check={ @($script:PageActionHits) -contains 'restore' }; Msg='「打开复原入口」没有真的触发 RestoreBtn' },
    @{ Page='report'; Check={ @($script:PageActionHits) -contains 'report' }; Msg='「导出诊断报告」没有真的触发 ReportBtn' })) {
    Invoke-SymptomPageAction $pageCase.Page
    Assert-True ([bool](& $pageCase.Check)) $pageCase.Msg
  }
  Assert-True (@($script:SymptomPageLabels.Keys).Count -eq 5) `
    "症状目录里的去处有 $(@($script:SymptomPageLabels.Keys).Count) 种，上面只逐个验了 5 种 —— 新增一种就必须在这里补一条"
  Invoke-SymptomPageAction '不存在的去处'
  Assert-True (@($script:LogLines | Where-Object { $_ -like '*未知的症状去处*' }).Count -eq 1) '未知去处应如实记日志而不是静默'

  # 忙碌闸门：RaiseEvent 不看 IsEnabled，所以这个函数必须自己拦
  $script:PageActionHits.Clear()
  $script:Busy = $true
  try {
    Invoke-SymptomPageAction 'report'
    Assert-True (@($script:PageActionHits).Count -eq 0) `
      '执行优化/还原途中，症状说明框的「导出诊断报告」仍然把 ReportBtn 触发了 —— 它的 finally 会把全局忙碌态清零'
  } finally { $script:Busy = $false }

  Clear-SymptomFilter
  Assert-True (@($ui.ItemPanel.Children | Where-Object { $_.Visibility -eq 'Collapsed' }).Count -eq 0) '「显示全部」没有恢复完整列表'
  Assert-True ($ui.SymptomSummary.Text -eq '未筛选 · 显示全部优化项') '摘要没有回到未筛选状态'

  # 症状 chip 是代码手搭的 Border，不走任何样式，所以 Ghost/Primary/TacCheck/TacCombo
  # 那四处禁用态一个也覆盖不到它。执行期间 Set-BusyState 会禁用整条 SymptomPanel，
  # 而 chip 在屏幕上零变化 —— 用户点下去毫无反应，又是一次「像卡死了」。
  $chipBusyProbe = @($script:SymptomChips.Values)[0]
  Assert-True ($null -ne $chipBusyProbe) '症状 chip 一个都没建出来'
  $script:Busy = $false
  Set-SymptomChipVisual $chipBusyProbe $false
  $chipIdleOpacity = [double]$chipBusyProbe.Border.Opacity
  $script:Busy = $true
  try {
    Set-SymptomChipVisual $chipBusyProbe $false
    Assert-True ([double]$chipBusyProbe.Border.Opacity -lt $chipIdleOpacity) `
      '执行期间症状 chip 被禁用了却毫无外观变化 —— 用户点下去没反应，读起来就是卡死'
    Assert-True ("$($chipBusyProbe.Border.Cursor)" -ne 'Hand') `
      '忙碌时 chip 还显示成可点的手形光标 —— 光标本身就是「这里能点」的承诺'
  } finally { $script:Busy = $false }
  # 选中态不能把忙碌态顶掉：两者是同一个函数的两个维度
  $script:Busy = $true
  try {
    Set-SymptomChipVisual $chipBusyProbe $true
    Assert-True ([double]$chipBusyProbe.Border.Opacity -lt $chipIdleOpacity) `
      '已选中的 chip 在忙碌期又变回了正常外观 —— 选中与否和能不能点是两件事'
  } finally { $script:Busy = $false }
  Set-SymptomChipVisual $chipBusyProbe $false
  Assert-True ([double]$chipBusyProbe.Border.Opacity -eq $chipIdleOpacity) '忙碌结束后 chip 没有恢复外观'

  # 未知症状 Id 不该改变任何筛选状态
  Switch-SymptomFilter '根本没有这条症状'
  Assert-True (@($script:ActiveSymptomIds).Count -eq 0) '未知症状 Id 不该进入筛选'
}

# ---------- 4c. 表头真的对齐（离屏渲染，不是看源码） ----------

# 「这张表没有表头」是社区那个外部 PR 想解决的问题之一。但表头只有在列真正对齐时才
# 是真话：每行的 Auto 列各算各的宽度时，标题会落在别的列头上，加表头反而制造误导。
# 所以这条断言不查源码，而是把真窗口的 XAML 解析出来、塞满真实行、跑一次离屏布局，
# 直接比对表头与每一行的四列实际宽度。
& {
  $script:C = @{
    Panel='#FF0E1B17';PanelDeep='#FF0B1713';Line='#FF1B2E28';LineSoft='#FF16241F';LineHi='#FF2C443B'
    TextPri='#FFFFFFFF';TextSec='#FF9AA5A0';TextMut='#FF7A8580';Gray='#FF7A8580'
    Green='#FF00E884';GreenDark='#FF04241B';Gold='#FFE5C46A';GoldDark='#FF3A2C0C';AccentPanel='#FF0E2A21'
  }
  function New-Brush([string]$Hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }
  function Write-Log([string]$Message) {}
  function Show-HealthDialog($Entries) {}
  $script:CheckHelp = @{}

  $xamlMatch = [regex]::Match($guiRaw, "(?s)\`$xaml = @'\r?\n(.*?)\r?\n'@")
  Assert-True ($xamlMatch.Success) '找不到主窗口 XAML'
  $window = [Windows.Markup.XamlReader]::Parse($xamlMatch.Groups[1].Value)
  foreach ($functionName in 'New-Text','New-Pill','Get-ItemRowTooltip','New-ItemRow') {
    Invoke-Expression (Import-GuiFunction $functionName)
  }

  $itemPanel = $window.FindName('ItemPanel')
  $headerGrid = $window.FindName('SelAllChk').Parent
  Assert-True ($headerGrid -is [Windows.Controls.Grid]) '全选行不再是一个 Grid，表头无处安放'
  Assert-True ($headerGrid.ColumnDefinitions.Count -eq 4) '表头不是四列'
  foreach ($rowItem in @(Get-OptItems $null)) {
    $itemPanel.Children.Add((New-ItemRow $rowItem `
      @{ Optimized = $false; Current = "$($rowItem.Id) 的当前状态故意写得很长很长很长很长很长" } $false)) | Out-Null
  }
  Assert-True ($itemPanel.Children.Count -ge 30) '离屏渲染没有塞进足够多的行'

  # Window 没显示过就不会布局，所以把 Content 摘下来单独量
  $content = $window.Content
  $window.Content = $null
  $content.Measure((New-Object Windows.Size 778, 1198))
  $content.Arrange((New-Object Windows.Rect 0, 0, 778, 1198))
  $content.UpdateLayout()

  $headerWidths = @($headerGrid.ColumnDefinitions | ForEach-Object { [math]::Round($_.ActualWidth, 2) })
  Assert-True (($headerWidths | Where-Object { $_ -gt 0 }).Count -eq 4) `
    "离屏布局没跑起来，四列宽度全是 0（$($headerWidths -join '/')）"
  foreach ($row in @($itemPanel.Children)) {
    $rowWidths = @($row.Child.ColumnDefinitions | ForEach-Object { [math]::Round($_.ActualWidth, 2) })
    Assert-True ("$($rowWidths -join '/')" -eq "$($headerWidths -join '/')") `
      ("表头与行的列宽不一致，表头等于在骗人：$($row.DataContext.ItemId) 是 $($rowWidths -join '/')，" +
       "表头是 $($headerWidths -join '/')")
  }
  # 名称列必须真的拿到大半个宽度，否则长项名全被裁成一截
  Assert-True ($headerWidths[0] -gt $headerWidths[1]) '名称列反而比当前状态列窄'

  # 列对齐还不够：名称列是定比宽度，长项名必须**被裁成省略号**，而不是画到隔壁
  # 「当前状态」列上（Grid 默认不裁剪子元素）。
  # 这条一定要在**窄窗口**下验：780px 默认宽度只有 1 行溢出 8px，几乎看不出来；
  # 而窗口是可以拉窄的（ResizeMode=CanResize，没有 MinWidth），560px 时 32 行里有
  # 18 行的项名压在隔壁列上，最多溢出 130px。
  # 根因是 TacCheck 模板原来用横向 StackPanel 包 ContentPresenter —— 横向 StackPanel
  # 用**无限宽**测量子元素，TextTrimming 因此永远不触发。
  foreach ($probeWidth in 778, 620, 500) {
    $content.Measure((New-Object Windows.Size $probeWidth, 1198))
    $content.Arrange((New-Object Windows.Rect 0, 0, $probeWidth, 1198))
    $content.UpdateLayout()
    $nameOverflow = New-Object Collections.Generic.List[string]
    foreach ($row in @($itemPanel.Children)) {
      $rowGrid = $row.Child
      $nameText = $rowGrid.Children[0].Content
      if ($nameText -isnot [Windows.Controls.TextBlock]) { continue }
      # TacCheck 的勾选框 13px + 内容左间距 8px
      $budget = $rowGrid.ColumnDefinitions[0].ActualWidth - 21
      if ($nameText.ActualWidth -gt $budget + 1) {
        [void]$nameOverflow.Add("$($row.DataContext.ItemId)（超出 $([math]::Round($nameText.ActualWidth - $budget, 1))px）")
      }
    }
    Assert-True ($nameOverflow.Count -eq 0) `
      ("窗口 ${probeWidth}px 下这些项名画到了「当前状态」列上，没有被裁成省略号：" +
       "$($nameOverflow -join '、')")
  }

}

# ---------- 5. 接线：可见性不变式必须在每条改勾选的路径末尾被执行 ----------

$updateCountAst = @($guiAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-Count'
}, $true) | Select-Object -First 1)
Assert-True ($updateCountAst.Count -eq 1) '找不到 Update-Count'
$visibilityCalls = @($updateCountAst[0].FindAll({
  param($node)
  $node -is [Management.Automation.Language.CommandAst] -and
  "$($node.GetCommandName())" -eq 'Update-SymptomRowVisibility'
}, $true))
Assert-True ($visibilityCalls.Count -eq 1) `
  'Update-Count 不再执行可见性不变式 —— 套方案/全选之后可能留下「勾上了却看不见」的项'

# 所有会改勾选状态的路径末尾都要回到 Update-Count。
#
# 这里原来查的是「那几行赋值语句的**字面量**还在不在」—— 而不变式根本不靠那几行存在，
# 靠的是它们之后有没有回到 Update-Count。实测：把套方案处理器末尾的 Update-Count 删掉
# （可见性不变式在那条路径上当场失守，正是 TESTING.md 2.8 第 5 步描述的场景），
# 两个测试文件仍然全绿。那就是一条假绿，和它要防的 ResidueBtn 是同一种病。
#
# 改成查关系：每一处给「优化项行的勾选框」赋值的语句，它所在的那个作用域
# （具名函数或事件处理器 scriptblock）必须也调用 Update-Count。
$checkedAssignments = @($guiAst.FindAll({
  param($node)
  if ($node -isnot [Management.Automation.Language.AssignmentStatementAst]) { return $false }
  $left = "$($node.Left)"
  # 只认优化项行的勾选框：还原面板那套复选框走的是 Update-InlineRestoreSelection，不在此列。
  # 这里必须用 EndsWith 而不是 -like：-like 会把 [0] 当成字符集通配符，
  # 'Children[0].IsChecked' 匹配的其实是 'Children0.IsChecked'，一条都对不上。
  $left.EndsWith('Children[0].IsChecked') -or ($left -eq '$cb.IsChecked')
}, $true))
Assert-True ($checkedAssignments.Count -ge 3) `
  "只找到 $($checkedAssignments.Count) 处优化项勾选赋值，AST 匹配多半失配了（建行 / 全选 / 套方案至少三处）"

function Get-EnclosingScopeAst($Node) {
  $cursor = $Node.Parent
  while ($cursor) {
    if ($cursor -is [Management.Automation.Language.FunctionDefinitionAst] -or
        $cursor -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $cursor }
    $cursor = $cursor.Parent
  }
  $null
}

$missingUpdateCount = New-Object Collections.Generic.List[string]
foreach ($assignment in $checkedAssignments) {
  $scope = Get-EnclosingScopeAst $assignment
  if (-not $scope) {
    [void]$missingUpdateCount.Add("第 $($assignment.Extent.StartLineNumber) 行的赋值找不到所属作用域")
    continue
  }
  # New-ItemRow 是唯一的例外，而且是正当的：它在**建行**时赋默认勾选，
  # 由调用方 Update-ItemList 在所有行都加完之后统一调一次 Update-Count。
  # 所以这个例外必须由下面那条断言兜住，不能白给。
  if ($scope -is [Management.Automation.Language.FunctionDefinitionAst] -and $scope.Name -eq 'New-ItemRow') { continue }
  $calls = @($scope.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and "$($node.GetCommandName())" -eq 'Update-Count'
  }, $true))
  if ($calls.Count -eq 0) {
    [void]$missingUpdateCount.Add("第 $($assignment.Extent.StartLineNumber) 行：$($assignment.Extent.Text.Trim())")
  }
}
Assert-True ($missingUpdateCount.Count -eq 0) `
  ("这些地方改了勾选状态却没有回到 Update-Count —— 可见性不变式在那条路径上不成立，" +
   "会留下「勾上了却看不见」的项目：$($missingUpdateCount -join '；')")

# New-ItemRow 的例外由这条兜住：建完行必须统一刷一次
$updateItemListAst = @($guiAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-ItemList'
}, $true) | Select-Object -First 1)
Assert-True ($updateItemListAst.Count -eq 1) '找不到 Update-ItemList'
Assert-True (@($updateItemListAst[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and "$($node.GetCommandName())" -eq 'Update-Count'
  }, $true)).Count -ge 1) `
  'Update-ItemList 重建完所有行之后没有调用 Update-Count —— New-ItemRow 里那处默认勾选就失去了兜底'

# 全选只动看得见的行
Assert-True ($guiRaw.Contains("`$allRows | Where-Object { `$_.Visibility -ne 'Collapsed' }")) `
  '「全选」不再限定在可见行 —— 屏幕上 5 项，点一下却勾上 32 项'
# 筛选带在启动路径上真的被建起来
Assert-True ($guiRaw.Contains("Initialize-SymptomFilterPanel`r`n    Update-ItemList") -or
             $guiRaw.Contains("Initialize-SymptomFilterPanel`n    Update-ItemList")) `
  '启动时没有初始化症状筛选带'
# 诊断报告与筛选带共用同一份症状数据
Assert-True ($guiRaw -match '\$script:DiagnosticIssueChoices\s*=\s*@\(@\(Get-SymptomCatalog\)') `
  '诊断报告的问题清单又自己写了一份，迟早与筛选带漂移'

# ---------- 6. 表头（社区那个外部 PR 改的就是这张表） ----------

foreach ($needle in @('Text="当前状态"', 'Text="重启"', 'Text="优化状态"',
                      'Grid.IsSharedSizeScope="True"',
                      'SharedSizeGroup="ItemRebootCol"', 'SharedSizeGroup="ItemStatusCol"')) {
  Assert-True ($guiRaw.Contains($needle)) "优化项表格缺少表头组成部分：$needle"
}
# 表头列定义必须与 New-ItemRow 的四列逐字对应
Assert-True ($guiRaw.Contains('<ColumnDefinition Width="5*"/>') -and $guiRaw.Contains('<ColumnDefinition Width="4*"/>')) `
  '表头的列比例与行不一致，标题会标到别的列上'
# 筛选带本体
foreach ($needle in @('x:Name="SymptomPanel"', 'x:Name="SymptomClearBtn"', 'x:Name="SymptomAdviceBox"',
                      'x:Name="SymptomAdviceActions"', 'x:Name="SymptomEmptyText"', 'Text="我遇到的问题"')) {
  Assert-True ($guiRaw.Contains($needle)) "症状筛选带缺少组成部分：$needle"
}

# ---------- 7. CLI ----------

$engineRaw = [IO.File]::ReadAllText((Join-Path $root 'scripts\delta-booster.ps1'), [Text.Encoding]::UTF8)
Assert-True ($engineRaw.Contains('[switch]$ListSymptoms')) '引擎没有 -ListSymptoms'
Assert-True ($engineRaw.Contains('$didDispatch = [bool]($ListItems -or $ListSymptoms')) `
  '-ListSymptoms 不在派发闸门里，跑它什么都不会发生'
$symptomCli = @(& (Join-Path $root 'scripts\delta-booster.ps1') -ListSymptoms)
Assert-True (@($symptomCli | Where-Object { $_ -like 'low_fps*' }).Count -eq 1) '-ListSymptoms 没有列出症状'
Assert-True (@($symptomCli | Where-Object { $_ -like '*本工具没有能直接解决这条症状的优化项*' }).Count -ge 1) `
  '-ListSymptoms 对治不了的症状没有如实说'
Assert-True (@($symptomCli | Where-Object { $_ -like '*症状目录异常*' }).Count -eq 0) '-ListSymptoms 报出了目录异常'

# ---------- 8. SKILL.md 的「优化项一览」必须和引擎对得上 ----------
#
# 这张表是给 **AI Agent** 读的操作手册。表里漏一项，agent 就永远不会向用户提到它；
# 「默认」列写反了，agent 会照着说「这一项默认不执行」而实际上它默认执行。
# 实测漂过两处：整张表漏了 shader-cache-clean（用户搜得最多的「解决掉帧」那一项），
# 而 vcredist-check 的默认列与代码相反。逐项对，不靠人眼。
$skillPath = Join-Path $root 'SKILL.md'
$skillRaw = [IO.File]::ReadAllText($skillPath, [Text.Encoding]::UTF8)
$skillStart = $skillRaw.IndexOf('## 优化项一览')
Assert-True ($skillStart -ge 0) 'SKILL.md 里找不到「优化项一览」'
$skillStop = $skillRaw.IndexOf('risky 档（默认不勾', $skillStart)
Assert-True ($skillStop -gt $skillStart) 'SKILL.md 的优化项表格找不到结尾'
$skillRows = @{}
foreach ($skillLine in (($skillRaw.Substring($skillStart, $skillStop - $skillStart)) -split "`r?`n")) {
  if ($skillLine -notmatch '^\|\s') { continue }
  $cells = @($skillLine -split '\|' | ForEach-Object { $_.Trim() })
  if ($cells.Count -lt 5) { continue }
  if ($cells[1] -eq 'Id' -or $cells[1] -match '^-+$') { continue }
  $skillRows[$cells[1]] = [pscustomobject]@{ Default = $cells[3]; Admin = $cells[4] }
}
Assert-True ($skillRows.Count -eq $optList.Count) `
  "SKILL.md 的优化项表有 $($skillRows.Count) 行，引擎有 $($optList.Count) 项 —— 表里漏掉的项目，agent 永远不会提到"
foreach ($optItem in $optList) {
  Assert-True ($skillRows.ContainsKey("$($optItem.Id)")) "SKILL.md 的优化项表缺行：$($optItem.Id)"
  if (-not $skillRows.ContainsKey("$($optItem.Id)")) { continue }
  # hibernate-off 的默认值是运行时按机型算的（台式机才默认勾），表里如实写「台式机默认」
  $expectedDefault = $(if ($optItem.Id -eq 'hibernate-off') { '台式机默认' }
                       elseif ($optItem.Default) { '是' } else { '否' })
  Assert-True ($skillRows["$($optItem.Id)"].Default -eq $expectedDefault) `
    "SKILL.md 里 $($optItem.Id) 的「默认」列是 $($skillRows["$($optItem.Id)"].Default)，代码里是 $expectedDefault"
  $expectedAdmin = $(if ($optItem.Admin) { '需要' } else { '否' })
  Assert-True ($skillRows["$($optItem.Id)"].Admin -eq $expectedAdmin) `
    "SKILL.md 里 $($optItem.Id) 的「管理员」列是 $($skillRows["$($optItem.Id)"].Admin)，代码里是 $expectedAdmin"
}

Write-Output "symptom-entry-tests: PASS ($script:Assertions assertions)"
