#Requires -Version 7.2
<#
.SYNOPSIS
Sandboxed tests for install.ps1 and uninstall.ps1.

.DESCRIPTION
Runs every scenario inside a fresh temporary directory. Child processes receive
sandboxed CODEX_HOME, USERPROFILE, LOCALAPPDATA, and CLAUDE_CONFIG_DIR values, and
the suite checks that the real Codex skill and Claude settings were not modified.
Does not contact Claude or the network.
#>
[CmdletBinding()]
param(
    # Keep the sandbox directory for inspection after the run.
    [switch]$KeepSandbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Force

$repoRoot = Get-ClaudeCXRepositoryRoot
$installScript = Join-Path $repoRoot 'install.ps1'
$uninstallScript = Join-Path $repoRoot 'uninstall.ps1'
$packagedSkill = Get-ClaudeCXPackagedSkillRoot
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "claudecx-install-test-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($sandbox) | Out-Null

$script:failures = [Collections.Generic.List[string]]::new()
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passed++
        Write-Host "  ok   $Message"
    }
    else {
        $script:failures.Add($Message)
        Write-Host "  FAIL $Message" -ForegroundColor Red
    }
}

function Get-RealStateFingerprint {
    # Metadata only (existence, size, timestamps); real settings content is never read.
    $paths = [Collections.Generic.List[string]]::new()
    if ($env:USERPROFILE) {
        $paths.Add((Join-Path $env:USERPROFILE '.codex\skills\claudecx'))
        $paths.Add((Join-Path $env:USERPROFILE '.codex\claudecx-backups'))
        $paths.Add((Join-Path $env:USERPROFILE '.claude\settings.json'))
        $paths.Add((Join-Path $env:USERPROFILE '.claudecx'))
    }
    if ($env:APPDATA) {
        $paths.Add((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ClaudeCX.lnk'))
        $paths.Add((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\ClaudeCX control center.lnk'))
    }
    if ($env:CODEX_HOME) {
        $paths.Add((Join-Path $env:CODEX_HOME 'skills\claudecx'))
        $paths.Add((Join-Path $env:CODEX_HOME 'claudecx-backups'))
    }
    if ($env:CLAUDE_CONFIG_DIR) {
        $paths.Add((Join-Path $env:CLAUDE_CONFIG_DIR 'settings.json'))
    }
    $lines = foreach ($path in $paths) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            "$path|absent"
        }
        elseif ($item.PSIsContainer) {
            $children = @(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object)
            "$path|dir|$($item.LastWriteTimeUtc.Ticks)|$($children -join ';')"
        }
        else {
            "$path|file|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
        }
    }
    return ($lines -join "`n")
}

function Invoke-Script {
    # Runs a script in a child pwsh with a sandboxed profile environment.
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [string]$CodexHomeEnv
    )

    $names = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CLAUDECX_HOME', 'TEMP', 'TMP')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        [IO.Directory]::CreateDirectory($ProfileRoot) | Out-Null
        [Environment]::SetEnvironmentVariable('USERPROFILE', $ProfileRoot)
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', (Join-Path $ProfileRoot 'AppData\Local'))
        [Environment]::SetEnvironmentVariable('APPDATA', (Join-Path $ProfileRoot 'AppData\Roaming'))
        [Environment]::SetEnvironmentVariable('CLAUDECX_HOME', $null)
        $tempRoot = Join-Path $ProfileRoot 'AppData\Local\Temp'
        [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
        [Environment]::SetEnvironmentVariable('TEMP', $tempRoot)
        [Environment]::SetEnvironmentVariable('TMP', $tempRoot)
        [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', (Join-Path $ProfileRoot '.claude'))
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $(if ($CodexHomeEnv) { $CodexHomeEnv } else { $null }))
        # The installer's setup checks would call the real claude; they have their own tests in test-doctor.ps1.
        if ([IO.Path]::GetFileName($ScriptPath) -eq 'install.ps1') { $Arguments = @($Arguments) + '-SkipChecks' }
        $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($output | ForEach-Object { "$_" }) -join "`n")
    }
}

function New-Case {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-Host ''
    Write-Host "[$Name]"
    $root = Join-Path $sandbox $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    return [pscustomobject]@{
        Root = $root
        ProfileRoot = Join-Path $root 'profile'
        CodexHome = Join-Path $root 'codex-home'
    }
}

function Get-BackupDirectories {
    param([string]$CodexHome, [string]$Prefix)
    $root = Join-Path $CodexHome 'claudecx-backups'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name.StartsWith("$Prefix-") })
}

$realBefore = Get-RealStateFingerprint

try {
    # --- Fresh install with explicit CodexHome, preserving unrelated skills ---
    $case = New-Case 'fresh-install'
    $other = Join-Path $case.CodexHome 'skills\other-skill'
    [IO.Directory]::CreateDirectory($other) | Out-Null
    Write-ClaudeCXUtf8File -Path (Join-Path $other 'SKILL.md') -Content "---`nname: other-skill`ndescription: unrelated`n---`n"
    $otherBefore = (Get-ClaudeCXTreeManifest -Root $other) -join "`n"
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome) -ProfileRoot $case.ProfileRoot
    $destination = Join-Path $case.CodexHome 'skills\claudecx'
    Assert-True ($result.ExitCode -eq 0) "install exits 0 ($($result.Text))"
    Assert-True (Test-ClaudeCXTreeEqual -Expected $packagedSkill -Actual $destination) 'installed copy matches packaged skill'
    foreach ($required in (Get-ClaudeCXRequiredSkillFiles)) {
        Assert-True (Test-Path -LiteralPath (Join-Path $destination $required) -PathType Leaf) "installed skill contains $required"
    }
    foreach ($dashboardFile in @('dashboard/index.html', 'dashboard/styles.css', 'dashboard/app.js', 'scripts/ClaudeCX.Dashboard.psm1', 'scripts/show-dashboard.ps1')) {
        $installedFile = Join-Path $destination $dashboardFile
        $packagedFile = Join-Path $packagedSkill $dashboardFile
        Assert-True ((Test-Path -LiteralPath $installedFile -PathType Leaf) -and
            ([IO.File]::ReadAllText($installedFile) -ceq [IO.File]::ReadAllText($packagedFile))) "installed dashboard asset matches the package: $dashboardFile"
    }
    $installedDashboard = @(Get-ChildItem -LiteralPath (Join-Path $destination 'dashboard') -File | ForEach-Object Name | Sort-Object)
    Assert-True (($installedDashboard -join ',') -ceq 'app.js,index.html,styles.css') "installed dashboard holds only the prebuilt assets ($($installedDashboard -join ','))"
    $buildArtifacts = @(Get-ChildItem -LiteralPath $destination -Recurse -Force | Where-Object { $_.Name -in @('node_modules', 'package.json', 'package-lock.json', 'dashboard-src', 'vite.config.mjs') -or $_.Name -like '*.map' })
    Assert-True ($buildArtifacts.Count -eq 0) 'installed skill contains no Node build tooling or source maps'
    $installerText = [IO.File]::ReadAllText((Join-Path (Get-ClaudeCXRepositoryRoot) 'install.ps1')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1'))
    Assert-True ($installerText -notmatch '(?i)\b(npm|npx|node\.exe|vite)\b') 'installation never invokes Node, npm, or Vite'
    Assert-True ($result.Text.Contains('$claudecx')) 'install prints the $claudecx next step'
    $startMenu = Join-Path $case.ProfileRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
    $shortcutFile = Join-Path $startMenu 'ClaudeCX.lnk'
    Assert-True (Test-Path -LiteralPath $shortcutFile -PathType Leaf) 'install adds a ClaudeCX Start menu shortcut in the sandboxed profile'
    if (Test-Path -LiteralPath $shortcutFile -PathType Leaf) {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcutFile)
        Assert-True ($link.Arguments.Contains((Join-Path $destination 'scripts\start-control-center.ps1')) -and $link.Arguments.Contains('-File') -and -not $link.Arguments.Contains('-NoBrowser')) "Start menu shortcut runs the installed launcher ($($link.Arguments))"
        Assert-True ([IO.Path]::GetFileNameWithoutExtension($link.TargetPath) -eq 'pwsh') 'Start menu shortcut runs pwsh'
        Assert-True ($link.IconLocation -eq ((Join-Path $destination 'assets\claudecx.ico') + ',0')) "Start menu shortcut uses the ClaudeCX icon ($($link.IconLocation))"
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $startMenu 'Startup\ClaudeCX control center.lnk'))) 'no sign-in shortcut without -StartAtLogin'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot '.claudecx'))) 'install creates no ClaudeCX settings file'
    Assert-True (((Get-ClaudeCXTreeManifest -Root $other) -join "`n") -ceq $otherBefore) 'unrelated skill preserved'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot '.claude'))) 'no Claude settings created without -DisableClaudeAttribution'
    Assert-True (@(Get-ChildItem -LiteralPath $case.CodexHome -Force -Filter '.claudecx-staging-*').Count -eq 0) 'staging directory cleaned up'

    # --- Refuse to overwrite without -Force ---
    $marker = Join-Path $destination 'local-marker.txt'
    Write-ClaudeCXUtf8File -Path $marker -Content 'local change'
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0) 'second install without -Force fails'
    Assert-True ($result.Text.Contains('-Force')) 'refusal message mentions -Force'
    Assert-True (Test-Path -LiteralPath $marker) 'existing installation left untouched'
    Assert-True (@(Get-BackupDirectories -CodexHome $case.CodexHome -Prefix 'skill').Count -eq 0) 'no backup created on refusal'

    # --- Forced update creates a recoverable backup ---
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-Force') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) "forced update exits 0 ($($result.Text))"
    $backups = @(Get-BackupDirectories -CodexHome $case.CodexHome -Prefix 'skill')
    Assert-True ($backups.Count -eq 1) 'exactly one timestamped backup created'
    Assert-True ($backups.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'local-marker.txt'))) 'backup contains previous installation'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'updated installation replaces previous files'
    Assert-True (Test-ClaudeCXTreeEqual -Expected $packagedSkill -Actual $destination) 'updated copy matches packaged skill'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.CodexHome 'skills\claudecx-backups'))) 'backups are kept outside the skills folder'

    # --- Second forced update gets its own backup ---
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-Force') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'second forced update exits 0'
    Assert-True (@(Get-BackupDirectories -CodexHome $case.CodexHome -Prefix 'skill').Count -eq 2) 'second forced update adds a distinct backup'

    # --- CODEX_HOME resolution ---
    $case = New-Case 'codex-home-env'
    $result = Invoke-Script -ScriptPath $installScript -ProfileRoot $case.ProfileRoot -CodexHomeEnv $case.CodexHome
    Assert-True ($result.ExitCode -eq 0) 'install via CODEX_HOME exits 0'
    Assert-True (Test-Path -LiteralPath (Join-Path $case.CodexHome 'skills\claudecx\SKILL.md')) 'CODEX_HOME is honored'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot '.codex'))) 'USERPROFILE fallback not used when CODEX_HOME is set'

    # --- USERPROFILE fallback ---
    $case = New-Case 'userprofile-fallback'
    $result = Invoke-Script -ScriptPath $installScript -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'install via USERPROFILE fallback exits 0'
    Assert-True (Test-Path -LiteralPath (Join-Path $case.ProfileRoot '.codex\skills\claudecx\SKILL.md')) 'USERPROFILE\.codex is the fallback'

    # --- Invalid packaged skill is rejected before the destination changes ---
    $case = New-Case 'invalid-package'
    $packageCopy = Join-Path $case.Root 'package'
    [IO.Directory]::CreateDirectory((Join-Path $packageCopy 'scripts')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $packageCopy 'skill')) | Out-Null
    Copy-Item -LiteralPath $installScript -Destination $packageCopy
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Destination (Join-Path $packageCopy 'scripts')
    Copy-Item -LiteralPath $packagedSkill -Destination (Join-Path $packageCopy 'skill\claudecx') -Recurse
    $brokenSkill = Join-Path $packageCopy 'skill\claudecx\SKILL.md'
    $skillText = [IO.File]::ReadAllText($brokenSkill).Replace('name: claudecx', 'name: ClaudeCX')
    Write-ClaudeCXUtf8File -Path $brokenSkill -Content $skillText
    $result = Invoke-Script -ScriptPath (Join-Path $packageCopy 'install.ps1') -Arguments @('-CodexHome', $case.CodexHome) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0) 'invalid package is rejected'
    Assert-True (-not (Test-Path -LiteralPath $case.CodexHome)) 'destination untouched when package is invalid'

    # --- Attribution merge preserves unrelated settings ---
    $case = New-Case 'attribution-merge'
    $settingsPath = Join-Path $case.Root 'claude\settings.json'
    $original = @'
{
  "model": "opus",
  "date": "2026-01-01T00:00:00Z",
  "ratio": 1.50,
  "unicode": "გამარჯობა",
  "env": { "FOO": "bar" },
  "permissions": { "allow": ["Bash(ls)"], "deny": [] },
  "attribution": { "commit": "Generated with Claude", "custom": 1 }
}
'@
    [IO.Directory]::CreateDirectory((Split-Path -Parent $settingsPath)) | Out-Null
    Write-ClaudeCXUtf8File -Path $settingsPath -Content $original
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-DisableClaudeAttribution', '-ClaudeSettingsPath', $settingsPath) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) "install with attribution exits 0 ($($result.Text))"
    $merged = [Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($settingsPath))
    Assert-True ($merged['attribution']['commit'].ToJsonString() -ceq '""') 'attribution.commit is empty'
    Assert-True ($merged['attribution']['pr'].ToJsonString() -ceq '""') 'attribution.pr is empty'
    Assert-True ($merged['attribution']['sessionUrl'].ToJsonString() -ceq 'false') 'attribution.sessionUrl is false'
    Assert-True ($merged['attribution']['custom'].ToJsonString() -ceq '1') 'unrelated attribution key preserved'
    Assert-True ($merged['model'].ToJsonString() -ceq '"opus"') 'model preserved'
    Assert-True ($merged['date'].ToJsonString() -ceq '"2026-01-01T00:00:00Z"') 'date-like string preserved verbatim'
    Assert-True ($merged['ratio'].ToJsonString() -ceq '1.50') 'number representation preserved'
    Assert-True ([string]$merged['unicode'] -ceq 'გამარჯობა') 'non-ASCII string preserved'
    Assert-True ([IO.File]::ReadAllText($settingsPath).Contains('"unicode": "გამარჯობა"')) 'non-ASCII string written unescaped'
    Assert-True ($merged['env'].ToJsonString() -ceq '{"FOO":"bar"}') 'env preserved'
    Assert-True ($merged['permissions'].ToJsonString() -ceq '{"allow":["Bash(ls)"],"deny":[]}') 'permissions preserved'
    $settingsBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $settingsPath) -File -Filter 'settings.json.claudecx-backup-*')
    Assert-True ($settingsBackups.Count -eq 1) 'settings backup created'
    Assert-True ($settingsBackups.Count -eq 1 -and [IO.File]::ReadAllText($settingsBackups[0].FullName) -ceq $original) 'settings backup is byte-identical to original'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot '.claude'))) 'default Claude settings untouched when a path is supplied'

    # --- Re-applying attribution is a no-op without a new backup ---
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-Force', '-DisableClaudeAttribution', '-ClaudeSettingsPath', $settingsPath) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'second attribution run exits 0'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $settingsPath) -File -Filter 'settings.json.claudecx-backup-*').Count -eq 1) 'no extra backup when settings already match'

    # --- Missing settings file is created; default path follows CLAUDE_CONFIG_DIR ---
    $case = New-Case 'attribution-default-path'
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-DisableClaudeAttribution') -ProfileRoot $case.ProfileRoot
    $defaultSettings = Join-Path $case.ProfileRoot '.claude\settings.json'
    Assert-True ($result.ExitCode -eq 0) 'attribution with default path exits 0'
    Assert-True (Test-Path -LiteralPath $defaultSettings -PathType Leaf) 'settings file created in sandboxed profile'
    if (Test-Path -LiteralPath $defaultSettings -PathType Leaf) {
        $created = [Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($defaultSettings))
        Assert-True ($created['attribution'].ToJsonString() -ceq '{"commit":"","pr":"","sessionUrl":false}') 'created settings contain only attribution'
    }

    # --- Invalid settings JSON is refused before any change ---
    $case = New-Case 'attribution-invalid'
    $badSettings = Join-Path $case.Root 'settings.json'
    $badText = "{ // comment`n  `"model`": `"opus`", }`n"
    Write-ClaudeCXUtf8File -Path $badSettings -Content $badText
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-DisableClaudeAttribution', '-ClaudeSettingsPath', $badSettings) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0) 'non-strict settings JSON is refused'
    Assert-True ([IO.File]::ReadAllText($badSettings) -ceq $badText) 'invalid settings file unchanged'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.CodexHome 'skills\claudecx'))) 'skill not installed when settings are invalid'

    # --- -ClaudeSettingsPath without the switch is rejected ---
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-ClaudeSettingsPath', $badSettings) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0) '-ClaudeSettingsPath alone is rejected'

    # --- Uninstall ---
    $case = New-Case 'uninstall'
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'install for uninstall test exits 0'
    $destination = Join-Path $case.CodexHome 'skills\claudecx'
    $other = Join-Path $case.CodexHome 'skills\other-skill'
    [IO.Directory]::CreateDirectory($other) | Out-Null
    Write-ClaudeCXUtf8File -Path (Join-Path $other 'SKILL.md') -Content "---`nname: other-skill`ndescription: unrelated`n---`n"
    $handoffLog = Join-Path $case.ProfileRoot 'AppData\Local\CodexClaude\handoffs\repo\session\log.txt'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $handoffLog)) | Out-Null
    Write-ClaudeCXUtf8File -Path $handoffLog -Content 'handoff'
    $claudeSettings = Join-Path $case.ProfileRoot '.claude\settings.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $claudeSettings)) | Out-Null
    Write-ClaudeCXUtf8File -Path $claudeSettings -Content '{"model":"opus"}'

    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0) 'non-interactive uninstall without -Yes fails'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'SKILL.md')) 'skill remains without confirmation'

    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome, '-Yes') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) "uninstall -Yes exits 0 ($($result.Text))"
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'skill removed from skills folder'
    $uninstalled = @(Get-BackupDirectories -CodexHome $case.CodexHome -Prefix 'uninstalled')
    Assert-True ($uninstalled.Count -eq 1 -and (Test-ClaudeCXTreeEqual -Expected $packagedSkill -Actual $uninstalled[0].FullName)) 'uninstalled skill recoverable from backup'
    Assert-True (Test-Path -LiteralPath (Join-Path $other 'SKILL.md')) 'unrelated skill preserved by uninstall'
    Assert-True (Test-Path -LiteralPath $handoffLog) 'handoff logs preserved by uninstall'
    Assert-True ([IO.File]::ReadAllText($claudeSettings) -ceq '{"model":"opus"}') 'Claude settings untouched by uninstall'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\ClaudeCX.lnk'))) 'uninstall removes the Start menu shortcut'

    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome, '-Yes') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'uninstall when not installed exits 0'

    # --- Permanent uninstall ---
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'reinstall exits 0'
    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome, '-Yes', '-Permanent') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'permanent uninstall exits 0'
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'skill permanently removed'
    Assert-True (@(Get-BackupDirectories -CodexHome $case.CodexHome -Prefix 'uninstalled').Count -eq 1) 'permanent uninstall creates no backup'

    # --- Uninstall -RemoveData deletes everything ClaudeCX created, and nothing else ---
    $case = New-Case 'remove-data'
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome) -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'install for the data removal test exits 0'
    $local = Join-Path $case.ProfileRoot 'AppData\Local'
    $logs = Join-Path $local 'CodexClaude\handoffs\aaaaaaaaaaaaaaaaaaaaaaaa'
    $appLogs = Join-Path $local 'Packages\OpenAI.Codex_test\LocalCache\Local\CodexClaude\handoffs\bbbbbbbbbbbbbbbbbbbbbbbb'
    foreach ($folder in @($logs, $appLogs, (Join-Path $local 'Temp\claudecx'), (Join-Path $case.ProfileRoot '.claudecx'), (Join-Path $case.CodexHome 'claudecx-backups\skill-1'))) {
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        Write-ClaudeCXUtf8File -Path (Join-Path $folder 'file.txt') -Content 'x'
    }
    $claudeDir = Join-Path $case.ProfileRoot '.claude'
    [IO.Directory]::CreateDirectory($claudeDir) | Out-Null
    Write-ClaudeCXUtf8File -Path (Join-Path $claudeDir 'settings.json') -Content '{"model":"opus"}'
    Write-ClaudeCXUtf8File -Path (Join-Path $claudeDir 'settings.json.claudecx-backup-1') -Content '{}'
    $keep = Join-Path $local 'keep.txt'
    Write-ClaudeCXUtf8File -Path $keep -Content 'unrelated'
    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome, '-RemoveData') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0 -and (Test-Path -LiteralPath $logs)) '-RemoveData without -Yes asks first and changes nothing'
    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome, '-RemoveData', '-Yes') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) "uninstall -RemoveData -Yes exits 0 ($($result.Text))"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.CodexHome 'skills\claudecx')) -and -not (Test-Path -LiteralPath (Join-Path $case.CodexHome 'claudecx-backups'))) '-RemoveData deletes the skill and keeps no backup'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $local 'CodexClaude')) -and -not (Test-Path -LiteralPath (Join-Path $local 'Packages\OpenAI.Codex_test\LocalCache\Local\CodexClaude'))) '-RemoveData deletes run logs in every folder'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $local 'Temp\claudecx')) -and -not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot '.claudecx'))) '-RemoveData deletes brief drafts and ClaudeCX settings'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $claudeDir 'settings.json.claudecx-backup-1')) -and (Test-Path -LiteralPath (Join-Path $claudeDir 'settings.json'))) '-RemoveData deletes Claude settings backups but keeps Claude settings'
    Assert-True ((Test-Path -LiteralPath $keep) -and -not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\ClaudeCX.lnk'))) '-RemoveData keeps unrelated files and removes the shortcut'

    # --- Sign-in shortcut, and no shortcuts at all ---
    $case = New-Case 'start-at-login'
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-StartAtLogin') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) "install -StartAtLogin exits 0 ($($result.Text))"
    $startupShortcut = Join-Path $case.ProfileRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\ClaudeCX control center.lnk'
    Assert-True (Test-Path -LiteralPath $startupShortcut -PathType Leaf) '-StartAtLogin adds a sign-in shortcut'
    if (Test-Path -LiteralPath $startupShortcut -PathType Leaf) {
        $shell = New-Object -ComObject WScript.Shell
        Assert-True ($shell.CreateShortcut($startupShortcut).Arguments.Contains('-NoBrowser')) 'sign-in shortcut starts the control center without a browser'
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome, '-Yes', '-Permanent') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $startupShortcut)) 'uninstall removes the sign-in shortcut'

    $case = New-Case 'no-shortcut'
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-NoShortcut') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -eq 0) 'install -NoShortcut exits 0'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.ProfileRoot 'AppData\Roaming\Microsoft'))) '-NoShortcut creates no shortcut'
    $result = Invoke-Script -ScriptPath $installScript -Arguments @('-CodexHome', $case.CodexHome, '-Force', '-NoShortcut', '-StartAtLogin') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0) '-NoShortcut with -StartAtLogin is rejected'

    # --- Uninstall refuses a directory that is not ClaudeCX ---
    $case = New-Case 'uninstall-foreign'
    $foreign = Join-Path $case.CodexHome 'skills\claudecx'
    [IO.Directory]::CreateDirectory($foreign) | Out-Null
    Write-ClaudeCXUtf8File -Path (Join-Path $foreign 'SKILL.md') -Content "---`nname: something-else`ndescription: x`n---`n"
    $result = Invoke-Script -ScriptPath $uninstallScript -Arguments @('-CodexHome', $case.CodexHome, '-Yes', '-Permanent') -ProfileRoot $case.ProfileRoot
    Assert-True ($result.ExitCode -ne 0) 'uninstall refuses a foreign skill directory'
    Assert-True (Test-Path -LiteralPath (Join-Path $foreign 'SKILL.md')) 'foreign skill directory preserved'
}
finally {
    $realAfter = Get-RealStateFingerprint
    Write-Host ''
    Assert-True ($realAfter -ceq $realBefore) 'real Codex skill and Claude settings were not modified'
    if ($KeepSandbox) {
        Write-Host "Sandbox kept at $sandbox"
    }
    else {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host "test-install: $($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    foreach ($failure in $script:failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "test-install: all $($script:passed) checks passed" -ForegroundColor Green
