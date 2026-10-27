[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $true)]
    [string]$BriefPath,

    [string]$ResumeSessionId,

    [ValidateSet('auto', 'plan')]
    [string]$PermissionMode = 'auto',

    [ValidateRange(1, 500)]
    [int]$MaxTurns = 60,

    [ValidateRange(0.01, 1000.0)]
    [decimal]$MaxBudgetUsd = 5.00,

    [ValidateRange(30, 86400)]
    [int]$TimeoutSeconds = 3600,

    [string]$StateRoot
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

if ($env:AGENT_HANDOFF_DEPTH -and $env:AGENT_HANDOFF_DEPTH -ne '0') {
    throw 'Nested agent handoffs are disabled. Claude may not invoke the Codex-to-Claude bridge.'
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
$resolvedBrief = (Resolve-Path -LiteralPath $BriefPath).Path
if (-not (Test-Path -LiteralPath $resolvedProject -PathType Container)) {
    throw "ProjectPath is not a directory: $resolvedProject"
}
if (-not (Test-Path -LiteralPath $resolvedBrief -PathType Leaf)) {
    throw "BriefPath is not a file: $resolvedBrief"
}

$repoRoot = Invoke-GitText -Repository $resolvedProject -Arguments @('rev-parse', '--show-toplevel')
$repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
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

try {
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

    $briefText = [IO.File]::ReadAllText($resolvedBrief, [Text.UTF8Encoding]::new($false))
    Write-Utf8File -Path (Join-Path $turnDir 'brief.md') -Content $briefText
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
    $arguments.Add('json')
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

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start Claude Code.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($briefText)
    $process.StandardInput.Close()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { }
        throw "Claude Code exceeded the ${TimeoutSeconds}-second timeout and was terminated."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()

    $stdoutPath = Join-Path $turnDir 'claude-result.json'
    $stderrPath = Join-Path $turnDir 'claude-stderr.txt'
    Write-Utf8File -Path $stdoutPath -Content $stdout
    Write-Utf8File -Path $stderrPath -Content $stderr

    if (-not $stdout.Trim()) {
        throw "Claude Code returned no JSON output (exit code $exitCode). See $stderrPath"
    }
    try {
        $outer = $stdout | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Claude Code output was not valid JSON (exit code $exitCode). See $stdoutPath"
    }

    $isErrorValue = Get-PropertyValue -Object $outer -Name 'is_error'
    $subtype = [string](Get-PropertyValue -Object $outer -Name 'subtype')
    $isError = ($isErrorValue -eq $true)
    if ($exitCode -ne 0 -or $isError -or ($subtype -and $subtype -ne 'success')) {
        throw "Claude Code failed closed (exit code $exitCode, is_error=$isError, subtype='$subtype'). See $stdoutPath and $stderrPath"
    }

    $headAfter = Invoke-GitText -Repository $repoRoot -Arguments @('rev-parse', 'HEAD')
    $initialHead = [string](Get-PropertyValue -Object $sessionMetadata -Name 'initial_head')
    if ($headAfter -ne $initialHead) {
        throw "Claude changed Git HEAD from $initialHead to $headAfter. The bridge will not continue; inspect the repository manually."
    }

    $report = Get-PropertyValue -Object $outer -Name 'structured_output'
    if ($null -eq $report) {
        $resultValue = Get-PropertyValue -Object $outer -Name 'result'
        if ($resultValue -is [string]) {
            try { $report = $resultValue | ConvertFrom-Json -Depth 100 } catch { }
        }
        elseif ($null -ne $resultValue) {
            $report = $resultValue
        }
    }
    if ($null -eq $report) {
        throw "Claude Code succeeded but did not return the required structured report. See $stdoutPath"
    }

    $reportPath = Join-Path $turnDir 'report.json'
    Write-Utf8File -Path $reportPath -Content ($report | ConvertTo-Json -Depth 100)
    $newState = Get-GitStateFingerprint -Repository $repoRoot
    Write-Utf8File -Path (Join-Path $sessionDir 'last-state.sha256') -Content $newState
    Write-Utf8File -Path (Join-Path $turnDir 'status-after.txt') -Content (Invoke-GitText -Repository $repoRoot -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))

    [ordered]@{
        status = 'success'
        session_id = $sessionId
        repository = $repoRoot
        run_directory = $turnDir
        report_path = $reportPath
        raw_result_path = $stdoutPath
        stderr_path = $stderrPath
        exit_code = $exitCode
    } | ConvertTo-Json -Compress
}
catch {
    $message = $_.Exception.Message
    if ($failurePath) {
        $failure = [ordered]@{
            status = 'failed'
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
