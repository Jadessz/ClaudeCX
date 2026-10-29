#Requires -Version 7.2
# ClaudeCX user settings, per-project limits, protected paths, run discovery, and log pruning.
# The user's settings file lives in the ClaudeCX home (CLAUDECX_HOME, default %USERPROFILE%\.claudecx),
# which is outside %LOCALAPPDATA% so packaged apps such as the Codex desktop app read the same file.
# Settings only tune limits and display. Safety switches are fixed in the bridge and listed as locked.

Set-StrictMode -Version Latest

$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:MaxSettingsBytes = 65536
$script:ProjectFileName = '.claudecx.json'
$script:RepoKeyPattern = '^[0-9a-f]{24}$'
$script:SessionPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$script:TurnPattern = '^\d{8}-\d{9}$'

# Each field: key, type (number, integer, choice, bool, paths), default, bounds or choices, and UI text.
# 'project' marks the fields a repository's .claudecx.json may set; it can only make them stricter.
$script:Fields = @(
    [ordered]@{ key = 'max_budget_usd'; group = 'limits'; type = 'number'; default = 5.0; min = 0.01; max = 1000.0; step = 0.5; unit = 'USD'; project = $true
        label = 'Budget per run'; help = 'Claude stops when a single run reaches this cost. Codex can ask for less, never more.' }
    [ordered]@{ key = 'max_turns'; group = 'limits'; type = 'integer'; default = 60; min = 1; max = 500; step = 1; unit = 'turns'; project = $true
        label = 'Turns per run'; help = 'The most back-and-forth steps Claude may take in one run.' }
    [ordered]@{ key = 'timeout_minutes'; group = 'limits'; type = 'integer'; default = 60; min = 1; max = 1440; step = 5; unit = 'minutes'; project = $true
        label = 'Time limit per run'; help = 'The bridge stops Claude after this long.' }
    [ordered]@{ key = 'model'; group = 'claude'; type = 'choice'; default = 'default'; choices = @('default', 'sonnet', 'opus', 'haiku'); project = $false
        label = 'Claude model'; help = 'The model that does the work in every run.' }
    [ordered]@{ key = 'progress_display'; group = 'display'; type = 'choice'; default = 'dashboard'; choices = @('dashboard', 'window', 'console', 'none'); project = $false
        label = 'Live view during a run'; help = 'Used when the control center is not running; otherwise runs appear there.' }
    [ordered]@{ key = 'open_center_on_new_run'; group = 'display'; type = 'bool'; default = $true; project = $false
        label = 'Open the control center when a run starts'; help = 'Only when the control center is running and not already open in a browser tab.' }
    [ordered]@{ key = 'keep_logs_days'; group = 'housekeeping'; type = 'integer'; default = 0; min = 0; max = 3650; step = 1; unit = 'days'; project = $false
        label = 'Delete finished run logs after'; help = '0 keeps them forever. Run logs can contain parts of your code.' }
    [ordered]@{ key = 'protected_paths'; group = 'safety'; type = 'paths'; default = @(); maxItems = 50; project = $true
        label = 'Protected paths'; help = 'Files or folders relative to the project root. A folder ends with /, and *.lock matches in every folder.' }
)

$script:Locked = @(
    [ordered]@{ label = 'Safe mode'; reason = 'Repository hooks, plugins, skills, and MCP servers never load inside Claude.' }
    [ordered]@{ label = 'No commit, push, tag, or deploy'; reason = 'You stay the only one who commits; Codex reviews the diff first.' }
    [ordered]@{ label = 'Permission mode auto or plan'; reason = 'Permission checks are never bypassed.' }
    [ordered]@{ label = 'Clean tree to start, checked state to resume'; reason = 'Your own work is never mixed with Claude''s.' }
    [ordered]@{ label = 'Structured report required'; reason = 'A run without the report counts as failed.' }
    [ordered]@{ label = 'No nested handoffs'; reason = 'Claude cannot start Codex, Claude Code, or another bridge run.' }
)

function Get-ClaudeCXSettingsFields { return $script:Fields }

function Get-ClaudeCXLockedSettings { return $script:Locked }

function Get-ClaudeCXProjectFileName { $script:ProjectFileName }

function Get-ClaudeCXHome {
    # CLAUDECX_HOME, then %USERPROFILE%\.claudecx.
    if ($env:CLAUDECX_HOME) {
        return [IO.Path]::GetFullPath($env:CLAUDECX_HOME)
    }
    if (-not $env:USERPROFILE) {
        throw 'USERPROFILE is unavailable; set CLAUDECX_HOME to choose where ClaudeCX keeps its settings.'
    }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claudecx'))
}

function Get-ClaudeCXSettingsPath {
    return Join-Path (Get-ClaudeCXHome) 'settings.json'
}

function Get-ClaudeCXDefaultSettings {
    $values = [ordered]@{}
    foreach ($field in $script:Fields) {
        $values[$field.key] = if ($field.type -eq 'paths') { , @() } else { $field.default }
    }
    return $values
}

function ConvertTo-ClaudeCXProtectedPath {
    # Normalizes one protected-path pattern. Returns @{ Value; Error }.
    param([AllowNull()][object]$Value)

    if ($Value -isnot [string]) { return @{ Value = $null; Error = 'must be text' } }
    $text = $Value.Trim().Replace('\', '/')
    while ($text.StartsWith('./')) { $text = $text.Substring(2) }
    $text = $text.TrimStart('/')
    if (-not $text) { return @{ Value = $null; Error = 'is empty' } }
    if ($text.Length -gt 200) { return @{ Value = $null; Error = 'is longer than 200 characters' } }
    if ($text -match ':' -or $text -match '[\x00-\x1f"<>|]') { return @{ Value = $null; Error = "is not a repository-relative path: $text" } }
    if (@($text.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0) { return @{ Value = $null; Error = "may not contain '..': $text" } }
    return @{ Value = $text; Error = $null }
}

function Test-ClaudeCXSettingValue {
    # Validates one value against its field. Returns @{ Value; Error } with the normalized value.
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Field,
        [AllowNull()][object]$Value
    )

    $label = $Field.label
    switch ($Field.type) {
        { $_ -in 'number', 'integer' } {
            $isNumber = $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]
            if (-not $isNumber) { return @{ Value = $null; Error = "$label must be a number." } }
            $number = [decimal]$Value
            if ($Field.type -eq 'integer' -and $number -ne [Math]::Truncate($number)) { return @{ Value = $null; Error = "$label must be a whole number." } }
            if ($number -lt [decimal]$Field.min -or $number -gt [decimal]$Field.max) {
                return @{ Value = $null; Error = "$label must be between $($Field.min) and $($Field.max)." }
            }
            if ($Field.type -eq 'integer') { return @{ Value = [int]$number; Error = $null } }
            return @{ Value = [double][Math]::Round($number, 2); Error = $null }
        }
        'choice' {
            if ($Value -isnot [string] -or $Field.choices -cnotcontains $Value) {
                return @{ Value = $null; Error = "$label must be one of: $($Field.choices -join ', ')." }
            }
            return @{ Value = $Value; Error = $null }
        }
        'bool' {
            if ($Value -isnot [bool]) { return @{ Value = $null; Error = "$label must be true or false." } }
            return @{ Value = $Value; Error = $null }
        }
        'paths' {
            $items = @($Value)
            if ($null -eq $Value) { $items = @() }
            elseif ($Value -is [string]) { return @{ Value = $null; Error = "$label must be a list." } }
            if ($items.Count -gt $Field.maxItems) { return @{ Value = $null; Error = "$label may hold at most $($Field.maxItems) entries." } }
            $normalized = [Collections.Generic.List[string]]::new()
            foreach ($item in $items) {
                $result = ConvertTo-ClaudeCXProtectedPath -Value $item
                if ($result.Error) { return @{ Value = $null; Error = "A protected path $($result.Error)." } }
                if (-not $normalized.Contains($result.Value)) { $normalized.Add($result.Value) }
            }
            return @{ Value = $normalized.ToArray(); Error = $null }
        }
    }
    return @{ Value = $null; Error = "$label has an unknown type." }
}

function ConvertFrom-ClaudeCXSettingsText {
    # Parses settings JSON into an ordered table of validated values. Unknown keys are reported, not used.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Source,
        [switch]$Project
    )

    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $values = [ordered]@{}
    $parsed = $null
    try {
        $parsed = $Text | ConvertFrom-Json -Depth 10 -ErrorAction Stop
    }
    catch {
        $errors.Add("$Source is not valid JSON.")
    }
    if ($null -ne $parsed -and $parsed -isnot [Management.Automation.PSCustomObject]) {
        $errors.Add("$Source must hold a JSON object.")
        $parsed = $null
    }
    if ($null -ne $parsed) {
        foreach ($property in $parsed.PSObject.Properties) {
            if ($property.Name -eq '$schema') { continue }
            $field = $script:Fields | Where-Object { $_.key -ceq $property.Name } | Select-Object -First 1
            if ($null -eq $field) {
                $warnings.Add("$Source has an unknown setting '$($property.Name)'; it is ignored.")
                continue
            }
            if ($Project -and -not $field.project) {
                $warnings.Add("$Source cannot set '$($property.Name)'; only your own settings can. It is ignored.")
                continue
            }
            $result = Test-ClaudeCXSettingValue -Field $field -Value $property.Value
            if ($result.Error) { $errors.Add("${Source}: $($result.Error)") } else { $values[$field.key] = $result.Value }
        }
    }
    return [pscustomobject]@{ Values = $values; Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
}

function Read-ClaudeCXUserSettings {
    # Returns the user's settings merged over the defaults, with any problems found.
    param([string]$Path = (Get-ClaudeCXSettingsPath))

    $values = Get-ClaudeCXDefaultSettings
    $exists = [IO.File]::Exists($Path)
    $errors = @()
    $warnings = @()
    if ($exists) {
        $info = [IO.FileInfo]::new($Path)
        if ($info.Length -gt $script:MaxSettingsBytes) {
            $errors = @("The settings file is larger than $($script:MaxSettingsBytes) bytes.")
        }
        else {
            $bytes = [IO.File]::ReadAllBytes($Path)
            $offset = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
            $text = $null
            try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset) } catch { $errors = @('The settings file is not valid UTF-8.') }
            if ($null -ne $text) {
                $parsed = ConvertFrom-ClaudeCXSettingsText -Text $text -Source 'settings.json'
                foreach ($entry in $parsed.Values.GetEnumerator()) { $values[$entry.Key] = $entry.Value }
                $errors = $parsed.Errors
                $warnings = $parsed.Warnings
            }
        }
    }
    return [pscustomobject]@{ Path = $Path; Exists = $exists; Values = $values; Errors = @($errors); Warnings = @($warnings) }
}

function Save-ClaudeCXUserSettings {
    # Validates every value, then writes the complete settings file atomically.
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Values,
        [string]$Path = (Get-ClaudeCXSettingsPath)
    )

    $output = [ordered]@{}
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($key in $Values.Keys) {
        if (-not ($script:Fields | Where-Object { $_.key -ceq $key })) { $errors.Add("Unknown setting '$key'.") }
    }
    foreach ($field in $script:Fields) {
        # Assigned directly: an if-expression would unroll a one-item list into a plain string.
        $value = (Get-ClaudeCXDefaultSettings)[$field.key]
        if ($Values.Contains($field.key)) { $value = $Values[$field.key] }
        $result = Test-ClaudeCXSettingValue -Field $field -Value $value
        if ($result.Error) { $errors.Add($result.Error) } else { $output[$field.key] = $result.Value }
    }
    if ($errors.Count -gt 0) {
        throw ($errors -join ' ')
    }
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $json = ConvertTo-Json -InputObject $output -Depth 5
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $json.Replace("`r`n", "`n") + "`n", $script:Utf8)
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    return $output
}

function Read-ClaudeCXProjectSettings {
    # Reads .claudecx.json from the committed HEAD, so a run cannot loosen its own project limits.
    param([Parameter(Mandatory = $true)][string]$Repository)

    $output = & git -C $Repository -c core.quotepath=off show "HEAD:$($script:ProjectFileName)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Exists = $false; Values = [ordered]@{}; Errors = @(); Warnings = @() }
    }
    $text = ($output | Out-String)
    if ($script:Utf8.GetByteCount($text) -gt $script:MaxSettingsBytes) {
        return [pscustomobject]@{ Exists = $true; Values = [ordered]@{}; Errors = @("$($script:ProjectFileName) is larger than $($script:MaxSettingsBytes) bytes."); Warnings = @() }
    }
    $parsed = ConvertFrom-ClaudeCXSettingsText -Text $text -Source $script:ProjectFileName -Project
    return [pscustomobject]@{ Exists = $true; Values = $parsed.Values; Errors = $parsed.Errors; Warnings = $parsed.Warnings }
}

function Resolve-ClaudeCXRunSettings {
    # Effective limits for one run. Your settings are the ceiling: values Codex passes and the
    # project file can only lower them. Protected paths from both sources are combined.
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$User,
        [Collections.IDictionary]$Project = [ordered]@{},
        [Collections.IDictionary]$Requested = @{}
    )

    $notes = [Collections.Generic.List[string]]::new()
    $budget = [decimal]$User['max_budget_usd']
    $turns = [int]$User['max_turns']
    $timeout = [int]$User['timeout_minutes'] * 60

    if ($Project.Contains('max_budget_usd') -and [decimal]$Project['max_budget_usd'] -lt $budget) {
        $budget = [decimal]$Project['max_budget_usd']; $notes.Add("The project file lowers the budget to $budget USD.")
    }
    if ($Project.Contains('max_turns') -and [int]$Project['max_turns'] -lt $turns) {
        $turns = [int]$Project['max_turns']; $notes.Add("The project file lowers the turn limit to $turns.")
    }
    if ($Project.Contains('timeout_minutes') -and [int]$Project['timeout_minutes'] * 60 -lt $timeout) {
        $timeout = [int]$Project['timeout_minutes'] * 60; $notes.Add("The project file lowers the time limit to $($Project['timeout_minutes']) minutes.")
    }
    if ($Requested.Contains('MaxBudgetUsd')) {
        $asked = [decimal]$Requested['MaxBudgetUsd']
        if ($asked -lt $budget) { $budget = $asked }
        elseif ($asked -gt $budget) { $notes.Add("Codex asked for a $asked USD budget; the limit of $budget USD applies.") }
    }
    if ($Requested.Contains('MaxTurns')) {
        $asked = [int]$Requested['MaxTurns']
        if ($asked -lt $turns) { $turns = $asked }
        elseif ($asked -gt $turns) { $notes.Add("Codex asked for $asked turns; the limit of $turns applies.") }
    }
    if ($Requested.Contains('TimeoutSeconds')) {
        $asked = [int]$Requested['TimeoutSeconds']
        if ($asked -lt $timeout) { $timeout = $asked }
        elseif ($asked -gt $timeout) { $notes.Add("Codex asked for a $asked-second time limit; the limit of $timeout seconds applies.") }
    }

    $protected = [Collections.Generic.List[string]]::new()
    $protected.Add($script:ProjectFileName)
    foreach ($source in @($User['protected_paths'], $(if ($Project.Contains('protected_paths')) { $Project['protected_paths'] } else { @() }))) {
        foreach ($item in @($source)) {
            if ($item -and -not $protected.Contains([string]$item)) { $protected.Add([string]$item) }
        }
    }

    $display = @{ dashboard = 'Dashboard'; window = 'Window'; console = 'Console'; none = 'None' }[[string]$User['progress_display']]
    return [pscustomobject]@{
        MaxBudgetUsd = $budget
        MaxTurns = $turns
        TimeoutSeconds = [Math]::Max(30, $timeout)
        Model = [string]$User['model']
        ProgressMode = $display
        OpenCenterOnNewRun = [bool]$User['open_center_on_new_run']
        KeepLogsDays = [int]$User['keep_logs_days']
        ProtectedPaths = $protected.ToArray()
        Notes = $notes.ToArray()
    }
}

function ConvertTo-ClaudeCXPathRegex {
    # Glob to anchored, case-insensitive regex. '**' crosses folders, '*' and '?' do not.
    # A pattern ending in '/' or without wildcards also covers everything below it.
    param([Parameter(Mandatory = $true)][string]$Pattern)

    $folder = $Pattern.EndsWith('/')
    $body = $Pattern.TrimEnd('/')
    $builder = [Text.StringBuilder]::new('^')
    $index = 0
    while ($index -lt $body.Length) {
        $character = $body[$index]
        if ($character -eq '*' -and $index + 1 -lt $body.Length -and $body[$index + 1] -eq '*') {
            [void]$builder.Append('.*'); $index += 2
            if ($index -lt $body.Length -and $body[$index] -eq '/') { $index++ ; [void]$builder.Append('/?') }
            continue
        }
        if ($character -eq '*') { [void]$builder.Append('[^/]*') }
        elseif ($character -eq '?') { [void]$builder.Append('[^/]') }
        else { [void]$builder.Append([Regex]::Escape([string]$character)) }
        $index++
    }
    $hasWildcard = $body.IndexOfAny([char[]]'*?') -ge 0
    if ($folder -or -not $hasWildcard) { [void]$builder.Append('(/.*)?') }
    if ($hasWildcard -and -not $body.Contains('/')) {
        # A bare pattern such as *.lock matches that name in any folder.
        $builder.Insert(1, '(.*/)?') | Out-Null
    }
    [void]$builder.Append('$')
    return [Regex]::new($builder.ToString(), [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Get-ClaudeCXChangedPaths {
    # Every path git reports as changed, added, deleted, or untracked, including both sides of a rename.
    param([Parameter(Mandatory = $true)][string]$Repository)

    $raw = & git -C $Repository -c core.quotepath=off status --porcelain=v1 -z --untracked-files=all 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'git status failed while checking protected paths.' }
    $entries = @((($raw | Out-String) -replace "`r?`n$", '') -split "`0" | Where-Object { $_ })
    $paths = [Collections.Generic.List[string]]::new()
    $index = 0
    while ($index -lt $entries.Count) {
        $entry = $entries[$index]
        if ($entry.Length -lt 4) { $index++; continue }
        $code = $entry.Substring(0, 2)
        $paths.Add($entry.Substring(3))
        if ($code -match '[RC]') {
            $index++
            if ($index -lt $entries.Count) { $paths.Add($entries[$index]) }
        }
        $index++
    }
    return $paths.ToArray()
}

function Find-ClaudeCXProtectedChanges {
    # Returns the changed paths that match any protected pattern.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ChangedPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Patterns
    )

    $regexes = @($Patterns | Where-Object { $_ } | ForEach-Object { ConvertTo-ClaudeCXPathRegex -Pattern $_ })
    $hits = [Collections.Generic.List[string]]::new()
    foreach ($path in $ChangedPaths) {
        $normalized = $path.Replace('\', '/').TrimEnd('/')
        foreach ($regex in $regexes) {
            if ($regex.IsMatch($normalized)) {
                if (-not $hits.Contains($normalized)) { $hits.Add($normalized) }
                break
            }
        }
    }
    return $hits.ToArray()
}

function Get-ClaudeCXStateRoots {
    # The standard log folder plus any copy that a packaged app (such as the Codex desktop app)
    # was redirected to by Windows. Each root gets a short stable id for run identifiers.
    param([string]$LocalAppData = $env:LOCALAPPDATA)

    $roots = [Collections.Generic.List[object]]::new()
    if (-not $LocalAppData) { return @() }
    $candidates = [Collections.Generic.List[object]]::new()
    $candidates.Add(@{ Path = (Join-Path $LocalAppData 'CodexClaude\handoffs'); Kind = 'standard'; App = $null })
    $packages = Join-Path $LocalAppData 'Packages'
    if ([IO.Directory]::Exists($packages)) {
        foreach ($package in [IO.Directory]::EnumerateDirectories($packages)) {
            $redirected = Join-Path $package 'LocalCache\Local\CodexClaude\handoffs'
            if ([IO.Directory]::Exists($redirected)) {
                $candidates.Add(@{ Path = $redirected; Kind = 'packaged'; App = ([IO.Path]::GetFileName($package) -split '_')[0] })
            }
        }
    }
    foreach ($candidate in $candidates) {
        $full = [IO.Path]::GetFullPath($candidate.Path)
        $hash = [Security.Cryptography.SHA256]::HashData($script:Utf8.GetBytes($full.ToLowerInvariant()))
        $roots.Add([pscustomobject]@{
                Id = ([Convert]::ToHexString($hash)).Substring(0, 8).ToLowerInvariant()
                Path = $full
                Kind = $candidate.Kind
                App = $candidate.App
                Exists = [IO.Directory]::Exists($full)
            })
    }
    return $roots.ToArray()
}

function Test-ClaudeCXPlainDirectory {
    param([Parameter(Mandatory = $true)][IO.DirectoryInfo]$Directory)
    return -not ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-ClaudeCXTurnDirectories {
    # Every turn folder under one state root: <repo-key>\<session>\<turn>. Names are checked; links are skipped.
    param([Parameter(Mandatory = $true)][object]$Root)

    $turns = [Collections.Generic.List[object]]::new()
    if (-not [IO.Directory]::Exists($Root.Path)) { return @() }
    foreach ($repoDir in [IO.DirectoryInfo]::new($Root.Path).EnumerateDirectories()) {
        if ($repoDir.Name -cnotmatch $script:RepoKeyPattern -or -not (Test-ClaudeCXPlainDirectory $repoDir)) { continue }
        foreach ($sessionDir in $repoDir.EnumerateDirectories()) {
            if ($sessionDir.Name -cnotmatch $script:SessionPattern -or -not (Test-ClaudeCXPlainDirectory $sessionDir)) { continue }
            foreach ($turnDir in $sessionDir.EnumerateDirectories()) {
                if ($turnDir.Name -cnotmatch $script:TurnPattern -or -not (Test-ClaudeCXPlainDirectory $turnDir)) { continue }
                $turns.Add([pscustomobject]@{
                        Id = "$($Root.Id)/$($repoDir.Name)/$($sessionDir.Name)/$($turnDir.Name)"
                        Root = $Root
                        RepoKey = $repoDir.Name
                        SessionId = $sessionDir.Name
                        Turn = $turnDir.Name
                        Path = $turnDir.FullName
                        SessionPath = $sessionDir.FullName
                    })
            }
        }
    }
    return $turns.ToArray()
}

function Resolve-ClaudeCXRunId {
    # Maps a run id to its turn folder. Only ids of the exact form root/repo-key/session/turn under a
    # known root resolve; anything else returns $null. No other path is ever derived from input.
    param(
        [AllowNull()][AllowEmptyString()][string]$RunId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Roots
    )

    if (-not $RunId) { return $null }
    $match = [Regex]::Match($RunId, '^(?<root>[0-9a-f]{8})/(?<repo>[0-9a-f]{24})/(?<session>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/(?<turn>\d{8}-\d{9})$')
    if (-not $match.Success) { return $null }
    $root = $Roots | Where-Object { $_.Id -ceq $match.Groups['root'].Value } | Select-Object -First 1
    if ($null -eq $root) { return $null }
    $sessionPath = Join-Path (Join-Path $root.Path $match.Groups['repo'].Value) $match.Groups['session'].Value
    $path = Join-Path $sessionPath $match.Groups['turn'].Value
    if (-not [IO.Directory]::Exists($path)) { return $null }
    foreach ($directory in @($path, $sessionPath, (Split-Path -Parent $sessionPath))) {
        if (-not (Test-ClaudeCXPlainDirectory ([IO.DirectoryInfo]::new($directory)))) { return $null }
    }
    return [pscustomobject]@{
        Id = $RunId
        Root = $root
        RepoKey = $match.Groups['repo'].Value
        SessionId = $match.Groups['session'].Value
        Turn = $match.Groups['turn'].Value
        Path = [IO.Path]::GetFullPath($path)
        SessionPath = [IO.Path]::GetFullPath($sessionPath)
    }
}

function Get-ClaudeCXDirectorySize {
    param([Parameter(Mandatory = $true)][string]$Path)
    $total = [long]0
    try {
        foreach ($file in [IO.DirectoryInfo]::new($Path).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $total += $file.Length }
    }
    catch { }
    return $total
}

function Remove-ClaudeCXOldRuns {
    # Deletes finished turn folders whose completion is older than -Days. Running turns (no
    # progress.done) are never touched. Session folders left without turns are removed too.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Roots,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3650)][int]$Days,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $cutoff = $Now.AddDays(-$Days).UtcDateTime
    $removed = 0
    $freed = [long]0
    $sessions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $Roots) {
        foreach ($turn in @(Get-ClaudeCXTurnDirectories -Root $root)) {
            $done = Join-Path $turn.Path 'progress.done'
            if (-not [IO.File]::Exists($done)) { continue }
            if ([IO.File]::GetLastWriteTimeUtc($done) -ge $cutoff) { continue }
            $size = Get-ClaudeCXDirectorySize -Path $turn.Path
            try {
                [IO.Directory]::Delete($turn.Path, $true)
                $removed++
                $freed += $size
                [void]$sessions.Add($turn.SessionPath)
            }
            catch { }
        }
    }
    foreach ($session in $sessions) {
        try {
            $left = @([IO.Directory]::EnumerateDirectories($session) | Where-Object { [IO.Path]::GetFileName($_) -match $script:TurnPattern })
            if ($left.Count -eq 0) { [IO.Directory]::Delete($session, $true) }
        }
        catch { }
    }
    return [pscustomobject]@{ RemovedRuns = $removed; FreedBytes = $freed }
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

function Remove-ClaudeCXShortcutFiles {
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

function Test-ClaudeCXRunActive {
    # $true when any log folder holds a lock whose bridge process is still alive.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Roots)

    foreach ($root in $Roots) {
        if (-not [IO.Directory]::Exists($root.Path)) { continue }
        foreach ($lockPath in [IO.Directory]::EnumerateFiles($root.Path, 'active.lock', [IO.SearchOption]::AllDirectories)) {
            try {
                $lock = [IO.File]::ReadAllText($lockPath) | ConvertFrom-Json
                if ($null -ne (Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue)) { return $true }
            }
            catch { }
        }
    }
    return $false
}

function Get-ClaudeCXCodexHomeFromSkill {
    # <CodexHome>\skills\claudecx -> <CodexHome>; otherwise CODEX_HOME or %USERPROFILE%\.codex.
    param([string]$SkillRoot)

    if ($SkillRoot) {
        $skills = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SkillRoot))
        if ([IO.Path]::GetFileName($skills) -ieq 'skills') { return [IO.Path]::GetDirectoryName($skills) }
    }
    if ($env:CODEX_HOME) { return [IO.Path]::GetFullPath($env:CODEX_HOME) }
    if ($env:USERPROFILE) { return Join-Path $env:USERPROFILE '.codex' }
    return $null
}

function Get-ClaudeCXDataInventory {
    # Everything ClaudeCX itself creates on this computer, grouped so a user can see and wipe it.
    # Each item lists exact paths; nothing outside these fixed locations is ever included.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Roots,
        [string]$SkillRoot
    )

    $measure = {
        param([string[]]$Paths)
        $bytes = [long]0
        foreach ($path in $Paths) {
            if ([IO.Directory]::Exists($path)) { $bytes += Get-ClaudeCXDirectorySize -Path $path }
            elseif ([IO.File]::Exists($path)) { $bytes += ([IO.FileInfo]::new($path)).Length }
        }
        return $bytes
    }
    $items = [Collections.Generic.List[object]]::new()

    $logFolders = @($Roots | ForEach-Object { [IO.Path]::GetDirectoryName($_.Path) } |
        Where-Object { $_ -and [IO.Path]::GetFileName($_) -ieq 'CodexClaude' -and [IO.Directory]::Exists($_) } | Select-Object -Unique)
    $items.Add([ordered]@{
            id = 'run-logs'; label = 'Run logs'; default = $true
            description = 'Briefs, your requests, Claude''s raw output, reports, and saved diffs for every run, in every log folder (including the copies Windows redirected for packaged apps).'
            warning = 'Past runs disappear from History, and their sessions can no longer be resumed.'
            paths = $logFolders
        })

    $drafts = [Collections.Generic.List[string]]::new()
    $drafts.Add((Join-Path ([IO.Path]::GetTempPath()) 'claudecx'))
    foreach ($root in $Roots | Where-Object { $_.Kind -eq 'packaged' }) {
        $drafts.Add([IO.Path]::GetFullPath((Join-Path $root.Path '..\..\Temp\claudecx')))
    }
    $items.Add([ordered]@{
            id = 'drafts'; label = 'Brief drafts'; default = $true
            description = 'The brief and request files Codex writes in a temporary folder before handing them to the bridge.'
            warning = $null
            paths = @($drafts | Where-Object { [IO.Directory]::Exists($_) } | Select-Object -Unique)
        })

    $settingsPath = Get-ClaudeCXSettingsPath
    $items.Add([ordered]@{
            id = 'settings'; label = 'Your ClaudeCX settings'; default = $false
            description = 'Limits, model, display choices, and protected paths.'
            warning = 'Every setting goes back to its default.'
            paths = @(@($settingsPath) | Where-Object { [IO.File]::Exists($_) })
        })

    $codexHome = Get-ClaudeCXCodexHomeFromSkill -SkillRoot $SkillRoot
    $backups = if ($codexHome) { Join-Path $codexHome 'claudecx-backups' } else { $null }
    $items.Add([ordered]@{
            id = 'skill-backups'; label = 'Old ClaudeCX versions'; default = $true
            description = 'Copies of earlier installs that the installer and uninstaller keep so you can roll back.'
            warning = 'You can no longer roll back to an earlier version.'
            paths = @(@($backups) | Where-Object { $_ -and [IO.Directory]::Exists($_) })
        })

    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.claude' } else { $null }
    $claudeBackups = @(if ($claudeDir -and [IO.Directory]::Exists($claudeDir)) {
            [IO.Directory]::EnumerateFiles($claudeDir, 'settings.json.claudecx-backup-*')
        })
    $items.Add([ordered]@{
            id = 'claude-backups'; label = 'Claude settings backups'; default = $false
            description = 'Copies of your Claude Code settings.json saved before -DisableClaudeAttribution changed it.'
            warning = 'These are the only copies of your Claude settings from before that change.'
            paths = $claudeBackups
        })

    $shortcutPaths = @()
    try { $shortcutPaths = @((Get-ClaudeCXShortcutPaths).PSObject.Properties.Value | Where-Object { [IO.File]::Exists($_) }) } catch { }
    $app = @(@($SkillRoot) | Where-Object { $_ -and [IO.Directory]::Exists($_) }) + $shortcutPaths + @(@(Get-ClaudeCXHome) | Where-Object { [IO.Directory]::Exists($_) })
    $items.Add([ordered]@{
            id = 'app'; label = 'ClaudeCX itself'; default = $false
            description = 'Uninstalls the skill from Codex, removes the Start menu and sign-in shortcuts, deletes the ClaudeCX folder in your profile, and stops the control center.'
            warning = '$claudecx stops working until you install it again from the repository.'
            paths = $app
        })

    foreach ($item in $items) {
        $item['paths'] = @($item['paths'])
        $item['bytes'] = & $measure $item['paths']
        $item['exists'] = ($item['paths'].Count -gt 0)
    }
    return $items.ToArray()
}

function Remove-ClaudeCXPathSafely {
    # Deletes one inventory path. Symbolic links and junctions are removed as links, never followed.
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path); return }
    if (-not [IO.Directory]::Exists($Path)) { return }
    $info = [IO.DirectoryInfo]::new($Path)
    if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { $info.Delete(); return }
    foreach ($child in $info.EnumerateFileSystemInfos()) {
        if ($child -is [IO.DirectoryInfo]) { Remove-ClaudeCXPathSafely -Path $child.FullName }
        else {
            $child.Attributes = [IO.FileAttributes]::Normal
            $child.Delete()
        }
    }
    $info.Delete()
}

function Remove-ClaudeCXData {
    # Deletes the chosen inventory items. 'app' is not handled here: the caller uninstalls last.
    # Returns one result per item with what was removed and any error.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Ids,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Roots,
        [string]$SkillRoot
    )

    $inventory = @(Get-ClaudeCXDataInventory -Roots $Roots -SkillRoot $SkillRoot)
    $results = [Collections.Generic.List[object]]::new()
    foreach ($item in $inventory) {
        if ($Ids -cnotcontains $item.id -or $item.id -eq 'app') { continue }
        $errors = [Collections.Generic.List[string]]::new()
        $removed = 0
        foreach ($path in $item.paths) {
            try { Remove-ClaudeCXPathSafely -Path $path; $removed++ } catch { $errors.Add("${path}: $($_.Exception.Message)") }
        }
        $results.Add([ordered]@{ id = $item.id; label = $item.label; removed = $removed; freed_bytes = $item.bytes; errors = $errors.ToArray() })
    }
    return $results.ToArray()
}

function Remove-ClaudeCXInstall {
    # Uninstalls permanently: shortcuts, the installed skill folder (only if it is a ClaudeCX skill
    # inside a 'skills' folder), and the ClaudeCX home. Returns the paths removed.
    param([Parameter(Mandatory = $true)][string]$SkillRoot)

    $removed = [Collections.Generic.List[string]]::new()
    try { foreach ($path in @(Remove-ClaudeCXShortcutFiles)) { $removed.Add($path) } } catch { }
    $full = [IO.Path]::GetFullPath($SkillRoot)
    $skillFile = Join-Path $full 'SKILL.md'
    $isSkill = [IO.File]::Exists($skillFile) -and ([IO.File]::ReadAllText($skillFile) -match '(?m)^name:\s*claudecx\s*$') -and
        ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($full)) -ieq 'skills')
    if ($isSkill) {
        Remove-ClaudeCXPathSafely -Path $full
        $removed.Add($full)
    }
    $home_ = Get-ClaudeCXHome
    if ([IO.Directory]::Exists($home_)) {
        Remove-ClaudeCXPathSafely -Path $home_
        $removed.Add($home_)
    }
    return $removed.ToArray()
}

function Get-ClaudeCXControlCenterPaths {
    $home_ = Get-ClaudeCXHome
    # One control center per ClaudeCX home; the mutex name keeps separate homes (tests) apart.
    $hash = [Security.Cryptography.SHA256]::HashData($script:Utf8.GetBytes($home_.ToLowerInvariant()))
    return [pscustomobject]@{
        Info = Join-Path $home_ 'control-center.json'
        Token = Join-Path $home_ 'control-center.token'
        Mutex = 'Local\ClaudeCXControlCenter-' + ([Convert]::ToHexString($hash)).Substring(0, 16).ToLowerInvariant()
    }
}

function Get-ClaudeCXControlCenter {
    # The running control center, or $null. The process must still be the one that wrote the file.
    $paths = Get-ClaudeCXControlCenterPaths
    try {
        if (-not [IO.File]::Exists($paths.Info)) { return $null }
        $info = [IO.File]::ReadAllText($paths.Info, $script:Utf8) | ConvertFrom-Json -ErrorAction Stop
        $port = [int]$info.port
        $processId = [int]$info.pid
        if ($port -lt 1024 -or $port -gt 65535 -or $processId -le 0) { return $null }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { return $null }
        $started = if ($info.started_at -is [DateTime]) { ([DateTimeOffset]$info.started_at).UtcDateTime } else { [DateTimeOffset]::Parse([string]$info.started_at, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
        if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $started).TotalSeconds) -gt 5) { return $null }
        return [pscustomobject]@{ Port = $port; ProcessId = $processId; Url = "http://127.0.0.1:$port/" }
    }
    catch {
        return $null
    }
}

Export-ModuleMember -Function @(
    'Get-ClaudeCXShortcutPaths',
    'Remove-ClaudeCXShortcutFiles',
    'Test-ClaudeCXRunActive',
    'Get-ClaudeCXCodexHomeFromSkill',
    'Get-ClaudeCXDataInventory',
    'Remove-ClaudeCXPathSafely',
    'Remove-ClaudeCXData',
    'Remove-ClaudeCXInstall',
    'Get-ClaudeCXControlCenterPaths',
    'Get-ClaudeCXControlCenter',
    'Get-ClaudeCXSettingsFields',
    'Get-ClaudeCXLockedSettings',
    'Get-ClaudeCXProjectFileName',
    'Get-ClaudeCXHome',
    'Get-ClaudeCXSettingsPath',
    'Get-ClaudeCXDefaultSettings',
    'Test-ClaudeCXSettingValue',
    'ConvertFrom-ClaudeCXSettingsText',
    'Read-ClaudeCXUserSettings',
    'Save-ClaudeCXUserSettings',
    'Read-ClaudeCXProjectSettings',
    'Resolve-ClaudeCXRunSettings',
    'ConvertTo-ClaudeCXPathRegex',
    'Get-ClaudeCXChangedPaths',
    'Find-ClaudeCXProtectedChanges',
    'Get-ClaudeCXStateRoots',
    'Get-ClaudeCXTurnDirectories',
    'Resolve-ClaudeCXRunId',
    'Get-ClaudeCXDirectorySize',
    'Remove-ClaudeCXOldRuns'
)
