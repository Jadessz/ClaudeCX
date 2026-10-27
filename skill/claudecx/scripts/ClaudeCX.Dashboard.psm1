#Requires -Version 7.2
# Local ClaudeCX dashboard: per-run metadata, the stop-request marker, the fixed read-only API,
# a bounded loopback HTTP handler, and progress-display fallback (Dashboard -> Window -> Console).
# The access token is held only in memory and in the server's environment. It is never written
# to disk, logs, metadata, process arguments, or responses.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Progress.psm1')

$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:TokenVariable = 'CLAUDECX_DASHBOARD_TOKEN'
$script:MetadataName = 'dashboard.json'
$script:EndpointName = 'dashboard-endpoint.json'
$script:StopName = 'stop-request.json'
$script:MaxActivityLines = 1000
$script:MaxActivityBytes = 262144
$script:MaxJsonFileBytes = 4194304
$script:ReportListFields = @('files_changed', 'commands_run', 'denied_actions', 'open_questions', 'deviations_from_brief', 'risks')
$script:StaticAssets = [ordered]@{
    '/' = @('index.html', 'text/html; charset=utf-8')
    '/index.html' = @('index.html', 'text/html; charset=utf-8')
    '/styles.css' = @('styles.css', 'text/css; charset=utf-8')
    '/app.js' = @('app.js', 'text/javascript; charset=utf-8')
}
$script:ApiRoutes = @{
    '/api/state' = 'GET'
    '/api/changes' = 'GET'
    '/api/report' = 'GET'
    '/api/stop' = 'POST'
}
$script:SecurityHeaders = [ordered]@{
    'Content-Security-Policy' = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    'X-Content-Type-Options' = 'nosniff'
    'X-Frame-Options' = 'DENY'
    'Referrer-Policy' = 'no-referrer'
    'Cross-Origin-Opener-Policy' = 'same-origin'
    'Cross-Origin-Resource-Policy' = 'same-origin'
    'Permissions-Policy' = 'camera=(), microphone=(), geolocation=(), clipboard-read=()'
    'Cache-Control' = 'no-store'
}

function Get-ClaudeCXDashboardTokenVariable { $script:TokenVariable }

function New-ClaudeCXDashboardToken {
    # 256 bits from the OS CSPRNG, base64url without padding (43 characters).
    $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-ClaudeCXDashboardToken {
    # Constant-time comparison of the presented token with the expected one.
    param(
        [AllowNull()][AllowEmptyString()][string]$Expected,
        [AllowNull()][AllowEmptyString()][string]$Presented
    )

    if (-not $Expected -or -not $Presented) {
        return $false
    }
    $expectedBytes = $script:Utf8.GetBytes($Expected)
    $presentedBytes = $script:Utf8.GetBytes($Presented)
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedBytes, $presentedBytes)
}

function Write-ClaudeCXAtomicFile {
    # Writes through a temporary sibling and renames it into place.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [switch]$NoOverwrite
    )

    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Content, $script:Utf8)
        [IO.File]::Move($temporary, $Path, (-not $NoOverwrite))
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ClaudeCXDashboardPaths {
    # Fixed artifact names inside one turn directory. Nothing is caller-controlled.
    param([Parameter(Mandatory = $true)][string]$TurnDirectory)

    $root = [IO.Path]::GetFullPath($TurnDirectory)
    return [pscustomobject]@{
        TurnDirectory = $root
        Metadata = Join-Path $root $script:MetadataName
        Endpoint = Join-Path $root $script:EndpointName
        Stop = Join-Path $root $script:StopName
        Progress = Join-Path $root 'progress.log'
        Done = Join-Path $root 'progress.done'
        Result = Join-Path $root 'claude-result.json'
        Report = Join-Path $root 'report.json'
        Failure = Join-Path $root 'failure.json'
        StatusBefore = Join-Path $root 'status-before.txt'
        StatusAfter = Join-Path $root 'status-after.txt'
    }
}

function Write-ClaudeCXDashboardMetadata {
    # Non-secret run facts for the dashboard server. Never includes the token.
    param(
        [Parameter(Mandatory = $true)][string]$TurnDirectory,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][bool]$Resumed,
        [Parameter(Mandatory = $true)][int]$BridgeProcessId,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$MaxTurns,
        [Parameter(Mandatory = $true)][decimal]$MaxBudgetUsd
    )

    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory $TurnDirectory
    $bridgeStarted = $null
    try { $bridgeStarted = (Get-Process -Id $BridgeProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { }
    $metadata = [ordered]@{
        repository = $Repository
        repository_name = (Split-Path -Leaf $Repository)
        run_directory = $paths.TurnDirectory
        session_id = $SessionId
        resumed = $Resumed
        bridge_pid = $BridgeProcessId
        bridge_started_at = $bridgeStarted
        started_at = [DateTimeOffset]::Now.ToString('o')
        timeout_seconds = $TimeoutSeconds
        max_turns = $MaxTurns
        max_budget_usd = $MaxBudgetUsd
    }
    Write-ClaudeCXAtomicFile -Path $paths.Metadata -Content ($metadata | ConvertTo-Json)
    return $paths.Metadata
}

function Read-ClaudeCXJsonFile {
    # Bounded, strict-enough JSON read. Returns $null when absent, oversized, or invalid.
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $info = [IO.FileInfo]::new($Path)
        if (-not $info.Exists -or $info.Length -gt $script:MaxJsonFileBytes) {
            return $null
        }
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $reader = [IO.StreamReader]::new($stream, $script:Utf8)
            $text = $reader.ReadToEnd()
        }
        finally {
            $stream.Dispose()
        }
        $parsed = $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ($parsed -is [Management.Automation.PSCustomObject]) {
            return $parsed
        }
    }
    catch { }
    return $null
}

function Read-ClaudeCXDashboardMetadata {
    # Loads metadata and checks that it describes the directory it lives in.
    param([Parameter(Mandatory = $true)][string]$MetadataPath)

    $full = [IO.Path]::GetFullPath($MetadataPath)
    if ([IO.Path]::GetFileName($full) -cne $script:MetadataName) {
        throw "Dashboard metadata must be named $($script:MetadataName)."
    }
    $metadata = Read-ClaudeCXJsonFile -Path $full
    if ($null -eq $metadata) {
        throw 'Dashboard metadata is missing or invalid.'
    }
    $turnDirectory = [IO.Path]::GetDirectoryName($full)
    foreach ($name in @('repository', 'run_directory', 'session_id', 'bridge_pid', 'started_at')) {
        if ($null -eq $metadata.PSObject.Properties[$name]) {
            throw "Dashboard metadata lacks $name."
        }
    }
    if (-not ([IO.Path]::GetFullPath([string]$metadata.run_directory)).Equals($turnDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Dashboard metadata does not describe its own run directory.'
    }
    if (-not (Test-Path -LiteralPath ([string]$metadata.repository) -PathType Container)) {
        throw 'Dashboard repository directory does not exist.'
    }
    return $metadata
}

function Request-ClaudeCXStop {
    # Atomically creates the stop marker. Returns $true when this call created it,
    # $false when it already existed. The marker carries no secret.
    param([Parameter(Mandatory = $true)][string]$TurnDirectory)

    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory $TurnDirectory
    $content = [ordered]@{
        requested_at = [DateTimeOffset]::Now.ToString('o')
        source = 'dashboard'
    } | ConvertTo-Json -Compress
    try {
        Write-ClaudeCXAtomicFile -Path $paths.Stop -Content $content -NoOverwrite
        return $true
    }
    catch [IO.IOException] {
        if (Test-Path -LiteralPath $paths.Stop -PathType Leaf) {
            return $false
        }
        throw
    }
}

function Test-ClaudeCXStopRequested {
    param([Parameter(Mandatory = $true)][string]$TurnDirectory)

    return [IO.File]::Exists((Join-Path $TurnDirectory $script:StopName))
}

function Get-ClaudeCXIsoTime {
    # ConvertFrom-Json turns ISO timestamps into DateTime; normalize back to round-trip text.
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    if ($property.Value -is [DateTime]) { return ([DateTimeOffset]$property.Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($property.Value -is [DateTimeOffset]) { return $property.Value.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$property.Value
}

function Test-ClaudeCXBridgeAlive {
    param([Parameter(Mandatory = $true)][object]$Metadata)

    $bridgePid = 0
    if (-not [int]::TryParse([string]$Metadata.bridge_pid, [ref]$bridgePid) -or $bridgePid -le 0) {
        return $false
    }
    $process = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }
    # Guards against PID reuse after the bridge exits.
    $expected = Get-ClaudeCXIsoTime -Object $Metadata -Name 'bridge_started_at'
    if ($expected) {
        try {
            $actual = $process.StartTime.ToUniversalTime()
            $recorded = [DateTimeOffset]::Parse($expected, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            if ([Math]::Abs(($actual - $recorded).TotalSeconds) -gt 2) {
                return $false
            }
        }
        catch { }
    }
    return $true
}

function Get-ClaudeCXActivityLines {
    # Tail of the sanitized progress log, re-sanitized line by line.
    param([Parameter(Mandatory = $true)][string]$ProgressPath)

    $lines = [Collections.Generic.List[string]]::new()
    if (-not [IO.File]::Exists($ProgressPath)) {
        return , $lines.ToArray()
    }
    try {
        $stream = [IO.FileStream]::new($ProgressPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $skipFirst = $false
            if ($stream.Length -gt $script:MaxActivityBytes) {
                $stream.Seek(-$script:MaxActivityBytes, [IO.SeekOrigin]::End) | Out-Null
                $skipFirst = $true
            }
            $reader = [IO.StreamReader]::new($stream, $script:Utf8)
            $text = $reader.ReadToEnd()
        }
        finally {
            $stream.Dispose()
        }
        $raw = @($text -split "`n")
        if ($skipFirst -and $raw.Count -gt 0) { $raw = @($raw | Select-Object -Skip 1) }
        foreach ($line in $raw) {
            $safe = ConvertTo-ClaudeCXSafeText -Text $line -MaxLength 400
            if ($safe) { $lines.Add($safe) }
        }
    }
    catch { }
    if ($lines.Count -gt $script:MaxActivityLines) {
        return , $lines.GetRange($lines.Count - $script:MaxActivityLines, $script:MaxActivityLines).ToArray()
    }
    return , $lines.ToArray()
}

function Get-ClaudeCXNumber {
    param([AllowNull()][object]$Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property -and $property.Value -is [ValueType] -and $property.Value -isnot [bool]) {
        return [double]$property.Value
    }
    return $null
}

function Get-ClaudeCXDashboardState {
    # Live run state from metadata and fixed artifacts. Only sanitized activity is included.
    param([Parameter(Mandatory = $true)][object]$Metadata)

    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory ([string]$Metadata.run_directory)
    $done = Read-ClaudeCXJsonFile -Path $paths.Done
    $bridgeAlive = Test-ClaudeCXBridgeAlive -Metadata $Metadata
    $stopRequested = [IO.File]::Exists($paths.Stop)
    $status = 'active'
    $finalMessage = $null
    $finishedAt = $null
    if ($null -ne $done) {
        $marker = [string]$done.PSObject.Properties['status']?.Value
        $status = switch ($marker) { 'success' { 'succeeded' } 'stopped' { 'stopped' } default { 'failed' } }
        $finalMessage = ConvertTo-ClaudeCXSafeText -Text ([string]$done.PSObject.Properties['message']?.Value) -MaxLength 500
        $finishedAt = Get-ClaudeCXIsoTime -Object $done -Name 'finished_at'
    }
    elseif (-not $bridgeAlive) {
        $status = 'failed'
        $finalMessage = 'The bridge process ended without signalling completion.'
    }
    $activity = Get-ClaudeCXActivityLines -ProgressPath $paths.Progress
    $result = $null
    $resultEvent = Read-ClaudeCXJsonFile -Path $paths.Result
    if ($null -ne $resultEvent) {
        $result = [ordered]@{
            num_turns = Get-ClaudeCXNumber -Object $resultEvent -Name 'num_turns'
            duration_ms = Get-ClaudeCXNumber -Object $resultEvent -Name 'duration_ms'
            total_cost_usd = Get-ClaudeCXNumber -Object $resultEvent -Name 'total_cost_usd'
        }
    }
    return [ordered]@{
        repository_name = ConvertTo-ClaudeCXSafeText -Text ([string]$Metadata.repository_name) -MaxLength 120
        session_id = [string]$Metadata.session_id
        resumed = ($Metadata.PSObject.Properties['resumed']?.Value -eq $true)
        started_at = Get-ClaudeCXIsoTime -Object $Metadata -Name 'started_at'
        timeout_seconds = Get-ClaudeCXNumber -Object $Metadata -Name 'timeout_seconds'
        max_turns = Get-ClaudeCXNumber -Object $Metadata -Name 'max_turns'
        max_budget_usd = Get-ClaudeCXNumber -Object $Metadata -Name 'max_budget_usd'
        status = $status
        bridge_alive = $bridgeAlive
        stop_requested = $stopRequested
        can_stop = ($status -eq 'active' -and $bridgeAlive -and -not $stopRequested)
        final_message = $finalMessage
        finished_at = $finishedAt
        last_activity = $(if ($activity.Count -gt 0) { $activity[-1] } else { $null })
        activity = $activity
        result = $result
        server_time = [DateTimeOffset]::Now.ToString('o')
    }
}

function Invoke-ClaudeCXDashboardGit {
    # Fixed, read-only Git queries with bounded time and output. No caller-supplied arguments.
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][ValidateSet('status', 'diff')][string]$Kind,
        [ValidateRange(1024, 67108864)][int]$MaxBytes = 2097152,
        [ValidateRange(100, 120000)][int]$TimeoutMilliseconds = 15000
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardErrorEncoding = $script:Utf8
    $fixed = @('-C', $Repository, '--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'core.quotepath=off')
    $query = if ($Kind -eq 'status') {
        @('status', '--short', '--untracked-files=all')
    }
    else {
        @('diff', '--no-ext-diff', '--no-textconv', '--no-color', 'HEAD', '--')
    }
    foreach ($argument in @($fixed + $query)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.Environment['GIT_PAGER'] = 'cat'
    $startInfo.Environment.Remove($script:TokenVariable) | Out-Null

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $buffer = [IO.MemoryStream]::new()
    $truncated = $false
    $timedOut = $false
    try {
        if (-not $process.Start()) {
            throw 'git did not start.'
        }
        $process.StandardInput.Close()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.BaseStream
        $chunk = [byte[]]::new(65536)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $remaining = $TimeoutMilliseconds - $clock.ElapsedMilliseconds
            if ($remaining -le 0) { $timedOut = $true; break }
            $read = $stdout.ReadAsync($chunk, 0, $chunk.Length)
            if (-not $read.Wait([int]$remaining)) { $timedOut = $true; break }
            $count = $read.Result
            if ($count -eq 0) { break }
            $room = $MaxBytes - $buffer.Length
            if ($count -gt $room) {
                $buffer.Write($chunk, 0, [int]$room)
                $truncated = $true
                break
            }
            $buffer.Write($chunk, 0, $count)
        }
        if ($timedOut -or $truncated) {
            try { $process.Kill($true) } catch { }
        }
        $remaining = [Math]::Max(1, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)
        if (-not $process.WaitForExit([int]$remaining)) {
            try { $process.Kill($true) } catch { }
            $timedOut = $true
        }
        $errorText = $null
        if (-not $timedOut -and -not $truncated -and $process.ExitCode -ne 0) {
            $stderr = if ($stderrTask.Wait(1000)) { $stderrTask.Result } else { '' }
            $errorText = ConvertTo-ClaudeCXSafeText -Text "git $Kind failed (exit $($process.ExitCode)): $stderr" -MaxLength 300
        }
        if ($timedOut) {
            $errorText = "git $Kind did not finish within $TimeoutMilliseconds ms."
        }
        return [pscustomobject]@{
            Text = $script:Utf8.GetString($buffer.ToArray())
            Truncated = $truncated
            Error = $errorText
        }
    }
    finally {
        $buffer.Dispose()
        $process.Dispose()
    }
}

function Get-ClaudeCXDashboardChanges {
    # Current status and diff against HEAD, rendered as text by the browser.
    param(
        [Parameter(Mandatory = $true)][object]$Metadata,
        [ValidateRange(1024, 67108864)][int]$MaxDiffBytes = 2097152
    )

    $repository = [string]$Metadata.repository
    $errors = [Collections.Generic.List[string]]::new()
    $status = $null
    $diff = $null
    try { $status = Invoke-ClaudeCXDashboardGit -Repository $repository -Kind 'status' -MaxBytes 262144 } catch { $errors.Add("git status could not run: $(ConvertTo-ClaudeCXSafeText -Text $_.Exception.Message -MaxLength 200)") }
    try { $diff = Invoke-ClaudeCXDashboardGit -Repository $repository -Kind 'diff' -MaxBytes $MaxDiffBytes } catch { $errors.Add("git diff could not run: $(ConvertTo-ClaudeCXSafeText -Text $_.Exception.Message -MaxLength 200)") }
    foreach ($item in @($status, $diff)) {
        if ($null -ne $item -and $item.Error) { $errors.Add($item.Error) }
    }
    return [ordered]@{
        status_text = $(if ($null -ne $status) { $status.Text } else { '' })
        status_truncated = ($null -ne $status -and $status.Truncated)
        diff_text = $(if ($null -ne $diff) { $diff.Text } else { '' })
        diff_truncated = ($null -ne $diff -and $diff.Truncated)
        max_diff_bytes = $MaxDiffBytes
        errors = $errors.ToArray()
        generated_at = [DateTimeOffset]::Now.ToString('o')
    }
}

function ConvertTo-ClaudeCXStringList {
    param([AllowNull()][object]$Value)

    $items = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($Value | Where-Object { $null -ne $_ })) {
        if ($entry -is [string] -or $entry -is [ValueType]) { $items.Add([string]$entry) }
    }
    return , $items.ToArray()
}

function Get-ClaudeCXDashboardReport {
    # Final structured report, failure details, or a pending marker. Fixed fields only.
    param([Parameter(Mandatory = $true)][object]$Metadata)

    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory ([string]$Metadata.run_directory)
    $report = Read-ClaudeCXJsonFile -Path $paths.Report
    if ($null -ne $report) {
        $normalized = [ordered]@{ summary = [string]$report.PSObject.Properties['summary']?.Value }
        foreach ($field in $script:ReportListFields) {
            $normalized[$field] = ConvertTo-ClaudeCXStringList -Value $report.PSObject.Properties[$field]?.Value
        }
        $checks = [Collections.Generic.List[object]]::new()
        foreach ($check in @($report.PSObject.Properties['checks']?.Value | Where-Object { $_ -is [Management.Automation.PSCustomObject] })) {
            $checks.Add([ordered]@{
                    command = [string]$check.PSObject.Properties['command']?.Value
                    status = [string]$check.PSObject.Properties['status']?.Value
                    output_summary = [string]$check.PSObject.Properties['output_summary']?.Value
                })
        }
        $normalized['checks'] = $checks.ToArray()
        return [ordered]@{ kind = 'report'; report = $normalized }
    }
    $failure = Read-ClaudeCXJsonFile -Path $paths.Failure
    if ($null -ne $failure) {
        return [ordered]@{
            kind = 'failure'
            failure = [ordered]@{
                status = [string]$failure.PSObject.Properties['status']?.Value
                message = ConvertTo-ClaudeCXSafeText -Text ([string]$failure.PSObject.Properties['message']?.Value) -MaxLength 2000
                occurred_at = Get-ClaudeCXIsoTime -Object $failure -Name 'occurred_at'
            }
        }
    }
    return [ordered]@{ kind = 'pending' }
}

function New-ClaudeCXDashboardContext {
    # Server-side request context. The token lives only in this in-memory object.
    param(
        [Parameter(Mandatory = $true)][object]$Metadata,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AssetRoot,
        [Parameter(Mandatory = $true)][int]$Port,
        [ValidateRange(1024, 67108864)][int]$MaxDiffBytes = 2097152
    )

    return [pscustomobject]@{
        Metadata = $Metadata
        Token = $Token
        AssetRoot = [IO.Path]::GetFullPath($AssetRoot)
        Port = $Port
        MaxDiffBytes = $MaxDiffBytes
        LastApiRequest = [DateTimeOffset]::UtcNow
    }
}

function New-ClaudeCXDashboardResponse {
    param(
        [Parameter(Mandatory = $true)][int]$Status,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Body,
        [Collections.IDictionary]$ExtraHeaders
    )

    $headers = [ordered]@{}
    foreach ($entry in $script:SecurityHeaders.GetEnumerator()) { $headers[$entry.Key] = $entry.Value }
    $headers['Content-Type'] = $ContentType
    if ($ExtraHeaders) {
        foreach ($entry in $ExtraHeaders.GetEnumerator()) { $headers[$entry.Key] = $entry.Value }
    }
    return [pscustomobject]@{ Status = $Status; Headers = $headers; Body = $Body }
}

function New-ClaudeCXJsonResponse {
    param(
        [Parameter(Mandatory = $true)][int]$Status,
        [Parameter(Mandatory = $true)][object]$Value,
        [Collections.IDictionary]$ExtraHeaders
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 10 -Compress -EscapeHandling EscapeHtml
    return New-ClaudeCXDashboardResponse -Status $Status -ContentType 'application/json; charset=utf-8' -Body $script:Utf8.GetBytes($json) -ExtraHeaders $ExtraHeaders
}

function Invoke-ClaudeCXDashboardRequest {
    # Routes one parsed request. Fixed routes and methods only; no path is ever derived from input.
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers
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
        $bytes = [IO.File]::ReadAllBytes((Join-Path $Context.AssetRoot $asset[0]))
        return New-ClaudeCXDashboardResponse -Status 200 -ContentType $asset[1] -Body $bytes
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
    if ($Method -cne $allowed) {
        return New-ClaudeCXJsonResponse -Status 405 -Value @{ error = 'method_not_allowed' } -ExtraHeaders @{ Allow = $allowed }
    }
    $Context.LastApiRequest = [DateTimeOffset]::UtcNow
    switch ($path) {
        '/api/state' {
            return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXDashboardState -Metadata $Context.Metadata)
        }
        '/api/changes' {
            return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXDashboardChanges -Metadata $Context.Metadata -MaxDiffBytes $Context.MaxDiffBytes)
        }
        '/api/report' {
            return New-ClaudeCXJsonResponse -Status 200 -Value (Get-ClaudeCXDashboardReport -Metadata $Context.Metadata)
        }
        '/api/stop' {
            $origin = if ($Headers.Contains('origin')) { [string]$Headers['origin'] } else { '' }
            if ($origin -and $origin -cne "http://$expectedHost") {
                return New-ClaudeCXJsonResponse -Status 403 -Value @{ error = 'forbidden_origin' }
            }
            $state = Get-ClaudeCXDashboardState -Metadata $Context.Metadata
            if ($state.status -ne 'active' -or -not $state.bridge_alive) {
                return New-ClaudeCXJsonResponse -Status 409 -Value ([ordered]@{ accepted = $false; reason = 'run_not_active' })
            }
            $created = Request-ClaudeCXStop -TurnDirectory ([string]$Context.Metadata.run_directory)
            return New-ClaudeCXJsonResponse -Status 202 -Value ([ordered]@{ accepted = $true; already_requested = (-not $created) })
        }
    }
    return New-ClaudeCXJsonResponse -Status 404 -Value @{ error = 'not_found' }
}

function Read-ClaudeCXHttpRequest {
    # Bounded HTTP/1.1 request reader: 16 KiB of headers, 4 KiB of body, then the connection closes.
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

    $limit = 16384
    $buffer = [IO.MemoryStream]::new()
    $one = [byte[]]::new(1024)
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $count = $Stream.Read($one, 0, $one.Length)
        if ($count -le 0) { return $null }
        $buffer.Write($one, 0, $count)
        $text = [Text.Encoding]::Latin1.GetString($buffer.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
        if ($headerEnd -lt 0 -and $buffer.Length -gt $limit) { throw 'request headers too large' }
    }
    $lines = $text.Substring(0, $headerEnd) -split "`r`n"
    $parts = $lines[0] -split ' '
    if ($parts.Count -ne 3 -or $parts[2] -notmatch '^HTTP/1\.[01]$' -or $parts[0] -notmatch '^[A-Z]{1,10}$' -or -not $parts[1].StartsWith('/')) {
        throw 'malformed request line'
    }
    $headers = [ordered]@{}
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        $colon = $line.IndexOf(':')
        if ($colon -le 0) { throw 'malformed header' }
        $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim()
    }
    $length = 0
    if ($headers.Contains('content-length') -and -not [int]::TryParse([string]$headers['content-length'], [ref]$length)) {
        throw 'invalid content length'
    }
    if ($length -gt 4096 -or $length -lt 0) { throw 'request body too large' }
    $received = $buffer.Length - ($headerEnd + 4)
    while ($received -lt $length) {
        $count = $Stream.Read($one, 0, $one.Length)
        if ($count -le 0) { break }
        $received += $count
    }
    return [pscustomobject]@{ Method = $parts[0]; Target = $parts[1]; Headers = $headers }
}

function Write-ClaudeCXHttpResponse {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][object]$Response
    )

    $reasons = @{ 200 = 'OK'; 202 = 'Accepted'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict'; 421 = 'Misdirected Request'; 500 = 'Internal Server Error' }
    $reason = if ($reasons.ContainsKey($Response.Status)) { $reasons[$Response.Status] } else { 'Status' }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append("HTTP/1.1 $($Response.Status) $reason`r`n")
    foreach ($entry in $Response.Headers.GetEnumerator()) {
        [void]$builder.Append("$($entry.Key): $($entry.Value)`r`n")
    }
    [void]$builder.Append("Content-Length: $($Response.Body.Length)`r`nConnection: close`r`n`r`n")
    $head = [Text.Encoding]::ASCII.GetBytes($builder.ToString())
    $Stream.Write($head, 0, $head.Length)
    if ($Response.Body.Length -gt 0) {
        $Stream.Write($Response.Body, 0, $Response.Body.Length)
    }
    $Stream.Flush()
}

function Invoke-ClaudeCXDashboardConnection {
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
        $request = Read-ClaudeCXHttpRequest -Stream $stream
        if ($null -eq $request) { return }
        try {
            $response = Invoke-ClaudeCXDashboardRequest -Context $Context -Method $request.Method -Target $request.Target -Headers $request.Headers
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

function Get-ClaudeCXPwshPath {
    $shellPath = [Environment]::ProcessPath
    if ($shellPath -and [IO.Path]::GetFileNameWithoutExtension($shellPath) -eq 'pwsh') {
        return $shellPath
    }
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        throw 'pwsh was not found for the dashboard server.'
    }
    return $command.Source
}

function Start-ClaudeCXDashboardServer {
    # Starts show-dashboard.ps1 hidden and without inherited handles. The token reaches the
    # child only through its inherited environment and is cleared from this process at once.
    param(
        [Parameter(Mandatory = $true)][string]$MetadataPath,
        [Parameter(Mandatory = $true)][string]$ServerScriptPath,
        [Parameter(Mandatory = $true)][string]$Token,
        [ValidateRange(60, 172800)][int]$MaxLifetimeSeconds = 7200,
        [ValidateRange(1, 120)][int]$ReadyTimeoutSeconds = 20,
        [hashtable]$ServerOptions
    )

    if (-not (Test-Path -LiteralPath $ServerScriptPath -PathType Leaf)) {
        throw "Dashboard server script is missing: $ServerScriptPath"
    }
    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory (Split-Path -Parent ([IO.Path]::GetFullPath($MetadataPath)))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-ClaudeCXPwshPath
    # Shell execution creates the server without inheriting the bridge's stdout/stderr handles.
    $startInfo.UseShellExecute = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoProfile', '-NoLogo', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', $ServerScriptPath,
            '-MetadataPath', $paths.Metadata,
            '-MaxLifetimeSeconds', $MaxLifetimeSeconds.ToString([Globalization.CultureInfo]::InvariantCulture))) {
        $arguments.Add($argument)
    }
    if ($ServerOptions) {
        foreach ($entry in $ServerOptions.GetEnumerator()) {
            if ($entry.Key -notin @('CompletionLingerSeconds', 'CompletionIdleSeconds', 'OrphanGraceSeconds', 'MaxDiffBytes')) {
                throw "Unsupported dashboard server option: $($entry.Key)"
            }
            $arguments.Add("-$($entry.Key)")
            $arguments.Add(([int]$entry.Value).ToString([Globalization.CultureInfo]::InvariantCulture))
        }
    }
    foreach ($argument in $arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $server = $null
    [Environment]::SetEnvironmentVariable($script:TokenVariable, $Token)
    try {
        $server = [Diagnostics.Process]::Start($startInfo)
    }
    finally {
        [Environment]::SetEnvironmentVariable($script:TokenVariable, [NullString]::Value)
    }
    if ($null -eq $server) {
        throw 'The dashboard server process did not start.'
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $endpoint = Read-ClaudeCXJsonFile -Path $paths.Endpoint
        if ($null -ne $endpoint) {
            $port = 0
            if ([int]::TryParse([string]$endpoint.PSObject.Properties['port']?.Value, [ref]$port) -and $port -ge 1024 -and $port -le 65535 -and
                [int]$endpoint.PSObject.Properties['pid']?.Value -eq $server.Id) {
                return [pscustomobject]@{ Process = $server; Port = $port; Url = "http://127.0.0.1:$port/" }
            }
        }
        if ($server.HasExited) {
            throw "The dashboard server exited during startup (exit code $($server.ExitCode))."
        }
        Start-Sleep -Milliseconds 100
    }
    try { $server.Kill($true) } catch { }
    throw 'The dashboard server did not report readiness in time.'
}

function Open-ClaudeCXBrowser {
    # Opens the default browser. The token travels only in the URL fragment.
    param([Parameter(Mandatory = $true)][string]$Url)

    if (-not $Url.StartsWith('http://127.0.0.1:', [StringComparison]::Ordinal)) {
        throw 'Refusing to open a non-loopback dashboard URL.'
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Url
    $startInfo.UseShellExecute = $true
    $null = [Diagnostics.Process]::Start($startInfo)
}

function Start-ClaudeCXDashboard {
    # Generates the per-run token, starts the server, and opens the browser at #token=...
    # Returns the server handle only; the token is not returned or persisted.
    param(
        [Parameter(Mandatory = $true)][string]$MetadataPath,
        [Parameter(Mandatory = $true)][string]$ServerScriptPath,
        [ValidateRange(60, 172800)][int]$MaxLifetimeSeconds = 7200,
        [scriptblock]$BrowserLauncher = { param($Url) Open-ClaudeCXBrowser -Url $Url },
        [hashtable]$ServerOptions
    )

    $token = New-ClaudeCXDashboardToken
    $server = Start-ClaudeCXDashboardServer -MetadataPath $MetadataPath -ServerScriptPath $ServerScriptPath -Token $token -MaxLifetimeSeconds $MaxLifetimeSeconds -ServerOptions $ServerOptions
    try {
        & $BrowserLauncher "$($server.Url)#token=$token"
    }
    catch {
        try { $server.Process.Kill($true) } catch { }
        throw "The browser could not be opened: $($_.Exception.Message)"
    }
    return [pscustomobject]@{ Process = $server.Process; Port = $server.Port }
}

function Start-ClaudeCXProgressDisplay {
    # Dashboard -> Window -> Console. Fallback changes observability only. Returns the mode in use.
    param(
        [Parameter(Mandatory = $true)][object]$Sink,
        [Parameter(Mandatory = $true)][ValidateSet('Dashboard', 'Window', 'Console', 'None')][string]$Mode,
        [scriptblock]$StartDashboard,
        [scriptblock]$StartWindow,
        [IO.TextWriter]$ErrorWriter
    )

    $writer = if ($ErrorWriter) { $ErrorWriter } else { [Console]::Error }
    $current = $Mode
    if ($current -eq 'Dashboard') {
        try {
            if (-not $StartDashboard) { throw 'no dashboard launcher' }
            $null = & $StartDashboard
            $Sink.Mode = 'Dashboard'
            return 'Dashboard'
        }
        catch {
            $writer.WriteLine("ClaudeCX: dashboard unavailable ($(ConvertTo-ClaudeCXSafeText -Text $_.Exception.Message -MaxLength 200)); falling back to the progress window.")
            $current = 'Window'
        }
    }
    if ($current -eq 'Window') {
        try {
            if (-not $StartWindow) { throw 'no window launcher' }
            $null = & $StartWindow
            $Sink.Mode = 'Window'
            return 'Window'
        }
        catch {
            $writer.WriteLine("ClaudeCX: progress window unavailable ($(ConvertTo-ClaudeCXSafeText -Text $_.Exception.Message -MaxLength 200)); showing progress on stderr.")
            $current = 'Console'
        }
    }
    $Sink.Mode = $current
    return $current
}

Export-ModuleMember -Function @(
    'Get-ClaudeCXDashboardTokenVariable',
    'New-ClaudeCXDashboardToken',
    'Test-ClaudeCXDashboardToken',
    'Get-ClaudeCXDashboardPaths',
    'Write-ClaudeCXDashboardMetadata',
    'Read-ClaudeCXDashboardMetadata',
    'Request-ClaudeCXStop',
    'Test-ClaudeCXStopRequested',
    'Test-ClaudeCXBridgeAlive',
    'Get-ClaudeCXDashboardState',
    'Invoke-ClaudeCXDashboardGit',
    'Get-ClaudeCXDashboardChanges',
    'Get-ClaudeCXDashboardReport',
    'New-ClaudeCXDashboardContext',
    'Invoke-ClaudeCXDashboardRequest',
    'Invoke-ClaudeCXDashboardConnection',
    'Write-ClaudeCXAtomicFile',
    'Start-ClaudeCXDashboardServer',
    'Open-ClaudeCXBrowser',
    'Start-ClaudeCXDashboard',
    'Start-ClaudeCXProgressDisplay'
)
