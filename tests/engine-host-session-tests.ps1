#requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'
$enginePath = Join-Path $root 'scripts\delta-booster.ps1'
$updaterPath = Join-Path $root 'scripts\updater.ps1'
$workerPath = Join-Path $root 'scripts\user-context-worker.ps1'
$hostBuildPath = Join-Path $root 'build\make-engine-host.ps1'
$launcherBuildPath = Join-Path $root 'build\make-launcher.ps1'
$installerBuildPath = Join-Path $root 'build\make-installer.ps1'
$uninstallBuildPath = Join-Path $root 'build\make-uninstall-host.ps1'
$runtimeRootPath = Join-Path $root 'build\runtime-root-validation.cs'
$tokenValidationPath = Join-Path $root 'build\token-validation.cs'
$uninstallHostSourcePath = Join-Path $root 'build\uninstall-host.cs'
$uninstallLauncherSourcePath = Join-Path $root 'build\uninstall-launcher.cs'
$batPath = Join-Path $root '启动优化工具.bat'
$winPs = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Read-Utf8([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }

function Parse-PowerShell([string]$Path) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Assert-True ($errors.Count -eq 0) ("PowerShell AST parse failed: $Path — " + (($errors | ForEach-Object Message) -join '; '))
  $ast
}

$guiAst = Parse-PowerShell $guiPath
$engineAst = Parse-PowerShell $enginePath
$null = Parse-PowerShell $updaterPath
$null = Parse-PowerShell $workerPath
$hostBuildAst = Parse-PowerShell $hostBuildPath
$null = Parse-PowerShell $launcherBuildPath
$null = Parse-PowerShell $installerBuildPath
$null = Parse-PowerShell $uninstallBuildPath

$gui = Read-Utf8 $guiPath
$engine = Read-Utf8 $enginePath
$updater = Read-Utf8 $updaterPath
$worker = Read-Utf8 $workerPath
$hostBuild = Read-Utf8 $hostBuildPath
$launcherBuild = Read-Utf8 $launcherBuildPath
$installerBuild = Read-Utf8 $installerBuildPath
$uninstallBuild = Read-Utf8 $uninstallBuildPath
$runtimeRoot = Read-Utf8 $runtimeRootPath
$tokenValidation = Read-Utf8 $tokenValidationPath
$uninstallHostSource = Read-Utf8 $uninstallHostSourcePath
$uninstallLauncherSource = Read-Utf8 $uninstallLauncherSourcePath
$bat = Read-Utf8 $batPath

# C# 词法骨架：注释与字符串/字符字面量整段换成空格（换行保留，长度不变），于是
# 花括号配平、标识符提取都不会被注释或字面量骗到；同一偏移处可回到原文取字面量。
function ConvertTo-CSharpSkeleton([string]$Text, [bool]$KeepLiterals) {
  $out = $Text.ToCharArray()
  $i = 0; $n = $Text.Length
  while ($i -lt $n) {
    $c = $Text[$i]
    $next = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }
    $start = $i; $literal = $false
    if ($c -eq [char]'/' -and $next -eq [char]'/') {
      while ($i -lt $n -and $Text[$i] -ne [char]10) { $i++ }
    } elseif ($c -eq [char]'/' -and $next -eq [char]'*') {
      $end = $Text.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
      Assert-True ($end -ge 0) 'C# skeleton: unterminated block comment'
      $i = $end + 2
    } elseif ($c -eq [char]'@' -and $next -eq [char]'"') {
      $literal = $true; $i += 2
      while ($true) {
        Assert-True ($i -lt $n) 'C# skeleton: unterminated verbatim string'
        if ($Text[$i] -eq [char]'"') {
          if ($i + 1 -lt $n -and $Text[$i + 1] -eq [char]'"') { $i += 2; continue }
          $i++; break
        }
        $i++
      }
    } elseif ($c -eq [char]'"' -or $c -eq [char]"'") {
      $literal = $true; $i++
      while ($true) {
        Assert-True ($i -lt $n -and $Text[$i] -ne [char]10) "C# skeleton: unterminated literal near offset $i"
        if ($Text[$i] -eq [char]'\') { $i += 2; continue }
        if ($Text[$i] -eq $c) { $i++; break }
        $i++
      }
    } else { $i++; continue }
    if ($literal -and $KeepLiterals) { continue }
    for ($k = $start; $k -lt $i; $k++) { if ($out[$k] -ne [char]10) { $out[$k] = [char]' ' } }
  }
  New-Object string (,$out)
}

# 按花括号配平取出函数体的偏移区间；签名必须在骨架里恰好出现一次。
function Get-CSharpBodySpan([string]$Skeleton, [string]$Signature) {
  $start = $Skeleton.IndexOf($Signature, [StringComparison]::Ordinal)
  Assert-True ($start -ge 0 -and $Skeleton.IndexOf($Signature, $start + 1, [StringComparison]::Ordinal) -lt 0) `
    "C# signature is missing or not unique: $Signature"
  $open = $Skeleton.IndexOf('{', $start)
  $depth = 0
  for ($i = $open; $i -lt $Skeleton.Length; $i++) {
    if ($Skeleton[$i] -eq [char]'{') { $depth++ }
    elseif ($Skeleton[$i] -eq [char]'}') {
      $depth--
      if ($depth -eq 0) { return [pscustomobject]@{ Start = $open; Length = $i - $open + 1 } }
    }
  }
  Assert-True $false "C# body is not brace-balanced: $Signature"
}

function Get-NormalizedCode([string]$Text) { ([regex]::Replace($Text, '\s+', ' ')).Trim() }

function Find-EngineFunction([string]$Name) {
  $matches = @($engineAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true))
  Assert-True ($matches.Count -eq 1) "engine helper missing or duplicated: $Name"
  $matches[0]
}

function Find-GuiFunction([string]$Name) {
  $matches = @($guiAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true))
  Assert-True ($matches.Count -eq 1) "GUI helper missing or duplicated: $Name"
  $matches[0]
}

$virtualDisplayFunction = Find-EngineFunction 'Test-VirtualDisplayAdapter'
$gpuPreferenceFunction = Find-EngineFunction 'Get-GpuPreferenceScore'
Invoke-Expression $virtualDisplayFunction.Extent.Text
Invoke-Expression $gpuPreferenceFunction.Extent.Text
Assert-True (Test-VirtualDisplayAdapter '' 'ToDesk Virtual Display') 'known remote display adapter is not classified'
Assert-True (-not (Test-VirtualDisplayAdapter 'PCI\VEN_10DE' 'NVIDIA GeForce RTX 4070')) 'physical GPU was classified as a virtual display'
Assert-True ((Get-GpuPreferenceScore ([pscustomobject]@{ Name='GameViewer Virtual Display'; Vendor='Unknown'; IsVirtualDisplay=$true })) -eq -1000) `
  'virtual display adapter can still win primary-GPU selection'
Assert-True ($engine.Contains("`$verified = (`$vendor -eq 'Intel')") -and
  -not $engine.Contains("`$verified = (`$vendor -notin @('NVIDIA','AMD'))")) `
  'unknown or virtual display adapters are still marked as verified physical GPUs'
Assert-True ($engine.Contains('$processors = @(Get-CimInstance Win32_Processor)') -and
  $engine.Contains('Measure-Object -Sum') -and $engine.Contains('CpuPackages   = $processors.Count') -and
  $engine.Contains('MemoryModuleCount = $memory.Count') -and $engine.Contains('AutomaticManagedPagefile')) `
  'hardware analysis fields do not use the complete OS-visible topology and memory/pagefile state'

# UAC 边界与 full-lifetime session。
Assert-True ($hostBuild -match 'requestedExecutionLevel level="requireAdministrator"') 'EngineHost manifest is not requireAdministrator'
Assert-True ($launcherBuild -match 'requestedExecutionLevel level="asInvoker"') 'launcher manifest is not asInvoker'
Assert-True ($launcherBuild -match 'string hostPath = Path\.Combine\(root, "EngineHost\.exe"\)' -and
  $launcherBuild -match 'psi\.FileName = hostPath' -and
  $launcherBuild -match 'psi\.Verb = "runas"') 'launcher does not request UAC only for EngineHost'
Assert-True ($launcherBuild -match 'NativeErrorCode != 8235' -and
  $launcherBuild -match 'StartEngineHostWithPolicyFallback' -and
  $launcherBuild -match 'WindowsPowerShell", "v1\.0", "powershell\.exe"' -and
  $launcherBuild -match '-EncodedCommand') `
  'launcher does not recover ERROR_DS_REFERRAL with a fixed trusted PowerShell boundary'
Assert-True ($launcherBuild -match 'QuotePowerShellLiteral\(hostPath\)' -and
  $launcherBuild -match 'QuotePowerShellLiteral\(pipeName\)' -and
  $launcherBuild -match 'QuotePowerShellLiteral\(session\)') `
  'signed-policy fallback does not quote all fixed EngineHost launch values'
Assert-True ($hostBuild -match 'AssemblyTitle\("帧率优化助手 管理员助手"\)') `
  'EngineHost UAC product description missing'
Assert-True ($launcherBuild.IndexOf('if (!createdNew)', [StringComparison]::Ordinal) -lt
  $launcherBuild.IndexOf('string validationError = ValidateFiles(root)', [StringComparison]::Ordinal)) `
  'second-launch marker is not checked before validation/UAC'
Assert-True ($launcherBuild -match 'DFB_ENGINE_DONE/1' -and $hostBuild -match 'DFB_ENGINE_DONE/1') `
  'launcher is not retained through the EngineHost/GUI lifetime'

# High PowerShell 环境必须在第一次模块自动加载/原生程序搜索前收紧。
$moduleOffset = $gui.IndexOf('$env:PSModulePath =', [StringComparison]::Ordinal)
$pathOffset = $gui.IndexOf('$env:PATH =', [StringComparison]::Ordinal)
$cimOffset = $gui.IndexOf('Get-CimInstance Win32_Process', [StringComparison]::Ordinal)
Assert-True ($moduleOffset -ge 0 -and $pathOffset -ge 0 -and $cimOffset -gt $moduleOffset -and $cimOffset -gt $pathOffset) `
  'GUI bootstrap can auto-load a user module before environment hardening'
Assert-True ($launcherBuild -match 'EnterTrustedElevationEnvironment' -and
  $launcherBuild -match 'Environment\.SetEnvironmentVariable\(name, null') `
  'managed RunAs environment can inherit CLR profiler or COMPlus injection variables'

# EngineHost -> 高权限 GUI 的环境边界（结构部分）。旧写法对整份文件 -match 'EnvironmentVariables\.Clear\(\)'，
# 把那行注释掉照样匹配到注释里的字面量（独立复核 09-host-env-comment）。这里只看去掉注释的 C# 骨架，
# 并且只在函数体范围内判定；行为边界由文件末尾「真实子进程环境块」那段守。结构部分补的是反射
# 调 StartGui 看不到的三件事：Main 里填的静态状态、StartGui 之外另起进程、传给 StartGui 的值被换源。
$hostCsAssign = @($hostBuildAst.FindAll({ param($n)
  $n -is [Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$cs' }, $true))
Assert-True ($hostCsAssign.Count -eq 1) 'EngineHost C# source here-string ($cs) is missing or ambiguous'
$hostCsText = $hostCsAssign[0].Right.Expression.Value
$hostSkel = ConvertTo-CSharpSkeleton $hostCsText $false
$hostCode = ConvertTo-CSharpSkeleton $hostCsText $true
$startGuiSpan = Get-CSharpBodySpan $hostSkel 'static Process StartGui('
$runGuiSpan = Get-CSharpBodySpan $hostSkel 'static int RunGuiAndServe('
$hostMainSpan = Get-CSharpBodySpan $hostSkel 'static int Main('
$startGuiSkel = $hostSkel.Substring($startGuiSpan.Start, $startGuiSpan.Length)
$startGuiCode = $hostCode.Substring($startGuiSpan.Start, $startGuiSpan.Length)
$runGuiSkel = $hostSkel.Substring($runGuiSpan.Start, $runGuiSpan.Length)
$runGuiCode = $hostCode.Substring($runGuiSpan.Start, $runGuiSpan.Length)
$hostMainCode = $hostCode.Substring($hostMainSpan.Start, $hostMainSpan.Length)

# (1) StartGui 的词表是封闭的：它只能读自己的参数、GetFolderPath 和当前进程 PID。多出任何标识符
#     （静态字段、辅助方法、GetEnvironmentVariables、foreach、IsInRole……）都要先改这里并说明理由。
$startGuiVocabulary = @('Arguments','Clear','Combine','CommonApplicationData','controlPipe','CreateNoWindow',
  'CultureInfo','Environment','EnvironmentVariables','false','FileName','GetCurrentProcess','GetDirectoryName',
  'GetFolderPath','GetPathRoot','Globalization','gui','guiProcess','Hidden','Id','if','InvalidOperationException',
  'InvariantCulture','IsNullOrEmpty','launcherPid','localAppData','machineModules','new','null','Path',
  'PathSeparator','powershell','Process','ProcessStartInfo','ProcessWindowStyle','programData','programFiles',
  'ProgramFiles','programFilesX86','ProgramFilesX86','psi','Quote','repairOnly','return','root','session',
  'sessionTemp','sid','SpecialFolder','Start','string','String','system','System','systemModules','throw',
  'ToString','TrimEnd','true','UseShellExecute','var','windows','Windows','WindowStyle','WorkingDirectory')
$startGuiIds = @([regex]::Matches($startGuiSkel, '\b[A-Za-z_][A-Za-z0-9_]*\b') | ForEach-Object { $_.Value } |
  Sort-Object -Unique -CaseSensitive)
$vocabAdded = @($startGuiIds | Where-Object { $startGuiVocabulary -cnotcontains $_ })
$vocabDropped = @($startGuiVocabulary | Where-Object { $startGuiIds -cnotcontains $_ })
Assert-True ($vocabAdded.Count -eq 0 -and $vocabDropped.Count -eq 0) `
  ('EngineHost StartGui vocabulary changed; review the child environment boundary. added: ' +
   ($vocabAdded -join ', ') + ' / dropped: ' + ($vocabDropped -join ', '))

# (2) 子进程环境块只由字面量键写入，键集合恰好是白名单；EngineHost 里别处不碰任何环境块。
$envWrites = @([regex]::Matches($startGuiCode, 'EnvironmentVariables\s*\[([^\]]*)\]') |
  ForEach-Object { $_.Groups[1].Value.Trim() })
$computedKeys = @($envWrites | Where-Object { $_ -cnotmatch '^"[A-Za-z0-9_()]+"$' })
Assert-True ($envWrites.Count -gt 0 -and $computedKeys.Count -eq 0) `
  ('StartGui writes child environment variables with computed keys: ' + ($computedKeys -join ', '))
$envKeys = @($envWrites | ForEach-Object { $_.Trim('"') } | Sort-Object -Unique -CaseSensitive)
$expectedEnvKeys = @('ALLUSERSPROFILE','COMSPEC','DFB_ENGINE_CONTROL_PIPE','DFB_ENGINE_HOST_PID',
  'DFB_ENGINE_HOST_SESSION','DFB_LAUNCHER_PID','DFB_ORIGINAL_LOCALAPPDATA','DFB_ORIGINAL_USER_SID',
  'DFB_REPAIR_ONLY','PATH','PATHEXT','PSModulePath','ProgramData','ProgramFiles','ProgramFiles(x86)',
  'SystemDrive','SystemRoot','TEMP','TMP','WINDIR') | Sort-Object -CaseSensitive
Assert-True (($envKeys -join '|') -ceq ($expectedEnvKeys -join '|')) `
  ('StartGui child environment whitelist is not the exact expected set: ' + ($envKeys -join ', '))
Assert-True ([regex]::Matches($hostSkel, 'EnvironmentVariables').Count -eq
  [regex]::Matches($startGuiSkel, 'EnvironmentVariables').Count -and
  $startGuiSkel -notmatch '\bpsi\s*\.\s*Environment\b') `
  'EngineHost touches a child environment block outside the StartGui whitelist'
$hostEnvMembers = @([regex]::Matches($hostSkel, '\bEnvironment\s*\.\s*([A-Za-z_]\w*)') |
  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-True (@($hostEnvMembers | Where-Object { @('GetFolderPath','SpecialFolder') -cnotcontains $_ }).Count -eq 0) `
  ('EngineHost reads or writes its own process environment: Environment.' + ($hostEnvMembers -join ', Environment.'))

# (3) 全 EngineHost 只有 StartGui 里那一处起进程。
Assert-True ([regex]::Matches($hostSkel, '\bProcess\s*\.\s*Start\s*\(').Count -eq 1 -and
  $startGuiSkel -match '\bProcess\s*\.\s*Start\s*\(\s*psi\s*\)' -and
  [regex]::Matches($hostSkel, '\bProcessStartInfo\b').Count -eq 1 -and
  $hostSkel -notmatch '\bnew\s+(System\s*\.\s*Diagnostics\s*\.\s*)?Process\s*\(' -and
  $hostSkel -notmatch '\.\s*Start\s*\(\s*\)' -and
  $hostCode -notmatch '(?i)CreateProcess|(?<![A-Za-z])ShellExecute|WinExec') `
  'EngineHost starts a child process outside the sanitized StartGui path'

# (4) 调用链钉死：Main -> RunGuiAndServe -> StartGui 各只有一处，值来自令牌验证与宿主自建目录。
Assert-True ([regex]::Matches($hostSkel, '\bStartGui\s*\(').Count -eq 2 -and
  [regex]::Matches($runGuiSkel, '\bStartGui\s*\(').Count -eq 1 -and
  (Get-NormalizedCode $runGuiCode).Contains('using (Process guiProcess = StartGui(root, sid, localAppData, session, controlPipeName, sessionTemp, launcherPid, launcher.RepairOnly))') -and
  (Get-NormalizedCode $runGuiCode).Contains('string sessionTemp = CreateSessionTemp(session);') -and
  [regex]::Matches($runGuiSkel, '\bsessionTemp\s*=(?!=)').Count -eq 1 -and
  $runGuiSkel -notmatch '\b(ref|out)\s+sessionTemp\b') `
  'RunGuiAndServe does not hand StartGui the host-created session temp through the single sanitized call'
Assert-True ([regex]::Matches($hostSkel, '\bRunGuiAndServe\s*\(').Count -eq 2 -and
  (Get-NormalizedCode $hostMainCode).Contains('return RunGuiAndServe(root, launcher.OriginalSid, launcher.OriginalLocalAppData, session, launcherPid, launcher);')) `
  'EngineHost Main does not hand RunGuiAndServe the launcher-token-verified identity'
Assert-True (-not ($gui -match 'Start-Process\s+[''"]?explorer\.exe') -and -not ($gui -match '-Verb\s+RunAs')) `
  'high GUI still launches explorer or creates a second UAC boundary'
Assert-True (-not ($updater -match '-Verb\s+RunAs')) 'updater still creates a PowerShell UAC prompt'

# OTS credentials: original account context travels over authenticated pipes; high state never lives in LocalAppData.
foreach ($needle in 'DFB_ORIGINAL_USER_SID','DFB_ORIGINAL_LOCALAPPDATA','GetNamedPipeServerProcessId','GetNamedPipeClientProcessId') {
  Assert-True ($hostBuild.Contains($needle) -or $launcherBuild.Contains($needle)) "authenticated OTS context element missing: $needle"
}
foreach ($needle in 'OpenProcessToken','TokenUser','TokenIntegrityLevel','TokenSessionId') {
  Assert-True $tokenValidation.Contains($needle) "launcher token binding element missing: $needle"
}
Assert-True ($hostBuild -match 'launcherToken\.Sid' -and $hostBuild -match 'launcherToken\.SessionId' -and
  $hostBuild -match 'ResolveOriginalLocalAppData' -and $hostBuild -match 'DFB_REPAIR_ONLY') `
  'EngineHost does not bind claimed OTS identity/repair mode to the real launcher token'
Assert-True ($launcherBuild -match '(?s)static bool IsRepairOnlyToken.*IntegrityRid < 0x3000.*return true;' -and
  $hostBuild -match '(?s)static bool IsRepairOnlyToken.*IntegrityRid < 0x3000.*return true;' -and
  $gui -match '\$script:RepairOnlySession -and -not \$needsUacRepair' -and
  $gui -match '管理员启动 · 兼容模式') `
  'direct elevated launch is not constrained to the broker-disabled compatibility session'
Assert-True ($gui -match 'FilterAdministratorToken' -and
  $gui -match 'Test-IsBuiltInAdministratorSid \$script:OriginalUserSid') `
  'RID-500 UAC repair path or OTS approved-account isolation is missing'
Assert-True ($gui -match 'DeltaForceBooster\\users\\\$sessionText|DeltaForceBooster\\session-temp' -or
  $gui -match 'ProtectedUserStateRoot') 'GUI protected per-SID state root missing'
Assert-True ($gui -match 'Initialize-ProtectedUserStateStore' -and $gui -match '\$script:BoosterUserConfigDir = \$configRoot') `
  'GUI/updater state is not consistently redirected to protected ProgramData'
Assert-True ($engine -match 'Get-ProtectedUserStateRoot \$script:TargetUserSid' -and
  $engine -match '\[string\]\$UserStateRoot' -and $engine -match '\[string\]\$RequestFile') `
  'child engine does not derive/accept protected per-SID state or action request'
Assert-True ($gui -match 'UserStateRoot\s*=\s*\[IO\.Path\]::GetFullPath\(\$script:ProtectedUserStateRoot\)' -and
  $engine -match 'UserStateRoot 与受保护 per-SID 状态分区不匹配') `
  'Apply/Restore child action can fall back to elevated LocalAppData'
$adminActionFunction = Find-GuiFunction 'Invoke-ElevatedEngineAction'
$adminActionText = $adminActionFunction.Extent.Text
Assert-True (-not $adminActionText.Contains('-EncodedCommand') -and $adminActionText.Contains("'-File'") -and
  $adminActionText.Contains("'-RequestFile'") -and $adminActionText.Contains('RedirectStandardError = $true') -and
  $adminActionText.Contains('ReadToEndAsync()')) `
  'Apply/Restore still uses encoded dynamic code or drops child-process diagnostics'
Assert-True ($gui -match 'Get-ProtectedEngineExchangeRoot' -and $engine -match 'Import-EngineActionRequest' -and
  $engine -match 'engine-result-\{0\}\.json') `
  'protected per-session request/result transport is incomplete'
Assert-True ($updater -match 'BoosterUserConfigDir' -and $updater -match '管理员更新器缺少受保护 per-SID 配置目录') `
  'elevated updater can fall back to the approval administrator LocalAppData'

# 原用户可写树动作全部留在 medium worker；参数和外部动作均为固定白名单。
Assert-True ($worker -match 'if \(Test-WorkerAdmin\).*拒绝执行' -and
  $launcherBuild -match 'psi\.CreateNoWindow = true') 'original-user worker can run high or flash a console'
Assert-True ($launcherBuild -match 'EnvironmentVariables\["SystemDrive"\] = Path\.GetPathRoot\(windows\)' -and
  $launcherBuild -match 'EnvironmentVariables\["ProgramData"\] = commonAppData' -and
  $launcherBuild -match 'EnvironmentVariables\["ALLUSERSPROFILE"\] = commonAppData') `
  'original-user worker clears SystemDrive/CommonApplicationData aliases, causing GetFolderPath to fail'
foreach ($action in 'MigrateLegacyData','ClearShaderCache','GetNvidiaPanelApps','GetAmdPanelApps','GetIntelPanelApps','GetNvAutoOptStatus','OpenUrl','OpenGpuPanel') {
  Assert-True ($gui.Contains($action) -and $hostBuild.Contains($action) -and $launcherBuild.Contains($action)) `
    "broker allowlist is inconsistent: $action"
}
foreach ($action in 'GetNvidiaPanelApps','GetAmdPanelApps','GetIntelPanelApps') {
  Assert-True $worker.Contains($action) "GPU software worker action is missing: $action"
}
Assert-True (-not ($gui.Contains('GetGpuPanelApps') -or $worker.Contains('GetGpuPanelApps') -or
  $hostBuild.Contains('GetGpuPanelApps') -or $launcherBuild.Contains('GetGpuPanelApps'))) `
  'legacy free-text GPU vendor action is still reachable across a broker boundary'
Assert-True ($launcherBuild -match 'UriSchemeHttps' -and $launcherBuild -match 'Array\.IndexOf\(allowed, host\)') `
  'URL broker is not constrained to fixed HTTPS hosts'
foreach ($key in 'nv-cpl','nv-app','amd-sw','intel-gcc') {
  Assert-True ($gui.Contains($key) -and $launcherBuild.Contains($key)) "GPU panel key is not end-to-end allowlisted: $key"
}
Assert-True ($gui -match 'Key = \$app\.Key') 'GPU panel button drops the allowlisted key'
Assert-True ($worker -match 'Get-AppxPackage' -and $gui -match 'Get-GuiGpuPanelInventory' -and
  $engine -match 'if \(Test-Admin\) \{ return \$null \}') 'AppX detection can observe the approval administrator instead of the original user'
Assert-True ($gui -match "'NVIDIA' \{ 'GetNvidiaPanelApps' \}" -and
  $gui -match "'AMD'\s+\{ 'GetAmdPanelApps' \}" -and
  $gui -match "'INTEL'\s+\{ 'GetIntelPanelApps' \}" -and
  $worker -match "'GetNvidiaPanelApps' \{ Get-WorkerGpuPanelApps 'NVIDIA' \}" -and
  $worker -match "'GetAmdPanelApps' \{ Get-WorkerGpuPanelApps 'AMD' \}" -and
  $worker -match "'GetIntelPanelApps' \{ Get-WorkerGpuPanelApps 'Intel' \}" -and
  $launcherBuild -match 'if \(!String\.IsNullOrEmpty\(payload\)\)') `
  'GPU vendor identity is not encoded as fixed zero-payload actions end to end'
Assert-True ($engine -match 'Registry::HKEY_USERS\\\$script:TargetUserSid.*Uninstall') `
  'game discovery does not enumerate the original user HKEY_USERS uninstall hive'

# Update handoff explicitly waits every image that can lock the app tree.
foreach ($pidArg in '/waitpid=$script:EngineHostPid','/waitpid2=$script:LauncherPid','/waitpid3=$PID') {
  Assert-True $gui.Contains($pidArg) "update handoff PID missing: $pidArg"
}
Assert-True ($gui -match '\$script:UpdateRunAfterAllowed = \$approvalSid -ieq \$script:OriginalUserSid' -and
  $gui -match 'if \(\$script:UpdateRunAfterAllowed\) \{ \$setupArgs\.Add\(''/runafter''\) \}') `
  'OTS updater can still auto-launch under the approval administrator account'
Assert-True ($installerBuild -match 'make-engine-host\.ps1' -and
  $installerBuild.IndexOf('make-engine-host.ps1', [StringComparison]::Ordinal) -lt
  $installerBuild.IndexOf('make-launcher.ps1', [StringComparison]::Ordinal)) 'installer build order is not EngineHost before launcher'
Assert-True ($installerBuild -match "'EngineHost\.exe'" -and $installerBuild -match "'scripts\\user-context-worker\.ps1'" -and
  $installerBuild -match 'SchemaVersion=2.*EngineHostSha256') 'EngineHost/worker/identity v2 is not in installer payload'
Assert-True ($launcherBuild -match 'SchemaVersion=1' -and $launcherBuild -match 'SchemaVersion=2' -and
  $hostBuild -match 'SchemaVersion=1' -and $hostBuild -match 'SchemaVersion=2') 'runtime identity validation lost v1 upgrade compatibility'
Assert-True (-not ($bat -match '(?i)powershell') -and $bat -match '启动优化工具\.exe') 'backup BAT bypasses the launcher/EngineHost chain'

# Runtime root contract and uninstall UAC boundary.
foreach ($needle in 'PermanentAnchor','EnsureExactAnchorDirectory','EnsureHighIntegrityAnchor','AnchorNeverDelete=1','EnsureTrustedProgramFilesChain') {
  Assert-True ($runtimeRoot.Contains($needle) -and $hostBuild.Contains('DfbRuntimeRoot.Validate') -and
    $launcherBuild.Contains('DfbRuntimeRoot.Validate')) "runtime protected-root contract missing: $needle"
}
Assert-True ($uninstallBuild -match 'requestedExecutionLevel level="requireAdministrator"' -and
  $uninstallBuild -match 'AssemblyDescription\("帧率优化助手 卸载助手"\)' -and
  $installerBuild -match 'make-uninstall-host\.ps1' -and $installerBuild -match 'UninstallHost\.exe') `
  'dedicated UninstallHost is not built into the installer payload'
Assert-True ($installerBuild -notmatch 'Start-Process \$psExe -Verb RunAs' -and
  $installerBuild -match 'Wait-VerifiedProcessExit' -and $uninstallHostSource -match 'WorkingDirectory = system' -and
  $uninstallLauncherSource -match 'psi\.Verb = "runas"') `
  'uninstall still prompts as PowerShell or keeps the product root locked'
Assert-True ($uninstallLauncherSource -match 'EnterTrustedElevationEnvironment' -and
  $uninstallLauncherSource -match 'Environment\.SetEnvironmentVariable\(key, null' -and
  $uninstallHostSource -match 'psi\.EnvironmentVariables\.Clear\(\)') `
  'uninstall elevation/script child can inherit CLR profiler or untrusted high-token environment'

# High GUI protected profile save/delete behavior. Mock only ACL primitives; real JSON/atomic write path runs.
$profileCase = Join-Path ([IO.Path]::GetTempPath()) ('dfb-profile-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $profileCase 'profiles'))
try {
  & {
    param($EnginePath, $StateRoot)
    . $EnginePath
    $script:TargetUserSid = 'S-1-5-21-111-222-333-1001'
    $script:UserDataRoot = $StateRoot
    $script:ConfigDir = Join-Path $StateRoot 'config'
    $script:ProfileDir = Join-Path $StateRoot 'profiles'
    function Test-Admin { $true }
    function Initialize-UserDataStore {}
    function Get-ProtectedUserStateRoot([string]$Sid) { $StateRoot }
    function Test-PathHasReparsePoint([string]$Path) { $false }
    function Test-ProtectedDirectoryAclExact([string]$Path, [bool]$UsersRead) { $true }
    function Set-ProtectedFileAcl([string]$Path) {}
    function Test-ProtectedFileAcl([string]$Path) { $true }
    $saved = Save-UserPreset '会话方案' @('game-mode')
    Assert-True (Test-Path -LiteralPath $saved -PathType Leaf) 'high GUI could not save into protected ProfileDir'
    $removed = Remove-UserPreset '会话方案'
    Assert-True ($removed -eq '会话方案' -and -not (Test-Path -LiteralPath $saved)) `
      'high GUI could not remove a protected profile'
  } $enginePath $profileCase
} finally { if (Test-Path -LiteralPath $profileCase) { Remove-Item -LiteralPath $profileCase -Recurse -Force } }

# Actual WinPS5.1 second-launch regression: a held current-session instance mutex returns before
# ValidateFiles/RunAs. The separate Global lifetime marker is intentionally not the duplicate gate.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DeltaForceBooster-Tests\engine-session-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$testLauncher = Join-Path $testRoot 'launcher-test.exe'
$markerFile = Join-Path $testRoot 'already-running.txt'
$marker = $null
$p = $null
try {
  & $winPs -NoProfile -ExecutionPolicy Bypass -File $hostBuildPath | Out-Host
  Assert-True ($LASTEXITCODE -eq 0) 'EngineHost test build failed'
  & $winPs -NoProfile -ExecutionPolicy Bypass -File $launcherBuildPath -TestBuild | Out-Host
  Assert-True ($LASTEXITCODE -eq 0) 'launcher DFB_TESTING build failed'
  Copy-Item -LiteralPath (Join-Path $root '启动优化工具.exe') -Destination $testLauncher
  $created = $false
  $marker = New-Object Threading.Mutex($false, 'Local\DeltaForceBooster.LaunchInstance', [ref]$created)
  Assert-True $created 'test could not acquire the current-session launcher marker'
  $env:DFB_TEST_ALREADY_RUNNING_LOG = $markerFile
  $p = Start-Process -FilePath $testLauncher -WorkingDirectory ([Environment]::SystemDirectory) -PassThru
  Assert-True ($p.WaitForExit(10000)) 'second launcher did not return without UAC'
  Assert-True ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $markerFile -PathType Leaf) -and
    [IO.File]::ReadAllText($markerFile) -eq 'already-running') 'second launcher did not take the pre-UAC already-running path'
} finally {
  Remove-Item Env:DFB_TEST_ALREADY_RUNNING_LOG -ErrorAction SilentlyContinue
  if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
  if ($p) { $p.Dispose() }
  if ($marker) { $marker.Dispose() }
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
  # Do not leave a DFB_TESTING launcher in the repository after the regression.
  & $winPs -NoProfile -ExecutionPolicy Bypass -File $hostBuildPath | Out-Null
  if ($LASTEXITCODE -eq 0) { & $winPs -NoProfile -ExecutionPolicy Bypass -File $launcherBuildPath | Out-Null }
}
Assert-True ($LASTEXITCODE -eq 0) 'production launcher rebuild after second-launch regression failed'

$hostInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $root 'EngineHost.exe'))
$launcherInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $root '启动优化工具.exe'))
Assert-True ($hostInfo.FileDescription -eq '帧率优化助手 管理员助手') 'EngineHost FileDescription is not the UAC-facing product name'
Assert-True ($launcherInfo.FileDescription -eq '帧率优化助手') 'launcher FileDescription changed unexpectedly'

# Behavior regression for the managed RunAs boundary: before ShellExecuteEx/AppInfo receives
# the launch request, every caller-controlled CLR/PowerShell variable is absent and the helper
# restores the medium launcher's original environment after Process.Start returns.
$launcherAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root '启动优化工具.exe')))
$launcherType = $launcherAssembly.GetType('Launcher', $true)
$enterEnv = $launcherType.GetMethod('EnterTrustedElevationEnvironment', [Reflection.BindingFlags]'Static,NonPublic')
$restoreEnv = $launcherType.GetMethod('RestoreProcessEnvironment', [Reflection.BindingFlags]'Static,NonPublic')
$poison = [ordered]@{
  COR_ENABLE_PROFILING='1'; COR_PROFILER_PATH='C:\untrusted\profiler.dll';
  COMPlus_ReadyToRun='0'; DOTNET_STARTUP_HOOKS='C:\untrusted\hook.dll'; PSModulePath='C:\untrusted\Modules'
}
$savedPoison = @{}
foreach ($name in $poison.Keys) { $savedPoison[$name] = [Environment]::GetEnvironmentVariable($name, 'Process');
  [Environment]::SetEnvironmentVariable($name, $poison[$name], 'Process') }
$savedEnvironment = $null
try {
  $savedEnvironment = $enterEnv.Invoke($null, @())
  foreach ($name in $poison.Keys) {
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable($name, 'Process')) `
      "RunAs sanitizer retained dangerous environment variable: $name"
  }
  Assert-True ([Environment]::GetEnvironmentVariable('PATH','Process').StartsWith([Environment]::SystemDirectory,
    [StringComparison]::OrdinalIgnoreCase)) 'RunAs sanitizer PATH is not rooted at trusted System32'
} finally {
  if ($savedEnvironment) { $restoreEnv.Invoke($null, [object[]]@(,$savedEnvironment)) | Out-Null }
  foreach ($name in $poison.Keys) { [Environment]::SetEnvironmentVariable($name, $savedPoison[$name], 'Process') }
}

# Behavior regression for the EngineHost -> GUI boundary: the child PowerShell must start from an
# environment EngineHost built from scratch. We call the real StartGui out of the freshly built
# production EngineHost.exe against a throwaway root whose gui\DeltaForceBooster-GUI.ps1 only dumps
# its own environment. CreateSessionTemp (the only elevated dependency) is replaced by passing a plain
# directory. Every argument is distinct so a swapped value cannot pass. The injected probe variable
# guarantees a missing Clear() is visible even on a machine whose environment happens to be tiny.
$hostAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root 'EngineHost.exe')))
$startGui = $hostAssembly.GetType('EngineHost', $true).GetMethod('StartGui', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $startGui) 'EngineHost.StartGui is not reachable for the child-environment regression'
$envProbeTemplate = @'
$rows = foreach ($entry in ([Environment]::GetEnvironmentVariables()).GetEnumerator()) {
  [string]$entry.Key + '=' + ([string]$entry.Value -replace '\r?\n', ' ')
}
[IO.File]::WriteAllLines('__DUMP__', [string[]]@($rows), (New-Object Text.UTF8Encoding($false)))
'@
$hostSession = 'abcdef0123456789abcdef0123456789'
$hostPipe = 'DeltaForceBooster.Engine.0123456789abcdef0123456789abcdef'
$hostSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
$hostLocalAppData = 'C:\DfbTest\OriginalUser\AppData\Local'
$sysDir = [Environment]::GetFolderPath('System')
$winDir = [Environment]::GetFolderPath('Windows')
$commonData = [Environment]::GetFolderPath('CommonApplicationData')
$progFiles = [Environment]::GetFolderPath('ProgramFiles')
$progFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
foreach ($repairOnly in @($false, $true)) {
  $envCase = [string](Join-Path ([IO.Path]::GetTempPath()) ('dfb-hostenv-' + [guid]::NewGuid().ToString('N')))
  $envSessionTemp = [string](Join-Path $envCase 'session-temp')
  $envDump = [string](Join-Path $envCase 'child-env.txt')
  [void][IO.Directory]::CreateDirectory((Join-Path $envCase 'gui'))
  [void][IO.Directory]::CreateDirectory($envSessionTemp)
  [IO.File]::WriteAllText((Join-Path $envCase 'gui\DeltaForceBooster-GUI.ps1'),
    $envProbeTemplate.Replace('__DUMP__', $envDump.Replace("'", "''")), (New-Object Text.UTF8Encoding($true)))
  $hostPoison = [ordered]@{
    DFB_ENV_INHERIT_PROBE = 'leaked'; COR_ENABLE_PROFILING = '1'; COR_PROFILER_PATH = 'C:\untrusted\profiler.dll'
    COMPlus_ReadyToRun = '0'; DOTNET_STARTUP_HOOKS = 'C:\untrusted\hook.dll'; PSModulePath = 'C:\untrusted\Modules'
    TEMP = 'C:\untrusted\temp'; TMP = 'C:\untrusted\temp'
  }
  $hostSaved = @{}
  $hostChild = $null
  try {
    try {
      foreach ($name in $hostPoison.Keys) {
        $hostSaved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $hostPoison[$name], 'Process')
      }
      # PS 5.1: MethodInfo.Invoke rejects PSObject-wrapped values, every argument must be cast.
      $hostChild = $startGui.Invoke($null, [object[]]@([string]$envCase, [string]$hostSid, [string]$hostLocalAppData,
        [string]$hostSession, [string]$hostPipe, [string]$envSessionTemp, [uint32]4321, [bool]$repairOnly))
      Assert-True ($hostChild.WaitForExit(60000)) 'EngineHost child GUI probe did not exit'
    } finally {
      foreach ($name in $hostPoison.Keys) { [Environment]::SetEnvironmentVariable($name, $hostSaved[$name], 'Process') }
      if ($hostChild -and -not $hostChild.HasExited) { $hostChild.Kill(); $hostChild.WaitForExit() }
      if ($hostChild) { $hostChild.Dispose() }
    }
    Assert-True (Test-Path -LiteralPath $envDump -PathType Leaf) 'EngineHost child GUI never reported its own environment'
    $childEnv = @{}   # case-insensitive, like the Win32 environment block
    foreach ($line in [IO.File]::ReadAllLines($envDump, [Text.Encoding]::UTF8)) {
      $split = $line.IndexOf('=')
      if ($split -gt 0) { $childEnv[$line.Substring(0, $split)] = $line.Substring($split + 1) }
    }
    $expected = [ordered]@{
      SystemRoot = $winDir; WINDIR = $winDir; SystemDrive = ([IO.Path]::GetPathRoot($winDir)).TrimEnd('\')
      COMSPEC = (Join-Path $sysDir 'cmd.exe')
      PATH = ($sysDir + ';' + $winDir + ';' + (Join-Path $sysDir 'Wbem') + ';' + (Join-Path $sysDir 'WindowsPowerShell\v1.0'))
      ProgramData = $commonData; ALLUSERSPROFILE = $commonData; ProgramFiles = $progFiles
      TEMP = $envSessionTemp; TMP = $envSessionTemp
      DFB_ENGINE_HOST_PID = [string]$PID; DFB_LAUNCHER_PID = '4321'
      DFB_ENGINE_HOST_SESSION = $hostSession; DFB_ORIGINAL_USER_SID = $hostSid
      DFB_ORIGINAL_LOCALAPPDATA = $hostLocalAppData; DFB_ENGINE_CONTROL_PIPE = $hostPipe
      DFB_REPAIR_ONLY = $(if ($repairOnly) { '1' } else { '0' })
    }
    if (-not [string]::IsNullOrEmpty($progFilesX86)) { $expected['ProgramFiles(x86)'] = $progFilesX86 }
    foreach ($name in $expected.Keys) {
      Assert-True ($childEnv.ContainsKey($name) -and
        [string]::Equals([string]$childEnv[$name], [string]$expected[$name], [StringComparison]::Ordinal)) `
        ("EngineHost child GUI variable is not the host-built value: $name -> " + $childEnv[$name])
    }
    # WinPS 5.1 appends .CPL to PATHEXT at startup, so only the fixed prefix is exact.
    Assert-True ($childEnv.ContainsKey('PATHEXT') -and
      $childEnv['PATHEXT'].StartsWith('.COM;.EXE;.BAT;.CMD', [StringComparison]::Ordinal)) `
      'EngineHost child GUI PATHEXT is not the fixed trusted list'
    # PSModulePath: exactly the two machine module roots, no user-writable segment.
    $moduleSegments = @(([string]$childEnv['PSModulePath']).Split(';') | Where-Object { $_ } |
      ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
    $expectedModules = @((Join-Path $sysDir 'WindowsPowerShell\v1.0\Modules'),
      (Join-Path $progFiles 'WindowsPowerShell\Modules')) | Sort-Object -Unique
    Assert-True (($moduleSegments -join '|') -eq ($expectedModules -join '|')) `
      ('EngineHost child GUI PSModulePath is not the machine-only module path: ' + $childEnv['PSModulePath'])
    # The whole point: nothing beyond the whitelist and what WinPS 5.1 itself adds for -ExecutionPolicy.
    $allowedNames = @($expected.Keys) + @('PATHEXT', 'PSModulePath', 'PSExecutionPolicyPreference')
    $leaked = @($childEnv.Keys | Where-Object { $allowedNames -notcontains $_ } | Sort-Object)
    Assert-True ($leaked.Count -eq 0) `
      ('EngineHost child GUI inherited environment variables it must not see: ' + ($leaked -join ', '))
  } finally {
    if (Test-Path -LiteralPath $envCase) { Remove-Item -LiteralPath $envCase -Recurse -Force }
  }
}

Write-Host 'PASS: EngineHost one-UAC lifetime session, OTS broker, protected state, update handoff and profiles'
