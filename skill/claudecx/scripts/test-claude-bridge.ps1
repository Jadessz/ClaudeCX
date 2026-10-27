[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScratchRoot,

    [decimal]$MaxBudgetUsd = 1.00,

    [ValidateSet('Window', 'Console', 'None')]
    [string]$ProgressMode = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8File {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Invoke-Git {
    param([string]$Repository, [string[]]$Arguments)
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output | Out-String)"
    }
    return (($output | Out-String).TrimEnd())
}

function Invoke-Bridge {
    param(
        [string]$Repository,
        [string]$Brief,
        [string]$ResumeId,
        [int]$MaxTurns = 30
    )

    $arguments = @(
        '-NoProfile', '-File', $bridgePath,
        '-ProjectPath', $Repository,
        '-BriefPath', $Brief,
        '-MaxTurns', $MaxTurns,
        '-MaxBudgetUsd', $MaxBudgetUsd,
        '-TimeoutSeconds', 600,
        '-ProgressMode', $ProgressMode
    )
    if ($ResumeId) {
        $arguments += @('-ResumeSessionId', $ResumeId)
    }
    # Keep stdout (the single JSON result) separate from stderr progress and errors.
    $errorPath = Join-Path $scratch "bridge-stderr-$([Guid]::NewGuid().ToString('N')).txt"
    $output = & pwsh @arguments 2>$errorPath
    $exitCode = $LASTEXITCODE
    $errorText = if (Test-Path -LiteralPath $errorPath) { [IO.File]::ReadAllText($errorPath).Trim() } else { '' }
    $stdoutText = ($output | Out-String).Trim()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdoutText
        Text = (@($stdoutText, $errorText) | Where-Object { $_ }) -join "`n"
    }
}

function Invoke-CommitDenialProbe {
    param([string]$Repository)

    $skillRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $settingsPath = Join-Path $skillRoot 'assets\bridge-settings.json'
    $mcpPath = Join-Path $skillRoot 'assets\empty-mcp.json'
    $sessionId = [Guid]::NewGuid().ToString('D')
    $oldMemory = $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY
    $oldBackground = $env:CLAUDE_CODE_DISABLE_BACKGROUND_TASKS
    Push-Location -LiteralPath $Repository
    try {
        $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = '1'
        $env:CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = '1'
        $output = & claude -p 'This is a permission-policy smoke test in a disposable repository. Request the Bash tool once with exactly: git commit --allow-empty -m bridge-smoke-must-be-denied. Do not use another command and do not work around a denial.' `
            --safe-mode `
            --permission-mode auto `
            --output-format json `
            --max-turns 3 `
            --max-budget-usd $MaxBudgetUsd `
            --settings $settingsPath `
            --strict-mcp-config `
            --mcp-config $mcpPath `
            --session-id $sessionId 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:CLAUDE_CODE_DISABLE_AUTO_MEMORY = $oldMemory
        $env:CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = $oldBackground
        Pop-Location
    }
    $text = ($output | Out-String).Trim()
    Write-Utf8File -Path (Join-Path $scratch 'commit-denial-probe.json') -Content $text
    try { $result = $text | ConvertFrom-Json -Depth 100 } catch { throw "Commit denial probe did not return JSON: $text" }
    if (@($result.permission_denials).Count -lt 1) {
        throw "Commit denial probe did not record a permission denial (exit $exitCode): $text"
    }
    return $result
}

$bridgePath = Join-Path $PSScriptRoot 'invoke-claude.ps1'
$scratch = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratch) {
    throw "ScratchRoot already exists; choose a fresh path: $scratch"
}
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$briefDir = Join-Path $scratch 'briefs'
$repo = Join-Path $scratch 'write-resume-repo'
$failureRepo = Join-Path $scratch 'forced-failure-repo'
[IO.Directory]::CreateDirectory($repo) | Out-Null
[IO.Directory]::CreateDirectory($failureRepo) | Out-Null

$authText = & claude auth status 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "Claude Code is not authenticated: $authText"
}

foreach ($repository in @($repo, $failureRepo)) {
    & git -C $repository init --quiet
    & git -C $repository config user.name 'Codex Claude Bridge Smoke Test'
    & git -C $repository config user.email 'bridge-smoke@example.invalid'
    Write-Utf8File -Path (Join-Path $repository 'README.md') -Content "# Bridge smoke test`n"
}

$hookSettings = [ordered]@{
    hooks = [ordered]@{
        SessionStart = @(
            [ordered]@{
                matcher = 'startup|resume'
                hooks = @(
                    [ordered]@{
                        type = 'command'
                        shell = 'powershell'
                        command = 'Set-Content -LiteralPath "$env:CLAUDE_PROJECT_DIR\hook-fired.txt" -Value "fired"'
                    }
                )
            }
        )
    }
} | ConvertTo-Json -Depth 20
Write-Utf8File -Path (Join-Path $repo '.claude\settings.json') -Content $hookSettings

foreach ($repository in @($repo, $failureRepo)) {
    Invoke-Git -Repository $repository -Arguments @('add', '.') | Out-Null
    Invoke-Git -Repository $repository -Arguments @('commit', '--quiet', '-m', 'smoke baseline') | Out-Null
}

$headBefore = Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD')
$georgianFirst = 'გამარჯობა, თბილისი — ხიდი მუშაობს.'
$georgianSecond = 'გაგრძელება წარმატებულია.'
$briefOne = Join-Path $briefDir 'initial.md'
Write-Utf8File -Path $briefOne -Content @"
# Objective

Create `georgian.txt` in the repository root containing exactly this one UTF-8 line:

$georgianFirst

Do not change any other file. Do not run any Git commit command.
"@

$first = Invoke-Bridge -Repository $repo -Brief $briefOne
if ($first.ExitCode -ne 0) {
    throw "Initial write smoke test failed closed: $($first.Text)"
}
if (@($first.Stdout -split "`r?`n" | Where-Object { $_ }).Count -ne 1) { throw "Bridge stdout was not a single JSON line: $($first.Stdout)" }
$firstResult = $first.Stdout | ConvertFrom-Json
$sessionId = [string]$firstResult.session_id
if (-not $sessionId) { throw 'Initial bridge result did not include a session UUID.' }
foreach ($logPath in @([string]$firstResult.events_path, [string]$firstResult.progress_log_path, [string]$firstResult.raw_result_path)) {
    if (-not $logPath -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw "Bridge did not write an expected log file: $logPath" }
}
if (-not (Test-Path -LiteralPath (Join-Path ([string]$firstResult.run_directory) 'progress.done') -PathType Leaf)) { throw 'Bridge did not write the progress completion marker.' }

$georgianPath = Join-Path $repo 'georgian.txt'
if (-not (Test-Path -LiteralPath $georgianPath -PathType Leaf)) { throw 'Claude did not create georgian.txt.' }
$actualFirst = [IO.File]::ReadAllText($georgianPath, [Text.UTF8Encoding]::new($false)).TrimEnd("`r", "`n")
if ($actualFirst -ne $georgianFirst) { throw 'Georgian UTF-8 content did not survive the stdin and file round trip.' }
if ((Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD')) -ne $headBefore) { throw 'Claude unexpectedly created a commit.' }
if (Test-Path -LiteralPath (Join-Path $repo 'hook-fired.txt')) { throw 'A repository SessionStart hook ran despite bridge isolation.' }
if (-not ([string]$firstResult.run_directory).StartsWith((Join-Path $env:LOCALAPPDATA 'CodexClaude\handoffs'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Bridge state was not written under LOCALAPPDATA.'
}

$report = Get-Content -Raw -LiteralPath ([string]$firstResult.report_path) | ConvertFrom-Json
$null = Invoke-CommitDenialProbe -Repository $repo
if ((Invoke-Git -Repository $repo -Arguments @('rev-parse', 'HEAD')) -ne $headBefore) { throw 'The commit denial probe unexpectedly created a commit.' }

$briefTwo = Join-Path $briefDir 'resume.md'
Write-Utf8File -Path $briefTwo -Content @"
Append exactly this UTF-8 line to `georgian.txt`, after the existing line, and change nothing else:

$georgianSecond
"@
$second = Invoke-Bridge -Repository $repo -Brief $briefTwo -ResumeId $sessionId
if ($second.ExitCode -ne 0) { throw "Resume smoke test failed: $($second.Text)" }
$actualCombined = [IO.File]::ReadAllText($georgianPath, [Text.UTF8Encoding]::new($false)).TrimEnd("`r", "`n")
if ($actualCombined -notmatch ('^' + [Regex]::Escape($georgianFirst) + "`r?`n" + [Regex]::Escape($georgianSecond) + '$')) {
    throw 'Resumed session did not preserve and append the expected Georgian text.'
}
if (Test-Path -LiteralPath (Join-Path $repo 'hook-fired.txt')) { throw 'A repository hook ran during resume.' }

$failureBrief = Join-Path $briefDir 'forced-failure.md'
Write-Utf8File -Path $failureBrief -Content @'
First read `README.md` using a file-reading tool. Only after receiving that tool result, create `should-not-exist.txt` containing `unexpected`. This task intentionally requires another agentic turn.
'@
$forced = Invoke-Bridge -Repository $failureRepo -Brief $failureBrief -MaxTurns 1
if ($forced.ExitCode -eq 0) { throw 'The forced max-turns failure unexpectedly reported success.' }

[ordered]@{
    status = 'passed'
    claude_api_reachable = $true
    localappdata_state_write = $true
    repository_write = $true
    git_commit_denied = $true
    georgian_utf8_round_trip = $true
    resume_same_session = $true
    project_hook_suppressed = $true
    forced_max_turns_reported_failure = $true
    session_id = $sessionId
    scratch_root = $scratch
    stream_json_logs = $true
    first_run_directory = [string]$firstResult.run_directory
} | ConvertTo-Json
