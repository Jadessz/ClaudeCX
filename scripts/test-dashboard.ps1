#Requires -Version 7.2
<#
.SYNOPSIS
Deterministic offline tests for the ClaudeCX dashboard and the bridge stop request.

.DESCRIPTION
Uses throwaway Git repositories and turn directories in a temporary sandbox. Starts the
dashboard server on 127.0.0.1 only, never opens a real browser (the browser launcher is
replaced by a recorder), and never contacts Claude: the bridge stop test runs against a
fake claude.cmd with a PATH that is verified to contain no other Claude executable.
Does not touch the real Codex or Claude configuration.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Force

$repoRoot = Get-ClaudeCXRepositoryRoot
$skillRoot = Get-ClaudeCXPackagedSkillRoot
$scriptsRoot = Join-Path $skillRoot 'scripts'
$dashboardRoot = Join-Path $skillRoot 'dashboard'
$serverScript = Join-Path $scriptsRoot 'show-dashboard.ps1'
$bridgeScript = Join-Path $scriptsRoot 'invoke-claude.ps1'
Import-Module (Join-Path $scriptsRoot 'ClaudeCX.Progress.psm1') -Force
Import-Module (Join-Path $scriptsRoot 'ClaudeCX.Dashboard.psm1') -Force

$utf8 = [Text.UTF8Encoding]::new($false)
$pwshPath = [Environment]::ProcessPath
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "claudecx-dashboard-test-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($sandbox) | Out-Null
$script:failures = [Collections.Generic.List[string]]::new()
$script:passed = 0
$script:cleanup = [Collections.Generic.List[Diagnostics.Process]]::new()

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

function Get-ThrownMessage {
    param([scriptblock]$Action)
    try { & $Action; return $null } catch { return $_.Exception.Message }
}

function Invoke-Git {
    param([string]$Repository, [string[]]$Arguments)
    $output = & git -C $Repository -c user.name=ClaudeCX-Test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.autocrlf=false @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $output" }
}

function New-TestRepository {
    param([string]$Name)
    $path = Join-Path $sandbox $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    Invoke-Git -Repository $path -Arguments @('init', '-q')
    [IO.File]::WriteAllText((Join-Path $path 'app.txt'), "line one`n", $utf8)
    Invoke-Git -Repository $path -Arguments @('add', '--', 'app.txt')
    Invoke-Git -Repository $path -Arguments @('commit', '-q', '-m', 'initial')
    return $path
}

function Invoke-Raw {
    # Sends an exact request line over loopback TCP so paths are not normalized by a client library.
    param(
        [int]$Port,
        [string]$Method = 'GET',
        [string]$Target = '/',
        [hashtable]$Headers = @{},
        [string]$HostHeader
    )
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect([Net.IPAddress]::Loopback, $Port)
        $client.ReceiveTimeout = 30000
        $stream = $client.GetStream()
        $hostValue = if ($PSBoundParameters.ContainsKey('HostHeader')) { $HostHeader } else { "127.0.0.1:$Port" }
        $builder = [Text.StringBuilder]::new()
        [void]$builder.Append("$Method $Target HTTP/1.1`r`nHost: $hostValue`r`n")
        foreach ($entry in $Headers.GetEnumerator()) { [void]$builder.Append("$($entry.Key): $($entry.Value)`r`n") }
        [void]$builder.Append("Content-Length: 0`r`nConnection: close`r`n`r`n")
        $bytes = [Text.Encoding]::ASCII.GetBytes($builder.ToString())
        $stream.Write($bytes, 0, $bytes.Length)
        $buffer = [IO.MemoryStream]::new()
        $stream.CopyTo($buffer)
        $raw = $buffer.ToArray()
    }
    finally {
        $client.Dispose()
    }
    $text = [Text.Encoding]::Latin1.GetString($raw)
    $split = $text.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
    $headLines = $text.Substring(0, $split) -split "`r`n"
    $responseHeaders = @{}
    foreach ($line in ($headLines | Select-Object -Skip 1)) {
        $colon = $line.IndexOf(':')
        $responseHeaders[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim()
    }
    $body = $utf8.GetString($raw, $split + 4, $raw.Length - $split - 4)
    return [pscustomobject]@{
        Status = [int](($headLines[0] -split ' ')[1])
        Headers = $responseHeaders
        Body = $body
    }
}

function Read-Shared {
    # Reads a file that another writer may still hold open.
    param([string]$Path)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { return [IO.StreamReader]::new($stream, $utf8).ReadToEnd() } finally { $stream.Dispose() }
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSeconds = 20)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return [bool](& $Condition)
}

function Start-Sleeper {
    # A harmless local process used as a stand-in bridge or an unrelated bystander.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300')) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    $script:cleanup.Add($process)
    return $process
}

function New-TurnDirectory {
    param([string]$Name, [string]$Repository, [int]$BridgeProcessId)
    $turn = Join-Path $sandbox "state\$Name"
    [IO.Directory]::CreateDirectory($turn) | Out-Null
    $metadataPath = Write-ClaudeCXDashboardMetadata -TurnDirectory $turn -Repository $Repository -SessionId ([Guid]::NewGuid().ToString('D')) `
        -Resumed $false -BridgeProcessId $BridgeProcessId -TimeoutSeconds 600 -MaxTurns 40 -MaxBudgetUsd 2.5
    return [pscustomobject]@{ Directory = $turn; Metadata = $metadataPath }
}

$canaries = @('BRIEF-CANARY-91d2', 'EVENT-CANARY-55ab', 'STDERR-CANARY-0c7e', 'CMD-ARG-CANARY-3f1b', 'SEARCH-CANARY-a8e4',
    'canary-host.example.invalid', 'THINKING-CANARY-6d0f', 'TOOL-OUTPUT-CANARY-2b9c', 'PROMPT-CANARY-77aa')

try {
    # --- Packaged assets and installer list ---
    Write-Host '[assets]'
    $required = @(Get-ClaudeCXRequiredSkillFiles)
    foreach ($file in @('dashboard/index.html', 'dashboard/styles.css', 'dashboard/app.js', 'scripts/ClaudeCX.Dashboard.psm1', 'scripts/show-dashboard.ps1')) {
        Assert-True ($required -contains $file) "required skill files include $file"
        Assert-True (Test-Path -LiteralPath (Join-Path $skillRoot $file) -PathType Leaf) "packaged skill contains $file"
    }
    $html = [IO.File]::ReadAllText((Join-Path $dashboardRoot 'index.html'), $utf8)
    $css = [IO.File]::ReadAllText((Join-Path $dashboardRoot 'styles.css'), $utf8)
    $js = [IO.File]::ReadAllText((Join-Path $dashboardRoot 'app.js'), $utf8)

    # --- Static UI source checks ---
    Write-Host '[ui source]'
    Assert-True ($html.StartsWith('<!doctype html>')) 'index.html has a doctype'
    Assert-True ($html -match '<script src="/app\.js" defer></script>') 'index.html loads the packaged script only'
    Assert-True (@([Regex]::Matches($html, '<script\b')).Count -eq 1) 'index.html has no inline scripts'
    Assert-True ($html -match '<link rel="stylesheet" href="/styles\.css">') 'index.html loads the packaged stylesheet'
    Assert-True ($html -notmatch '(?i)<style\b|\sstyle\s*=') 'index.html has no inline styles'
    Assert-True ($html -notmatch '(?i)\son[a-z]+\s*=') 'index.html has no inline event handlers'
    foreach ($source in @(@('index.html', $html), @('styles.css', $css), @('app.js', $js))) {
        Assert-True ($source[1] -notmatch '(?i)(https?:)?//[a-z0-9.-]+\.[a-z]{2,}|wss?://') "$($source[0]) references no external origin"
    }
    Assert-True ($css -notmatch '(?i)@import|url\(') 'styles.css loads no other resources'
    Assert-True ($css.Contains('prefers-reduced-motion')) 'styles.css honours prefers-reduced-motion'
    foreach ($pattern in @('innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'setTimeout("', "setTimeout('", 'localStorage', 'sessionStorage', 'window.open', 'location.href =')) {
        Assert-True (-not $js.Contains($pattern)) "app.js does not use $pattern"
    }
    Assert-True ($js.Contains('textContent')) 'app.js renders with textContent'
    Assert-True ($js.Contains('history.replaceState') -and $js.Contains("'Authorization': 'Bearer ' + token")) 'app.js removes the fragment and sends the token in a header'
    Assert-True (@([Regex]::Matches($js, '\bfetch\(')).Count -eq 1 -and $js.Contains('fetch(path,')) 'app.js has a single fetch call site'
    $apiCalls = @([Regex]::Matches($js, '(?<!function )\bapi\(([^,)]+)') | ForEach-Object { $_.Groups[1].Value.Trim() } | Sort-Object -Unique)
    Assert-True (@($apiCalls | Where-Object { $_ -notmatch '^API_(STATE|CHANGES|REPORT|STOP)$' }).Count -eq 0) "app.js calls only fixed API constants ($($apiCalls -join ', '))"
    foreach ($id in @([Regex]::Matches($js, "el\('([a-z-]+)'\)") | ForEach-Object { $_.Groups[1].Value })) {
        Assert-True ($html.Contains("id=`"$id`"")) "index.html defines #$id used by app.js"
    }
    foreach ($source in @(@('styles.css', $css, '{', '}'), @('app.js', $js, '{', '}'), @('app.js', $js, '(', ')'), @('app.js', $js, '[', ']'))) {
        $open = $source[1].Split($source[2]).Count - 1
        $close = $source[1].Split($source[3]).Count - 1
        Assert-True ($open -eq $close) "$($source[0]) has balanced '$($source[2])$($source[3])' ($open/$close)"
    }
    Assert-True ($js.Contains("'use strict'")) 'app.js runs in strict mode'
    Assert-True ($html.Contains('role="tablist"') -and $html.Contains('aria-selected') -and $html.Contains('aria-live')) 'index.html exposes accessible tabs and live regions'
    Assert-True ($html.Contains('Partial edits remain in the working tree for Codex review')) 'stop confirmation explains that partial edits remain'
    Assert-True ($js.Contains('Stop requested…')) 'app.js shows Stop requested after confirming'

    # --- Token generation and comparison ---
    Write-Host '[token]'
    $tokenA = New-ClaudeCXDashboardToken
    $tokenB = New-ClaudeCXDashboardToken
    Assert-True ($tokenA -cmatch '^[A-Za-z0-9_-]{43}$') 'token is 43 base64url characters (256 bits)'
    Assert-True ($tokenA -cne $tokenB) 'tokens differ per run'
    Assert-True (Test-ClaudeCXDashboardToken -Expected $tokenA -Presented $tokenA) 'matching token accepted'
    Assert-True (-not (Test-ClaudeCXDashboardToken -Expected $tokenA -Presented $tokenB)) 'different token rejected'
    Assert-True (-not (Test-ClaudeCXDashboardToken -Expected $tokenA -Presented '')) 'empty token rejected'
    Assert-True (-not (Test-ClaudeCXDashboardToken -Expected $tokenA -Presented ($tokenA + 'x'))) 'extended token rejected'

    # --- Throwaway repository and turn directory with canaries ---
    Write-Host '[fixture]'
    $repo = New-TestRepository 'repo-main'
    $turn = New-TurnDirectory -Name 'turn-main' -Repository $repo -BridgeProcessId $PID
    [IO.File]::WriteAllText((Join-Path $turn.Directory 'brief.md'), "Secret brief BRIEF-CANARY-91d2 PROMPT-CANARY-77aa`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $turn.Directory 'claude-stderr.txt'), "STDERR-CANARY-0c7e`n", $utf8)
    $sink = New-ClaudeCXProgressSink -Mode 'None' -ProgressPath (Join-Path $turn.Directory 'progress.log') -DonePath (Join-Path $turn.Directory 'progress.done')
    $stream = New-ClaudeCXStreamState -EventsPath (Join-Path $turn.Directory 'claude-events.jsonl') -RepositoryRoot $repo
    $events = @(
        '{"type":"system","subtype":"init","model":"claude-test","cwd":"EVENT-CANARY-55ab"}',
        ('{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"THINKING-CANARY-6d0f"},{"type":"tool_use","name":"Bash","input":{"command":"npm test CMD-ARG-CANARY-3f1b"}}]}}'),
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"SEARCH-CANARY-a8e4","path":"src"}}]}}',
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://canary-host.example.invalid/x","prompt":"PROMPT-CANARY-77aa"}}]}}',
        '{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"TOOL-OUTPUT-CANARY-2b9c"}]}}',
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"app.txt","old_string":"EVENT-CANARY-55ab","new_string":"x"}}]}}'
    )
    foreach ($line in $events) {
        foreach ($message in @(Add-ClaudeCXStreamLine -State $stream -Line $line)) { Write-ClaudeCXProgress -Sink $sink -Message $message }
    }
    Close-ClaudeCXStreamState -State $stream
    [IO.File]::WriteAllText((Join-Path $repo 'app.txt'), "line one`nline two <script>alert(1)</script>`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $repo 'new-file.txt'), "untracked`n", $utf8)
    $metadataText = [IO.File]::ReadAllText($turn.Metadata, $utf8)
    Assert-True ($null -ne ($metadataText | ConvertFrom-Json)) 'dashboard metadata is JSON'
    $metadataKeys = @(($metadataText | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object)
    Assert-True (($metadataKeys -join ',') -ceq 'bridge_pid,bridge_started_at,max_budget_usd,max_turns,repository,repository_name,resumed,run_directory,session_id,started_at,timeout_seconds') "metadata holds only non-secret fields ($($metadataKeys -join ','))"

    # --- Server startup on loopback ---
    Write-Host '[server]'
    $token = New-ClaudeCXDashboardToken
    $server = Start-ClaudeCXDashboardServer -MetadataPath $turn.Metadata -ServerScriptPath $serverScript -Token $token -MaxLifetimeSeconds 600 `
        -ServerOptions @{ CompletionLingerSeconds = 4; CompletionIdleSeconds = 2 }
    $script:cleanup.Add($server.Process)
    $port = $server.Port
    Assert-True ($port -ge 1024) "server reports a high port ($port)"
    Assert-True ($server.Url -ceq "http://127.0.0.1:$port/") 'server URL is IPv4 loopback'
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable((Get-ClaudeCXDashboardTokenVariable))) 'token removed from the launching process environment'
    $paths = Get-ClaudeCXDashboardPaths -TurnDirectory $turn.Directory
    $endpointText = [IO.File]::ReadAllText($paths.Endpoint, $utf8)
    Assert-True (-not $endpointText.Contains($token)) 'readiness file does not contain the token'
    $endpointKeys = @(($endpointText | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object)
    Assert-True (($endpointKeys -join ',') -ceq 'pid,port,started_at') 'readiness file holds only port, pid, and start time'
    $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        Assert-True (@($listeners | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count -eq 0) "server listens on 127.0.0.1 only ($(@($listeners.LocalAddress) -join ','))"
    }
    else {
        Write-Host '  skip listener address check (Get-NetTCPConnection unavailable)'
    }
    $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($server.Process.Id)" -ErrorAction SilentlyContinue).CommandLine
    Assert-True ($null -ne $commandLine -and -not $commandLine.Contains($token)) 'token is not in the server command line'
    foreach ($file in @(Get-ChildItem -LiteralPath $turn.Directory -File)) {
        Assert-True (-not (Read-Shared $file.FullName).Contains($token)) "token not written to $($file.Name)"
    }

    # --- Static assets and headers ---
    Write-Host '[static assets]'
    $response = Invoke-Raw -Port $port -Target '/'
    Assert-True ($response.Status -eq 200 -and $response.Headers['content-type'] -like 'text/html*') 'GET / serves index.html'
    $csp = [string]$response.Headers['content-security-policy']
    foreach ($directive in @("default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self'", "frame-ancestors 'none'", "base-uri 'none'", "form-action 'none'")) {
        Assert-True ($csp.Contains($directive)) "CSP contains $directive"
    }
    Assert-True ($csp -notmatch "unsafe-inline|unsafe-eval|https?:|\*") 'CSP allows no inline code, eval, or external origins'
    foreach ($header in @(@('x-content-type-options', 'nosniff'), @('referrer-policy', 'no-referrer'), @('x-frame-options', 'DENY'), @('cache-control', 'no-store'))) {
        Assert-True ($response.Headers[$header[0]] -ceq $header[1]) "$($header[0]) is $($header[1])"
    }
    Assert-True ((Invoke-Raw -Port $port -Target '/styles.css').Headers['content-type'] -like 'text/css*') 'styles.css served as CSS'
    Assert-True ((Invoke-Raw -Port $port -Target '/app.js').Headers['content-type'] -like 'text/javascript*') 'app.js served as JavaScript'

    # --- Rejections ---
    Write-Host '[rejections]'
    $auth = @{ Authorization = "Bearer $token" }
    Assert-True ((Invoke-Raw -Port $port -Target '/api/state').Status -eq 401) 'API without a token is 401'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/state' -Headers @{ Authorization = "Bearer $tokenA" }).Status -eq 401) 'API with a wrong token is 401'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/state' -Headers @{ Authorization = $token }).Status -eq 401) 'API with a non-Bearer token is 401'
    Assert-True ((Invoke-Raw -Port $port -Target "/api/state?token=$token").Status -eq 401) 'token in the query string is not accepted'
    Assert-True ((Invoke-Raw -Port $port -Method 'POST' -Target '/api/stop').Status -eq 401) 'stop without a token is 401'
    Assert-True ((Invoke-Raw -Port $port -Method 'POST' -Target '/api/state' -Headers $auth).Status -eq 405) 'POST to a GET route is 405'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/stop' -Headers $auth).Status -eq 405) 'GET to the stop route is 405'
    Assert-True ((Invoke-Raw -Port $port -Method 'DELETE' -Target '/' -Headers $auth).Status -eq 405) 'DELETE on a static route is 405'
    Assert-True ((Invoke-Raw -Port $port -Method 'OPTIONS' -Target '/api/state').Status -eq 401) 'CORS preflight is not honoured'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/unknown' -Headers $auth).Status -eq 404) 'unknown API route is 404'
    Assert-True ((Invoke-Raw -Port $port -Target '/nope').Status -eq 404) 'unknown static route is 404'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/state' -Headers $auth -HostHeader 'attacker.example.invalid').Status -eq 421) 'foreign Host header is rejected'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/state' -Headers $auth -HostHeader "localhost:$port").Status -eq 421) 'localhost Host header is rejected'
    foreach ($target in @('/brief.md', '/claude-events.jsonl', '/claude-stderr.txt', '/../brief.md', '/%2e%2e/brief.md', '/..%5cbrief.md',
            '/dashboard/../scripts/show-dashboard.ps1', '/api/../brief.md', '/api/state/../../brief.md', '/index.html/../../dashboard.json',
            '//etc/passwd', '/C:/Windows/win.ini', '/progress.log', '/dashboard.json')) {
        $response = Invoke-Raw -Port $port -Target $target -Headers $auth
        $leaked = $response.Body.Contains('BRIEF-CANARY') -or $response.Body.Contains('EVENT-CANARY') -or $response.Body.Contains('STDERR-CANARY') -or $response.Body.Contains('session_id')
        Assert-True ($response.Status -eq 404 -and -not $leaked) "path traversal blocked: $target ($($response.Status))"
    }

    # --- Authorized state ---
    Write-Host '[state]'
    $response = Invoke-Raw -Port $port -Target '/api/state' -Headers $auth
    Assert-True ($response.Status -eq 200 -and $response.Headers['content-type'] -like 'application/json*') 'state is 200 JSON'
    $state = $response.Body | ConvertFrom-Json
    Assert-True ($state.status -ceq 'active' -and $state.bridge_alive -and $state.can_stop) 'state reports an active, stoppable run'
    Assert-True ($state.repository_name -ceq 'repo-main' -and $state.max_turns -eq 40 -and $state.timeout_seconds -eq 600 -and $state.max_budget_usd -eq 2.5) 'state reports repository and limits'
    Assert-True ($state.resumed -eq $false -and $state.session_id -match '^[0-9a-f-]{36}$') 'state reports run kind and session'
    $activity = @($state.activity) -join "`n"
    Assert-True ($activity.Contains('Tool Bash: running npm') -and $activity.Contains('Tool Grep: searching src') -and $activity.Contains('Tool WebFetch: requesting URL')) 'activity contains sanitized tool lines'
    foreach ($canary in $canaries) {
        Assert-True (-not $response.Body.Contains($canary)) "state does not disclose $canary"
    }
    Assert-True (-not $response.Body.Contains($token)) 'state does not contain the token'
    Assert-True (-not $response.Body.Contains($repo)) 'state does not contain the full repository path'

    # --- Changes ---
    Write-Host '[changes]'
    $response = Invoke-Raw -Port $port -Target '/api/changes' -Headers $auth
    $changes = $response.Body | ConvertFrom-Json
    Assert-True ($response.Status -eq 200) 'changes is 200'
    Assert-True ($changes.status_text.Contains('M app.txt') -and $changes.status_text.Contains('?? new-file.txt')) 'changes include git status --short'
    Assert-True ($changes.diff_text.Contains('+line two <script>alert(1)</script>')) 'changes include the diff text verbatim'
    Assert-True (-not $response.Body.Contains('<script>')) 'diff markup is JSON-escaped in the response'
    Assert-True (-not $changes.diff_truncated -and $changes.max_diff_bytes -eq 2097152 -and @($changes.errors).Count -eq 0) 'diff is complete under the 2 MiB default'
    $bigRepo = New-TestRepository 'repo-big'
    $bigTurn = New-TurnDirectory -Name 'turn-big' -Repository $bigRepo -BridgeProcessId $PID
    [IO.File]::WriteAllText((Join-Path $bigRepo 'app.txt'), (('x' * 100 + "`n") * 400), $utf8)
    $big = Get-ClaudeCXDashboardChanges -Metadata (Read-ClaudeCXDashboardMetadata -MetadataPath $bigTurn.Metadata) -MaxDiffBytes 4096
    Assert-True ($big.diff_truncated -and $utf8.GetByteCount($big.diff_text) -le 4096) 'diff output is capped and flagged as truncated'
    $emptyChanges = Get-ClaudeCXDashboardChanges -Metadata (Read-ClaudeCXDashboardMetadata -MetadataPath (New-TurnDirectory -Name 'turn-clean' -Repository (New-TestRepository 'repo-clean') -BridgeProcessId $PID).Metadata)
    Assert-True ($emptyChanges.status_text -ceq '' -and $emptyChanges.diff_text -ceq '' -and @($emptyChanges.errors).Count -eq 0) 'clean repository yields empty changes'
    $notRepo = Join-Path $sandbox 'not-a-repo'
    [IO.Directory]::CreateDirectory($notRepo) | Out-Null
    $errorChanges = Get-ClaudeCXDashboardChanges -Metadata (Read-ClaudeCXDashboardMetadata -MetadataPath (New-TurnDirectory -Name 'turn-norepo' -Repository $notRepo -BridgeProcessId $PID).Metadata)
    Assert-True (@($errorChanges.errors).Count -gt 0) 'git errors are reported as an error state'

    # --- Report and failure ---
    Write-Host '[report]'
    $report = (Invoke-Raw -Port $port -Target '/api/report' -Headers $auth).Body | ConvertFrom-Json
    Assert-True ($report.kind -ceq 'pending') 'report is pending during an active run'
    [IO.File]::WriteAllText($paths.Failure, '{"status":"failed","message":"Claude Code failed closed.","occurred_at":"2026-01-01T00:00:00Z","extra":"STDERR-CANARY-0c7e"}', $utf8)
    $response = Invoke-Raw -Port $port -Target '/api/report' -Headers $auth
    $report = $response.Body | ConvertFrom-Json
    Assert-True ($report.kind -ceq 'failure' -and $report.failure.message -ceq 'Claude Code failed closed.') 'failure details shown when there is no report'
    Assert-True (-not $response.Body.Contains('STDERR-CANARY')) 'failure response includes only fixed fields'
    $reportJson = [ordered]@{
        summary = 'Done <b>bold</b>'
        files_changed = @('app.txt')
        commands_run = @('pwsh -File test.ps1')
        checks = @([ordered]@{ command = 'pwsh -File test.ps1'; status = 'passed'; output_summary = 'ok' })
        denied_actions = @()
        open_questions = @('Q1')
        deviations_from_brief = @()
        risks = @('R1')
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($paths.Report, $reportJson, $utf8)
    $response = Invoke-Raw -Port $port -Target '/api/report' -Headers $auth
    $report = $response.Body | ConvertFrom-Json
    Assert-True ($report.kind -ceq 'report' -and $report.report.summary -ceq 'Done <b>bold</b>' -and @($report.report.checks)[0].status -ceq 'passed') 'structured report returned with all sections'
    Assert-True (-not $response.Body.Contains('<b>')) 'report markup is JSON-escaped in the response'
    Remove-Item -LiteralPath $paths.Report, $paths.Failure -Force

    # --- Stop requests ---
    Write-Host '[stop]'
    Assert-True ((Invoke-Raw -Port $port -Method 'POST' -Target '/api/stop' -Headers @{ Authorization = "Bearer $token"; Origin = 'http://attacker.example.invalid' }).Status -eq 403) 'stop from a foreign origin is rejected'
    Assert-True (-not (Test-Path -LiteralPath $paths.Stop)) 'rejected stop creates no marker'
    $response = Invoke-Raw -Port $port -Method 'POST' -Target '/api/stop' -Headers @{ Authorization = "Bearer $token"; Origin = "http://127.0.0.1:$port" }
    $stop = $response.Body | ConvertFrom-Json
    Assert-True ($response.Status -eq 202 -and $stop.accepted -and -not $stop.already_requested) 'authorized stop is accepted'
    $markerText = [IO.File]::ReadAllText($paths.Stop, $utf8)
    Assert-True (-not $markerText.Contains($token)) 'stop marker does not contain the token'
    Assert-True (((($markerText | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'requested_at,source') 'stop marker holds only fixed fields'
    $stop = (Invoke-Raw -Port $port -Method 'POST' -Target '/api/stop' -Headers $auth).Body | ConvertFrom-Json
    Assert-True ($stop.accepted -and $stop.already_requested) 'repeated stop is idempotent'
    $state = (Invoke-Raw -Port $port -Target '/api/state' -Headers $auth).Body | ConvertFrom-Json
    Assert-True ($state.stop_requested -and -not $state.can_stop) 'state reflects the stop request'
    $atomicTurn = New-TurnDirectory -Name 'turn-atomic' -Repository $repo -BridgeProcessId $PID
    Assert-True ((Request-ClaudeCXStop -TurnDirectory $atomicTurn.Directory) -eq $true) 'first stop request creates the marker'
    Assert-True ((Request-ClaudeCXStop -TurnDirectory $atomicTurn.Directory) -eq $false) 'second stop request finds the existing marker'
    Assert-True (@(Get-ChildItem -LiteralPath $atomicTurn.Directory -Filter '*.tmp').Count -eq 0) 'no temporary files left by the atomic marker write'
    Assert-True (Test-ClaudeCXStopRequested -TurnDirectory $atomicTurn.Directory) 'bridge-side check sees the marker'

    Complete-ClaudeCXProgress -Sink $sink -Status 'stopped' -Message 'Stopped by a user request.'
    $response = Invoke-Raw -Port $port -Method 'POST' -Target '/api/stop' -Headers $auth
    Assert-True ($response.Status -eq 409) 'stop after completion is rejected'
    $state = (Invoke-Raw -Port $port -Target '/api/state' -Headers $auth).Body | ConvertFrom-Json
    Assert-True ($state.status -ceq 'stopped' -and -not $state.can_stop) 'state reports a stopped run'

    # --- Completion auto-exit ---
    Write-Host '[lifetime]'
    Assert-True (Wait-Until { $server.Process.HasExited } -TimeoutSeconds 20) 'server exits after the completion interval'
    Assert-True (-not (Test-Path -LiteralPath $paths.Endpoint)) 'server removes its readiness file on exit'

    $bridgeStandIn = Start-Sleeper
    $orphanTurn = New-TurnDirectory -Name 'turn-orphan' -Repository $repo -BridgeProcessId $bridgeStandIn.Id
    $orphan = Start-ClaudeCXDashboardServer -MetadataPath $orphanTurn.Metadata -ServerScriptPath $serverScript -Token (New-ClaudeCXDashboardToken) -MaxLifetimeSeconds 600
    $script:cleanup.Add($orphan.Process)
    Start-Sleep -Milliseconds 1500
    Assert-True (-not $orphan.Process.HasExited) 'server stays up while the bridge is alive'
    $bridgeStandIn.Kill($true)
    Assert-True (Wait-Until { $orphan.Process.HasExited } -TimeoutSeconds 20) 'server exits when the bridge disappears'
    $orphanState = Get-ClaudeCXDashboardState -Metadata (Read-ClaudeCXDashboardMetadata -MetadataPath $orphanTurn.Metadata)
    Assert-True ($orphanState.status -ceq 'failed' -and -not $orphanState.can_stop) 'vanished bridge is reported as failed'

    $noTokenTurn = New-TurnDirectory -Name 'turn-notoken' -Repository $repo -BridgeProcessId $PID
    $null = & $pwshPath -NoProfile -NonInteractive -File $serverScript -MetadataPath $noTokenTurn.Metadata 2>&1
    Assert-True ($LASTEXITCODE -eq 2) 'server refuses to start without a token'
    Assert-True (-not (Test-Path -LiteralPath (Get-ClaudeCXDashboardPaths -TurnDirectory $noTokenTurn.Directory).Endpoint)) 'tokenless server never reports readiness'

    # --- Start-ClaudeCXDashboard with a recording browser launcher ---
    Write-Host '[launch]'
    $launchTurn = New-TurnDirectory -Name 'turn-launch' -Repository $repo -BridgeProcessId $PID
    $script:launchedUrl = $null
    $dashboard = Start-ClaudeCXDashboard -MetadataPath $launchTurn.Metadata -ServerScriptPath $serverScript -MaxLifetimeSeconds 600 -BrowserLauncher { param($Url) $script:launchedUrl = $Url }
    $script:cleanup.Add($dashboard.Process)
    Assert-True ($script:launchedUrl -cmatch '^http://127\.0\.0\.1:\d+/#token=[A-Za-z0-9_-]{43}$') 'browser URL is loopback with the token in the fragment only'
    Assert-True (@($dashboard.PSObject.Properties.Name | Where-Object { $_ -match '(?i)token|url' }).Count -eq 0) 'launch result does not expose the token'
    $launchToken = ($script:launchedUrl -split '#token=', 2)[1]
    Assert-True ((Invoke-Raw -Port $dashboard.Port -Target '/api/state' -Headers @{ Authorization = "Bearer $launchToken" }).Status -eq 200) 'fragment token authorizes the API'
    $dashboard.Process.Kill($true)

    $failTurn = New-TurnDirectory -Name 'turn-browser-fail' -Repository $repo -BridgeProcessId $PID
    $script:failedServer = $null
    $message = Get-ThrownMessage { Start-ClaudeCXDashboard -MetadataPath $failTurn.Metadata -ServerScriptPath $serverScript -BrowserLauncher { param($Url) throw 'no browser' } }
    Assert-True ($null -ne $message -and $message.Contains('browser could not be opened')) 'browser failure is reported'
    $failPid = $null
    try { $failPid = [int](([IO.File]::ReadAllText((Get-ClaudeCXDashboardPaths -TurnDirectory $failTurn.Directory).Endpoint)) | ConvertFrom-Json).pid } catch { }
    Assert-True ($null -eq $failPid -or (Wait-Until { $null -eq (Get-Process -Id $failPid -ErrorAction SilentlyContinue) } -TimeoutSeconds 10)) 'server is stopped when the browser cannot open'
    Assert-True ($null -ne (Get-ThrownMessage { Open-ClaudeCXBrowser -Url 'http://example.invalid/' })) 'non-loopback browser URL is refused before launch'

    # --- Fallback chain ---
    Write-Host '[fallback]'
    foreach ($case in @(
            @{ Name = 'dashboard ok'; Mode = 'Dashboard'; Dash = { 'ok' }; Win = { throw 'unexpected' }; Expected = 'Dashboard'; Warnings = 0 },
            @{ Name = 'dashboard -> window'; Mode = 'Dashboard'; Dash = { throw 'no server' }; Win = { 'ok' }; Expected = 'Window'; Warnings = 1 },
            @{ Name = 'dashboard -> window -> console'; Mode = 'Dashboard'; Dash = { throw 'no server' }; Win = { throw 'no window' }; Expected = 'Console'; Warnings = 2 },
            @{ Name = 'window -> console'; Mode = 'Window'; Dash = { throw 'unexpected' }; Win = { throw 'no window' }; Expected = 'Console'; Warnings = 1 },
            @{ Name = 'none'; Mode = 'None'; Dash = { throw 'unexpected' }; Win = { throw 'unexpected' }; Expected = 'None'; Warnings = 0 },
            @{ Name = 'console'; Mode = 'Console'; Dash = { throw 'unexpected' }; Win = { throw 'unexpected' }; Expected = 'Console'; Warnings = 0 })) {
        $fallbackDir = Join-Path $sandbox "fallback-$([Guid]::NewGuid().ToString('N'))"
        [IO.Directory]::CreateDirectory($fallbackDir) | Out-Null
        $fallbackSink = New-ClaudeCXProgressSink -Mode $case.Mode -ProgressPath (Join-Path $fallbackDir 'progress.log') -DonePath (Join-Path $fallbackDir 'progress.done') -ErrorWriter ([IO.StringWriter]::new())
        $writer = [IO.StringWriter]::new()
        $mode = Start-ClaudeCXProgressDisplay -Sink $fallbackSink -Mode $case.Mode -StartDashboard $case.Dash -StartWindow $case.Win -ErrorWriter $writer
        $warnings = @($writer.ToString() -split "`n" | Where-Object { $_.Trim() }).Count
        Assert-True ($mode -ceq $case.Expected -and $fallbackSink.Mode -ceq $case.Expected -and $warnings -eq $case.Warnings) "fallback $($case.Name) yields $($case.Expected) with $($case.Warnings) warning(s) ($mode, $warnings)"
        Complete-ClaudeCXProgress -Sink $fallbackSink -Status 'success' -Message 'done'
    }

    # --- Bridge stop with a fake Claude ---
    Write-Host '[bridge stop]'
    $gitDir = Split-Path -Parent (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $pwshDir = Split-Path -Parent $pwshPath
    $systemDir = [Environment]::SystemDirectory
    $fakeBin = Join-Path $sandbox 'fake-bin'
    [IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $fakePidFile = Join-Path $sandbox 'fake-claude.pid'
    $fakeCmd = @(
        '@echo off',
        'echo {"type":"system","subtype":"init","model":"fake-model"}',
        'echo partial> partial-edit.txt',
        ('"{0}" -NoProfile -NonInteractive -Command "Set-Content -LiteralPath ''{1}'' -Value $PID; Start-Sleep -Seconds 120"' -f $pwshPath, $fakePidFile)
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $fakeBin 'claude.cmd'), $fakeCmd + "`r`n", $utf8)
    $searchPath = @($fakeBin, $gitDir, $pwshDir, $systemDir) -join [IO.Path]::PathSeparator
    $otherClaude = @(@($gitDir, $pwshDir, $systemDir) | ForEach-Object {
            foreach ($name in @('claude.exe', 'claude.cmd', 'claude.bat', 'claude.ps1', 'claude.com')) {
                if (Test-Path -LiteralPath (Join-Path $_ $name)) { Join-Path $_ $name }
            }
        })
    if ($otherClaude.Count -gt 0) {
        Assert-True $false "restricted PATH contains a real Claude executable; bridge stop test skipped ($($otherClaude -join ', '))"
    }
    else {
        $bridgeRepo = New-TestRepository 'repo-bridge'
        $stateRoot = Join-Path $sandbox 'bridge-state'
        $briefPath = Join-Path $sandbox 'bridge-brief.md'
        [IO.File]::WriteAllText($briefPath, "Fake brief BRIEF-CANARY-91d2`n", $utf8)
        $bystander = Start-Sleeper
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $bridgeScript, '-ProjectPath', $bridgeRepo, '-BriefPath', $briefPath,
                '-StateRoot', $stateRoot, '-ProgressMode', 'None', '-TimeoutSeconds', '120', '-MaxTurns', '3', '-MaxBudgetUsd', '0.01')) {
            $startInfo.ArgumentList.Add($argument)
        }
        $startInfo.Environment['PATH'] = $searchPath
        $startInfo.Environment.Remove('AGENT_HANDOFF_DEPTH') | Out-Null
        $startInfo.Environment['LOCALAPPDATA'] = Join-Path $sandbox 'bridge-localappdata'
        $bridge = [Diagnostics.Process]::Start($startInfo)
        $script:cleanup.Add($bridge)
        $bridgeOut = $bridge.StandardOutput.ReadToEndAsync()
        $bridgeErr = $bridge.StandardError.ReadToEndAsync()
        $script:bridgeTurn = $null
        $started = Wait-Until -TimeoutSeconds 60 -Condition {
            $log = @(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -Filter 'progress.log' -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($log.Count -eq 0 -or -not (Test-Path -LiteralPath $fakePidFile)) { return $false }
            $script:bridgeTurn = $log[0].DirectoryName
            return (Read-Shared $log[0].FullName).Contains('Claude session started')
        }
        Assert-True $started "fake Claude started under the bridge ($(if ($bridge.HasExited) { $bridgeErr.Result }))"
        if ($started) {
            $sessionDir = Split-Path -Parent $script:bridgeTurn
            $fingerprintBefore = [IO.File]::ReadAllText((Join-Path $sessionDir 'last-state.sha256'))
            $fakePid = [int]([IO.File]::ReadAllText($fakePidFile).Trim())
            Assert-True ($null -ne (Get-Process -Id $fakePid -ErrorAction SilentlyContinue)) 'fake Claude child process is running'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $null = Request-ClaudeCXStop -TurnDirectory $script:bridgeTurn
            $exited = $bridge.WaitForExit(30000)
            Assert-True $exited "bridge exits after a stop request ($([int]$clock.Elapsed.TotalSeconds)s)"
            if ($exited) {
                $bridge.WaitForExit()
                Assert-True ($bridge.ExitCode -ne 0) "stopped bridge exits nonzero ($($bridge.ExitCode))"
                Assert-True (-not $bridgeOut.Result.Contains('"status":"success"')) 'stopped bridge prints no success result'
                Assert-True ($bridgeErr.Result.Contains('partial edits remain')) 'stopped bridge explains that partial edits remain'
                $failure = [IO.File]::ReadAllText((Join-Path $script:bridgeTurn 'failure.json')) | ConvertFrom-Json
                Assert-True ($failure.status -ceq 'stopped' -and $failure.message.Contains('partial edits remain')) 'failure.json records a stopped run'
                $done = [IO.File]::ReadAllText((Join-Path $script:bridgeTurn 'progress.done')) | ConvertFrom-Json
                Assert-True ($done.status -ceq 'stopped') 'progress completion marker records a stopped run'
                Assert-True ((Read-Shared (Join-Path $script:bridgeTurn 'progress.log')).Contains('ClaudeCX run stopped')) 'progress log records the stop'
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:bridgeTurn 'report.json'))) 'no report is written for a stopped run'
                Assert-True ([IO.File]::ReadAllText((Join-Path $sessionDir 'last-state.sha256')) -ceq $fingerprintBefore) 'resume fingerprint is not updated by a stopped run'
                Assert-True (Test-Path -LiteralPath (Join-Path $bridgeRepo 'partial-edit.txt')) 'partial edits are preserved'
                Assert-True (Wait-Until { $null -eq (Get-Process -Id $fakePid -ErrorAction SilentlyContinue) } -TimeoutSeconds 10) 'the fake Claude process tree was terminated'
                Assert-True (-not $bystander.HasExited) 'an unrelated process was not terminated'
                Assert-True (@(Get-ChildItem -LiteralPath $stateRoot -Recurse -File -Filter 'active.lock').Count -eq 0) 'bridge lock released after the stop'
            }
        }
    }
}
finally {
    foreach ($process in $script:cleanup) {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
    }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host "test-dashboard: $($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    foreach ($failure in $script:failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "test-dashboard: all $($script:passed) checks passed" -ForegroundColor Green
