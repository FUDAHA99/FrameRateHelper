#requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $root 'gui\DeltaForceBooster-GUI.ps1'

function Assert-True([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($guiPath,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) ('GUI AST parse failed: ' + (($errors | ForEach-Object Message) -join '; '))

function Get-GuiFunctionText([string]$Name) {
  $node = @($ast.FindAll({
    param($candidate)
    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name
  },$true) | Select-Object -First 1)
  Assert-True ($node.Count -eq 1) "function not found: $Name"
  $node[0].Extent.Text
}

foreach ($name in 'Get-SavedUiPreferences','Get-SavedAppTheme','Get-SavedAppWindowHeight','Save-AppUiPreferences','Test-TelemetryOptIn') {
  Invoke-Expression (Get-GuiFunctionText $name)
}

$case = Join-Path ([IO.Path]::GetTempPath()) ('dfb-ui-prefs-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($case)
$script:UiPreferencesPath = Join-Path $case 'ui-preferences.json'
$script:DefaultAppWindowHeight = 1200.0
$script:LightThemeEnabled = $true
function Write-BytesAtomic([string]$Path,[byte[]]$Bytes) { [IO.File]::WriteAllBytes($Path,$Bytes) }

try {
  Assert-True ((Get-SavedAppTheme) -eq 'dark') 'missing preferences did not default to dark theme'
  Assert-True ((Get-SavedAppWindowHeight) -eq 1200) 'missing preferences did not default to 1200 height'

  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":1,"theme":"light"}',[Text.UTF8Encoding]::new($false))
  Assert-True ((Get-SavedAppTheme) -eq 'light') 'legacy theme-only preference was not loaded'
  Assert-True ((Get-SavedAppWindowHeight) -eq 1200) 'legacy preference did not receive the new default height'

  Save-AppUiPreferences 'light' 1188.4
  $saved = Get-Content -LiteralPath $script:UiPreferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ($saved.theme -eq 'light' -and [int]$saved.windowHeight -eq 1188) 'theme and window height were not saved together'
  Assert-True ((Get-SavedAppWindowHeight) -eq 1188) 'saved window height was not restored'

  $script:LightThemeEnabled = $false
  Assert-True ((Get-SavedAppTheme) -eq 'dark') 'deferred light theme was still restored in the current version'
  Save-AppUiPreferences 'light' 1188.4
  $saved = Get-Content -LiteralPath $script:UiPreferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ($saved.theme -eq 'dark' -and [int]$saved.windowHeight -eq 1188) 'disabled light theme was persisted instead of dark'
  $script:LightThemeEnabled = $true

  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":1,"theme":"dark","windowHeight":400}',[Text.UTF8Encoding]::new($false))
  Assert-True ((Get-SavedAppWindowHeight) -eq 1200) 'unsafe short window height was not rejected'

  # --- telemetry opt-in switch: negative assertions guarding "off by default" ---
  # NOTE: this file has no UTF-8 BOM, so every message here must stay ASCII.
  # Any failure below means the build reports telemetry without user consent.

  Remove-Item -LiteralPath $script:UiPreferencesPath -Force
  Assert-True ((Test-TelemetryOptIn) -eq $false) 'missing preference file did not fail closed'

  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":1,"theme":"dark"}',[Text.UTF8Encoding]::new($false))
  Assert-True ((Test-TelemetryOptIn) -eq $false) 'missing telemetryEnabled field did not fail closed'

  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":1,"theme":"dark","telemetry',[Text.UTF8Encoding]::new($false))
  Assert-True ((Test-TelemetryOptIn) -eq $false) 'corrupt JSON did not fail closed'

  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":1,"theme":"dark","telemetryEnabled":"true"}',[Text.UTF8Encoding]::new($false))
  Assert-True ((Test-TelemetryOptIn) -eq $false) 'string "true" was coerced to boolean true'

  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":1,"theme":"dark","telemetryEnabled":1}',[Text.UTF8Encoding]::new($false))
  Assert-True ((Test-TelemetryOptIn) -eq $false) 'number 1 was coerced to boolean true'

  # schemaVersion other than 1 makes Get-SavedUiPreferences return $null
  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":2,"telemetryEnabled":true}',[Text.UTF8Encoding]::new($false))
  Assert-True ((Test-TelemetryOptIn) -eq $false) 'unknown schemaVersion did not fail closed'

  # only an explicit boolean true enables it
  [IO.File]::WriteAllText($script:UiPreferencesPath,'{"schemaVersion":1,"theme":"dark","telemetryEnabled":true}',[Text.UTF8Encoding]::new($false))
  Assert-True ((Test-TelemetryOptIn) -eq $true) 'explicit opt-in was not honoured'

  # the two-argument save (theme change / window close) must not silently reset it
  Save-AppUiPreferences 'dark' 1188.4
  Assert-True ((Test-TelemetryOptIn) -eq $true) 'two-argument save reset an enabled opt-in'

  # only an explicit $false turns it back off
  Save-AppUiPreferences 'dark' 1188.4 $false
  Assert-True ((Test-TelemetryOptIn) -eq $false) 'explicit opt-out was not persisted'
} finally {
  Remove-Item -LiteralPath $case -Recurse -Force -ErrorAction SilentlyContinue
}

'UI preference tests passed.'
