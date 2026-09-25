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

# 这份测试里的正则全是单引号字面量。经 shell heredoc 生成时 \b 曾被折叠成 U+0008（独立复核 R1），正则于是静默匹配 0 次、
# 相关断言恒真。源码里除 Tab/CR/LF 外不允许出现任何控制字符。
$selfSource = Read-Utf8 $PSCommandPath
$selfControl = [regex]::Match($selfSource, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')
Assert-True (-not $selfControl.Success) `
  ('test source contains a control character at offset ' + $selfControl.Index + '; a regex escape was probably collapsed')

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

# 在 C# 骨架里数一个局部变量/参数被赋值的次数：=、复合赋值、++/--、ref/out 都算。骨架已去掉注释和字面量。
function Get-AssignmentCount([string]$Skeleton, [string]$Name) {
  [regex]::Matches($Skeleton, '\b' + $Name + '\s*(?:<<|>>|\?\?|[-+*/%&|^])?=(?!=)').Count +
    [regex]::Matches($Skeleton, '\b(?:ref|out)\s+' + $Name + '\b|(?:\+\+|--)\s*' + $Name + '\b|\b' + $Name + '\s*(?:\+\+|--)').Count
}

# 已编译程序集的 IL 解码（W1 / EH-1）：只看真实的 call/callvirt/newobj/ldftn 目标和跳转。注释、死字符串、
# #if 预处理分支、构建脚本里的 $ 展开、using 别名都骗不过它，因为这里读的是 csc 真正产出的方法体。
# 默认只返回调用、跳转、return、throw 这几类指令；-All 返回每一条（ldstr 解析出字符串，ldc.i4* 给出整数）。
# 行：{Caller; Offset; Op; Jump; Targets; Callee; Literal}。
# 操作码表按首字节（0xFE 前缀另一张表）索引：@(操作数字节数，-1 = switch 表; 种类 0 普通/1 短跳/2 长跳/3 switch/4 方法/
# 5 字符串/6 短整数/7 整数; 是否改变控制流; 助记符; ldc.i4.N 的常量)。
$ilOneByte = New-Object object[] 256; $ilTwoByte = New-Object object[] 256
foreach ($opField in [Reflection.Emit.OpCodes].GetFields([Reflection.BindingFlags]'Public,Static')) {
  $opCode = [Reflection.Emit.OpCode]$opField.GetValue($null)
  $operand = [string]$opCode.OperandType
  $opSize = 4
  if ($operand -ceq 'InlineNone') { $opSize = 0 }
  elseif (@('ShortInlineBrTarget','ShortInlineI','ShortInlineVar') -ccontains $operand) { $opSize = 1 }
  elseif ($operand -ceq 'InlineVar') { $opSize = 2 }
  elseif (@('InlineI8','InlineR') -ccontains $operand) { $opSize = 8 }
  elseif ($operand -ceq 'InlineSwitch') { $opSize = -1 }
  $opKind = [array]::IndexOf([string[]]@('', 'ShortInlineBrTarget', 'InlineBrTarget', 'InlineSwitch', 'InlineMethod',
    'InlineString', 'ShortInlineI', 'InlineI'), $operand)
  if ($opKind -lt 0) { $opKind = 0 }
  $opJump = @('Branch','Cond_Branch','Return','Throw') -ccontains [string]$opCode.FlowControl
  $opConst = $null
  if ($opCode.Name -cmatch '^ldc\.i4\.([0-8])$') { $opConst = [int]$Matches[1] } elseif ($opCode.Name -ceq 'ldc.i4.m1') { $opConst = -1 }
  $opInfo = @($opSize, $opKind, $opJump, $opCode.Name, $opConst)
  if ($opCode.Size -eq 1) { $ilOneByte[[int]($opCode.Value -band 0xFF)] = $opInfo } else { $ilTwoByte[[int]($opCode.Value -band 0xFF)] = $opInfo }
}
function Get-ILInstructions([Reflection.MethodBase]$Method, [switch]$All) {
  $body = $Method.GetMethodBody()
  if ($null -eq $body) { return }
  $rows = New-Object System.Collections.Generic.List[object]
  $caller = $Method.DeclaringType.FullName + '::' + $Method.Name
  $il = $body.GetILAsByteArray()
  $module = $Method.Module
  $typeArgs = [Type[]]@(); $methodArgs = [Type[]]@()
  if ($Method.DeclaringType.IsGenericType) { $typeArgs = [Type[]]$Method.DeclaringType.GetGenericArguments() }
  if ($Method.IsGenericMethod) { $methodArgs = [Type[]]$Method.GetGenericArguments() }
  $n = $il.Length; $i = 0
  while ($i -lt $n) {
    $offset = $i
    if ($il[$i] -eq 0xFE) { $info = $ilTwoByte[$il[$i + 1]]; $i += 2 } else { $info = $ilOneByte[$il[$i]]; $i += 1 }
    if ($null -eq $info) { throw ('ASSERT FAILED: IL decoder met an unknown opcode in ' + $caller) }
    $size = $info[0]
    if ($size -lt 0) { $size = 4 + 4 * [BitConverter]::ToInt32($il, $i) }
    $next = $i + $size
    $kind = $info[1]
    if ($All -or ($kind -ge 1 -and $kind -le 4) -or $info[2]) {
      $targets = $null; $callee = $null; $literal = $info[4]
      if ($kind -eq 4) {
        $target = $module.ResolveMethod([BitConverter]::ToInt32($il, $i), $typeArgs, $methodArgs)
        $callee = $target.DeclaringType.FullName + '::' + $target.Name
      } elseif ($kind -eq 1) {
        $rel = [int]$il[$i]; if ($rel -gt 127) { $rel -= 256 }; $targets = @($next + $rel)
      } elseif ($kind -eq 2) { $targets = @($next + [BitConverter]::ToInt32($il, $i)) }
      elseif ($kind -eq 3) {
        $count = [BitConverter]::ToInt32($il, $i)
        $targets = @(for ($k = 0; $k -lt $count; $k++) { $next + [BitConverter]::ToInt32($il, $i + 4 + 4 * $k) })
      } elseif ($kind -eq 5) { $literal = $module.ResolveString([BitConverter]::ToInt32($il, $i)) }
      elseif ($kind -eq 6) { $literal = [int]$il[$i]; if ($literal -gt 127) { $literal -= 256 } }
      elseif ($kind -eq 7) { $literal = [BitConverter]::ToInt32($il, $i) }
      $rows.Add([pscustomobject]@{ Caller = $caller; Offset = $offset; Op = $info[3]; Jump = $info[2]; Targets = $targets
        Callee = $callee; Literal = $literal })
    }
    $i = $next
  }
  $rows.ToArray()
}
# 整个程序集每个方法体（含构造函数、编译器生成的闭包类）里的调用：{Caller; Offset; Callee}。P/Invoke 方法没有 IL，
# 单独列成 "Type::Name -> dll!EntryPoint"。
function Get-AssemblyILFacts([Reflection.Assembly]$Assembly) {
  $calls = New-Object System.Collections.Generic.List[object]
  $pinvoke = New-Object System.Collections.Generic.List[string]
  $flags = [Reflection.BindingFlags]'Static,Instance,Public,NonPublic,DeclaredOnly'
  foreach ($type in $Assembly.GetTypes()) {
    $members = New-Object System.Collections.Generic.List[Reflection.MethodBase]
    foreach ($m in $type.GetMethods($flags)) { $members.Add($m) }
    foreach ($m in $type.GetConstructors($flags)) { $members.Add($m) }
    foreach ($m in $members) {
      if (($m.Attributes -band [Reflection.MethodAttributes]::PinvokeImpl) -ne 0) {
        $import = @($m.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false))
        $pinvoke.Add($type.FullName + '::' + $m.Name + ' -> ' + $import[0].Value.ToLowerInvariant() + '!' + $import[0].EntryPoint)
        continue
      }
      foreach ($row in @(Get-ILInstructions $m)) { if ($null -ne $row.Callee) { $calls.Add($row) } }
    }
  }
  [pscustomobject]@{ Calls = $calls.ToArray(); PInvoke = $pinvoke.ToArray() }
}
# 提升启动的接线：$Method 里恰好一次 $Start 调用；恰好一次 $Enter 调用在它之前，且两者之间是不含任何其他调用的
# 直线代码（没有分支/返回/抛出，也没有别处跳进这段），所以只要走到 $Start 就一定刚走过 $Enter、中间没人改回环境；
# 恰好一次 $Restore 位于某个覆盖 $Start 的 finally 里。
function Assert-SanitizedElevationStart([Reflection.MethodBase]$Method, [string]$Enter, [string]$Start, [string]$Restore,
    [string]$Label) {
  $rows = @(Get-ILInstructions $Method)
  $callRows = @($rows | Where-Object { $null -ne $_.Callee })
  Assert-True ($callRows.Count -gt 20) ("$Label IL decoding returned too few call sites: " + $callRows.Count)
  $startRows = @($callRows | Where-Object { $_.Callee -ceq $Start })
  $enterRows = @($callRows | Where-Object { $_.Callee -ceq $Enter })
  $restoreRows = @($callRows | Where-Object { $_.Callee -ceq $Restore })
  Assert-True ($startRows.Count -eq 1) ("$Label no longer has exactly one elevated start call to ${Start}: " + $startRows.Count)
  $startAt = $startRows[0].Offset
  Assert-True ($enterRows.Count -eq 1 -and $enterRows[0].Offset -lt $startAt) `
    "$Label does not sanitize the environment before the elevated start"
  $enterAt = $enterRows[0].Offset
  $detours = New-Object System.Collections.Generic.List[string]
  foreach ($row in $rows) {
    if ($row.Offset -ge $enterAt -and $row.Offset -lt $startAt -and $row.Jump) {
      $detours.Add(('branch/return/throw at IL_{0:x4}' -f $row.Offset))
    }
    if ($row.Offset -gt $enterAt -and $row.Offset -lt $startAt -and $null -ne $row.Callee) {
      $detours.Add(('call {0} at IL_{1:x4}' -f $row.Callee, $row.Offset))
    }
    foreach ($target in @($row.Targets)) {
      if ($target -gt $enterAt -and $target -le $startAt) { $detours.Add(('jump into IL_{0:x4} from IL_{1:x4}' -f $target, $row.Offset)) }
    }
  }
  foreach ($clause in $Method.GetMethodBody().ExceptionHandlingClauses) {
    if ($clause.HandlerOffset -gt $enterAt -and $clause.HandlerOffset -le $startAt) { $detours.Add(('handler at IL_{0:x4}' -f $clause.HandlerOffset)) }
  }
  Assert-True ($detours.Count -eq 0) `
    ("$Label runs other code between sanitizing and the elevated start (the sanitizer can be skipped or undone): " + ($detours -join ', '))
  $covered = $false
  foreach ($clause in $Method.GetMethodBody().ExceptionHandlingClauses) {
    if ($clause.Flags -ne [Reflection.ExceptionHandlingClauseOptions]::Finally) { continue }
    if ($startAt -lt $clause.TryOffset -or $startAt -ge ($clause.TryOffset + $clause.TryLength)) { continue }
    foreach ($row in $restoreRows) {
      if ($row.Offset -ge $clause.HandlerOffset -and $row.Offset -lt ($clause.HandlerOffset + $clause.HandlerLength)) { $covered = $true }
    }
  }
  Assert-True ($restoreRows.Count -eq 1 -and $covered) `
    "$Label does not restore the caller environment in a finally that covers the elevated start"
}

# RunAs 启动的工作目录（复核 L-NOWD）：$Method 里恰好一次 ProcessStartInfo::set_WorkingDirectory，参数直接是
# Environment.GetFolderPath(SpecialFolder.System = 0x25) 的返回值；它在最后一次 $Start 之前，两者之间是直线代码（无分支、
# 无跳入），中间只调 ProcessStartInfo 的其他 setter 和 $Enter。去掉这一行，提权进程就从调用方可控的当前目录起步。
function Assert-SystemWorkingDirectory([Reflection.MethodBase]$Method, [string]$Start, [string]$Enter, [string]$Label) {
  $rows = @(Get-ILInstructions $Method -All)
  $wd = @(for ($k = 0; $k -lt $rows.Count; $k++) {
    if ($rows[$k].Callee -ceq 'System.Diagnostics.ProcessStartInfo::set_WorkingDirectory') { $k } })
  $starts = @(for ($k = 0; $k -lt $rows.Count; $k++) { if ($rows[$k].Callee -ceq $Start) { $k } })
  $problems = New-Object System.Collections.Generic.List[string]
  if ($wd.Count -ne 1) { $problems.Add('set_WorkingDirectory calls: ' + $wd.Count) }
  elseif ($wd[0] -lt 2 -or $rows[$wd[0] - 1].Callee -cne 'System.Environment::GetFolderPath' -or
      $rows[$wd[0] - 2].Op -cnotlike 'ldc.i4*' -or $rows[$wd[0] - 2].Literal -ne 37) {
    $problems.Add('value is not GetFolderPath(SpecialFolder.System)')
  } elseif ($starts.Count -eq 0 -or $starts[-1] -lt $wd[0]) { $problems.Add("not set before $Start") }
  else {
    $from = $rows[$wd[0]].Offset; $to = $rows[$starts[-1]].Offset
    foreach ($row in $rows) {
      if ($row.Offset -gt $from -and $row.Offset -lt $to) {
        if ($row.Jump) { $problems.Add(('branch at IL_{0:x4}' -f $row.Offset)) }
        if ($null -ne $row.Callee -and $row.Callee -cne $Enter -and
            -not $row.Callee.StartsWith('System.Diagnostics.ProcessStartInfo::set_', [StringComparison]::Ordinal)) {
          $problems.Add(('call {0} at IL_{1:x4}' -f $row.Callee, $row.Offset))
        }
      }
      foreach ($target in @($row.Targets)) {
        if ($target -gt $from -and $target -le $to) { $problems.Add(('jump into IL_{0:x4}' -f $target)) }
      }
    }
  }
  Assert-True ($problems.Count -eq 0) ("$Label does not start the elevated process from WorkingDirectory = System32: " + ($problems -join ', '))
}

# 进程环境快照（名字大小写不敏感，同 Win32 环境块）。只用 .NET、不调 cmdlet：清理函数生效期间 PSModulePath 等都不在，
# 不能触发模块自动加载。值为空串的变量按「不存在」计：.NET Framework 的 SetEnvironmentVariable(name, "") 就是删除，
# 产品的还原函数（和这里的 finally）都无法重建「存在但为空」（从带空值变量的父进程启动测试时实测）。
function Get-ProcessEnvironment {
  $snapshot = @{}
  foreach ($entry in [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).GetEnumerator()) {
    if (-not [string]::IsNullOrEmpty([string]$entry.Value)) { $snapshot[[string]$entry.Key] = [string]$entry.Value }
  }
  $snapshot
}

# RunAs 之前的环境清理（复核 W1 的行为面，主启动器与卸载入口共用）。调用方环境里放 CLR/PowerShell 注入变量、一个金丝雀、
# 一段以调用方目录开头的 PATH，白名单里其余每个名字都放一个调用方的值（「这个名字不清也不设、沿用调用方的」也会露出来），
# 并删掉白名单里的 TMP/COMSPEC。反射调用真实的 Enter 之后，整个进程环境必须恰好是固定白名单，名字和值逐项相等（前缀
# denylist、保留调用方 PATH 尾巴、漏清任何变量都红）；再调 Restore 之后必须逐项回到 Enter 之前的快照（只回填、不先删掉
# 白名单值的还原会留下 TMP/COMSPEC）。测试进程自己的环境在 finally 里按原样恢复。GetFolderPath 不随这些变量变化（WinPS 5.1 实测）。
function Assert-ElevationSanitizer([Reflection.MethodInfo]$Enter, [Reflection.MethodInfo]$Restore, [string]$Label) {
  $original = Get-ProcessEnvironment
  $canary = 'DFB_SANITIZER_CANARY'
  $system = [Environment]::GetFolderPath('System'); $windows = [Environment]::GetFolderPath('Windows')
  $programData = [Environment]::GetFolderPath('CommonApplicationData')
  $want = [ordered]@{
    SystemRoot = $windows; WINDIR = $windows; SystemDrive = ([IO.Path]::GetPathRoot($windows)).TrimEnd('\')
    COMSPEC = (Join-Path $system 'cmd.exe')
    PATH = ($system + ';' + $windows + ';' + (Join-Path $system 'Wbem') + ';' + (Join-Path $system 'WindowsPowerShell\v1.0'))
    PATHEXT = '.COM;.EXE;.BAT;.CMD'; TEMP = (Join-Path $windows 'Temp'); TMP = (Join-Path $windows 'Temp')
    ProgramData = $programData; ALLUSERSPROFILE = $programData; ProgramFiles = [Environment]::GetFolderPath('ProgramFiles')
  }
  $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
  if (-not [string]::IsNullOrEmpty($programFilesX86)) { $want['ProgramFiles(x86)'] = $programFilesX86 }
  $callerSetup = [ordered]@{
    COR_ENABLE_PROFILING = '1'; COR_PROFILER_PATH = 'C:\untrusted\profiler.dll'; COMPlus_ReadyToRun = '0'
    DOTNET_STARTUP_HOOKS = 'C:\untrusted\hook.dll'; PSModulePath = 'C:\untrusted\Modules'; TEMP = 'C:\untrusted\temp'
    PATH = 'C:\untrusted\bin;' + [string]$original['PATH']; DFB_SANITIZER_CANARY = 'leaked'; TMP = $null; COMSPEC = $null
  }
  foreach ($name in $want.Keys) { if (-not $callerSetup.Contains($name)) { $callerSetup[$name] = 'C:\untrusted\caller-' + $name } }
  $before = @{}; $entered = @{}; $restored = @{}; $saved = $null
  try {
    foreach ($name in $callerSetup.Keys) { [Environment]::SetEnvironmentVariable($name, $callerSetup[$name], 'Process') }
    $before = Get-ProcessEnvironment
    try {
      $saved = $Enter.Invoke($null, @())
      $entered = Get-ProcessEnvironment
    } finally {
      if ($null -ne $saved) { [void]$Restore.Invoke($null, [object[]]@(,$saved)) }
    }
    $restored = Get-ProcessEnvironment
  } finally {
    foreach ($name in @((Get-ProcessEnvironment).Keys)) {
      if (-not $original.ContainsKey($name)) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    }
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
  }
  $canaryKept = $entered.ContainsKey($canary)
  $extra = @($entered.Keys | Where-Object { -not $want.Contains($_) } | Sort-Object)
  Assert-True ($extra.Count -eq 0) `
    ("$Label RunAs sanitizer leaves caller variables outside the whitelist (canary kept=$canaryKept): " + ($extra -join ', '))
  foreach ($name in $want.Keys) {
    Assert-True ($entered.ContainsKey($name) -and [string]::Equals($entered[$name], [string]$want[$name], [StringComparison]::Ordinal)) `
      ("$Label RunAs sanitizer whitelist value is not the trusted one: $name -> " + $entered[$name])
  }
  $restoreDiff = @(@($before.Keys) + @($restored.Keys) | Sort-Object -Unique | ForEach-Object {
    if (-not $restored.ContainsKey($_)) { "$_ dropped" }
    elseif (-not $before.ContainsKey($_)) { "$_ left behind" }
    elseif (-not [string]::Equals($before[$_], $restored[$_], [StringComparison]::Ordinal)) { "$_ changed" }
  })
  Assert-True ($before.ContainsKey($canary) -and -not $before.ContainsKey('TMP') -and $restoreDiff.Count -eq 0) `
    ("$Label RunAs environment restore does not return the exact pre-sanitizer environment: " + ($restoreDiff -join ', '))
}

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
# 这条只证明清理函数存在（正则同样匹配到方法定义本身、也匹配注释）。清理的效果由文件后面反射调用真实清理/还原函数的
# 整环境比对守（Assert-ElevationSanitizer），它确实包住唯一的 RunAs 启动由已编译 LaunchEngineHost / 卸载入口 Main 的
# IL 接线检查守（复核 W1）。
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
Assert-True ([string]::Equals(($envKeys -join '|'), ($expectedEnvKeys -join '|'), [StringComparison]::Ordinal)) `
  ('StartGui child environment whitelist is not the exact expected set: ' + ($envKeys -join ', '))
# EnvironmentVariables 只允许出现在 StartGui：恰好一次 Clear()，加上白名单里每个键各一次字面量写入。两边的计数都钉在
# 白名单大小上（20 键 + 1 次 Clear = 21）：正则一旦失效（例如 \b 被写成 U+0008）得到的是 0，而不是「两边都是 0 所以相等」。
$hostEnvBlockRefs = [regex]::Matches($hostSkel, '\bEnvironmentVariables\b').Count
$startGuiEnvBlockRefs = [regex]::Matches($startGuiSkel, '\bEnvironmentVariables\b').Count
$startGuiEnvClears = [regex]::Matches($startGuiSkel, '\bpsi\s*\.\s*EnvironmentVariables\s*\.\s*Clear\s*\(\s*\)').Count
Assert-True ($startGuiEnvClears -eq 1 -and $envWrites.Count -eq $expectedEnvKeys.Count -and
  $startGuiEnvBlockRefs -eq ($expectedEnvKeys.Count + 1) -and $hostEnvBlockRefs -eq $startGuiEnvBlockRefs) `
  ('EngineHost touches a child environment block outside the StartGui whitelist (host refs ' + $hostEnvBlockRefs +
   ', StartGui refs ' + $startGuiEnvBlockRefs + ', Clear ' + $startGuiEnvClears + ', literal writes ' + $envWrites.Count +
   ', expected ' + ($expectedEnvKeys.Count + 1) + ')')
# 进程自身环境的托管入口只剩 Environment.GetFolderPath / Environment.SpecialFolder：标识符 Environment 的每一次出现都必须
# 是这两种静态访问之一。Environment.GetEnvironmentVariable / ExpandEnvironmentVariables / GetCommandLineArgs、
# 当前进程 StartInfo.Environment[...]（.NET 4.6 的字典视图，不含 EnvironmentVariables 字样）、psi.Environment、
# typeof(Environment)、using 别名都会留下一个不是静态访问的 Environment。
$hostEnvStaticAccess = [regex]'\GEnvironment\s*\.\s*(GetFolderPath|SpecialFolder)\b'
$hostEnvTokens = @([regex]::Matches($hostSkel, '\bEnvironment\b'))
$hostEnvOther = @($hostEnvTokens | Where-Object { -not $hostEnvStaticAccess.Match($hostSkel, $_.Index).Success } |
  ForEach-Object {
    $from = [Math]::Max(0, $_.Index - 40)
    Get-NormalizedCode $hostSkel.Substring($from, [Math]::Min(80, $hostSkel.Length - $from))
  })
Assert-True ($hostEnvTokens.Count -gt 0 -and $hostEnvOther.Count -eq 0) `
  ('EngineHost reads or writes its own process environment outside Environment.GetFolderPath: ' + ($hostEnvOther -join ' | '))

# (3) 全 EngineHost 只有 StartGui 里那一处起进程。
Assert-True ([regex]::Matches($hostSkel, '\bProcess\s*\.\s*Start\s*\(').Count -eq 1 -and
  $startGuiSkel -match '\bProcess\s*\.\s*Start\s*\(\s*psi\s*\)' -and
  [regex]::Matches($hostSkel, '\bProcessStartInfo\b').Count -eq 1 -and
  $hostSkel -notmatch '\bnew\s+(System\s*\.\s*Diagnostics\s*\.\s*)?Process\s*\(' -and
  $hostSkel -notmatch '\.\s*Start\s*\(\s*\)' -and
  $hostCode -notmatch '(?i)CreateProcess|(?<![A-Za-z])ShellExecute|WinExec') `
  'EngineHost starts a child process outside the sanitized StartGui path'

# (3b) 上面几条只扫 $cs。EngineHost.exe 由同一条 csc 同时编入 runtime-root-validation.cs 和 token-validation.cs，
#      其中 IsTestBypass（读 DFB_TEST_SKIP_ACL 跳过安装根校验）只能活在 #if DFB_TESTING 里。生产构建的 csc 不得定义
#      任何符号，编译单元恰好这三个；三个单元编出来的真实 IL 由构建后的「整个 EngineHost.exe」IL 检查守（复核 EH-1）。
$hostCsc = @($hostBuildAst.FindAll({ param($n)
  $n -is [Management.Automation.Language.CommandAst] -and
  $n.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
  $n.CommandElements[0].Extent.Text -ceq '$csc' }, $true))
Assert-True ($hostCsc.Count -eq 1) 'EngineHost csc invocation is missing or duplicated'
$hostCscArgs = @($hostCsc[0].CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text })
$hostCscSources = @($hostCscArgs | Where-Object { -not $_.StartsWith('/') })
$hostCscDefines = @($hostCscArgs | Where-Object { $_ -match '^[/-](d|define)[:+]' -or $_.StartsWith('@') })
Assert-True ($hostCscArgs.Count -gt 3 -and $hostCscDefines.Count -eq 0 -and
  [string]::Equals(($hostCscSources -join '|'), '"$runtimeValidation"|"$tokenValidation"|"$source"', [StringComparison]::Ordinal)) `
  ('production EngineHost csc defines preprocessor symbols or changed compilation units: ' + ($hostCscArgs -join ' '))

# (4) 调用链钉死：Main -> RunGuiAndServe -> StartGui 各只有一处，值来自令牌验证与宿主自建目录。
Assert-True ([regex]::Matches($hostSkel, '\bStartGui\s*\(').Count -eq 2 -and
  [regex]::Matches($runGuiSkel, '\bStartGui\s*\(').Count -eq 1 -and
  (Get-NormalizedCode $runGuiCode).Contains('using (Process guiProcess = StartGui(root, sid, localAppData, session, controlPipeName, sessionTemp, launcherPid, launcher.RepairOnly))') -and
  (Get-NormalizedCode $runGuiCode).Contains('string sessionTemp = CreateSessionTemp(session);') -and
  [regex]::Matches($runGuiSkel, '\bsessionTemp\s*=(?!=)').Count -eq 1 -and
  $runGuiSkel -notmatch '\b(ref|out)\s+sessionTemp\b') `
  'RunGuiAndServe does not hand StartGui the host-created session temp through the single sanitized call'
# DFB_ENGINE_CONTROL_PIPE 的值同样在 RunGuiAndServe 里生成：只能是固定前缀加 CSPRNG 的 RandomHex()，且只赋值一次。
# 反射行为层自己传管道名，看不到这里；改成 session（启动器和命令行都知道）或调用方可控的值会在这里红。
Assert-True ([regex]::Matches($runGuiSkel, '\bcontrolPipeName\s*=(?!=)').Count -eq 1 -and
  $runGuiSkel -notmatch '\b(ref|out)\s+controlPipeName\b' -and
  (Get-NormalizedCode $runGuiCode).Contains('string controlPipeName = "DeltaForceBooster.Engine." + RandomHex();')) `
  'RunGuiAndServe does not hand StartGui a fresh random control pipe name'
Assert-True ([regex]::Matches($hostSkel, '\bRunGuiAndServe\s*\(').Count -eq 2 -and
  (Get-NormalizedCode $hostMainCode).Contains('return RunGuiAndServe(root, launcher.OriginalSid, launcher.OriginalLocalAppData, session, launcherPid, launcher);')) `
  'EngineHost Main does not hand RunGuiAndServe the launcher-token-verified identity'
# 反射行为层自己给 StartGui 传 root/session/sid……，看不到调用链中途的改写：root 决定高权限子进程 -File 的脚本，
# session 会拼进 CreateSessionTemp 的目录。所以 RunGuiAndServe 不得改写任何参数；Main 里 root 只来自
# AppDomain.BaseDirectory（随后 ValidateFiles 复验），session 只来自命令行 args[5]，且在任何使用之前先过 IsHex32
# （挡 ..\ 目录穿越）。改成环境变量、注册表、P/Invoke、反射或别的命令行参数，都需要多一次赋值或绕开这道校验。
$runGuiParamWrites = @(foreach ($name in 'root','sid','localAppData','session','launcherPid','launcher') {
  $writes = Get-AssignmentCount $runGuiSkel $name
  if ($writes -ne 0) { "$name x$writes" }
})
$runGuiLauncherWrites = [regex]::Matches($runGuiSkel, '\blauncher\s*\.\s*[A-Za-z_]\w*\s*(?:<<|>>|\?\?|[-+*/%&|^])?=(?!=)').Count
Assert-True ($runGuiSkel.Contains('controlPipeName') -and $runGuiParamWrites.Count -eq 0 -and $runGuiLauncherWrites -eq 0) `
  ('RunGuiAndServe rewrites a verified value before handing it to StartGui: ' + ($runGuiParamWrites -join ', ') +
   ' / launcher member writes ' + $runGuiLauncherWrites)
$hostMainSkel = $hostSkel.Substring($hostMainSpan.Start, $hostMainSpan.Length)
$hostMainNorm = Get-NormalizedCode $hostMainCode
$mainSessionAt = $hostMainNorm.IndexOf('string session = args[5];', [StringComparison]::Ordinal)
$mainHexGateAt = $hostMainNorm.IndexOf('|| !IsHex32(session)) throw new InvalidOperationException(', [StringComparison]::Ordinal)
$mainAuthAt = $hostMainNorm.IndexOf('AuthenticateLauncher(pipeName, session, launcherPid, root)', [StringComparison]::Ordinal)
Assert-True ((Get-AssignmentCount $hostMainSkel 'session') -eq 1 -and $mainSessionAt -ge 0 -and
  $mainHexGateAt -gt $mainSessionAt -and $mainAuthAt -gt $mainHexGateAt -and
  [regex]::Matches($hostMainSkel, '\bIsHex32\s*\(\s*session\s*\)').Count -eq 1) `
  'EngineHost Main does not take the session only from args[5] behind the IsHex32 gate'
Assert-True ((Get-AssignmentCount $hostMainSkel 'root') -eq 1 -and
  $hostMainNorm.Contains('string root = AppDomain.CurrentDomain.BaseDirectory; string validationError = ValidateFiles(root);')) `
  'EngineHost Main does not take the install root only from its own validated base directory'

# (5) StartGui 写进子进程的 TEMP/TMP 来自 CreateSessionTemp。反射行为层自己传 sessionTemp，看不到它；生产 EngineHost.exe
#     里的 CreateSessionTemp 也不能直接跑：非提权时 EnsureAdminSystemDirectory 在 return 之前就抛，提权时又会重写真实
#     ProgramData\DeltaForceBooster 的 ACL。所以分两层：
#     a. 词表封闭（同 StartGui）：Path.GetTempPath、ExpandEnvironmentVariables、Registry/HKCU、Process.StartInfo、
#        LocalApplicationData、别的静态字段或辅助方法……任何新来源都会带进词表外的标识符。
#     b. 把原函数体原样编译进一个只把 EnsureAdminSystemDirectory 换成「记录路径」的外壳，在 TEMP/TMP/ProgramData 等
#        调用方可控变量全部投毒时执行。返回值必须逐字等于 GUI 自举校验的
#        <CommonApplicationData>\DeltaForceBooster\session-temp\<session>，三级目录必须父到子逐级经过
#        EnsureAdminSystemDirectory。骨架里看不见的字面量改动在这一层红。
$sessionTempSpan = Get-CSharpBodySpan $hostSkel 'static string CreateSessionTemp(string session)'
$sessionTempSkel = $hostSkel.Substring($sessionTempSpan.Start, $sessionTempSpan.Length)
$sessionTempVocabulary = @('Combine','common','CommonApplicationData','EnsureAdminSystemDirectory','Environment',
  'GetFolderPath','Path','product','return','session','sessionRoot','SpecialFolder','string','tempRoot')
$sessionTempIds = @([regex]::Matches($sessionTempSkel, '\b[A-Za-z_][A-Za-z0-9_]*\b') | ForEach-Object { $_.Value } |
  Sort-Object -Unique -CaseSensitive)
$sessionTempAdded = @($sessionTempIds | Where-Object { $sessionTempVocabulary -cnotcontains $_ })
$sessionTempDropped = @($sessionTempVocabulary | Where-Object { $sessionTempIds -cnotcontains $_ })
Assert-True ($sessionTempAdded.Count -eq 0 -and $sessionTempDropped.Count -eq 0) `
  ('EngineHost CreateSessionTemp vocabulary changed; review where the child TEMP comes from. added: ' +
   ($sessionTempAdded -join ', ') + ' / dropped: ' + ($sessionTempDropped -join ', '))

$hostUsingText = $hostSkel.Substring(0, $hostSkel.IndexOf('static class EngineHost', [StringComparison]::Ordinal))
$hostUsings = @([regex]::Matches($hostUsingText, '(?m)^[ \t]*using[ \t]+[A-Za-z_][\w.]*[ \t]*;') |
  ForEach-Object { $_.Value.Trim() })
Assert-True ($hostUsings -ccontains 'using System;' -and $hostUsings -ccontains 'using System.IO;') `
  'EngineHost C# using directives were not found for the CreateSessionTemp harness'
$sessionTempHarnessName = 'DfbSessionTempHarness' + [guid]::NewGuid().ToString('N')
$sessionTempHarnessSource = ($hostUsings -join "`r`n") + "`r`npublic static class $sessionTempHarnessName {`r`n" +
  "    public static readonly System.Collections.Generic.List<string> Ensured = new System.Collections.Generic.List<string>();`r`n" +
  "    static void EnsureAdminSystemDirectory(string path) { Ensured.Add(path); }`r`n" +
  "    public static string CreateSessionTemp(string session) " +
  $hostCsText.Substring($sessionTempSpan.Start, $sessionTempSpan.Length) + "`r`n}`r`n"
$sessionTempHarness = @(); $sessionTempHarnessError = ''
try {
  # PS 5.1 Add-Type 默认把编译警告当错误；这里要的是行为，所以 -IgnoreWarnings。
  $sessionTempHarness = @(Add-Type -TypeDefinition $sessionTempHarnessSource -Language CSharp -IgnoreWarnings -PassThru `
    -ReferencedAssemblies 'System.Windows.Forms' | Where-Object { $_.Name -eq $sessionTempHarnessName })
} catch { $sessionTempHarnessError = $_.Exception.Message }
Assert-True ($sessionTempHarness.Count -eq 1) ('CreateSessionTemp body does not compile on its own: ' + $sessionTempHarnessError)
$sessionTempType = $sessionTempHarness[0]
$sessionTempCommon = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
Assert-True (-not [string]::IsNullOrEmpty($sessionTempCommon)) 'CommonApplicationData is not resolvable for the CreateSessionTemp harness'
# GetFolderPath(CommonApplicationData) 不随这些变量变化（WinPS 5.1 实测）；GetTempPath、ExpandEnvironmentVariables、
# StartInfo.Environment[Variables]、HKCU\Environment 的 TEMP、HKLM ProfileList 的 %SystemDrive%\ProgramData 都会带出投毒值。
$sessionTempPoison = [ordered]@{}
foreach ($name in 'TEMP','TMP','ProgramData','ALLUSERSPROFILE','USERPROFILE','LOCALAPPDATA','APPDATA','PUBLIC',
    'SystemDrive','SystemRoot','windir','HOMEDRIVE','HOMEPATH') {
  $sessionTempPoison[$name] = 'C:\DfbPoison\' + $name
}
foreach ($sessionCase in @('0123456789abcdef0123456789abcdef', 'fedcba9876543210fedcba9876543210')) {
  $sessionTempType::Ensured.Clear()
  $madeTemp = $null; $madeError = ''; $poisonSaved = @{}
  try {
    foreach ($name in $sessionTempPoison.Keys) {
      $poisonSaved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
      [Environment]::SetEnvironmentVariable($name, $sessionTempPoison[$name], 'Process')
    }
    try { $madeTemp = [string]$sessionTempType::CreateSessionTemp($sessionCase) } catch { $madeError = ' / threw: ' + $_.Exception.Message }
  } finally {
    foreach ($name in $sessionTempPoison.Keys) { [Environment]::SetEnvironmentVariable($name, $poisonSaved[$name], 'Process') }
  }
  $wantProduct = [IO.Path]::Combine($sessionTempCommon, 'DeltaForceBooster')
  $wantTempRoot = [IO.Path]::Combine($wantProduct, 'session-temp')
  $wantSession = [IO.Path]::Combine($wantTempRoot, $sessionCase)
  Assert-True ($madeError -eq '' -and [string]::Equals($madeTemp, $wantSession, [StringComparison]::Ordinal)) `
    ('CreateSessionTemp does not return the protected per-session directory the GUI bootstrap expects: ' + $madeTemp + $madeError)
  $ensured = @($sessionTempType::Ensured)
  Assert-True ($ensured.Count -eq 3 -and
    [string]::Equals(($ensured -join '|'), (@($wantProduct, $wantTempRoot, $wantSession) -join '|'), [StringComparison]::Ordinal)) `
    ('CreateSessionTemp does not protect product, session-temp and session directories parent-first: ' + ($ensured -join ' ; '))
}
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
# 整文件正则连注释都会匹配，只是存在性提示；真正的守卫在后面：卸载入口清理/还原的整环境行为比对，
# UninstallHost.StartScript 的 IL（Clear 先于每次写入和唯一的 Process.Start、字面量键白名单）。
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
  # 后面生产二进制的「DFB_TEST_SKIP_ACL 不得放行」检查的正对照：刚编出的 DFB_TESTING 启动器，对 %TEMP%\
  # DeltaForceBooster-Tests 下的根，只在 DFB_TEST_SKIP_ACL=1 时放行。这条不成立时，生产检查根本走不到旁路点，会空转。
  $rootBypassSaved = [Environment]::GetEnvironmentVariable('DFB_TEST_SKIP_ACL', 'Process')
  $bypassControlOn = 'unset'; $bypassControlOff = $null
  try {
    $testRuntimeRoot = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root '启动优化工具.exe'))).GetType('DfbRuntimeRoot', $true)
    [Environment]::SetEnvironmentVariable('DFB_TEST_SKIP_ACL', '1', 'Process')
    $bypassControlOn = $testRuntimeRoot.GetMethod('Validate').Invoke($null, [object[]]@([string]$testRoot))
    [Environment]::SetEnvironmentVariable('DFB_TEST_SKIP_ACL', $null, 'Process')
    $bypassControlOff = $testRuntimeRoot.GetMethod('Validate').Invoke($null, [object[]]@([string]$testRoot))
  } finally { [Environment]::SetEnvironmentVariable('DFB_TEST_SKIP_ACL', $rootBypassSaved, 'Process') }
  Assert-True ($null -eq $bypassControlOn -and -not [string]::IsNullOrEmpty([string]$bypassControlOff)) `
    ('DFB_TESTING launcher root-bypass positive control failed (with=' + [string]$bypassControlOn +
     ' / without=' + [string]$bypassControlOff + '); the production bypass check would be vacuous')
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

# EH-1：整个生产 EngineHost.exe（三个编译单元编出来的真实 IL，含编译器生成的闭包类）里：System.Environment 只调
# GetFolderPath；子进程环境块只在 StartGui 里取 21 次（1 次 Clear + 20 个白名单键）；不碰 StartInfo.Environment、
# 当前进程 StartInfo、GetTempPath；全程序集只有 StartGui 一处 Process.Start；P/Invoke 入口固定为 11 个（没有
# GetEnvironmentVariableW、CreateProcessW、ShellExecuteExW 之类）。去掉 #if DFB_TESTING、给 csc 加符号、构建脚本
# 用 $ 展开往 $cs 里塞代码、在 runtime-root-validation.cs / token-validation.cs 里新读环境，文本骨架都看不到，这里都红。
$hostAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root 'EngineHost.exe')))
$hostIl = Get-AssemblyILFacts $hostAssembly
$hostIlCalls = @($hostIl.Calls)
Assert-True ($hostIlCalls.Count -gt 400 -and @($hostIlCalls | Where-Object { $_.Caller -ceq 'EngineHost::StartGui' }).Count -gt 40 -and
  @($hostIlCalls | Where-Object { $_.Caller -ceq 'DfbRuntimeRoot::Validate' }).Count -gt 10 -and
  @($hostIlCalls | Where-Object { $_.Caller -ceq 'DfbTokenValidation::ReadToken' }).Count -gt 5) `
  ('production EngineHost.exe IL scan did not see all three compilation units: ' + $hostIlCalls.Count + ' call sites')
$hostEnvCalls = @($hostIlCalls | Where-Object { $_.Callee.StartsWith('System.Environment::', [StringComparison]::Ordinal) })
$hostEnvOtherCalls = @($hostEnvCalls | Where-Object { $_.Callee -cne 'System.Environment::GetFolderPath' } |
  ForEach-Object { $_.Caller + ' -> ' + $_.Callee })
Assert-True ($hostEnvCalls.Count -gt 0 -and $hostEnvOtherCalls.Count -eq 0) `
  ('production EngineHost.exe reads or writes its own process environment: ' + ($hostEnvOtherCalls -join ', '))
$hostBlockCalls = @($hostIlCalls | Where-Object { $_.Callee -ceq 'System.Diagnostics.ProcessStartInfo::get_EnvironmentVariables' })
$hostBlockOutside = @($hostBlockCalls | Where-Object { $_.Caller -cne 'EngineHost::StartGui' } | ForEach-Object { $_.Caller })
$hostEnvRoutes = @($hostIlCalls | Where-Object { @('System.Diagnostics.ProcessStartInfo::get_Environment',
    'System.Diagnostics.Process::get_StartInfo', 'System.IO.Path::GetTempPath', 'System.IO.Path::GetTempFileName') -ccontains $_.Callee } |
  ForEach-Object { $_.Caller + ' -> ' + $_.Callee })
Assert-True ($hostBlockCalls.Count -eq ($expectedEnvKeys.Count + 1) -and $hostBlockOutside.Count -eq 0 -and $hostEnvRoutes.Count -eq 0) `
  ('production EngineHost.exe touches an environment block outside the StartGui whitelist (EnvironmentVariables refs ' +
   $hostBlockCalls.Count + ', expected ' + ($expectedEnvKeys.Count + 1) + '; outside StartGui: ' + ($hostBlockOutside -join ', ') +
   '; other routes: ' + ($hostEnvRoutes -join ', ') + ')')
$hostStarts = @($hostIlCalls | Where-Object { @('System.Diagnostics.Process::Start', 'System.Diagnostics.Process::.ctor') -ccontains $_.Callee })
Assert-True ($hostStarts.Count -eq 1 -and $hostStarts[0].Caller -ceq 'EngineHost::StartGui' -and
  $hostStarts[0].Callee -ceq 'System.Diagnostics.Process::Start') `
  ('production EngineHost.exe starts a process outside StartGui: ' + (($hostStarts | ForEach-Object { $_.Caller + ' -> ' + $_.Callee }) -join ', '))
$expectedHostPInvoke = @(
  'DfbRuntimeRoot::ConvertSecurityDescriptorToStringSecurityDescriptor -> advapi32.dll!ConvertSecurityDescriptorToStringSecurityDescriptorW',
  'DfbRuntimeRoot::GetNamedSecurityInfo -> advapi32.dll!GetNamedSecurityInfoW',
  'DfbRuntimeRoot::LocalFree -> kernel32.dll!LocalFree',
  'DfbTokenValidation::CloseHandle -> kernel32.dll!CloseHandle',
  'DfbTokenValidation::GetTokenInformation -> advapi32.dll!GetTokenInformation',
  'DfbTokenValidation::OpenProcessToken -> advapi32.dll!OpenProcessToken',
  'EngineHost::CloseHandle -> kernel32.dll!CloseHandle',
  'EngineHost::GetNamedPipeClientProcessId -> kernel32.dll!GetNamedPipeClientProcessId',
  'EngineHost::GetNamedPipeServerProcessId -> kernel32.dll!GetNamedPipeServerProcessId',
  'EngineHost::OpenProcess -> kernel32.dll!OpenProcess',
  'EngineHost::QueryFullProcessImageName -> kernel32.dll!QueryFullProcessImageName') | Sort-Object -CaseSensitive
$hostPInvoke = @($hostIl.PInvoke | Sort-Object -CaseSensitive)
Assert-True ([string]::Equals(($hostPInvoke -join '|'), ($expectedHostPInvoke -join '|'), [StringComparison]::Ordinal)) `
  ('production EngineHost.exe native imports changed; review environment/process access: ' + ($hostPInvoke -join ', '))

# DfbRuntimeRoot（build\runtime-root-validation.cs）同时编进生产 EngineHost.exe 和启动器。只有 DFB_TESTING 启动器可以
# 认 DFB_TEST_SKIP_ACL（上面的正对照）；生产二进制对同一类根，有没有这个变量都必须给出同一条非空拒绝。
$rootBypassProbe = Join-Path ([IO.Path]::GetTempPath()) ('DeltaForceBooster-Tests\root-bypass-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($rootBypassProbe)
$rootBypassSaved = [Environment]::GetEnvironmentVariable('DFB_TEST_SKIP_ACL', 'Process')
try {
  foreach ($exeName in 'EngineHost.exe', '启动优化工具.exe') {
    $prodRuntimeRoot = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root $exeName))).GetType('DfbRuntimeRoot', $true)
    [Environment]::SetEnvironmentVariable('DFB_TEST_SKIP_ACL', $null, 'Process')
    $prodOff = [string]$prodRuntimeRoot.GetMethod('Validate').Invoke($null, [object[]]@([string]$rootBypassProbe))
    [Environment]::SetEnvironmentVariable('DFB_TEST_SKIP_ACL', '1', 'Process')
    $prodOn = $prodRuntimeRoot.GetMethod('Validate').Invoke($null, [object[]]@([string]$rootBypassProbe))
    [Environment]::SetEnvironmentVariable('DFB_TEST_SKIP_ACL', $null, 'Process')
    Assert-True ($prodOff.Length -gt 0 -and [string]::Equals([string]$prodOn, $prodOff, [StringComparison]::Ordinal)) `
      ("production $exeName root validation honours DFB_TEST_SKIP_ACL: with=" + [string]$prodOn + ' / without=' + $prodOff)
    Assert-True ($null -eq $prodRuntimeRoot.GetMethod('IsTestBypass', [Reflection.BindingFlags]'Static,Public,NonPublic')) `
      "production $exeName still contains the DFB_TESTING root-validation bypass method"
  }
} finally {
  [Environment]::SetEnvironmentVariable('DFB_TEST_SKIP_ACL', $rootBypassSaved, 'Process')
  Remove-Item -LiteralPath $rootBypassProbe -Recurse -Force -ErrorAction SilentlyContinue
}

# Main 里 session（命令行 args[5]）唯一的闸门是 IsHex32；它拼进 CreateSessionTemp 的目录，所以必须挡住 ..\ 之类。
$isHex32 = $hostAssembly.GetType('EngineHost', $true).GetMethod('IsHex32', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $isHex32) 'EngineHost.IsHex32 is not reachable for the session argument check'
$hexCases = @(
  @('0123456789abcdef0123456789abcdef', $true), @('FEDCBA9876543210FEDCBA9876543210', $true),
  @('..\..\..\..\..\..\..\..\..\..\ab', $false), @('C:\ProgramData\0123456789abcdef0', $false),
  @('0123456789abcdef0123456789abcde', $false), @('0123456789abcdef0123456789abcdef0', $false),
  @('0123456789abcdef0123456789abcdeg', $false), @('', $false))
foreach ($hexCase in $hexCases) {
  $hexSeen = [bool]$isHex32.Invoke($null, [object[]]@([string]$hexCase[0]))
  Assert-True ($hexSeen -eq [bool]$hexCase[1]) `
    ("EngineHost.IsHex32 misjudges a command-line session: '" + $hexCase[0] + "' -> " + $hexSeen)
}

# 会话临时目录的保护（复核 EASD-NOCHECK）。高权限 GUI 的 TEMP/TMP 指向这里，唯一的保护是「目录只归 Administrators/SYSTEM」。
# 直接反射调用刚编出的生产 EngineHost.exe 里真实的 IsExactAdminSystemDirectory / EnsureAdminSystemDirectory，非提权就能跑：
# 用户自建的目录（默认继承 ACL；或者 DACL 恰好只剩 Administrators/SYSTEM、所有者仍是用户）都必须判为不合格；对这样一个已存在
# 的目录，EnsureAdminSystemDirectory 必须在写 ACL 之前抛「已被不安全地预占」，ACL 原样不动。提权后才走得到的那一段
# （SetAccessControl 之后的复验）由紧接着的 IL 调用序列钉住。
$easdType = $hostAssembly.GetType('EngineHost', $true)
$easdIsExact = $easdType.GetMethod('IsExactAdminSystemDirectory', [Reflection.BindingFlags]'Static,NonPublic')
$easdEnsure = $easdType.GetMethod('EnsureAdminSystemDirectory', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $easdIsExact -and $null -ne $easdEnsure) `
  'EngineHost session-temp ACL helpers are not reachable for the pre-existing directory check'
$easdRoot = Join-Path ([IO.Path]::GetTempPath()) ('dfb-easd-' + [guid]::NewGuid().ToString('N'))
$easdCases = [ordered]@{ 'default user ACL' = (Join-Path $easdRoot 'default'); 'user-owned admin/SYSTEM-only DACL' = (Join-Path $easdRoot 'owned') }
$easdSections = [Security.AccessControl.AccessControlSections]'Owner,Group,Access'
$easdInherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
try {
  foreach ($easdPath in $easdCases.Values) { [void][IO.Directory]::CreateDirectory($easdPath) }
  $easdOwnedAcl = New-Object Security.AccessControl.DirectorySecurity
  $easdOwnedAcl.SetAccessRuleProtection($true, $false)
  foreach ($easdSid in 'S-1-5-32-544', 'S-1-5-18') {
    $easdOwnedAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
      (New-Object Security.Principal.SecurityIdentifier($easdSid)), [Security.AccessControl.FileSystemRights]::FullControl,
      $easdInherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
  }
  [IO.Directory]::SetAccessControl([string]$easdCases['user-owned admin/SYSTEM-only DACL'], $easdOwnedAcl)
  foreach ($easdCase in $easdCases.Keys) {
    $easdPath = [string]$easdCases[$easdCase]
    $easdBefore = [IO.Directory]::GetAccessControl($easdPath, $easdSections).GetSecurityDescriptorSddlForm($easdSections)
    $easdExact = [bool]$easdIsExact.Invoke($null, [object[]]@($easdPath))
    Assert-True (-not $easdExact) "EngineHost.IsExactAdminSystemDirectory accepts a user-created directory ($easdCase)"
    $easdError = '<returned without an exception>'
    try { [void]$easdEnsure.Invoke($null, [object[]]@($easdPath)) } catch {
      $easdInner = $_.Exception.GetBaseException()
      $easdError = $easdInner.GetType().FullName + ': ' + $easdInner.Message
    }
    $easdAfter = [IO.Directory]::GetAccessControl($easdPath, $easdSections).GetSecurityDescriptorSddlForm($easdSections)
    Assert-True ([string]::Equals($easdError, 'System.InvalidOperationException: 受保护会话目录已被不安全地预占：' + $easdPath,
        [StringComparison]::Ordinal) -and [string]::Equals($easdAfter, $easdBefore, [StringComparison]::Ordinal)) `
      ("EngineHost.EnsureAdminSystemDirectory does not refuse a pre-existing user directory before touching its ACL ($easdCase): " +
       $easdError + $(if ($easdAfter -cne $easdBefore) { ' / ACL changed to ' + $easdAfter }))
  }
} finally {
  if (Test-Path -LiteralPath $easdRoot) {
    try {
      $easdReset = New-Object Security.AccessControl.DirectorySecurity
      $easdReset.SetAccessRuleProtection($false, $false)
      $easdReset.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.AccessControl.FileSystemRights]::FullControl, $easdInherit, [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)))
      [IO.Directory]::SetAccessControl([string]$easdCases['user-owned admin/SYSTEM-only DACL'], $easdReset)
    } catch { }
    Remove-Item -LiteralPath $easdRoot -Recurse -Force
  }
}
$easdCalls = @(@(Get-ILInstructions $easdEnsure) | Where-Object { $null -ne $_.Callee } | ForEach-Object { $_.Callee -replace '^EngineHost::', '' })
$easdExpectedCalls = @('CreateAdminSystemDirectorySecurity', 'System.IO.Directory::Exists', 'IsExactAdminSystemDirectory',
  'System.String::Concat', 'System.InvalidOperationException::.ctor', 'System.IO.Path::GetDirectoryName', 'System.String::IsNullOrEmpty',
  'PathHasReparsePoint', 'System.String::Concat', 'System.InvalidOperationException::.ctor', 'System.IO.Directory::CreateDirectory',
  'System.IO.Directory::SetAccessControl', 'IsExactAdminSystemDirectory', 'System.String::Concat', 'System.InvalidOperationException::.ctor')
Assert-True ([string]::Equals(($easdCalls -join ' > '), ($easdExpectedCalls -join ' > '), [StringComparison]::Ordinal)) `
  ('EngineHost.EnsureAdminSystemDirectory call sequence changed (the post-ACL verification only runs elevated): ' + ($easdCalls -join ' > '))

# 管理员启动的 RunAs 边界（复核 W1）。行为面：反射调用生产启动器真实的清理/还原函数，见 Assert-ElevationSanitizer——
# 清理后整个进程环境恰好是固定白名单，还原后逐项回到清理前。
$launcherAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root '启动优化工具.exe')))
$launcherType = $launcherAssembly.GetType('Launcher', $true)
$enterEnv = $launcherType.GetMethod('EnterTrustedElevationEnvironment', [Reflection.BindingFlags]'Static,NonPublic')
$restoreEnv = $launcherType.GetMethod('RestoreProcessEnvironment', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $enterEnv -and $null -ne $restoreEnv) 'Launcher RunAs environment sanitizer is not reachable'
Assert-ElevationSanitizer $enterEnv $restoreEnv 'main launcher'

# W1：上面的反射只证明清理函数被直接调用时管用。这里证明编译出的生产 LaunchEngineHost 真在唯一的 RunAs 启动前
# 调它、中间没有能绕开它的分支，并在覆盖启动的 finally 里还原；全程序集也只有 LaunchEngineHost 调 RunAs 启动函数。
# 读的是 IL 调用目标和跳转：注释、死分支、条件分支里的调用、定义了却不调的函数都过不了。
$launchHost = $launcherType.GetMethod('LaunchEngineHost', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $launchHost) 'Launcher.LaunchEngineHost is not reachable for the RunAs wiring check'
Assert-SanitizedElevationStart $launchHost 'Launcher::EnterTrustedElevationEnvironment' 'Launcher::StartEngineHostWithPolicyFallback' `
  'Launcher::RestoreProcessEnvironment' 'production Launcher.LaunchEngineHost'
$runAsCallers = @(@((Get-AssemblyILFacts $launcherAssembly).Calls) |
  Where-Object { $_.Callee -ceq 'Launcher::StartEngineHostWithPolicyFallback' } | ForEach-Object { $_.Caller })
Assert-True ($runAsCallers.Count -eq 1 -and $runAsCallers[0] -ceq 'Launcher::LaunchEngineHost') `
  ('RunAs start helper is reachable from an unsanitized caller: ' + ($runAsCallers -join ', '))
Assert-SystemWorkingDirectory $launchHost 'Launcher::StartEngineHostWithPolicyFallback' 'Launcher::EnterTrustedElevationEnvironment' `
  'production Launcher.LaunchEngineHost'

# 签名策略回退（复核 FB-NOPROFILE / L-NOWD）：要 UAC 且要策略返回 8235，测试跑不到，只能钉 IL。fallback.Arguments 恰好赋值
# 一次，值是固定字面量直接拼 Base64 命令（ldstr <字面量>; ldloc; String::Concat; set_Arguments）；少了 -NoProfile，高权限
# PowerShell 就会加载 medium 用户可写的 profile 脚本。工作目录同 LaunchEngineHost。
$fallbackMethod = $launcherType.GetMethod('StartEngineHostWithPolicyFallback', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $fallbackMethod) 'Launcher.StartEngineHostWithPolicyFallback is not reachable for the fallback argument check'
$fallbackRows = @(Get-ILInstructions $fallbackMethod -All)
$fallbackArgs = @(for ($k = 0; $k -lt $fallbackRows.Count; $k++) {
  if ($fallbackRows[$k].Callee -ceq 'System.Diagnostics.ProcessStartInfo::set_Arguments') { $k } })
$fallbackLiteral = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '
$fallbackSeen = ''; $fallbackOk = $false
if ($fallbackArgs.Count -eq 1 -and $fallbackArgs[0] -ge 3) {
  $k = $fallbackArgs[0]
  $fallbackSeen = (@($fallbackRows[($k - 3)..($k - 1)]) | ForEach-Object { ($_.Op + ' ' + $_.Callee + ' ' + [string]$_.Literal).Trim() }) -join ' ; '
  $fallbackOk = $fallbackRows[$k - 3].Op -ceq 'ldstr' -and
    [string]::Equals([string]$fallbackRows[$k - 3].Literal, $fallbackLiteral, [StringComparison]::Ordinal) -and
    $fallbackRows[$k - 2].Op -clike 'ldloc*' -and $fallbackRows[$k - 1].Callee -ceq 'System.String::Concat'
}
Assert-True $fallbackOk ('signed-policy fallback does not start PowerShell with the fixed "' + $fallbackLiteral.Trim() +
  '" arguments: set_Arguments calls ' + $fallbackArgs.Count + '; ' + $fallbackSeen)
Assert-SystemWorkingDirectory $fallbackMethod 'System.Diagnostics.Process::Start' $null 'signed-policy fallback'

# 卸载入口是同一种边界：build\uninstall-launcher.cs 和 build\uninstall-host.cs 按 make-uninstall-host.ps1 的方式（同样的
# 附带源文件、/optimize+）编进一个临时程序集。卸载入口 Main 做同样的 IL 接线、工作目录和清理/还原行为检查；
# 全程序集里 UninstallLauncher 只有 Main 一处 Process.Start。
$cscPath = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$uninstallIlDir = Join-Path ([IO.Path]::GetTempPath()) ('dfb-uninstall-il-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($uninstallIlDir)
try {
  $uninstallIlDll = Join-Path $uninstallIlDir 'uninstall-il.dll'
  $cscOutput = @(& $cscPath /nologo /target:library /platform:anycpu /optimize+ /codepage:65001 "/out:$uninstallIlDll" `
    /r:System.Windows.Forms.dll /r:System.Core.dll $runtimeRootPath $tokenValidationPath $uninstallLauncherSourcePath $uninstallHostSourcePath)
  Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $uninstallIlDll -PathType Leaf)) `
    ('uninstall launcher/host did not compile for the RunAs wiring check: ' + ($cscOutput -join ' '))
  $uninstallAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($uninstallIlDll))
} finally { Remove-Item -LiteralPath $uninstallIlDir -Recurse -Force -ErrorAction SilentlyContinue }
$uninstallLauncherType = $uninstallAssembly.GetType('UninstallLauncher', $true)
$uninstallMain = $uninstallLauncherType.GetMethod('Main', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $uninstallMain) 'UninstallLauncher.Main is not reachable for the RunAs wiring check'
Assert-SanitizedElevationStart $uninstallMain 'UninstallLauncher::EnterTrustedElevationEnvironment' 'System.Diagnostics.Process::Start' `
  'UninstallLauncher::RestoreEnvironment' 'uninstall launcher Main'
$uninstallFacts = Get-AssemblyILFacts $uninstallAssembly
$uninstallStarts = @(@($uninstallFacts.Calls) | Where-Object {
    $_.Callee -ceq 'System.Diagnostics.Process::Start' -and $_.Caller -cmatch '^UninstallLauncher(::|\+)' } | ForEach-Object { $_.Caller })
Assert-True ($uninstallStarts.Count -eq 1 -and $uninstallStarts[0] -ceq 'UninstallLauncher::Main') `
  ('uninstall launcher starts a process outside the sanitized Main path: ' + ($uninstallStarts -join ', '))
Assert-SystemWorkingDirectory $uninstallMain 'System.Diagnostics.Process::Start' 'UninstallLauncher::EnterTrustedElevationEnvironment' `
  'uninstall launcher Main'
$uninstallEnter = $uninstallLauncherType.GetMethod('EnterTrustedElevationEnvironment', [Reflection.BindingFlags]'Static,NonPublic')
$uninstallRestore = $uninstallLauncherType.GetMethod('RestoreEnvironment', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $uninstallEnter -and $null -ne $uninstallRestore) 'uninstall launcher RunAs environment sanitizer is not reachable'
Assert-ElevationSanitizer $uninstallEnter $uninstallRestore 'uninstall launcher'

# UninstallHost -> 卸载脚本的环境边界（复核 UH-CLEAR）。StartScript 先 EnsureDirectory（非提权会抛），不能直接跑，所以钉编译出
# 的 IL：UninstallHost 里只有 StartScript 一处 new ProcessStartInfo 和一处 Process.Start；环境块只在 StartScript 里取；第一次
# 取出来紧接着 Clear()，Clear 在每次写入和 Process.Start 之前、不会被跳过；之后每次取环境块都紧跟一个字面量键（ldstr），键
# 集合恰好是白名单；UninstallHost 自己只经 Environment.GetFolderPath 读进程环境。注释掉的 Clear()、条件 Clear()、另起一个
# psi、计算出来的键、读调用方变量都过不了。
$uhCalls = @(@($uninstallFacts.Calls) | Where-Object { $_.Caller -cmatch '^UninstallHost(::|\+)' })
$uhProcess = @($uhCalls | Where-Object { @('System.Diagnostics.Process::Start', 'System.Diagnostics.Process::.ctor',
    'System.Diagnostics.ProcessStartInfo::.ctor') -ccontains $_.Callee } | ForEach-Object { $_.Caller + ' -> ' + $_.Callee })
$uhBlockOutside = @($uhCalls | Where-Object {
    ($_.Callee -ceq 'System.Diagnostics.ProcessStartInfo::get_EnvironmentVariables' -and $_.Caller -cne 'UninstallHost::StartScript') -or
    (@('System.Diagnostics.ProcessStartInfo::get_Environment', 'System.Diagnostics.Process::get_StartInfo') -ccontains $_.Callee) } |
  ForEach-Object { $_.Caller + ' -> ' + $_.Callee })
Assert-True ($uhCalls.Count -gt 100 -and [string]::Equals(($uhProcess -join ' | '), ('UninstallHost::StartScript -> ' +
    'System.Diagnostics.ProcessStartInfo::.ctor | UninstallHost::StartScript -> System.Diagnostics.Process::Start'), [StringComparison]::Ordinal) -and
    $uhBlockOutside.Count -eq 0) `
  ('UninstallHost starts a process or builds a child environment outside StartScript: ' + ($uhProcess -join ', ') + ' / ' +
   ($uhBlockOutside -join ', ') + ' / call sites ' + $uhCalls.Count)
$uhEnvOther = @($uhCalls | Where-Object { ($_.Callee.StartsWith('System.Environment::', [StringComparison]::Ordinal) -and
    $_.Callee -cne 'System.Environment::GetFolderPath') -or @('System.IO.Path::GetTempPath', 'System.IO.Path::GetTempFileName') -ccontains $_.Callee } |
  ForEach-Object { $_.Caller + ' -> ' + $_.Callee })
Assert-True ($uhEnvOther.Count -eq 0) ('UninstallHost reads or writes its own process environment: ' + ($uhEnvOther -join ', '))
$scriptStart = $uninstallAssembly.GetType('UninstallHost', $true).GetMethod('StartScript', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $scriptStart) 'UninstallHost.StartScript is not reachable for the child environment check'
$ssRows = @(Get-ILInstructions $scriptStart -All)
$ssClears = @(for ($k = 0; $k -lt $ssRows.Count; $k++) {
  if ($ssRows[$k].Callee -ceq 'System.Collections.Specialized.StringDictionary::Clear') { $k } })
$ssBlocks = @(for ($k = 0; $k -lt $ssRows.Count; $k++) {
  if ($ssRows[$k].Callee -ceq 'System.Diagnostics.ProcessStartInfo::get_EnvironmentVariables') { $k } })
$ssStarts = @(for ($k = 0; $k -lt $ssRows.Count; $k++) { if ($ssRows[$k].Callee -ceq 'System.Diagnostics.Process::Start') { $k } })
Assert-True ($ssClears.Count -eq 1 -and $ssClears[0] -ge 1 -and
    $ssRows[$ssClears[0] - 1].Callee -ceq 'System.Diagnostics.ProcessStartInfo::get_EnvironmentVariables') `
  ('UninstallHost.StartScript does not clear the child environment block exactly once: Clear calls ' + $ssClears.Count)
$ssClearAt = $ssRows[$ssClears[0]].Offset
$ssSkips = New-Object System.Collections.Generic.List[string]
foreach ($row in $ssRows) {
  foreach ($target in @($row.Targets)) {
    if ($null -ne $target -and $row.Offset -lt $ssClearAt -and $target -gt $ssClearAt) {
      $ssSkips.Add(('jump IL_{0:x4} -> IL_{1:x4}' -f $row.Offset, $target))
    }
  }
}
$ssHandlers = @($scriptStart.GetMethodBody().ExceptionHandlingClauses).Count
Assert-True ($ssStarts.Count -eq 1 -and $ssBlocks[0] -eq ($ssClears[0] - 1) -and $ssStarts[0] -gt $ssClears[0] -and
    $ssSkips.Count -eq 0 -and $ssHandlers -eq 0) `
  ('UninstallHost.StartScript can reach Process.Start without clearing the environment block first: ' + ($ssSkips -join ', ') +
   ' / starts ' + $ssStarts.Count + ' / exception clauses ' + $ssHandlers + ' / first block access is the Clear: ' + ($ssBlocks[0] -eq ($ssClears[0] - 1)))
$ssKeys = New-Object System.Collections.Generic.List[string]
foreach ($k in $ssBlocks) {
  if ($k -eq ($ssClears[0] - 1)) { continue }
  if ($k -gt $ssStarts[0]) { $ssKeys.Add('<after Process.Start>') }
  elseif ($ssRows[$k + 1].Op -ceq 'ldstr') { $ssKeys.Add([string]$ssRows[$k + 1].Literal) }
  else { $ssKeys.Add('<computed ' + $ssRows[$k + 1].Op + '>') }
}
$ssKeyList = @($ssKeys.ToArray() | Sort-Object -CaseSensitive)
$uhExpectedKeys = @('ALLUSERSPROFILE', 'COMSPEC', 'PATH', 'PATHEXT', 'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'PSModulePath',
  'SystemDrive', 'SystemRoot', 'TEMP', 'TMP', 'WINDIR') | Sort-Object -CaseSensitive
Assert-True ([string]::Equals(($ssKeyList -join '|'), ($uhExpectedKeys -join '|'), [StringComparison]::Ordinal)) `
  ('UninstallHost.StartScript child environment whitelist is not the exact literal set: ' + ($ssKeyList -join ', '))
# 卸载脚本子进程是高权限 PowerShell，同 fallback 一样必须 -NoProfile：StartScript 里带 "-File" 的字面量恰好一个，逐字等于固定前缀。
$ssFileArgs = @($ssRows | Where-Object { $_.Op -ceq 'ldstr' -and ([string]$_.Literal).Contains('-File') } | ForEach-Object { [string]$_.Literal })
Assert-True ($ssFileArgs.Count -eq 1 -and
  [string]::Equals($ssFileArgs[0], '-NoProfile -ExecutionPolicy Bypass -File ', [StringComparison]::Ordinal)) `
  ('UninstallHost.StartScript does not start the uninstall script with the fixed "-NoProfile -ExecutionPolicy Bypass -File" arguments: ' +
   ($ssFileArgs -join ' | '))

# Behavior regression for the EngineHost -> GUI boundary: the child PowerShell must start from an
# environment EngineHost built from scratch. We call the real StartGui out of the freshly built
# production EngineHost.exe against a throwaway root whose gui\DeltaForceBooster-GUI.ps1 only dumps
# its own environment. CreateSessionTemp (the only elevated dependency) is replaced by passing a plain
# directory. Every argument is distinct so a swapped value cannot pass. The injected probe variable
# guarantees a missing Clear() is visible even on a machine whose environment happens to be tiny.
# CreateSessionTemp's own derivation is pinned by (5); the probe also reports its command line and cwd.
# The throwaway root has the shape of the default %ProgramFiles%\DeltaForceBooster install: a space and a
# non-ASCII segment, so an unquoted -File argument splits (review F2/W4). The test's own current directory
# is moved away from System32 while StartGui runs, so a child that inherits it instead of the fixed
# WorkingDirectory is visible (review F1/W3).
$startGui = $hostAssembly.GetType('EngineHost', $true).GetMethod('StartGui', [Reflection.BindingFlags]'Static,NonPublic')
Assert-True ($null -ne $startGui) 'EngineHost.StartGui is not reachable for the child-environment regression'
# The probe writes its command line and cwd first, so "the script never ran" (bad -File argument, child exit code) and
# "the script ran but did not dump its environment" are told apart.
$envProbeTemplate = @'
[IO.File]::WriteAllLines('__FACTS__', [string[]]@([Environment]::CommandLine, [Environment]::CurrentDirectory),
  (New-Object Text.UTF8Encoding($false)))
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
$envCasePrefix = 'dfb hostenv ' + [string][char]0x5E27 + [string][char]0x7387 + ' '
foreach ($repairOnly in @($false, $true)) {
  $envCase = [string](Join-Path ([IO.Path]::GetTempPath()) ($envCasePrefix + [guid]::NewGuid().ToString('N')))
  Assert-True ($envCase.Contains(' ') -and @($envCase.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -gt 0) `
    'hostenv probe root must contain a space and a non-ASCII segment like the default Program Files install root'
  $envSessionTemp = [string](Join-Path $envCase 'session-temp')
  $envDump = [string](Join-Path $envCase 'child-env.txt')
  $envFacts = [string](Join-Path $envCase 'child-facts.txt')
  [void][IO.Directory]::CreateDirectory((Join-Path $envCase 'gui'))
  [void][IO.Directory]::CreateDirectory($envSessionTemp)
  [IO.File]::WriteAllText((Join-Path $envCase 'gui\DeltaForceBooster-GUI.ps1'),
    $envProbeTemplate.Replace('__DUMP__', $envDump.Replace("'", "''")).Replace('__FACTS__', $envFacts.Replace("'", "''")),
    (New-Object Text.UTF8Encoding($true)))
  $hostPoison = [ordered]@{
    DFB_ENV_INHERIT_PROBE = 'leaked'; COR_ENABLE_PROFILING = '1'; COR_PROFILER_PATH = 'C:\untrusted\profiler.dll'
    COMPlus_ReadyToRun = '0'; DOTNET_STARTUP_HOOKS = 'C:\untrusted\hook.dll'; PSModulePath = 'C:\untrusted\Modules'
    TEMP = 'C:\untrusted\temp'; TMP = 'C:\untrusted\temp'
  }
  $hostSaved = @{}
  $hostChild = $null
  $hostChildExit = '<none>'
  $hostChildLaunch = '<none>'
  $hostCwd = [Environment]::CurrentDirectory
  try {
    try {
      foreach ($name in $hostPoison.Keys) {
        $hostSaved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $hostPoison[$name], 'Process')
      }
      [Environment]::CurrentDirectory = $envCase
      # PS 5.1: MethodInfo.Invoke rejects PSObject-wrapped values, every argument must be cast.
      $hostChild = $startGui.Invoke($null, [object[]]@([string]$envCase, [string]$hostSid, [string]$hostLocalAppData,
        [string]$hostSession, [string]$hostPipe, [string]$envSessionTemp, [uint32]4321, [bool]$repairOnly))
      # The returned Process keeps the ProcessStartInfo EngineHost handed to Process.Start. Only used to explain a child
      # whose script never ran (the child cannot report its own command line then); the pass/fail facts come from the child.
      $hostChildLaunch = [string]$hostChild.StartInfo.FileName + ' ' + [string]$hostChild.StartInfo.Arguments
      Assert-True ($hostChild.WaitForExit(60000)) 'EngineHost child GUI probe did not exit'
      $hostChildExit = [string]$hostChild.ExitCode
    } finally {
      [Environment]::CurrentDirectory = $hostCwd
      foreach ($name in $hostPoison.Keys) { [Environment]::SetEnvironmentVariable($name, $hostSaved[$name], 'Process') }
      if ($hostChild -and -not $hostChild.HasExited) { $hostChild.Kill(); $hostChild.WaitForExit() }
      if ($hostChild) { $hostChild.Dispose() }
    }
    # WinPS 5.1 exits -196608 when the -File argument does not name an existing .ps1 (unquoted or single-quoted path with a space).
    Assert-True (Test-Path -LiteralPath $envFacts -PathType Leaf) `
      ('EngineHost child GUI probe script never started (child exit code ' + $hostChildExit +
       '); powershell.exe did not run the -File script; started as: ' + $hostChildLaunch)
    Assert-True (Test-Path -LiteralPath $envDump -PathType Leaf) `
      ('EngineHost child GUI started but never reported its own environment (child exit code ' + $hostChildExit + ')')
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
      # Not written by EngineHost: WinPS 5.1 derives it from the fixed "-ExecutionPolicy Bypass" argument.
      PSExecutionPolicyPreference = 'Bypass'
    }
    if (-not [string]::IsNullOrEmpty($progFilesX86)) { $expected['ProgramFiles(x86)'] = $progFilesX86 }
    foreach ($name in $expected.Keys) {
      Assert-True ($childEnv.ContainsKey($name) -and
        [string]::Equals([string]$childEnv[$name], [string]$expected[$name], [StringComparison]::Ordinal)) `
        ("EngineHost child GUI variable is not the host-built value: $name -> " + $childEnv[$name])
    }
    # PATHEXT: WinPS 5.1 appends ";.CPL" at startup unless .CPL is already listed (measured on 5.1.26100:
    # ".COM;.EXE;.BAT;.CMD" -> ".COM;.EXE;.BAT;.CMD;.CPL", ".COM;.EXE;.BAT;.CMD;.VBS;.JS" -> "...;.VBS;.JS;.CPL").
    # Accept exactly the product list, or that list plus the one known append. No prefix match, no case folding.
    $pathExtAccepted = @('.COM;.EXE;.BAT;.CMD', '.COM;.EXE;.BAT;.CMD;.CPL')
    $pathExtSeen = [string]$childEnv['PATHEXT']
    Assert-True ($childEnv.ContainsKey('PATHEXT') -and
      @($pathExtAccepted | Where-Object { [string]::Equals($pathExtSeen, $_, [StringComparison]::Ordinal) }).Count -eq 1) `
      ('EngineHost child GUI PATHEXT is not the fixed trusted list: ' + $pathExtSeen)
    # PSModulePath: exactly "<System32 modules>;<Program Files modules>", compared as one string (no set, trim or case
    # folding). The order is load-bearing: WinPS 5.1 keeps this value as is, but when the block carries the machine default
    # order (Program Files first) it prepends the user-writable Documents\WindowsPowerShell\Modules (measured).
    $expectedModulePath = (Join-Path $sysDir 'WindowsPowerShell\v1.0\Modules') + ';' + (Join-Path $progFiles 'WindowsPowerShell\Modules')
    Assert-True ($childEnv.ContainsKey('PSModulePath') -and
      [string]::Equals([string]$childEnv['PSModulePath'], $expectedModulePath, [StringComparison]::Ordinal)) `
      ('EngineHost child GUI PSModulePath is not the machine-only module path: ' + $childEnv['PSModulePath'])
    # The whole point: nothing beyond the whitelist (PSExecutionPolicyPreference is value-checked in $expected).
    $allowedNames = @($expected.Keys) + @('PATHEXT', 'PSModulePath')
    $leaked = @($childEnv.Keys | Where-Object { $allowedNames -notcontains $_ } | Sort-Object)
    Assert-True ($leaked.Count -eq 0) `
      ('EngineHost child GUI inherited environment variables it must not see: ' + ($leaked -join ', '))
    # Beyond the environment block: the high child must be System32 powershell.exe with -NoProfile (otherwise the
    # elevated GUI runs the user-writable Documents\WindowsPowerShell profiles, which still resolve under the cleared
    # environment), the fixed policy argument, the GUI script as one quoted -File argument, and System32 as cwd.
    $childFacts = @([IO.File]::ReadAllLines($envFacts, [Text.Encoding]::UTF8))
    $expectedCommandLine = '"' + [IO.Path]::Combine($sysDir, 'WindowsPowerShell', 'v1.0', 'powershell.exe') +
      '" -NoProfile -ExecutionPolicy Bypass -File "' + [IO.Path]::Combine($envCase, 'gui', 'DeltaForceBooster-GUI.ps1') + '"'
    Assert-True ($childFacts.Count -eq 2 -and [string]::Equals($childFacts[0], $expectedCommandLine, [StringComparison]::Ordinal)) `
      ('EngineHost child GUI command line is not the fixed -NoProfile -ExecutionPolicy Bypass -File launch: ' + $childFacts[0])
    Assert-True ($childFacts.Count -eq 2 -and [string]::Equals($childFacts[1], $sysDir, [StringComparison]::Ordinal)) `
      ('EngineHost child GUI working directory is not System32: ' + $childFacts[1])
  } finally {
    if (Test-Path -LiteralPath $envCase) { Remove-Item -LiteralPath $envCase -Recurse -Force }
  }
}

Write-Host 'PASS: EngineHost one-UAC lifetime session, OTS broker, protected state, update handoff and profiles'
