#Requires -Version 7.2
# The always-on ClaudeCX control center: run discovery across every log folder, run history, the
# per-run views of the dashboard, user settings, setup health, and log clean-up. It serves the same
# packaged dashboard assets on 127.0.0.1 with a bearer token, like the per-run dashboard.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Progress.psm1')
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Dashboard.psm1')
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Settings.psm1')

$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:TokenVariable = 'CLAUDECX_CENTER_TOKEN'
$script:MaxBodyBytes = 32768
$script:HistoryLimit = 300
$script:StaticAssets = [ordered]@{
    '/' = @('index.html', 'text/html; charset=utf-8')
    '/index.html' = @('index.html', 'text/html; charset=utf-8')
    '/styles.css' = @('styles.css', 'text/css; charset=utf-8')
    '/app.js' = @('app.js', 'text/javascript; charset=utf-8')
}
$script:ApiRoutes = @{
    '/api/center' = 'GET'
    '/api/runs' = 'GET'
    '/api/run/state' = 'GET'
    '/api/run/changes' = 'GET'
    '/api/run/report' = 'GET'
    '/api/run/prompts' = 'GET'
    '/api/run/stop' = 'POST'
    '/api/settings' = 'GET,POST'
    '/api/health' = 'GET'
    '/api/logs/prune' = 'POST'
    '/api/data' = 'GET'
    '/api/data/wipe' = 'POST'
    '/api/center/quit' = 'POST'
}
$script:WipeConfirmation = 'DELETE'

function Get-ClaudeCXCenterTokenVariable { $script:TokenVariable }

function New-ClaudeCXCenterContext {
    # Server-side state. The token lives only in this object, the server's memory, and the
    # control-center.token file in the user's ClaudeCX home.
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AssetRoot,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$SkillRoot,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )

    return [pscustomobject]@{
        Token = $Token
        AssetRoot = [IO.Path]::GetFullPath($AssetRoot)
        SkillRoot = [IO.Path]::GetFullPath($SkillRoot)
        Port = $Port
        LocalAppData = $LocalAppData
        LastApiRequest = [DateTimeOffset]::MinValue
        Roots = @()
        RootsAt = [DateTimeOffset]::MinValue
        SeenActive = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        Scanned = $false
        QuitRequested = $false
        UninstallRequested = $false
        StartedAt = [DateTimeOffset]::Now
    }
}

function Get-ClaudeCXCenterRoots {
    # Log folders, re-discovered at most every 15 seconds.
    param([Parameter(Mandatory = $true)][object]$Context, [switch]$Refresh)

    $now = [DateTimeOffset]::UtcNow
    if ($Refresh -or ($now - $Context.RootsAt).TotalSeconds -ge 15) {
        $Context.Roots = @(Get-ClaudeCXStateRoots -LocalAppData $Context.LocalAppData)
        $Context.RootsAt = $now
    }
    return $Context.Roots
}

function Get-ClaudeCXTurnStartTime {
    param([Parameter(Mandatory = $true)][string]$Turn)
    try {
        $local = [DateTime]::ParseExact($Turn, 'yyyyMMdd-HHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
        return ([DateTimeOffset]$local).ToString('o')
    }
    catch { return $null }
}

function Get-ClaudeCXRunMetadata {
    # Metadata for one turn folder, with run_directory set to where the folder really is. Folders
    # written by a packaged app record the path the app saw, which differs from the real one.
    param([Parameter(Mandatory = $true)][object]$Turn)

    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory $Turn.Path
    $metadata = Read-ClaudeCXJsonFile -Path $paths.Metadata
    if ($null -eq $metadata) {
        $session = Read-ClaudeCXJsonFile -Path (Join-Path $Turn.SessionPath 'session.json')
        $repository = if ($null -ne $session) { [string]$session.PSObject.Properties['repository']?.Value } else { '' }
        $metadata = [pscustomobject][ordered]@{
            repository = $repository
            repository_name = $(if ($repository) { Split-Path -Leaf $repository } else { 'Unknown repository' })
            session_id = $Turn.SessionId
            resumed = $false
            bridge_pid = 0
            bridge_started_at = $null
            started_at = Get-ClaudeCXTurnStartTime -Turn $Turn.Turn
        }
    }
    $metadata | Add-Member -NotePropertyName run_directory -NotePropertyValue $paths.TurnDirectory -Force
    foreach ($name in @('repository', 'repository_name', 'session_id', 'bridge_pid', 'started_at')) {
        if ($null -eq $metadata.PSObject.Properties[$name]) {
            $metadata | Add-Member -NotePropertyName $name -NotePropertyValue $null -Force
        }
    }
    return $metadata
}

function Get-ClaudeCXRequestPreview {
    # First meaningful line of the user's request (or of the brief), shortened.
    param([Parameter(Mandatory = $true)][object]$Paths)

    foreach ($path in @($Paths.OriginalPrompt, $Paths.CodexBrief)) {
        $text = Read-ClaudeCXPromptFile -Path $path
        if ($null -eq $text) { continue }
        foreach ($line in ($text -split "`n")) {
            # Markdown links (Codex writes the skill name as one) keep only their text.
            $clean = (($line -replace '\[([^\]]*)\]\([^)]*\)', '$1') -replace '^\s*#+\s*', '').Trim()
            if ($clean) { return ConvertTo-ClaudeCXSafeText -Text $clean -MaxLength 160 }
        }
    }
    return $null
}

function Get-ClaudeCXRunSummary {
    # One history row. Reads only small fixed files in the turn folder.
    param([Parameter(Mandatory = $true)][object]$Turn)

    $metadata = Get-ClaudeCXRunMetadata -Turn $Turn
    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory $Turn.Path
    $done = Read-ClaudeCXJsonFile -Path $paths.Done
    $status = 'interrupted'
    $finishedAt = $null
    if ($null -ne $done) {
        $marker = [string]$done.PSObject.Properties['status']?.Value
        $status = switch ($marker) { 'success' { 'succeeded' } 'stopped' { 'stopped' } default { 'failed' } }
        $finishedAt = Get-ClaudeCXIsoTime -Object $done -Name 'finished_at'
    }
    elseif ([int]($metadata.bridge_pid ?? 0) -gt 0 -and (Test-ClaudeCXBridgeAlive -Metadata $metadata)) {
        $status = 'active'
    }
    $result = Read-ClaudeCXJsonFile -Path $paths.Result
    return [ordered]@{
        id = $Turn.Id
        repository_name = ConvertTo-ClaudeCXSafeText -Text ([string]$metadata.repository_name) -MaxLength 120
        repository = ConvertTo-ClaudeCXSafeText -Text ([string]$metadata.repository) -MaxLength 400
        session_id = $Turn.SessionId
        resumed = ($metadata.PSObject.Properties['resumed']?.Value -eq $true)
        started_at = Get-ClaudeCXIsoTime -Object $metadata -Name 'started_at'
        finished_at = $finishedAt
        status = $status
        total_cost_usd = Get-ClaudeCXNumber -Object $result -Name 'total_cost_usd'
        num_turns = Get-ClaudeCXNumber -Object $result -Name 'num_turns'
        duration_ms = Get-ClaudeCXNumber -Object $result -Name 'duration_ms'
        max_budget_usd = Get-ClaudeCXNumber -Object $metadata -Name 'max_budget_usd'
        request = Get-ClaudeCXRequestPreview -Paths $paths
        source = $(if ($Turn.Root.Kind -eq 'packaged') { 'codex-app' } else { 'standard' })
    }
}

function Get-ClaudeCXRunHistory {
    # Newest first across every log folder.
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [ValidateRange(1, 1000)][int]$Limit = $script:HistoryLimit
    )

    $turns = [Collections.Generic.List[object]]::new()
    foreach ($root in (Get-ClaudeCXCenterRoots -Context $Context)) {
        foreach ($turn in (Get-ClaudeCXTurnDirectories -Root $root)) { $turns.Add($turn) }
    }
    $sorted = @($turns | Sort-Object -Property @{ Expression = 'Turn'; Descending = $true } | Select-Object -First $Limit)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($turn in $sorted) {
        try { $rows.Add((Get-ClaudeCXRunSummary -Turn $turn)) } catch { }
    }
    return [ordered]@{ runs = $rows.ToArray(); total = $turns.Count; limit = $Limit; generated_at = [DateTimeOffset]::Now.ToString('o') }
}

function Get-ClaudeCXActiveRuns {
    # Runs in progress: a live bridge lock, then the newest turn of that repository.
    param([Parameter(Mandatory = $true)][object]$Context)

    $active = [Collections.Generic.List[object]]::new()
    foreach ($root in (Get-ClaudeCXCenterRoots -Context $Context)) {
        if (-not $root.Exists) { continue }
        foreach ($repoDir in [IO.DirectoryInfo]::new($root.Path).EnumerateDirectories()) {
            if ($repoDir.Name -cnotmatch '^[0-9a-f]{24}$') { continue }
            $lock = Read-ClaudeCXJsonFile -Path (Join-Path $repoDir.FullName 'active.lock')
            if ($null -eq $lock) { continue }
            $lockPid = 0
            if (-not [int]::TryParse([string]$lock.PSObject.Properties['pid']?.Value, [ref]$lockPid) -or $null -eq (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) { continue }
            $newest = $null
            foreach ($turn in (Get-ClaudeCXTurnDirectories -Root $root)) {
                if ($turn.RepoKey -cne $repoDir.Name) { continue }
                if ($null -eq $newest -or [string]::CompareOrdinal($turn.Turn, $newest.Turn) -gt 0) { $newest = $turn }
            }
            if ($null -eq $newest) { continue }
            $summary = Get-ClaudeCXRunSummary -Turn $newest
            if ($summary.status -eq 'active') { $active.Add($summary) }
        }
    }
    return $active.ToArray()
}

function Get-ClaudeCXLatestRun {
    param([Parameter(Mandatory = $true)][object]$Context)

    $newest = $null
    foreach ($root in (Get-ClaudeCXCenterRoots -Context $Context)) {
        foreach ($turn in (Get-ClaudeCXTurnDirectories -Root $root)) {
            if ($null -eq $newest -or [string]::CompareOrdinal($turn.Turn, $newest.Turn) -gt 0) { $newest = $turn }
        }
    }
    if ($null -eq $newest) { return $null }
    return Get-ClaudeCXRunSummary -Turn $newest
}

function Get-ClaudeCXCenterOverview {
    param([Parameter(Mandatory = $true)][object]$Context)

    $settings = Read-ClaudeCXUserSettings
    return [ordered]@{
        active = @(Get-ClaudeCXActiveRuns -Context $Context)
        latest = Get-ClaudeCXLatestRun -Context $Context
        settings_path = $settings.Path
        settings_errors = @($settings.Errors)
        started_at = $Context.StartedAt.ToString('o')
        server_time = [DateTimeOffset]::Now.ToString('o')
    }
}

function Get-ClaudeCXSettingsPayload {
    $settings = Read-ClaudeCXUserSettings
    $fields = foreach ($field in @(Get-ClaudeCXSettingsFields)) {
        $copy = [ordered]@{}
        foreach ($entry in $field.GetEnumerator()) { $copy[$entry.Key] = $entry.Value }
        $copy
    }
    return [ordered]@{
        path = $settings.Path
        exists = $settings.Exists
        values = $settings.Values
        defaults = Get-ClaudeCXDefaultSettings
        fields = @($fields)
        locked = @(Get-ClaudeCXLockedSettings)
        project_file = Get-ClaudeCXProjectFileName
        errors = @($settings.Errors)
        warnings = @($settings.Warnings)
    }
}

function Save-ClaudeCXSettingsFromBody {
    # Body: {"values": {...}}. Returns @{ Status; Value }.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body)

    $parsed = $null
    try { $parsed = $Body | ConvertFrom-Json -Depth 10 -ErrorAction Stop } catch { }
    $valuesNode = if ($parsed -is [Management.Automation.PSCustomObject]) { $parsed.PSObject.Properties['values']?.Value } else { $null }
    if ($valuesNode -isnot [Management.Automation.PSCustomObject]) {
        return @{ Status = 400; Value = [ordered]@{ error = 'bad_request'; messages = @('Send {"values": {...}}.') } }
    }
    $values = [ordered]@{}
    foreach ($property in $valuesNode.PSObject.Properties) { $values[$property.Name] = $property.Value }
    try {
        $null = Save-ClaudeCXUserSettings -Values $values
    }
    catch {
        return @{ Status = 422; Value = [ordered]@{ error = 'invalid_settings'; messages = @(ConvertTo-ClaudeCXSafeText -Text $_.Exception.Message -MaxLength 1000) } }
    }
    return @{ Status = 200; Value = (Get-ClaudeCXSettingsPayload) }
}

function Invoke-ClaudeCXCenterTool {
    # Runs a fixed read-only command with a timeout. .cmd shims run through the command interpreter.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    if ([IO.Path]::GetExtension($Path) -in '.cmd', '.bat') {
        $startInfo.FileName = $env:ComSpec
        foreach ($argument in @('/d', '/c', $Path) + $Arguments) { $startInfo.ArgumentList.Add($argument) }
    }
    else {
        $startInfo.FileName = $Path
        foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:Utf8
    $startInfo.Environment.Remove($script:TokenVariable) | Out-Null
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { return $null }
        $process.StandardInput.Close()
        $out = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $true }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $out.GetAwaiter().GetResult(); TimedOut = $false }
    }
    catch {
        return $null
    }
    finally {
        $process.Dispose()
    }
}

function Get-ClaudeCXHealth {
    # Setup checks for the Health tab, plus log storage per folder.
    param([Parameter(Mandatory = $true)][object]$Context)

    $checks = [Collections.Generic.List[object]]::new()
    $add = { param($Id, $Label, $Status, $Message, $Fix) $checks.Add([ordered]@{ id = $Id; label = $Label; status = $Status; message = $Message; fix = $Fix }) }

    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $version = Invoke-ClaudeCXCenterTool -Path $git.Source -Arguments @('--version') -TimeoutSeconds 10
        & $add 'git' 'Git' 'ok' ($(if ($version -and $version.ExitCode -eq 0) { $version.Output.Trim() } else { $git.Source })) $null
    }
    else {
        & $add 'git' 'Git' 'fail' 'Git was not found on PATH.' 'Install Git: winget install --id Git.Git -e --source winget'
    }

    $claude = Get-Command claude.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claude) { $claude = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($claude) {
        $version = Invoke-ClaudeCXCenterTool -Path $claude.Source -Arguments @('--version') -TimeoutSeconds 20
        $text = if ($version -and $version.ExitCode -eq 0) { ConvertTo-ClaudeCXSafeText -Text $version.Output.Trim() -MaxLength 120 } else { 'found, but --version did not answer' }
        & $add 'claude' 'Claude Code' $(if ($version -and $version.ExitCode -eq 0) { 'ok' } else { 'warn' }) $text $(if ($version -and $version.ExitCode -eq 0) { $null } else { 'Run claude --version in a terminal; update with claude update.' })
        $auth = Invoke-ClaudeCXCenterTool -Path $claude.Source -Arguments @('auth', 'status') -TimeoutSeconds 20
        $loggedIn = $false
        if ($auth -and $auth.ExitCode -eq 0) {
            try { $loggedIn = (($auth.Output | ConvertFrom-Json -ErrorAction Stop).PSObject.Properties['loggedIn']?.Value -eq $true) } catch { }
        }
        if ($loggedIn) { & $add 'claude-signin' 'Claude sign-in' 'ok' 'Signed in.' $null }
        elseif ($env:ANTHROPIC_API_KEY) { & $add 'claude-signin' 'Claude sign-in' 'ok' 'Using an API key from the environment.' $null }
        else { & $add 'claude-signin' 'Claude sign-in' 'fail' 'Claude Code is not signed in.' 'Run claude auth login in a terminal.' }
    }
    else {
        & $add 'claude' 'Claude Code' 'fail' 'Claude Code was not found on PATH.' 'Install it: irm https://claude.ai/install.ps1 | iex'
    }

    $settings = Read-ClaudeCXUserSettings
    if ($settings.Errors.Count -gt 0) {
        & $add 'settings' 'Settings file' 'fail' ($settings.Errors -join ' ') 'Save the Settings tab again, or delete the file to go back to defaults.'
    }
    else {
        & $add 'settings' 'Settings file' 'ok' $(if ($settings.Exists) { 'Valid.' } else { 'Not created yet; defaults apply.' }) $null
    }

    $missing = @('index.html', 'app.js', 'styles.css' | Where-Object { -not [IO.File]::Exists((Join-Path $Context.AssetRoot $_)) })
    & $add 'skill' 'ClaudeCX skill' $(if ($missing.Count) { 'fail' } else { 'ok' }) $(if ($missing.Count) { "Dashboard files are missing: $($missing -join ', ')" } else { $Context.SkillRoot }) $(if ($missing.Count) { 'Reinstall: pwsh -NoProfile -File .\install.ps1 -Force' } else { $null })

    $storage = foreach ($root in (Get-ClaudeCXCenterRoots -Context $Context -Refresh)) {
        $turns = @(Get-ClaudeCXTurnDirectories -Root $root)
        [ordered]@{
            path = $root.Path
            kind = $root.Kind
            app = $root.App
            exists = $root.Exists
            runs = $turns.Count
            bytes = $(if ($root.Exists) { Get-ClaudeCXDirectorySize -Path $root.Path } else { 0 })
        }
    }
    $failing = @($checks | Where-Object { $_.status -eq 'fail' }).Count
    return [ordered]@{
        ready = ($failing -eq 0)
        checks = $checks.ToArray()
        storage = @($storage)
        keep_logs_days = [int]$settings.Values['keep_logs_days']
        generated_at = [DateTimeOffset]::Now.ToString('o')
    }
}

function Invoke-ClaudeCXCenterPrune {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body
    )

    $days = 0
    try {
        $parsed = $Body | ConvertFrom-Json -ErrorAction Stop
        $value = $parsed.PSObject.Properties['days']?.Value
        if ($value -is [int] -or $value -is [long]) { $days = [int]$value }
    }
    catch { }
    if ($days -lt 1 -or $days -gt 3650) {
        return @{ Status = 422; Value = [ordered]@{ error = 'invalid_days'; messages = @('Choose between 1 and 3650 days.') } }
    }
    $result = Remove-ClaudeCXOldRuns -Roots @(Get-ClaudeCXCenterRoots -Context $Context -Refresh) -Days $days
    return @{ Status = 200; Value = [ordered]@{ removed_runs = $result.RemovedRuns; freed_bytes = $result.FreedBytes; days = $days } }
}

function Get-ClaudeCXDataPayload {
    param([Parameter(Mandatory = $true)][object]$Context)

    $roots = @(Get-ClaudeCXCenterRoots -Context $Context -Refresh)
    return [ordered]@{
        items = @(Get-ClaudeCXDataInventory -Roots $roots -SkillRoot $Context.SkillRoot)
        run_active = (Test-ClaudeCXRunActive -Roots $roots)
        confirmation = $script:WipeConfirmation
    }
}

function Invoke-ClaudeCXCenterWipe {
    # Body: {"items": ["run-logs", ...], "confirm": "DELETE"}. 'app' uninstalls after the server stops.
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body
    )

    $parsed = $null
    try { $parsed = $Body | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($parsed -isnot [Management.Automation.PSCustomObject]) {
        return @{ Status = 400; Value = [ordered]@{ error = 'bad_request'; messages = @('Send {"items": [...], "confirm": "DELETE"}.') } }
    }
    if ([string]$parsed.PSObject.Properties['confirm']?.Value -cne $script:WipeConfirmation) {
        return @{ Status = 422; Value = [ordered]@{ error = 'not_confirmed'; messages = @("Type $($script:WipeConfirmation) to confirm.") } }
    }
    $known = @('run-logs', 'drafts', 'settings', 'skill-backups', 'claude-backups', 'app')
    $ids = @($parsed.PSObject.Properties['items']?.Value | ForEach-Object { [string]$_ })
    if ($ids.Count -eq 0 -or @($ids | Where-Object { $known -cnotcontains $_ }).Count -gt 0) {
        return @{ Status = 422; Value = [ordered]@{ error = 'invalid_items'; messages = @('Choose at least one item to delete.') } }
    }
    $roots = @(Get-ClaudeCXCenterRoots -Context $Context -Refresh)
    if (Test-ClaudeCXRunActive -Roots $roots) {
        return @{ Status = 409; Value = [ordered]@{ error = 'run_active'; messages = @('A run is in progress. Wait for it to finish, or stop it, then try again.') } }
    }
    $results = @(Remove-ClaudeCXData -Ids $ids -Roots $roots -SkillRoot $Context.SkillRoot)
    $Context.RootsAt = [DateTimeOffset]::MinValue
    if ($ids -ccontains 'app') {
        $Context.UninstallRequested = $true
        $Context.QuitRequested = $true
    }
    return @{ Status = 200; Value = [ordered]@{ results = $results; uninstalling = ($ids -ccontains 'app') } }
}

function Get-ClaudeCXQueryValue {
    param([Parameter(Mandatory = $true)][string]$Target, [Parameter(Mandatory = $true)][string]$Name)

    $query = ($Target -split '\?', 2)
    if ($query.Count -lt 2) { return $null }
    foreach ($pair in ($query[1] -split '&')) {
        $split = $pair.IndexOf('=')
        if ($split -lt 1) { continue }
        if ($pair.Substring(0, $split) -ceq $Name) {
            try { return [Uri]::UnescapeDataString($pair.Substring($split + 1).Replace('+', ' ')) } catch { return $null }
        }
    }
    return $null
}

function Invoke-ClaudeCXCenterRequest {
    # Routes one parsed request. Fixed routes only; a run is addressed by a validated id.
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
        [AllowEmptyString()][string]$Body = ''
    )

    $expectedHost = "127.0.0.1:$($Context.Port)"
    $hostHeader = if ($Headers.Contains('host')) { [string]$Headers['host'] } else { '' }
    if ($hostHeader -cne $expectedHost) {
        return New-ClaudeCXJsonResponse -Status 421 -Value @{ error = 'misdirected_request' }
    }
    $path = ($Target -split '\?', 2)[0]

    if ($script:StaticAssets.Contains($path)) {
        if ($Method -cne 'GET') {
            return New-ClaudeCXJsonResponse -Status 405 -Value @{ error = 'method_not_allowed' } -ExtraHeaders @{ Allow = 'GET' }
        }
        $asset = $script:StaticAssets[$path]
        return New-ClaudeCXDashboardResponse -Status 200 -ContentType $asset[1] -Body ([IO.File]::ReadAllBytes((Join-Path $Context.AssetRoot $asset[0])))
    }
    if (-not $script:ApiRoutes.ContainsKey($path)) {
        return New-ClaudeCXJsonResponse -Status 404 -Value @{ error = 'not_found' }
    }

    $authorization = if ($Headers.Contains('authorization')) { [string]$Headers['authorization'] } else { '' }
    $presented = if ($authorization.StartsWith('Bearer ', [StringComparison]::Ordinal)) { $authorization.Substring(7) } else { '' }
    if (-not (Test-ClaudeCXDashboardToken -Expected $Context.Token -Presented $presented)) {
        return New-ClaudeCXJsonResponse -Status 401 -Value @{ error = 'unauthorized' } -ExtraHeaders @{ 'WWW-Authenticate' = 'Bearer' }
    }
    $allowed = $script:ApiRoutes[$path]
    if (($allowed -split ',') -cnotcontains $Method) {
        return New-ClaudeCXJsonResponse -Status 405 -Value @{ error = 'method_not_allowed' } -ExtraHeaders @{ Allow = $allowed.Replace(',', ', ') }
    }
    if ($Method -ceq 'POST') {
        $origin = if ($Headers.Contains('origin')) { [string]$Headers['origin'] } else { '' }
        if ($origin -and $origin -cne "http://$expectedHost") {
            return New-ClaudeCXJsonResponse -Status 403 -Value @{ error = 'forbidden_origin' }
        }
        $type = if ($Headers.Contains('content-type')) { [string]$Headers['content-type'] } else { '' }
        if ($Body -and -not $type.StartsWith('application/json', [StringComparison]::OrdinalIgnoreCase)) {
            return New-ClaudeCXJsonResponse -Status 415 -Value @{ error = 'unsupported_media_type' }
        }
    }
    $Context.LastApiRequest = [DateTimeOffset]::UtcNow

    if ($path.StartsWith('/api/run/', [StringComparison]::Ordinal)) {
        $turn = Resolve-ClaudeCXRunId -RunId (Get-ClaudeCXQueryValue -Target $Target -Name 'run') -Roots @(Get-ClaudeCXCenterRoots -Context $Context)
        if ($null -eq $turn) {
            $turn = Resolve-ClaudeCXRunId -RunId (Get-ClaudeCXQueryValue -Target $Target -Name 'run') -Roots @(Get-ClaudeCXCenterRoots -Context $Context -Refresh)
        }
        if ($null -eq $turn) {
            return New-ClaudeCXJsonResponse -Status 404 -Value @{ error = 'run_not_found' }
        }
        $metadata = Get-ClaudeCXRunMetadata -Turn $turn
        switch ($path) {
            '/api/run/state' {
                $state = Get-ClaudeCXDashboardState -Metadata $metadata
                $state['run_id'] = $turn.Id
                if (-not $state.bridge_alive -and $state.status -eq 'failed' -and -not [IO.File]::Exists((Get-ClaudeCXDashboardPaths -TurnDirectory $turn.Path).Done)) {
                    $state.final_message = 'The bridge ended without recording a result. The run was probably interrupted.'
                }
                return New-ClaudeCXJsonResponse -Status 200 -Value $state
            }
            '/api/run/changes' {
                $state = Get-ClaudeCXDashboardState -Metadata $metadata
                if ($state.status -eq 'active') {
                    $live = Get-ClaudeCXDashboardChanges -Metadata $metadata
                    $live['snapshot'] = $false
                    return New-ClaudeCXJsonResponse -Status 200 -Value $live
                }
                $saved = Get-ClaudeCXSavedChanges -TurnDirectory $turn.Path
                if ($null -eq $saved) {
                    return New-ClaudeCXJsonResponse -Status 200 -Value ([ordered]@{
                            status_text = ''; status_truncated = $false; diff_text = ''; diff_truncated = $false; max_diff_bytes = 0
                            errors = @('This run ended before ClaudeCX saved each run''s changes, so its diff is not available. The repository may have moved on since.')
                            generated_at = $null; snapshot = $true
                        })
                }
                return New-ClaudeCXJsonResponse -Status 200 -Value $saved
            }
            '/api/run/report' { return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXDashboardReport -Metadata $metadata) }
            '/api/run/prompts' { return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXDashboardPrompts -Metadata $metadata) }
            '/api/run/stop' {
                $state = Get-ClaudeCXDashboardState -Metadata $metadata
                if ($state.status -ne 'active' -or -not $state.bridge_alive) {
                    return New-ClaudeCXJsonResponse -Status 409 -Value ([ordered]@{ accepted = $false; reason = 'run_not_active' })
                }
                $created = Request-ClaudeCXStop -TurnDirectory $turn.Path
                return New-ClaudeCXJsonResponse -Status 202 -Value ([ordered]@{ accepted = $true; already_requested = (-not $created) })
            }
        }
    }

    switch ($path) {
        '/api/center' { return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXCenterOverview -Context $Context) }
        '/api/runs' { return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXRunHistory -Context $Context) }
        '/api/settings' {
            if ($Method -ceq 'GET') { return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXSettingsPayload) }
            $saved = Save-ClaudeCXSettingsFromBody -Body $Body
            return New-ClaudeCXJsonResponse -Status $saved.Status -Value $saved.Value
        }
        '/api/health' { return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXHealth -Context $Context) }
        '/api/logs/prune' {
            $pruned = Invoke-ClaudeCXCenterPrune -Context $Context -Body $Body
            return New-ClaudeCXJsonResponse -Status $pruned.Status -Value $pruned.Value
        }
        '/api/data' { return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXDataPayload -Context $Context) }
        '/api/data/wipe' {
            $wiped = Invoke-ClaudeCXCenterWipe -Context $Context -Body $Body
            return New-ClaudeCXJsonResponse -Status $wiped.Status -Value $wiped.Value
        }
        '/api/center/quit' {
            $Context.QuitRequested = $true
            return New-ClaudeCXJsonResponse -Status 202 -Value ([ordered]@{ accepted = $true })
        }
    }
    return New-ClaudeCXJsonResponse -Status 404 -Value @{ error = 'not_found' }
}

function Invoke-ClaudeCXCenterConnection {
    # Serves exactly one request on an accepted loopback connection.
    param(
        [Parameter(Mandatory = $true)][Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory = $true)][object]$Context
    )

    $Client.ReceiveTimeout = 5000
    $Client.SendTimeout = 10000
    $stream = $Client.GetStream()
    $response = $null
    try {
        $request = Read-ClaudeCXHttpRequest -Stream $stream -MaxBodyBytes $script:MaxBodyBytes
        if ($null -eq $request) { return }
        try {
            $response = Invoke-ClaudeCXCenterRequest -Context $Context -Method $request.Method -Target $request.Target -Headers $request.Headers -Body $request.Body
        }
        catch {
            $response = New-ClaudeCXJsonResponse -Status 500 -Value @{ error = 'internal_error' }
        }
    }
    catch {
        $response = New-ClaudeCXJsonResponse -Status 400 -Value @{ error = 'bad_request' }
    }
    try { Write-ClaudeCXHttpResponse -Stream $stream -Response $response } catch { }
}

function Find-ClaudeCXNewRuns {
    # Active runs the center has not seen yet. The first scan only records what is already running.
    param([Parameter(Mandatory = $true)][object]$Context)

    $new = [Collections.Generic.List[object]]::new()
    foreach ($run in (Get-ClaudeCXActiveRuns -Context $Context)) {
        if ($Context.SeenActive.Add([string]$run.id) -and $Context.Scanned) { $new.Add($run) }
    }
    $Context.Scanned = $true
    return $new.ToArray()
}

Export-ModuleMember -Function @(
    'Get-ClaudeCXCenterTokenVariable',
    'New-ClaudeCXCenterContext',
    'Get-ClaudeCXCenterRoots',
    'Get-ClaudeCXRunMetadata',
    'Get-ClaudeCXRunSummary',
    'Get-ClaudeCXRunHistory',
    'Get-ClaudeCXActiveRuns',
    'Get-ClaudeCXCenterOverview',
    'Get-ClaudeCXSettingsPayload',
    'Get-ClaudeCXHealth',
    'Get-ClaudeCXDataPayload',
    'Get-ClaudeCXQueryValue',
    'Invoke-ClaudeCXCenterRequest',
    'Invoke-ClaudeCXCenterConnection',
    'Find-ClaudeCXNewRuns'
)
