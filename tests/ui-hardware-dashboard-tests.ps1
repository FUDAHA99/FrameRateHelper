#requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
$enginePath = Join-Path $root 'scripts\delta-booster.ps1'

function Assert-True([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$tokens = $null; $errors = $null
$guiAst = [Management.Automation.Language.Parser]::ParseFile($guiPath,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI AST parse failed: ' + (($errors | ForEach-Object Message) -join '; '))
$tokens = $null; $errors = $null
$engineAst = [Management.Automation.Language.Parser]::ParseFile($enginePath,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) ('engine AST parse failed: ' + (($errors | ForEach-Object Message) -join '; '))

function Get-GuiFunctionText([string]$Name) {
  $wanted = $Name
  $found = @($guiAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wanted
  }, $true) | Select-Object -First 1)
  if ($found.Count -ne 1) { throw "ASSERT FAILED: 界面里找不到函数 $Name" }
  $found[0].Extent.Text
}

$raw = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
$engineRaw = Get-Content -LiteralPath $enginePath -Raw -Encoding UTF8
Assert-True ($raw -match '(?s)<Grid>\s*<Grid\.ColumnDefinitions>\s*<ColumnDefinition Width="Auto"/>\s*<ColumnDefinition Width="\*"/>\s*<ColumnDefinition Width="Auto"/>\s*</Grid\.ColumnDefinitions>.*?x:Name="GameText" Grid\.Column="1".*?x:Name="BrowseBtn" Grid\.Column="2"') `
  'game path row does not keep the relocate button pinned to the right edge'
foreach ($needle in @(
  'x:Name="ThemeBtn"','Visibility="Collapsed"','$script:LightThemeEnabled = $false','x:Name="MetricsGrid"','x:Name="HwGrid" Columns="4"',
  'Width="780" Height="1200" MinHeight="640"','$workAreaHeight-32.0','$script:DefaultAppWindowHeight = 1200.0',
  'function New-FpsMetricCard',"@('cpu','CPU 占用','%',100)","@('gpu','GPU 占用','%',100)","@('memory','内存占用','%',100)",
  'function New-MetricHistoryButton','MetricHistoryButton','function Set-LiveMetricComparison',
  'function Select-PerformanceComparisonPair','function Show-PerformanceMetricHistory','Refresh-PerformanceComparison -Force',
  "`$readout.Orientation = 'Horizontal'",
  "Set-HardwareTemperature 'cpu'","Set-HardwareTemperature 'gpu'","-TemperatureKey 'cpu'","-TemperatureKey 'gpu'",
  "`$v.TextWrapping = 'Wrap'","`$v.TextTrimming = 'None'","`$v.ToolTip = `$Value",
  'DfbLivePresentMonSampler','DfbProcessorUtilitySampler','DfbLiveSystemMetrics','Get-TemperatureColor','Start-LiveMetricsMonitor',
  'GpuTemperatureStatus',
  "`$State.FpsStatus = '等待有效帧'",
  '@"\Processor Information(_Total)\% Processor Utility"','处理器效用',
  'windowHeight=[math]::Round($WindowHeight,0)','Set-SavedAppWindowHeight','Save-AppUiPreferences $script:CurrentTheme',
  "Set-AppTheme (Get-SavedAppTheme)","Set-AppTheme `$(if (`$script:CurrentTheme -eq 'dark') { 'light' } else { 'dark' }) -Persist"
)) { Assert-True $raw.Contains($needle) "GUI missing hardware dashboard/theme integration: $needle" }
Assert-True (-not $raw.Contains('较优化前')) 'metric cards still assume that the user has run optimization'
Assert-True (-not $raw.Contains("@('fps','FPS','帧',240)")) 'FPS was still configured as a circular gauge'
Assert-True (-not $raw.Contains("@('cpuTemp','CPU 温度','°C',100)")) 'CPU temperature was still configured as a circular gauge'
Assert-True (-not $raw.Contains("@('gpuTemp','GPU 温度','°C',100)")) 'GPU temperature was still configured as a circular gauge'
Assert-True (-not $raw.Contains('$script:LiveMetricAnimations')) 'occupancy rings still contained flow-animation state'
Assert-True (-not $raw.Contains('ArcColorStops')) 'occupancy rings still contained animated glass gradients'
Assert-True (-not $raw.Contains('CtaFill')) 'primary action still used the contour-line drawing brush'
Assert-True (-not $raw.Contains('PathGeometry Figures="M 0,7 C')) 'primary action still contained decorative contour curves'
Assert-True ($raw.Contains('<Path x:Name="Bg" Stretch="Fill" Fill="{DynamicResource Green}"')) 'primary action does not use the shared theme green'
Assert-True ($raw.Contains("GreenLine='#FF00E884';Gold='#FFE5C46A'") -and
  $raw.Contains("GreenLine='#FF00E884';Gold='#FF1677B8'")) `
  'both themes do not share the primary green or their yellow/blue accents are missing'
Assert-True (-not $raw.Contains('#FFB5840D') -and -not $raw.Contains('#FFFFF5D9')) `
  'legacy light-theme yellow surfaces are still present'
Assert-True ($raw.IndexOf('x:Name="HwGrid" Columns="4"') -lt $raw.IndexOf('x:Name="MetricsGrid"')) `
  'CPU/GPU hardware row is not above the FPS and occupancy row'
Assert-True (-not $raw.Contains('MSAcpi_ThermalZoneTemperature')) 'motherboard ACPI thermal zone was still presented as CPU package temperature'
# 本分支不再内置传感器栈。这些断言是反向的：一旦有人把它们加回来，
# 就重新带回 PawnIO 的 GPL-2.0 源码义务、8 个无随附许可证的 DLL，
# 以及静默安装内核驱动带来的杀软误报 —— 而它们只产出一个数字（CPU 封装温度）。
foreach ($name in @('LibreHardwareMonitorLib.dll','HidSharp.dll','DiskInfoToolkit.dll','RAMSPDToolkit-NDD.dll',
  'BlackSharp.Core.dll','System.Memory.dll','System.Runtime.CompilerServices.Unsafe.dll',
  'System.Buffers.dll','System.Numerics.Vectors.dll','PawnIO_setup.exe')) {
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "tools\$name"))) `
    "the bundled sensor stack is back: tools\$name"
}
Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'scripts\hardware-sensors.ps1'))) `
  'scripts\hardware-sensors.ps1 is back; the bundled sensor provider was reintroduced'
# 温度只能来自 nvidia-smi 或用户自装的监控软件的 WMI 命名空间
Assert-True ($raw.Contains("root\LibreHardwareMonitor") -and $raw.Contains("root\OpenHardwareMonitor")) `
  'the WMI temperature fallback was removed; there is now no temperature source at all'
foreach ($needle in 'WmiMonitorID','PrimaryDisplayName','DisplayName','DisplayNames') {
  Assert-True $engineRaw.Contains($needle) "engine missing display identity field: $needle"
}

Add-Type -AssemblyName PresentationFramework
$xamlBlocks = [regex]::Matches($raw,"(?s)=\s*@'\r?\n(\s*<(?:Window|ResourceDictionary).*?)\r?\n'@")
Assert-True ($xamlBlocks.Count -ge 10) 'expected GUI XAML blocks were not found'
foreach ($block in $xamlBlocks) {
  $parsed = [Windows.Markup.XamlReader]::Parse($block.Groups[1].Value)
  if ($parsed -is [Windows.Window]) { $parsed.Close() }
}

foreach ($functionName in 'Resolve-DisplayClassLabel','Get-TemperatureColor','Initialize-LiveMetricsTypes') {
  $function = @($guiAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
  },$true) | Select-Object -First 1)
  Assert-True ($function.Count -eq 1) "function not found: $functionName"
  Invoke-Expression $function[0].Extent.Text
}

Assert-True ((Resolve-DisplayClassLabel 1920 1080) -eq '1K') '1920x1080 was not labeled 1K'
Assert-True ((Resolve-DisplayClassLabel 2560 1440) -eq '2K') '2560x1440 was not labeled 2K'
Assert-True ((Resolve-DisplayClassLabel 3840 2160) -eq '4K') '3840x2160 was not labeled 4K'
Assert-True ((Resolve-DisplayClassLabel 3440 1440) -eq '3440 × 1440') 'non-standard resolution did not keep its dimensions'
$script:C = @{ Green='#FF00E884' }
Assert-True ((Get-TemperatureColor 40) -eq $script:C.Green) 'low temperature does not use the active theme green'
Assert-True ((Get-TemperatureColor 40) -ne (Get-TemperatureColor 95)) 'temperature color does not change from low to high'

& {
  $script:C = @{
    Panel='#FF0E1B17';Line='#FF1B2E28';LineHi='#FF2C443B';TextPri='#FFFFFFFF'
    TextSec='#FF9AA5A0';TextMut='#FF7A8580';Green='#FF00E884';Gold='#FFE5C46A'
  }
  function New-Brush([string]$Hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex) }
  foreach ($functionName in 'New-Text','New-HwCard','New-MetricHistoryButton','New-FpsMetricCard','New-LiveMetricGauge','Set-LiveMetricGauge','Set-LiveMetricComparison','Set-HardwareTemperature','Initialize-LiveMetricsDashboard') {
    $wanted = $functionName
    $function = @($guiAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wanted
    },$true) | Select-Object -First 1)
    Assert-True ($function.Count -eq 1) "dashboard function not found: $functionName"
    Invoke-Expression $function[0].Extent.Text
  }
  $ui = @{ MetricsGrid = New-Object Windows.Controls.Grid }
  $script:MetricGauges = @{}
  $script:HardwareTemperatureReadouts = @{}
  Initialize-LiveMetricsDashboard
  Assert-True ($ui.MetricsGrid.Children.Count -eq 4) 'dashboard did not render one FPS card and three circular gauges'
  Assert-True ($script:MetricGauges.fps.Kind -eq 'number' -and $null -eq $script:MetricGauges.fps.Arc) 'FPS card still owns circular-gauge geometry'
  Assert-True ($script:MetricGauges.fps.ValueText.Foreground.Color -eq ([Windows.Media.ColorConverter]::ConvertFromString($script:C.Green))) 'FPS value was not rendered in the active theme green'
  Assert-True ($script:MetricGauges.fps.ValueText.Parent.HorizontalAlignment -eq [Windows.HorizontalAlignment]::Center) 'FPS value and unit are not horizontally centered'
  Assert-True ($script:MetricGauges.fps.SubText.HorizontalAlignment -eq [Windows.HorizontalAlignment]::Center) 'FPS status is not horizontally centered'
  Assert-True ($script:MetricGauges.fps.TitleText.HorizontalAlignment -eq [Windows.HorizontalAlignment]::Center) 'FPS title is not horizontally centered'
  foreach ($key in 'fps','cpu','gpu','memory') {
    Assert-True ($script:MetricGauges[$key].HistoryButton.Content -eq '记录') "history marker is missing from metric card: $key"
    Assert-True ("$($script:MetricGauges[$key].HistoryButton.Tag)" -eq $key) "history marker points to the wrong metric: $key"
  }
  Set-LiveMetricComparison -Key fps -Before 100 -After 120 -Mode percent -Prefix '变化'
  Assert-True ($script:MetricGauges.fps.CompareText.Text -eq '变化 +20.0%') 'FPS card did not show its compact neutral change'
  Assert-True ($script:MetricGauges.fps.CompareText.Foreground.Color -eq ([Windows.Media.ColorConverter]::ConvertFromString($script:C.Green))) 'positive FPS change was not highlighted green'
  Set-LiveMetricComparison -Key cpu -Before 50 -After 45 -Mode points -Prefix '变化'
  Assert-True ($script:MetricGauges.cpu.CompareText.Text -eq '变化 -5.0点') 'CPU card did not show its compact neutral change'
  foreach ($key in 'cpu','gpu','memory') {
    Assert-True ($script:MetricGauges[$key].Kind -eq 'ring') "occupancy gauge was not circular: $key"
    Assert-True ($script:MetricGauges[$key].Arc.Stroke -is [Windows.Media.SolidColorBrush]) "occupancy gauge did not use the ordinary solid ring: $key"
    Assert-True ($script:MetricGauges[$key].UnitText.FontSize -eq $script:MetricGauges[$key].ValueText.FontSize) "percentage unit size differs from its number: $key"
    Assert-True ($script:MetricGauges[$key].ValueText.FontSize -eq 14) "occupancy number is too large for decimal values: $key"
    Assert-True ($script:MetricGauges[$key].UnitText.FontWeight -eq $script:MetricGauges[$key].ValueText.FontWeight) "percentage unit weight differs from its number: $key"
    Assert-True ($script:MetricGauges[$key].UnitText.Foreground.Color -eq $script:MetricGauges[$key].ValueText.Foreground.Color) "percentage unit color differs from its number: $key"
  }
  [void](New-HwCard 'CPU' 'CPU fixture' '8核 / 16线程' -TemperatureKey 'cpu')
  Set-HardwareTemperature 'cpu' 48 'fixture sensor'
  Assert-True ($script:HardwareTemperatureReadouts.cpu.ValueText.Text -eq '48') 'CPU temperature was not rendered inside its hardware card'
  Assert-True ($script:HardwareTemperatureReadouts.cpu.Container.ToolTip -eq '数据源：fixture sensor') 'CPU temperature source is not visible'
  Assert-True ($script:HardwareTemperatureReadouts.cpu.UnitText.FontSize -eq $script:HardwareTemperatureReadouts.cpu.ValueText.FontSize) 'temperature unit size differs from its number'
  Assert-True ($script:HardwareTemperatureReadouts.cpu.UnitText.FontWeight -eq $script:HardwareTemperatureReadouts.cpu.ValueText.FontWeight) 'temperature unit weight differs from its number'
  Assert-True ($script:HardwareTemperatureReadouts.cpu.UnitText.Foreground.Color -eq $script:HardwareTemperatureReadouts.cpu.ValueText.Foreground.Color) 'temperature unit color differs from its number'
  Set-HardwareTemperature 'cpu' $null '' 'fixture unavailable reason'
  Assert-True ($script:HardwareTemperatureReadouts.cpu.ValueText.Text -eq 'N/A' -and
    $script:HardwareTemperatureReadouts.cpu.UnitText.Text -eq '' -and
    $script:HardwareTemperatureReadouts.cpu.Container.ToolTip -eq 'fixture unavailable reason') `
    'missing CPU temperature does not explain the unavailable sensor source'
  Set-HardwareTemperature 'cpu' 52 'fixture sensor'
  Assert-True ($script:HardwareTemperatureReadouts.cpu.UnitText.Text -eq '°C') `
    'temperature unit was not restored after a sensor source became available'
}

foreach ($functionName in 'Expand-PerformanceSessions','Get-PerformanceSessionTimestamp','Test-PerformanceSessionValid',
  'Get-PerformanceSessionDisplayMode','Get-PerformanceSessionToolState','Get-PerformanceSessionToolStateLabel',
  'Get-PerformanceSessionComparisonConfidence','Select-PerformanceComparisonPair',
  'Get-PerformanceComparisonMetricValue','Get-PerformanceMetricHistoryDefinition','Get-PerformanceMetricHistoryRows') {
  $wanted = $functionName
  $function = @($guiAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wanted
  },$true) | Select-Object -First 1)
  Assert-True ($function.Count -eq 1) "performance comparison function not found: $functionName"
  Invoke-Expression $function[0].Extent.Text
}
$baseContext = [pscustomobject]@{
  gameExeVersion='1.2.3.4';powerSource='ac'
  gpuAdapters=@([pscustomobject]@{main=$true;displayMode='2560x1440@165'})
}
$beforeSession = [pscustomobject]@{
  recordedAt='2026-08-14T01:00:00Z';validity='valid';configTier='baseline';optimizationScheme='baseline'
  optimizationItemSetHash='';gpuModel='NVIDIA GeForce RTX 4070 SUPER';avgFps=100.0;gpuUtilAvg=70.0
  analysisContext=$baseContext;performanceContext=[pscustomobject]@{processCpuAvgPct=30.0;systemMemoryUsedAvgPct=60.0}
}
$afterSession = [pscustomobject]@{
  recordedAt='2026-08-14T02:00:00Z';validity='valid';configTier='full';optimizationScheme='main'
  optimizationItemSetHash='fixture-hash';gpuModel='NVIDIA GeForce RTX 4070 SUPER';avgFps=120.0;gpuUtilAvg=75.0
  analysisContext=$baseContext;performanceContext=[pscustomobject]@{processCpuAvgPct=27.0;systemMemoryUsedAvgPct=58.0}
}
$pair = Select-PerformanceComparisonPair @($beforeSession,$afterSession) ([pscustomobject]@{ItemSetHash='fixture-hash'})
Assert-True ($pair.Status -eq 'paired' -and $pair.Confidence -eq 'comparable' -and $pair.PairKind -eq 'tool_change') 'valid same-environment tool-state sessions were not paired'
Assert-True ((Get-PerformanceComparisonMetricValue $pair.After 'cpu') -eq 27.0) 'comparison did not read the game CPU summary'
$secondBaseline = $beforeSession.PSObject.Copy()
$secondBaseline.recordedAt = '2026-08-14T03:00:00Z'; $secondBaseline.avgFps = 105.0
$baselinePair = Select-PerformanceComparisonPair @($beforeSession,$secondBaseline,$afterSession) ([pscustomobject]@{ItemSetHash=''})
Assert-True ($baselinePair.Status -eq 'paired' -and $baselinePair.PairKind -eq 'history') 'two sessions without tool changes were not compared as ordinary history'
Assert-True ((Get-PerformanceSessionToolStateLabel $secondBaseline) -eq '未使用工具') 'baseline history was not clearly labeled as not using the tool'
$historyRows = @(Get-PerformanceMetricHistoryRows @($beforeSession,$secondBaseline,$afterSession) 'fps')
Assert-True ($historyRows.Count -eq 3 -and $historyRows[0].ValueText -eq '105.0 帧') 'FPS history rows were not built in newest-first order'
Assert-True (@($historyRows | Where-Object { $_.StateText -eq '未使用工具' }).Count -eq 2) 'history did not preserve unoptimized sessions'
$differentContext = [pscustomobject]@{
  gameExeVersion='1.2.3.4';powerSource='ac'
  gpuAdapters=@([pscustomobject]@{main=$true;displayMode='1920x1080@165'})
}
$mismatchedAfter = $afterSession.PSObject.Copy(); $mismatchedAfter.analysisContext = $differentContext
$mismatch = Select-PerformanceComparisonPair @($beforeSession,$mismatchedAfter) ([pscustomobject]@{ItemSetHash='fixture-hash'})
Assert-True ($mismatch.Status -eq 'environment_mismatch') 'known display-mode mismatch was still presented as an optimization change'

$displayFunction = @($engineAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DisplayTopologyInfo'
},$true) | Select-Object -First 1)
Assert-True ($displayFunction.Count -eq 1) 'Get-DisplayTopologyInfo not found'
& {
  param([string]$FunctionText)
  function Get-CimInstance {
    param([string]$Namespace,[string]$ClassName)
    if ($ClassName -eq 'WmiMonitorConnectionParams') {
      return [pscustomobject]@{ Active=$true; VideoOutputTechnology=10 }
    }
    if ($ClassName -eq 'WmiMonitorID') {
      return [pscustomobject]@{ Active=$true; UserFriendlyName=[uint16[]]@(83,65,78,67,0,0) }
    }
  }
  Invoke-Expression $FunctionText
  $display = Get-DisplayTopologyInfo
  Assert-True ($display.PrimaryDisplayName -eq 'SANC') 'monitor friendly name was not decoded'
  Assert-True ($display.ActiveDisplayCount -eq 1 -and $display.Connectors -contains 'displayport') 'display topology fields regressed'
} $displayFunction[0].Extent.Text

Initialize-LiveMetricsTypes
Assert-True ([bool]('DfbLivePresentMonSampler' -as [type])) 'PresentMon live sampler type did not compile'
Assert-True ([bool]('DfbProcessorUtilitySampler' -as [type])) 'processor utility sampler type did not compile'
Assert-True ([bool]('DfbLiveSystemMetrics' -as [type])) 'system metrics type did not compile'
$displaySampler = New-Object DfbLivePresentMonSampler
try {
  $displaySampler.AcceptCsvLine('Application,ProcessID,SwapChainAddress,DisplayedTime,FrameTime')
  foreach ($index in 1..10) { $displaySampler.AcceptCsvLine("game.exe,42,0xMAIN,10,8") }
  foreach ($index in 1..5) { $displaySampler.AcceptCsvLine("game.exe,42,0xUI,50,5") }
  $displaySampler.AcceptCsvLine('game.exe,42,0xMAIN,NA,8')
  Assert-True ([math]::Abs($displaySampler.ReadFps()-100.0) -lt 0.01) `
    'live FPS mixed secondary swap chains or counted a dropped displayed frame'
  Assert-True ($displaySampler.MetricLabel -eq '显示帧率') 'live FPS did not prefer the actual display cadence'
} finally { $displaySampler.Dispose() }
$presentSampler = New-Object DfbLivePresentMonSampler
try {
  $presentSampler.AcceptCsvLine('Application,ProcessID,SwapChainAddress,DisplayedTime,FrameTime')
  foreach ($index in 1..8) { $presentSampler.AcceptCsvLine("game.exe,42,0xMAIN,NA,20") }
  Assert-True ([math]::Abs($presentSampler.ReadFps()-50.0) -lt 0.01) 'live FPS fallback did not read PresentMon FrameTime'
  Assert-True ($presentSampler.MetricLabel -eq '呈现帧率') 'unavailable display tracking was not labeled as present FPS'
} finally { $presentSampler.Dispose() }
$cpuSampler = New-Object DfbProcessorUtilitySampler
try {
  # 单次 NaN 是 PDH 的正常瞬态（该次采样数据无效，产品按「未知」显示），整套测试并行、CPU 满载时
  # 偶尔出现。连读三次只要有一次合法就算采样器可用；若它每次都拿不到值，这里照样会失败。
  $cpuUtility = [double]::NaN
  foreach ($attempt in 1..3) {
    Start-Sleep -Milliseconds 1000
    $cpuUtility = $cpuSampler.Read()
    if (-not [double]::IsNaN($cpuUtility)) { break }
  }
  Assert-True (-not [double]::IsNaN($cpuUtility) -and $cpuUtility -ge 0 -and $cpuUtility -le 100) 'processor utility counter returned an invalid value'
} finally { $cpuSampler.Dispose() }
$memory = [DfbLiveSystemMetrics]::ReadMemoryUsage()
Assert-True (-not [double]::IsNaN($memory) -and $memory -ge 0 -and $memory -le 100) 'memory usage probe returned an invalid value'


# ---------------------------------------------------------------------------
#  机型三态必须一路走到屏幕上
# ---------------------------------------------------------------------------
#
# Resolve-FormFactor 是**刻意做的三态**（laptop / desktop / unknown + 置信度），
# 引擎明确拒绝在证据不足时猜机型。但界面原来把它塌成布尔 `$hw.IsLaptop`：
# unknown 直接显示成「台式机」，而这是屏幕上唯一露出机型的地方 —— 用户没有理由怀疑。
# 下游更要命：`hibernate-off` 的默认勾选是 `-not $hw.IsLaptop`，于是一台
# 机箱类型缺失（白牌本）、或**合盖接扩展坞**（内屏 inactive）的笔记本，
# 会被**默认勾上**「关闭休眠与快速启动」——hiberfil.sys 被删、合盖不再休眠。
. $enginePath

$formFactorCases = @(
  @{ Name='真台式机';                 Chassis=@(3);    Battery=$false; Internal=$false; Label='台式机';     HibDefault=$true  },
  @{ Name='真笔记本';                 Chassis=@(10);   Battery=$true;  Internal=$true;  Label='笔记本';     HibDefault=$false },
  @{ Name='机箱类型缺失（白牌本）';   Chassis=@();     Battery=$null;  Internal=$null;  Label='机型未确认'; HibDefault=$false },
  @{ Name='合盖接扩展坞（内屏非活动）'; Chassis=@();   Battery=$true;  Internal=$false; Label='机型未确认'; HibDefault=$false },
  @{ Name='变形本（机箱类型自相矛盾）'; Chassis=@(3,10); Battery=$true; Internal=$true; Label='机型未确认'; HibDefault=$false },
  @{ Name='台式机接 UPS';             Chassis=@(3);    Battery=$true;  Internal=$false; Label='台式机';     HibDefault=$true  }
)
foreach ($ffCase in $formFactorCases) {
  $ff = Resolve-FormFactor $ffCase.Chassis $ffCase.Battery $ffCase.Internal
  $hwProbe = [pscustomobject]@{
    FormFactor = "$($ff.FormFactor)"; FormFactorConfidence = "$($ff.Confidence)"
    IsUpsAmbiguous = [bool]$ff.IsUpsAmbiguous; IsLaptop = ($ff.FormFactor -eq 'laptop')
  }
  Assert-True ((Get-FormFactorLabel $hwProbe) -eq $ffCase.Label) `
    "$($ffCase.Name)：卡片应显示「$($ffCase.Label)」，实际「$(Get-FormFactorLabel $hwProbe)」"
  # hibernate-off 的默认勾选判据必须是「**确认**是台式机」，不是「不是笔记本」
  $hibDefault = [bool]($hwProbe -and "$($hwProbe.FormFactor)" -eq 'desktop')
  Assert-True ($hibDefault -eq $ffCase.HibDefault) `
    "$($ffCase.Name)：「关闭休眠与快速启动」的默认勾选应为 $($ffCase.HibDefault)，实际 $hibDefault"
}
# 判不出机型时绝不能预先勾上 —— 这条单独钉死，上面那张表改坏了也还有它
$unknownProbe = [pscustomobject]@{ FormFactor='unknown'; FormFactorConfidence='low'; IsUpsAmbiguous=$false; IsLaptop=$false }
Assert-True ((Get-FormFactorLabel $unknownProbe) -notin '笔记本','台式机') `
  '机型 unknown 时卡片仍然说出了一个确定的机型'
Assert-True ($engineRaw.Contains("Default = [bool](`$hw -and `"`$(`$hw.FormFactor)`" -eq 'desktop')")) `
  '「关闭休眠与快速启动」的默认勾选又回到了 -not $hw.IsLaptop —— unknown 会被当成台式机替用户勾上'
# 性能历史：「没有记录」和「读不出来」必须分开。
# 写入侧和读取侧原来共用同一句解析，旧文件坏了会让**新记录也存不进去**，
# 而界面一直说「运行游戏就会出现」—— 一条永远兑现不了的承诺。
& {
  foreach ($fn in 'Read-PerformanceSessionsState') { Invoke-Expression (Get-GuiFunctionText $fn) }
  function Expand-PerformanceSessions($Decoded) { @($Decoded) }
  $probeDir = Join-Path ([IO.Path]::GetTempPath()) ("dfb-perf-" + [guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($probeDir)
  try {
    $missing = Join-Path $probeDir 'none.json'
    $st = Read-PerformanceSessionsState $missing
    Assert-True (-not $st.ReadFailed -and @($st.Sessions).Count -eq 0) '文件不存在应是「没有记录」，不是「读不出来」'

    $broken = Join-Path $probeDir 'broken.json'
    [IO.File]::WriteAllText($broken, '[{"a":1', (New-Object Text.UTF8Encoding($false)))
    $st2 = Read-PerformanceSessionsState $broken
    Assert-True ($st2.ReadFailed -and "$($st2.Reason)" -like '*读取失败*') `
      'JSON 被截断时必须报「读不出来」，不能和「还没有记录」收敛成同一种呈现'

    $good = Join-Path $probeDir 'good.json'
    [IO.File]::WriteAllText($good, '[{"a":1}]', (New-Object Text.UTF8Encoding($false)))
    $st3 = Read-PerformanceSessionsState $good
    Assert-True (-not $st3.ReadFailed -and @($st3.Sessions).Count -eq 1) '正常文件应能读出记录'
  } finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
}
# 界面必须把这个区分**用出来**，而不是读了就扔。
# 这里查关系不查字面量：只断言 '$sessionState.ReadFailed' 这串字存在的话，
# 把赋值那一行换成写死的 @{ReadFailed=$false} 仍然全绿（下面两处引用还在）——
# 这个坑本轮已经踩过三次了。
foreach ($perfFn in 'Show-PerformanceMetricHistory', 'Refresh-PerformanceComparison') {
  $wantedPerfFn = $perfFn
  $perfFnAst = @($guiAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $wantedPerfFn
  }, $true) | Select-Object -First 1)
  Assert-True ($perfFnAst.Count -eq 1) "找不到函数 $perfFn"
  $perfReads = @($perfFnAst[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    "$($node.GetCommandName())" -eq 'Read-PerformanceSessionsState'
  }, $true))
  Assert-True ($perfReads.Count -ge 1) `
    "$perfFn 没有走 Read-PerformanceSessionsState —— 「没有记录」和「读不出来」又被压成同一种呈现"
}
Assert-True ($raw.Contains('这不等于没有记录')) '读不出来时仍然可能被当成「还没有记录」'

# 写入侧：旧文件坏了不能把新记录一起丢掉。
# 同样查结构 —— 那句解析必须被**自己的** try/catch 包住，而不是只靠外层那个
# （外层一接住，整次写入就被静默放弃，新记录也存不进去）。
$captureWorkerAst = @($guiAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
  "$($node.Left)" -eq '$script:PerformanceCaptureWorker'
}, $true) | Select-Object -First 1)
Assert-True ($captureWorkerAst.Count -eq 1) '找不到性能采集 worker'
$guardedParse = @($captureWorkerAst[0].FindAll({
  param($node)
  # 必须同时钉住 catch 里那个改名动作：只要求「body 含 Expand-PerformanceSessions 且有
  # catch」的话，**外层**那个包住整次写入的 try 也满足 —— 而它正是要防的那一个。
  $node -is [Management.Automation.Language.TryStatementAst] -and
  $node.Body.Extent.Text.Contains('Expand-PerformanceSessions') -and
  @($node.CatchClauses).Count -ge 1 -and
  (@($node.CatchClauses) | Where-Object { $_.Extent.Text.Contains('corrupt-') }).Count -ge 1
}, $true))
Assert-True ($guardedParse.Count -ge 1) `
  '旧记录文件的解析没有被自己的 try/catch 包住 —— 文件一坏，整次写入被外层静默放弃，新记录也存不进去'
Assert-True ($raw.Contains('.corrupt-') -and $raw.Contains('从本局起重新累积')) `
  '旧记录文件解析失败后没有改名留档并继续累积'

# 「着色器缓存读不出来」不能说成「没有缓存」。清理着色器缓存是「进游戏后每隔十几秒
# 卡 2~3 秒」唯一对症的那一项 —— 把「我不知道」说成「没有」，等于把最需要它的人
# 从它面前赶走。（缓存目录可能是目录联接或被权限挡住，Get-SafeFilesUnderRoot 会把它
# 计进 .Rejected 并返回空文件表。）
& {
  $cacheItem = @{ Kind = 'cache' }
  $originalDirs = ${function:Get-ShaderCacheDirs}
  $originalScan = ${function:Get-SafeFilesUnderRoot}
  try {
    function Get-ShaderCacheDirs { @([pscustomobject]@{ Path = $env:TEMP; Scope = 'user' }) }

    function Get-SafeFilesUnderRoot([string]$Root) { [pscustomobject]@{ Files=@(); Rejected=@($Root) } }
    $blockedText = "$((Get-ItemState $cacheItem).Current)"
    Assert-True ($blockedText -like '*读不出来*' -and $blockedText -like '*这不等于没有缓存*') `
      "缓存目录读不出来时说成了「$blockedText」—— 那是把「我不知道」说成了「没有」"

    function Get-SafeFilesUnderRoot([string]$Root) { [pscustomobject]@{ Files=@(); Rejected=@() } }
    Assert-True ("$((Get-ItemState $cacheItem).Current)" -eq '当前无缓存可清理') `
      '确实读到 0 且全部可读时，就该直说没有缓存可清理'

    function Get-SafeFilesUnderRoot([string]$Root) {
      [pscustomobject]@{ Files=@([pscustomobject]@{ Length = 5MB }); Rejected=@() }
    }
    Assert-True ("$((Get-ItemState $cacheItem).Current)" -like '*约 5MB*') '有缓存时应报出占用量'

    function Get-SafeFilesUnderRoot([string]$Root) {
      [pscustomobject]@{ Files=@([pscustomobject]@{ Length = 5MB }); Rejected=@('X') }
    }
    $mixedText = "$((Get-ItemState $cacheItem).Current)"
    Assert-True ($mixedText -like '*约 5MB*' -and $mixedText -like '*读不出来*') `
      '部分目录读不出来时，报出来的占用量必须同时说明它可能不完整'
  } finally {
    Set-Item -LiteralPath Function:\Get-ShaderCacheDirs -Value $originalDirs
    Set-Item -LiteralPath Function:\Get-SafeFilesUnderRoot -Value $originalScan
  }
}

# 显卡指引的「检测依据」那一行同样不能硬写台式机：它给出的是一个用户无从质疑的前提，
# 而「笔记本补充」（插电、厂商性能模式、别靠提高功耗上限硬撑）会因此整段消失。
$unknownHw = [pscustomobject]@{
  FormFactor='unknown'; FormFactorConfidence='low'; IsUpsAmbiguous=$false; IsLaptop=$false
  DisplayWidth=1920; DisplayHeight=1080; DisplayRefreshHz=144; RamGB=16
}
$unknownGuide = Get-AmdConfiguredGuideText $unknownHw 'Radeon RX 7800 XT' $false
Assert-True ($unknownGuide -match '检测依据：[^
]*机型未确认') `
  '机型未确认时，显卡指引的「检测依据」仍然笃定地写着台式机'
Assert-True ($unknownGuide.Contains('如果这是笔记本')) `
  '机型未确认时，笔记本那几条补充被整段跳过了 —— 判不出来就该两边都说'
$desktopGuide = Get-AmdConfiguredGuideText ([pscustomobject]@{
  FormFactor='desktop'; FormFactorConfidence='high'; IsUpsAmbiguous=$false; IsLaptop=$false
  DisplayWidth=1920; DisplayHeight=1080; DisplayRefreshHz=144; RamGB=16 }) 'Radeon RX 7800 XT' $false
Assert-True ($desktopGuide -match '检测依据：[^
]*台式机') '确认是台式机时就该直说台式机'
Assert-True (-not $desktopGuide.Contains('如果这是笔记本')) '机型确定时不该再给「如果这是笔记本」的兜底'

# 界面必须用三态文案，不能再自己写 if ($hw.IsLaptop) { '笔记本' } else { '台式机' }。
# 注意：这条只能钉**构造那一行**，不能全文搜 —— 解释这段历史的注释里就有那串字，
# 全文搜会命中注释自己（这个坑在本仓库已经踩过一次）。
$systemCardLine = @($raw -split "`r?`n" | Where-Object { $_ -match "New-HwCard 'SYSTEM'" })
Assert-True ($systemCardLine.Count -eq 1) '找不到 SYSTEM 硬件卡的构造行'
Assert-True ($systemCardLine[0].Contains('$formFactorLabel')) `
  'SYSTEM 硬件卡没有使用三态机型文案'
Assert-True (-not $systemCardLine[0].Contains('IsLaptop')) `
  'SYSTEM 硬件卡又把机型塌回了布尔 IsLaptop'

'UI hardware dashboard tests passed.'
