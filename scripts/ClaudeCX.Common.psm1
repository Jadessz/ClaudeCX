#Requires -Version 7.2
# Shared helpers for the ClaudeCX installer, uninstaller, and validation scripts.
# Every helper uses structured PowerShell or .NET operations; nothing builds shell strings.

Set-StrictMode -Version Latest

$script:SkillName = 'claudecx'
$script:BackupFolderName = 'claudecx-backups'
$script:RequiredSkillFiles = @(
    'SKILL.md',
    'agents/openai.yaml',
    'assets/bridge-settings.json',
    'assets/claude-role-prompt.md',
    'assets/empty-mcp.json',
    'assets/report-schema.json',
    'dashboard/app.js',
    'dashboard/index.html',
    'dashboard/styles.css',
    'scripts/ClaudeCX.ControlCenter.psm1',
    'scripts/ClaudeCX.Dashboard.psm1',
    'scripts/ClaudeCX.Progress.psm1',
    'scripts/ClaudeCX.Settings.psm1',
    'scripts/claudecx-settings.ps1',
    'scripts/invoke-claude.ps1',
    'scripts/show-control-center.ps1',
    'scripts/show-dashboard.ps1',
    'scripts/start-control-center.ps1',
    'scripts/test-claude-bridge.ps1',
    'scripts/watch-progress.ps1'
)

function Get-ClaudeCXSkillName { $script:SkillName }

function Get-ClaudeCXRequiredSkillFiles { $script:RequiredSkillFiles }

function Get-ClaudeCXRepositoryRoot {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-ClaudeCXPackagedSkillRoot {
    Join-Path (Get-ClaudeCXRepositoryRoot) (Join-Path 'skill' $script:SkillName)
}

function Resolve-ClaudeCXCodexHome {
    # Explicit parameter first, then CODEX_HOME, then %USERPROFILE%\.codex.
    param([AllowEmptyString()][AllowNull()][string]$CodexHome)

    if ($CodexHome) {
        $candidate = $CodexHome
    }
    elseif ($env:CODEX_HOME) {
        $candidate = $env:CODEX_HOME
    }
    elseif ($env:USERPROFILE) {
        $candidate = Join-Path $env:USERPROFILE '.codex'
    }
    else {
        throw 'Cannot locate Codex home: pass -CodexHome, set CODEX_HOME, or ensure USERPROFILE is defined.'
    }
    return [IO.Path]::GetFullPath($candidate)
}

function Resolve-ClaudeCXClaudeSettingsPath {
    # Explicit parameter first, then CLAUDE_CONFIG_DIR, then %USERPROFILE%\.claude\settings.json.
    param([AllowEmptyString()][AllowNull()][string]$ClaudeSettingsPath)

    if ($ClaudeSettingsPath) {
        return [IO.Path]::GetFullPath($ClaudeSettingsPath)
    }
    if ($env:CLAUDE_CONFIG_DIR) {
        return [IO.Path]::GetFullPath((Join-Path $env:CLAUDE_CONFIG_DIR 'settings.json'))
    }
    if ($env:USERPROFILE) {
        return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude\settings.json'))
    }
    throw 'Cannot locate Claude settings: pass -ClaudeSettingsPath.'
}

function Test-ClaudeCXReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $false
    }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-ClaudeCXTimestamp {
    [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture)
}

function New-ClaudeCXUniquePath {
    # Returns a path under Parent that does not exist yet. The parent is created if needed.
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    [IO.Directory]::CreateDirectory($Parent) | Out-Null
    $stamp = Get-ClaudeCXTimestamp
    $candidate = Join-Path $Parent "$Prefix-$stamp"
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Parent "$Prefix-$stamp-$suffix"
        $suffix++
    }
    return $candidate
}

function Get-ClaudeCXBackupRoot {
    # Backups live beside, not inside, the skills folder so Codex never discovers a duplicate skill.
    param([Parameter(Mandatory = $true)][string]$CodexHome)
    Join-Path $CodexHome $script:BackupFolderName
}

function Get-ClaudeCXFrontMatter {
    # Minimal parser for the flat `key: value` YAML front matter used by SKILL.md.
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = [IO.File]::ReadAllLines($Path, [Text.UTF8Encoding]::new($false))
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        return $null
    }
    $values = [ordered]@{}
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line.Trim() -eq '---') {
            return $values
        }
        if ($line -match '^(?<key>[A-Za-z0-9_-]+):\s*(?<value>.*)$') {
            $values[$Matches['key']] = $Matches['value'].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Test-ClaudeCXStrictJson {
    # Returns $null for strict, valid JSON or the parser message otherwise.
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
        $document = [Text.Json.JsonDocument]::Parse($text)
        $document.Dispose()
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

function Test-ClaudeCXStrictUtf8 {
    # Returns $null when the bytes are valid UTF-8 or the decoder message otherwise.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    try {
        $null = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

function Test-ClaudeCXPowerShellSyntax {
    # Returns parser error strings for a PowerShell file (empty when it parses cleanly).
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    return @($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" })
}

function Get-ClaudeCXSkillProblems {
    # Validates a ClaudeCX skill directory (packaged or installed). Returns a list of problems.
    param([Parameter(Mandatory = $true)][string]$SkillRoot)

    $problems = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $SkillRoot -PathType Container)) {
        $problems.Add("Skill directory does not exist: $SkillRoot")
        return $problems.ToArray()
    }

    foreach ($relative in $script:RequiredSkillFiles) {
        $path = Join-Path $SkillRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $problems.Add("Required skill file is missing: $relative")
        }
    }
    if ($problems.Count -gt 0) {
        return $problems.ToArray()
    }

    $frontMatter = Get-ClaudeCXFrontMatter -Path (Join-Path $SkillRoot 'SKILL.md')
    if ($null -eq $frontMatter) {
        $problems.Add('SKILL.md does not start with a closed YAML front matter block.')
    }
    else {
        $name = if ($frontMatter.Contains('name')) { [string]$frontMatter['name'] } else { '' }
        $description = if ($frontMatter.Contains('description')) { [string]$frontMatter['description'] } else { '' }
        if ($name -cne $script:SkillName) {
            $problems.Add("SKILL.md name must be exactly '$($script:SkillName)' (lowercase); found '$name'.")
        }
        if (-not $description) {
            $problems.Add('SKILL.md description is empty.')
        }
        elseif (-not $description.Contains('$claudecx')) {
            $problems.Add('SKILL.md description must mention the explicit $claudecx invocation.')
        }
    }

    $yamlText = [IO.File]::ReadAllText((Join-Path $SkillRoot 'agents/openai.yaml'), [Text.UTF8Encoding]::new($false))
    if ($yamlText -notmatch '(?m)^\s+allow_implicit_invocation:\s*false\s*$') {
        $problems.Add('agents/openai.yaml must set policy.allow_implicit_invocation: false.')
    }
    if ($yamlText -notmatch '(?m)^\s+display_name:\s*"ClaudeCX"\s*$') {
        $problems.Add('agents/openai.yaml display_name must be "ClaudeCX".')
    }
    $promptMatch = [Regex]::Match($yamlText, '(?m)^\s+default_prompt:\s*"(?<prompt>[^"]*)"\s*$')
    if (-not $promptMatch.Success -or -not $promptMatch.Groups['prompt'].Value.Contains('$claudecx')) {
        $problems.Add('agents/openai.yaml default_prompt must mention $claudecx.')
    }

    foreach ($json in @(Get-ChildItem -LiteralPath $SkillRoot -Recurse -File -Filter '*.json')) {
        $message = Test-ClaudeCXStrictJson -Path $json.FullName
        if ($message) {
            $problems.Add("Invalid JSON in $($json.Name): $message")
        }
    }
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $SkillRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })) {
        foreach ($syntaxError in (Test-ClaudeCXPowerShellSyntax -Path $scriptFile.FullName)) {
            $problems.Add("PowerShell parse error in $($scriptFile.Name): $syntaxError")
        }
    }

    return $problems.ToArray()
}

function Get-ClaudeCXTreeManifest {
    # Sorted "relative-path|sha256" entries for every file below Root.
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootFull = [IO.Path]::GetFullPath($Root)
    $entries = foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force)) {
        $relative = [IO.Path]::GetRelativePath($rootFull, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relative|$hash"
    }
    return @($entries | Sort-Object -CaseSensitive)
}

function Test-ClaudeCXTreeEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual
    )

    $left = Get-ClaudeCXTreeManifest -Root $Expected
    $right = Get-ClaudeCXTreeManifest -Root $Actual
    return (($left -join "`n") -ceq ($right -join "`n"))
}

function Write-ClaudeCXUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Read-ClaudeCXSettingsNode {
    # Parses a Claude settings file as strict JSON, preserving every key and value verbatim.
    # A missing file yields an empty object.
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ,[Text.Json.Nodes.JsonObject]::new()
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Claude settings path is not a file: $Path"
    }
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    if (-not $text.Trim()) {
        return ,[Text.Json.Nodes.JsonObject]::new()
    }
    try {
        $node = [Text.Json.Nodes.JsonNode]::Parse($text)
        # Enumerate once so duplicate keys surface as an error now instead of mid-merge.
        if ($node -is [Text.Json.Nodes.JsonObject]) { $null = $node.Count }
    }
    catch {
        throw "Claude settings file is not strict JSON; refusing to modify it: $Path ($($_.Exception.Message))"
    }
    if ($node -isnot [Text.Json.Nodes.JsonObject]) {
        throw "Claude settings file must contain a JSON object: $Path"
    }
    $attribution = $node['attribution']
    if ($node.ContainsKey('attribution') -and $attribution -isnot [Text.Json.Nodes.JsonObject]) {
        throw "Claude settings 'attribution' is not an object; refusing to modify it: $Path"
    }
    # The comma keeps PowerShell from enumerating the JsonObject into key/value pairs.
    return ,$node
}

function Set-ClaudeCXAttributionDisabled {
    # Sets attribution.commit = "", attribution.pr = "", attribution.sessionUrl = false while
    # preserving every other key. Backs up an existing file before replacing it.
    # Returns an object describing the change.
    param([Parameter(Mandatory = $true)][string]$Path)

    $settings = Read-ClaudeCXSettingsNode -Path $Path
    if (-not $settings.ContainsKey('attribution')) {
        $settings['attribution'] = [Text.Json.Nodes.JsonObject]::new()
    }
    $attribution = $settings['attribution']

    $desired = [ordered]@{ commit = ''; pr = ''; sessionUrl = $false }
    $desiredJson = @{ commit = '""'; pr = '""'; sessionUrl = 'false' }
    $changed = $false
    foreach ($key in $desired.Keys) {
        $value = $desired[$key]
        $current = $attribution[$key]
        $alreadySet = ($null -ne $current -and $current.ToJsonString() -ceq $desiredJson[$key])
        if (-not $alreadySet) {
            if ($value -is [bool]) {
                $attribution[$key] = [Text.Json.Nodes.JsonValue]::Create([bool]$value)
            }
            else {
                $attribution[$key] = [Text.Json.Nodes.JsonValue]::Create([string]$value)
            }
            $changed = $true
        }
    }

    if (-not $changed) {
        return [pscustomobject]@{ Changed = $false; Path = $Path; BackupPath = $null }
    }

    $options = [Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    $options.Encoder = [Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    $json = $settings.ToJsonString($options) + "`n"

    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $backupPath = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backupPath = "$Path.claudecx-backup-$(Get-ClaudeCXTimestamp)"
        $suffix = 1
        $baseBackup = $backupPath
        while (Test-Path -LiteralPath $backupPath) {
            $backupPath = "$baseBackup-$suffix"
            $suffix++
        }
        Copy-Item -LiteralPath $Path -Destination $backupPath
    }

    $temporary = Join-Path $parent ".settings.claudecx-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Write-ClaudeCXUtf8File -Path $temporary -Content $json
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return [pscustomobject]@{ Changed = $true; Path = $Path; BackupPath = $backupPath }
}

function Get-ClaudeCXShortcutPaths {
    # Start menu and sign-in (Startup) shortcuts for the control center, under %APPDATA%.
    if (-not $env:APPDATA) {
        throw 'APPDATA is unavailable; cannot place the Start menu shortcut. Use -NoShortcut.'
    }
    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    return [pscustomobject]@{
        StartMenu = Join-Path $programs 'ClaudeCX.lnk'
        Startup = Join-Path $programs 'Startup\ClaudeCX control center.lnk'
    }
}

function Get-ClaudeCXSystemPwsh {
    # Prefer the pwsh on PATH over a bundled copy, so shortcuts survive tool updates.
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return [Environment]::ProcessPath
}

function New-ClaudeCXControlCenterShortcut {
    # Creates a shortcut that runs start-control-center.ps1 hidden. Shortcut arguments are a single
    # string by design; the only variable part is the installed script path, which is quoted.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [switch]$NoBrowser
    )

    if ($LauncherPath.Contains('"')) { throw "Unexpected quote in the launcher path: $LauncherPath" }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $arguments = '-NoProfile -WindowStyle Hidden -File "' + $LauncherPath + '"'
    if ($NoBrowser) { $arguments += ' -NoBrowser' }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = Get-ClaudeCXSystemPwsh
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = Split-Path -Parent $LauncherPath
        $shortcut.Description = 'ClaudeCX control center: live runs, history, settings, and health'
        $shortcut.WindowStyle = 7
        $shortcut.Save()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Remove-ClaudeCXControlCenterShortcuts {
    # Removes only shortcuts that point at a ClaudeCX launcher. Returns the paths removed.
    $removed = [Collections.Generic.List[string]]::new()
    $paths = Get-ClaudeCXShortcutPaths
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($path in @($paths.StartMenu, $paths.Startup)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $shortcut = $shell.CreateShortcut($path)
            if ([string]$shortcut.Arguments -like '*start-control-center.ps1*') {
                Remove-Item -LiteralPath $path -Force
                $removed.Add($path)
            }
        }
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    return $removed.ToArray()
}

function Stop-ClaudeCXRunningControlCenter {
    # Stops a running control center (it may be serving files that are about to be replaced).
    # Returns $true when one was running.
    param([Parameter(Mandatory = $true)][string]$SettingsModulePath)

    Import-Module $SettingsModulePath -Force
    $running = Get-ClaudeCXControlCenter
    if ($null -eq $running) { return $false }
    try { (Get-Process -Id $running.ProcessId -ErrorAction Stop).Kill($true) } catch { }
    $files = Get-ClaudeCXControlCenterPaths
    foreach ($path in @($files.Info, $files.Token)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    return $true
}

Export-ModuleMember -Function @(
    'Get-ClaudeCXSkillName',
    'Get-ClaudeCXRequiredSkillFiles',
    'Get-ClaudeCXRepositoryRoot',
    'Get-ClaudeCXPackagedSkillRoot',
    'Resolve-ClaudeCXCodexHome',
    'Resolve-ClaudeCXClaudeSettingsPath',
    'Test-ClaudeCXReparsePoint',
    'Get-ClaudeCXTimestamp',
    'New-ClaudeCXUniquePath',
    'Get-ClaudeCXBackupRoot',
    'Get-ClaudeCXFrontMatter',
    'Test-ClaudeCXStrictJson',
    'Test-ClaudeCXStrictUtf8',
    'Test-ClaudeCXPowerShellSyntax',
    'Get-ClaudeCXSkillProblems',
    'Get-ClaudeCXTreeManifest',
    'Test-ClaudeCXTreeEqual',
    'Write-ClaudeCXUtf8File',
    'Read-ClaudeCXSettingsNode',
    'Set-ClaudeCXAttributionDisabled',
    'Get-ClaudeCXShortcutPaths',
    'Get-ClaudeCXSystemPwsh',
    'New-ClaudeCXControlCenterShortcut',
    'Remove-ClaudeCXControlCenterShortcuts',
    'Stop-ClaudeCXRunningControlCenter'
)
