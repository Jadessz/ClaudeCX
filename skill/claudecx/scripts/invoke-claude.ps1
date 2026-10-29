[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $true)]
    [string]$BriefPath,

    # Optional: the user's original request to Codex, shown in the dashboard's prompt journey.
    [string]$OriginalPromptPath,

    [string]$ResumeSessionId,

    [ValidateSet('auto', 'plan')]
    [string]$PermissionMode = 'auto',

    # The three limits below come from the user's ClaudeCX settings. A value passed here can only
    # lower them for this run; a higher value is capped at the user's setting.
    [ValidateRange(1, 500)]
    [int]$MaxTurns = 60,

    [ValidateRange(0.01, 1000.0)]
    [decimal]$MaxBudgetUsd = 5.00,

    [ValidateRange(30, 86400)]
    [int]$TimeoutSeconds = 3600,

    [string]$StateRoot,

    # Dashboard: local browser dashboard (Windows; falls back to Window, then Console).
    # Window: read-only progress window (Windows). Console: progress on stderr. None: logs only.
    # When omitted, the user's progress_display setting decides.
    [ValidateSet('Dashboard', 'Window', 'Console', 'None')]
    [string]$ProgressMode = 'Dashboard'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & git -C $Repository @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).TrimEnd()
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code ${exitCode}: $text"
    }
    return $text
}

function Get-GitStateFingerprint {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add((Invoke-GitText -Repository $Repository -Arguments @('status', '--porcelain=v1', '--untracked-files=all')))
    $parts.Add((Invoke-GitText -Repository $Repository -Arguments @('diff', '--binary', 'HEAD', '--')))
    $parts.Add((Invoke-GitText -Repository $Repository -Arguments @('diff', '--cached', '--binary', 'HEAD', '--')))

    $untrackedText = Invoke-GitText -Repository $Repository -Arguments @('ls-files', '--others', '--exclude-standard')
    $untracked = @($untrackedText -split "`r?`n" | Where-Object { $_ })
    foreach ($relativePath in ($untracked | Sort-Object)) {
        $fullPath = Join-Path $Repository $relativePath
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $fileHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $parts.Add("untracked:$relativePath`n$fileHash")
        }
        else {
            $parts.Add("untracked-nonfile:$relativePath")
        }
    }

    return Get-Sha256Text -Text ($parts -join "`n--bridge-part--`n")
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

# Prompt artifacts are bounded and must be strict UTF-8. They are copied byte-for-byte (minus a
# leading BOM) into fixed files in the turn directory; source paths and contents never reach
# metadata, logs, or process arguments.
$script:MaxPromptBytes = 1048576

function Read-PromptInput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Repository
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is not a file."
    }
    $full = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
    $info = [IO.FileInfo]::new($full)
    $candidates = @($full)
    $target = $info.ResolveLinkTarget($true)
    if ($null -ne $target) {
        $candidates += [IO.Path]::GetFullPath($target.FullName)
        $info = [IO.FileInfo]::new($target.FullName)
    }
    $repositoryPrefix = $Repository.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($candidate in $candidates) {
        if ($candidate.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label must be outside the repository so Claude cannot modify its own instructions."
        }
    }
    if ($info.Length -gt $script:MaxPromptBytes) {
        throw "$Label exceeds the $($script:MaxPromptBytes)-byte limit."
    }
    $bytes = [IO.File]::ReadAllBytes($info.FullName)
    if ($bytes.Length -gt $script:MaxPromptBytes) {
        throw "$Label exceeds the $($script:MaxPromptBytes)-byte limit."
    }
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
    }
    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        throw "$Label is not valid UTF-8."
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Progress.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Dashboard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Settings.psm1') -Force

if ($env:AGENT_HANDOFF_DEPTH -and $env:AGENT_HANDOFF_DEPTH -ne '0') {
    throw 'Nested agent handoffs are disabled. Claude may not invoke the Codex-to-Claude bridge.'
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $resolvedProject -PathType Container)) {
    throw "ProjectPath is not a directory: $resolvedProject"
}

$repoRoot = Invoke-GitText -Repository $resolvedProject -Arguments @('rev-parse', '--show-toplevel')
$repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
# A brand-new repository has no HEAD to compare Claude's changes against; say so plainly.
$null = & git -C $repoRoot rev-parse --verify --quiet 'HEAD^{commit}' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "The Git repository has no commits yet, so there is nothing to compare Claude's changes against. Make a first commit (for example: git add -A, then git commit -m 'Initial commit'), then run again."
}
# Validated and read before any state is created, so bad inputs fail closed before Claude starts.
$briefText = Read-PromptInput -Path $BriefPath -Label 'BriefPath' -Repository $repoRoot
$originalPromptText = $null
if ($PSBoundParameters.ContainsKey('OriginalPromptPath')) {
    $originalPromptText = Read-PromptInput -Path $OriginalPromptPath -Label 'OriginalPromptPath' -Repository $repoRoot
}

# The user's settings set the limits; the committed .claudecx.json and the values Codex passes can
# only lower them. Problems in either file stop the run before Claude starts.
$userSettings = Read-ClaudeCXUserSettings
if ($userSettings.Errors.Count -gt 0) {
    throw "Your ClaudeCX settings file has problems: $($userSettings.Errors -join ' ') Fix them in the control center, with scripts\claudecx-settings.ps1, or by deleting $($userSettings.Path)."
}
$projectSettings = Read-ClaudeCXProjectSettings -Repository $repoRoot
if ($projectSettings.Errors.Count -gt 0) {
    throw "This repository's $(Get-ClaudeCXProjectFileName) has problems: $($projectSettings.Errors -join ' ')"
}
$requestedLimits = @{}
foreach ($name in @('MaxTurns', 'MaxBudgetUsd', 'TimeoutSeconds')) {
    if ($PSBoundParameters.ContainsKey($name)) { $requestedLimits[$name] = $PSBoundParameters[$name] }
}
$runSettings = Resolve-ClaudeCXRunSettings -User $userSettings.Values -Project $projectSettings.Values -Requested $requestedLimits
$MaxTurns = $runSettings.MaxTurns
$MaxBudgetUsd = $runSettings.MaxBudgetUsd
$TimeoutSeconds = $runSettings.TimeoutSeconds
if (-not $PSBoundParameters.ContainsKey('ProgressMode')) {
    $ProgressMode = $runSettings.ProgressMode
}
$headBefore = Invoke-GitText -Repository $repoRoot -Arguments @('rev-parse', 'HEAD')

if (-not $StateRoot) {
    if (-not $env:LOCALAPPDATA) {
        throw 'LOCALAPPDATA is unavailable; refusing to store handoff state in an unknown location.'
    }
    $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexClaude\handoffs'
}
$stateRootFull = [IO.Path]::GetFullPath($StateRoot)
$repoKey = (Get-Sha256Text -Text $repoRoot.ToLowerInvariant()).Substring(0, 24)
$repoState = Join-Path $stateRootFull $repoKey
[IO.Directory]::CreateDirectory($repoState) | Out-Null

$lockPath = Join-Path $repoState 'active.lock'
$lockToken = [Guid]::NewGuid().ToString('D')
if (Test-Path -LiteralPath $lockPath) {
    $existingLock = $null
    try {
        $existingLock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
    }
    catch {
        throw "A bridge lock already exists and cannot be validated: $lockPath"
    }
    $existingPid = Get-PropertyValue -Object $existingLock -Name 'pid'
    if ($existingPid -and (Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue)) {
        throw "Another Claude bridge run is active for this repository (PID $existingPid)."
    }
    Remove-Item -LiteralPath $lockPath -Force
}

$lock = [ordered]@{
    token = $lockToken
    pid = $PID
    repository = $repoRoot
    created_at = [DateTimeOffset]::Now.ToString('o')
} | ConvertTo-Json
Write-Utf8File -Path $lockPath -Content $lock

$turnDir = $null
$sessionDir = $null
$sessionId = $null
$failurePath = $null
$progress = $null
$stream = $null
$process = $null
$stderrTask = $null
$stderrPath = $null
$stopRequested = $false

try {
    if ($runSettings.KeepLogsDays -gt 0) {
        # Best effort: only finished turns older than the user's keep_logs_days are removed.
        try {
            $null = Remove-ClaudeCXOldRuns -Roots @([pscustomobject]@{ Id = 'local'; Path = $stateRootFull }) -Days $runSettings.KeepLogsDays
        }
        catch { }
    }
    $statusBefore = Invoke-GitText -Repository $repoRoot -Arguments @('status', '--porcelain=v1', '--untracked-files=all')

    if ($ResumeSessionId) {
        $parsedResumeId = [Guid]::Empty
        if (-not [Guid]::TryParse($ResumeSessionId, [ref]$parsedResumeId)) {
            throw "ResumeSessionId must be a UUID: $ResumeSessionId"
        }
        $sessionId = $parsedResumeId.ToString('D')
        $sessionDir = Join-Path $repoState $sessionId
        $sessionMetadataPath = Join-Path $sessionDir 'session.json'
        $lastStatePath = Join-Path $sessionDir 'last-state.sha256'
        if (-not (Test-Path -LiteralPath $sessionMetadataPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $lastStatePath -PathType Leaf)) {
            throw "No bridge session state exists for $sessionId in this repository."
        }
        $sessionMetadata = Get-Content -Raw -LiteralPath $sessionMetadataPath | ConvertFrom-Json
        $recordedRepository = [string](Get-PropertyValue -Object $sessionMetadata -Name 'repository')
        if (-not $recordedRepository.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Resume directory does not match the repository recorded for this session.'
        }
        $recordedHead = [string](Get-PropertyValue -Object $sessionMetadata -Name 'initial_head')
        if ($headBefore -ne $recordedHead) {
            throw 'HEAD changed since this Claude session started. Refusing to resume.'
        }
        $expectedState = (Get-Content -Raw -LiteralPath $lastStatePath).Trim()
        $actualState = Get-GitStateFingerprint -Repository $repoRoot
        if ($actualState -ne $expectedState) {
            throw 'The working tree changed outside the prior successful Claude turn. Refusing to resume.'
        }
    }
    else {
        if ($statusBefore) {
            throw 'A new Claude bridge session requires a clean Git working tree, including untracked files.'
        }
        $sessionId = [Guid]::NewGuid().ToString('D')
        $sessionDir = Join-Path $repoState $sessionId
        [IO.Directory]::CreateDirectory($sessionDir) | Out-Null
        $sessionMetadata = [pscustomobject][ordered]@{
            session_id = $sessionId
            repository = $repoRoot
            initial_head = $headBefore
            created_at = [DateTimeOffset]::Now.ToString('o')
        }
        Write-Utf8File -Path (Join-Path $sessionDir 'session.json') -Content ($sessionMetadata | ConvertTo-Json)
        Write-Utf8File -Path (Join-Path $sessionDir 'last-state.sha256') -Content (Get-GitStateFingerprint -Repository $repoRoot)
    }

    $turnName = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
    $turnDir = Join-Path $sessionDir $turnName
    [IO.Directory]::CreateDirectory($turnDir) | Out-Null
    $failurePath = Join-Path $turnDir 'failure.json'
    # Fixed prompt artifacts for this turn. The copied brief is the exact Claude input.
    $codexBriefPath = Join-Path $turnDir 'codex-brief.md'
    Write-ClaudeCXAtomicFile -Path $codexBriefPath -Content $briefText
    if ($null -ne $originalPromptText) {
        Write-ClaudeCXAtomicFile -Path (Join-Path $turnDir 'original-prompt.md') -Content $originalPromptText
    }
    $briefText = [IO.File]::ReadAllText($codexBriefPath, [Text.UTF8Encoding]::new($false, $true))

    $progressMode = $ProgressMode
    if ($progressMode -in @('Dashboard', 'Window') -and -not $IsWindows) {
        $progressMode = 'Console'
    }
    $progress = New-ClaudeCXProgressSink -Mode $progressMode -ProgressPath (Join-Path $turnDir 'progress.log') -DonePath (Join-Path $turnDir 'progress.done')
    $repoName = Split-Path -Leaf $repoRoot
    $runKind = if ($ResumeSessionId) { 'resumed session' } else { 'new session' }
    Write-ClaudeCXProgress -Sink $progress -Message "Preparing Claude run for $repoName ($runKind)"
    Write-ClaudeCXProgress -Sink $progress -Message "Limits: $MaxBudgetUsd USD, $MaxTurns turns, $([Math]::Round($TimeoutSeconds / 60)) minutes; model $($runSettings.Model)"
    foreach ($note in $runSettings.Notes) {
        Write-ClaudeCXProgress -Sink $progress -Message "Settings: $note"
    }
    $stopPollMs = 250
    # Run facts for the dashboard and the control center's history. Never includes a token.
    $metadataPath = Write-ClaudeCXDashboardMetadata -TurnDirectory $turnDir -Repository $repoRoot -SessionId $sessionId `
        -Resumed ([bool]$ResumeSessionId) -BridgeProcessId $PID -TimeoutSeconds $TimeoutSeconds -MaxTurns $MaxTurns -MaxBudgetUsd $MaxBudgetUsd `
        -Model $runSettings.Model -ProtectedPaths $runSettings.ProtectedPaths -SettingsNotes $runSettings.Notes
    # Observability fallback only (Dashboard -> Window -> Console): Claude's flags, permissions, and limits are unchanged.
    $progressMode = Start-ClaudeCXProgressDisplay -Sink $progress -Mode $progressMode -StartDashboard {
        if ($null -ne (Get-ClaudeCXControlCenter)) {
            # The always-on control center finds this run on its own; no per-run server is needed.
            Write-ClaudeCXProgress -Sink $progress -Message 'Dashboard: showing this run in the ClaudeCX control center'
            return
        }
        Start-ClaudeCXDashboard -MetadataPath $metadataPath -ServerScriptPath (Join-Path $PSScriptRoot 'show-dashboard.ps1') `
            -MaxLifetimeSeconds ([Math]::Min(172800, $TimeoutSeconds + 1800))
    } -StartWindow {
        Start-ClaudeCXProgressWindow -Sink $progress `
            -MonitorScriptPath (Join-Path $PSScriptRoot 'watch-progress.ps1') `
            -Title "ClaudeCX - $repoName" -RepositoryName $repoName -SessionId $sessionId -BridgeProcessId $PID
    }

    Write-Utf8File -Path (Join-Path $turnDir 'status-before.txt') -Content $statusBefore

    $skillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $settingsPath = Join-Path $skillRoot 'assets\bridge-settings.json'
    $rolePromptPath = Join-Path $skillRoot 'assets\claude-role-prompt.md'
    $schemaPath = Join-Path $skillRoot 'assets\report-schema.json'
    $mcpPath = Join-Path $skillRoot 'assets\empty-mcp.json'
    foreach ($requiredPath in @($settingsPath, $rolePromptPath, $schemaPath, $mcpPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Bridge asset is missing: $requiredPath"
        }
    }

    $claudeCommand = Get-Command claude.exe -ErrorAction SilentlyContinue
    if (-not $claudeCommand) {
        $claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
    }
    if (-not $claudeCommand) {
        throw 'Claude Code was not found on PATH.'
    }
    $claudePath = $claudeCommand.Source
    $schemaText = [IO.File]::ReadAllText($schemaPath, [Text.UTF8Encoding]::new($false))

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('-p')
    $arguments.Add('Implement the complete task brief supplied through standard input. Follow the appended implementation-worker role exactly.')
    $arguments.Add('--safe-mode')
    $arguments.Add('--permission-mode')
    $arguments.Add($PermissionMode)
    $arguments.Add('--output-format')
    $arguments.Add('stream-json')
    $arguments.Add('--verbose')
    $arguments.Add('--json-schema')
    $arguments.Add($schemaText)
    $arguments.Add('--max-turns')
    $arguments.Add($MaxTurns.ToString([Globalization.CultureInfo]::InvariantCulture))
    $arguments.Add('--max-budget-usd')
    $arguments.Add($MaxBudgetUsd.ToString([Globalization.CultureInfo]::InvariantCulture))
    $arguments.Add('--settings')
    $arguments.Add($settingsPath)
    $arguments.Add('--append-system-prompt-file')
    $arguments.Add($rolePromptPath)
    $arguments.Add('--strict-mcp-config')
    $arguments.Add('--mcp-config')
    $arguments.Add($mcpPath)
    if ($runSettings.Model -ne 'default') {
        $arguments.Add('--model')
        $arguments.Add($runSettings.Model)
    }
    if ($ResumeSessionId) {
        $arguments.Add('--resume')
        $arguments.Add($sessionId)
    }
    else {
        $arguments.Add('--session-id')
        $arguments.Add($sessionId)
    }

    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $claudePath
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in $arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['AGENT_HANDOFF_DEPTH'] = '1'
    $startInfo.Environment['CLAUDE_CODE_DISABLE_AUTO_MEMORY'] = '1'
    $startInfo.Environment['CLAUDE_CODE_DISABLE_BACKGROUND_TASKS'] = '1'
    $startInfo.Environment['CLAUDE_CODE_DISABLE_AGENT_VIEW'] = '1'
    $startInfo.Environment.Remove((Get-ClaudeCXDashboardTokenVariable)) | Out-Null

    $eventsPath = Join-Path $turnDir 'claude-events.jsonl'
    $stdoutPath = Join-Path $turnDir 'claude-result.json'
    $stderrPath = Join-Path $turnDir 'claude-stderr.txt'
    $stream = New-ClaudeCXStreamState -EventsPath $eventsPath -RepositoryRoot $repoRoot

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start Claude Code.'
    }
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    $timeoutMs = [int64]$TimeoutSeconds * 1000
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $lineTask = $process.StandardOutput.ReadLineAsync()
    $process.StandardInput.Write($briefText)
    $process.StandardInput.Close()
    Write-ClaudeCXProgress -Sink $progress -Message 'Claude Code started; waiting for activity'

    # Consume stream-json incrementally: one event per non-empty stdout line. The wait wakes
    # every $stopPollMs to look for a dashboard stop request; the overall timeout is unchanged.
    $timedOut = $false
    while ($true) {
        $remainingMs = $timeoutMs - $elapsed.ElapsedMilliseconds
        if ($remainingMs -le 0) {
            $timedOut = $true
            break
        }
        if (Test-ClaudeCXStopRequested -TurnDirectory $turnDir) {
            $stopRequested = $true
            break
        }
        if (-not $lineTask.Wait([int][Math]::Min($remainingMs, $stopPollMs))) {
            continue
        }
        $line = $lineTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
            break
        }
        $messages = @(Add-ClaudeCXStreamLine -State $stream -Line $line)
        foreach ($message in $messages) {
            Write-ClaudeCXProgress -Sink $progress -Message $message
        }
        $lineTask = $process.StandardOutput.ReadLineAsync()
    }
    while (-not $timedOut -and -not $stopRequested) {
        $remainingMs = [Math]::Max(0, $timeoutMs - $elapsed.ElapsedMilliseconds)
        if ($process.WaitForExit([int][Math]::Min($remainingMs, $stopPollMs))) {
            break
        }
        if ($elapsed.ElapsedMilliseconds -ge $timeoutMs) {
            $timedOut = $true
            break
        }
        $stopRequested = Test-ClaudeCXStopRequested -TurnDirectory $turnDir
    }
    if ($stopRequested) {
        # Only the Claude process tree started by this bridge is terminated. Edits are not reverted.
        try { $process.Kill($true) } catch { }
        throw 'Stopped by a user request from the ClaudeCX dashboard. Claude Code was terminated; partial edits remain in the working tree for Codex review.'
    }
    if ($timedOut) {
        try { $process.Kill($true) } catch { }
        throw "Claude Code exceeded the ${TimeoutSeconds}-second timeout and was terminated. See $eventsPath"
    }
    $process.WaitForExit()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    $process = $null
    Close-ClaudeCXStreamState -State $stream
    Write-Utf8File -Path $stderrPath -Content $stderr

    $outer = $stream.ResultEvent
    if ($null -ne $outer) {
        Write-Utf8File -Path $stdoutPath -Content $stream.ResultLine
    }
    Assert-ClaudeCXResultSuccess -Outer $outer -ExitCode $exitCode -EventsPath $eventsPath -StderrPath $stderrPath

    $headAfter = Invoke-GitText -Repository $repoRoot -Arguments @('rev-parse', 'HEAD')
    $initialHead = [string](Get-PropertyValue -Object $sessionMetadata -Name 'initial_head')
    if ($headAfter -ne $initialHead) {
        throw "Claude changed Git HEAD from $initialHead to $headAfter. The bridge will not continue; inspect the repository manually."
    }

    $report = Get-ClaudeCXStructuredReport -Outer $outer
    if ($null -eq $report) {
        throw "Claude Code succeeded but did not return the required structured report. See $stdoutPath and $eventsPath"
    }

    $reportPath = Join-Path $turnDir 'report.json'
    Write-Utf8File -Path $reportPath -Content ($report | ConvertTo-Json -Depth 100)
    $newState = Get-GitStateFingerprint -Repository $repoRoot
    Write-Utf8File -Path (Join-Path $sessionDir 'last-state.sha256') -Content $newState
    Write-Utf8File -Path (Join-Path $turnDir 'status-after.txt') -Content (Invoke-GitText -Repository $repoRoot -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))

    # Protected paths fail the run. The state above is already recorded, so Codex can resume the
    # session and ask Claude to undo the change.
    $protectedHits = @(Find-ClaudeCXProtectedChanges -ChangedPaths @(Get-ClaudeCXChangedPaths -Repository $repoRoot) -Patterns $runSettings.ProtectedPaths)
    if ($protectedHits.Count -gt 0) {
        $shown = @($protectedHits | Select-Object -First 10) -join ', '
        throw "Claude changed protected paths: $shown. The edits remain in the working tree for review; resume this session to have Claude undo them, or revert them yourself."
    }
    Save-ClaudeCXRunChanges -Repository $repoRoot -TurnDirectory $turnDir
    Complete-ClaudeCXProgress -Sink $progress -Status 'success' -Message 'Structured report saved.'

    [ordered]@{
        status = 'success'
        session_id = $sessionId
        repository = $repoRoot
        run_directory = $turnDir
        report_path = $reportPath
        raw_result_path = $stdoutPath
        events_path = $eventsPath
        progress_log_path = $progress.ProgressPath
        stderr_path = $stderrPath
        exit_code = $exitCode
    } | ConvertTo-Json -Compress
}
catch {
    $message = $_.Exception.Message
    if ($null -ne $process) {
        # Covers malformed stream lines and unexpected exceptions while Claude is running.
        try {
            if (-not $process.HasExited) { $process.Kill($true) }
        }
        catch { }
        try {
            if ($null -ne $stderrTask -and $stderrTask.Wait(5000)) {
                Write-Utf8File -Path $stderrPath -Content $stderrTask.GetAwaiter().GetResult()
            }
        }
        catch { }
    }
    $failureStatus = if ($stopRequested) { 'stopped' } else { 'failed' }
    if ($null -ne $turnDir) {
        Save-ClaudeCXRunChanges -Repository $repoRoot -TurnDirectory $turnDir
    }
    if ($null -ne $progress) {
        Complete-ClaudeCXProgress -Sink $progress -Status $failureStatus -Message $message
    }
    if ($failurePath) {
        $failure = [ordered]@{
            status = $failureStatus
            session_id = $sessionId
            repository = $repoRoot
            run_directory = $turnDir
            message = $message
            occurred_at = [DateTimeOffset]::Now.ToString('o')
        } | ConvertTo-Json
        Write-Utf8File -Path $failurePath -Content $failure
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
finally {
    if ($null -ne $stream) {
        Close-ClaudeCXStreamState -State $stream
    }
    if ($null -ne $progress) {
        # No-op after a normal completion; otherwise tells the monitor to stop tailing.
        Complete-ClaudeCXProgress -Sink $progress -Status 'failed' -Message 'The bridge stopped before reporting a result.'
    }
    if (Test-Path -LiteralPath $lockPath) {
        try {
            $currentLock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
            if ((Get-PropertyValue -Object $currentLock -Name 'token') -eq $lockToken) {
                Remove-Item -LiteralPath $lockPath -Force
            }
        }
        catch { }
    }
}
