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

    # --- Built UI checks (React/Vite output; source checks also run in dashboard-src/scripts/check-dashboard.mjs) ---
    Write-Host '[ui build]'
    $builtNames = @(Get-ChildItem -LiteralPath $dashboardRoot -File | ForEach-Object Name | Sort-Object)
    Assert-True (($builtNames -join ',') -ceq 'app.js,index.html,styles.css') "dashboard folder holds exactly the stable built assets ($($builtNames -join ','))"
    Assert-True ($html.StartsWith('<!doctype html>')) 'index.html has a doctype'
    Assert-True ($html -match '<script type="module" crossorigin src="/app\.js"></script>') 'index.html loads the packaged module script only'
    Assert-True (@([Regex]::Matches($html, '<script\b')).Count -eq 1) 'index.html has no inline scripts'
    Assert-True ($html -match '<link rel="stylesheet" crossorigin href="/styles\.css">') 'index.html loads the packaged stylesheet'
    Assert-True ($html -notmatch '(?i)<style\b|\sstyle\s*=') 'index.html has no inline styles'
    Assert-True ($html -notmatch '(?i)\son[a-z]+\s*=') 'index.html has no inline event handlers'
    # React needs XML namespace identifiers to create SVG nodes; they are never fetched.
    $namespaceUris = 'http://www\.w3\.org/(2000/svg|1999/xlink|1998/Math/MathML|XML/1998/namespace|1999/xhtml)'
    foreach ($source in @(@('index.html', $html), @('styles.css', $css), @('app.js', $js))) {
        $withoutNamespaces = $source[1] -replace $namespaceUris, ''
        Assert-True ($withoutNamespaces -notmatch '(?i)(https?:)?//[a-z0-9.-]+\.[a-z]{2,}|wss?://') "$($source[0]) references no external origin"
        Assert-True ($source[1] -notmatch 'sourceMappingURL') "$($source[0]) has no source map reference"
        Assert-True (-not $source[1].Contains("`r") -and -not $source[1].StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) "$($source[0]) is LF without BOM"
    }
    Assert-True ($css -notmatch '(?i)@import|url\(') 'styles.css loads no other resources'
    Assert-True ($css.Contains('prefers-reduced-motion')) 'styles.css honours prefers-reduced-motion'
    foreach ($pattern in @('eval(', 'new Function(', 'localStorage', 'sessionStorage', 'window.open(')) {
        Assert-True (-not $js.Contains($pattern)) "app.js does not use $pattern"
    }
    foreach ($route in @('/api/state', '/api/changes', '/api/report', '/api/prompts', '/api/stop')) {
        Assert-True ($js.Contains("`"$route`"")) "app.js calls $route"
    }
    Assert-True ($js.Contains('history.replaceState') -and $js.Contains('"Bearer "+')) 'app.js removes the fragment and sends the token in a header'
    Assert-True ($js.Contains('Partial edits remain in the working tree for Codex review') -and $js.Contains('Stop requested…')) 'stop confirmation explains that partial edits remain'
    Assert-True ($js.Contains('Original request not captured') -and $js.Contains('a reload cannot reconnect')) 'app.js explains a missing original request and the memory-only token'
    Assert-True ($js.Contains('role:"tablist"') -and $js.Contains('"aria-live":"polite"')) 'app.js exposes accessible tabs and live regions'
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'dashboard-src\src') -File -Recurse)) {
        $sourceText = [IO.File]::ReadAllText($sourceFile.FullName, $utf8)
        Assert-True (-not $sourceText.Contains('dangerouslySetInnerHTML') -and -not $sourceText.Contains('innerHTML')) "React source $($sourceFile.Name) never injects HTML"
        Assert-True ($sourceText -notmatch 'rehype-raw|rehypePlugins|remarkPlugins|allowDangerousHtml') "React source $($sourceFile.Name) enables no raw-HTML Markdown plugin"
    }
    # Report summaries render as restricted Markdown; every other surface stays plain text.
    $markdownSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'dashboard-src\src\safe-markdown.js'), $utf8)
    Assert-True ($markdownSource.Contains('skipHtml: true') -and $markdownSource.Contains('unwrapDisallowed: true') -and $markdownSource.Contains('urlTransform: noUrl') -and
        $markdownSource.Contains("const noUrl = () => '';") -and $markdownSource.Contains("createElement('span', { className: 'md-link' }")) 'summary Markdown skips raw HTML, discards URLs, and renders links as text'
    $allowedList = [Regex]::Match($markdownSource, 'SUMMARY_ALLOWED_ELEMENTS = \[([^\]]*)\]').Groups[1].Value
    $allowedTags = @([Regex]::Matches($allowedList, "'([a-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Assert-True (($allowedTags -join ',') -ceq 'a,blockquote,br,code,em,h1,h2,h3,h4,h5,h6,hr,li,ol,p,pre,strong,ul') "summary Markdown allows only fixed text elements ($($allowedTags -join ','))"
    $viewsSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'dashboard-src\src\views.jsx'), $utf8)
    Assert-True (@([Regex]::Matches($viewsSource, '<SafeMarkdown\b')).Count -eq 1 -and $viewsSource.Contains('<SafeMarkdown text={body.summary} />')) 'Markdown is used only for the report summary'
    Assert-True ($viewsSource.Contains('<pre className="document-body" tabIndex={0} aria-label={title}>{text}</pre>')) 'prompt documents stay exact plain text'
    $packageText = [IO.File]::ReadAllText((Join-Path $repoRoot 'package.json'), $utf8)
    Assert-True ($packageText -notmatch 'rehype-raw|rehype-sanitize|html-react-parser|remark-html') 'no raw-HTML Markdown package is a dependency'

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
    $originalPrompt = "Please add a greeting ORIGINAL-CANARY-4e1a`nქართული: გამარჯობა, მსოფლიო <b>&</b>`n"
    $codexBrief = "# Task`n`n## Objective`n- CODEX-BRIEF-CANARY-7c3d გამარჯობა`n`n## Acceptance criteria`n- one`n- two`n"
    $promptCanaries = @('ORIGINAL-CANARY-4e1a', 'CODEX-BRIEF-CANARY-7c3d', 'გამარჯობა')
    [IO.File]::WriteAllText((Join-Path $turn.Directory 'original-prompt.md'), $originalPrompt, $utf8)
    [IO.File]::WriteAllText((Join-Path $turn.Directory 'codex-brief.md'), $codexBrief, $utf8)
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
    Write-Host '[prompts]'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/prompts').Status -eq 401) 'prompts without a token is 401'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/prompts' -Headers @{ Authorization = "Bearer $tokenA" }).Status -eq 401) 'prompts with a wrong token is 401'
    Assert-True ((Invoke-Raw -Port $port -Target '/api/prompts' -Headers $auth -HostHeader "localhost:$port").Status -eq 421) 'prompts with a foreign Host is 421'
    foreach ($method in @('POST', 'PUT', 'DELETE')) {
        $response = Invoke-Raw -Port $port -Method $method -Target '/api/prompts' -Headers $auth
        Assert-True ($response.Status -eq 405 -and $response.Headers['allow'] -ceq 'GET') "prompts $method is 405 with Allow: GET"
    }
    foreach ($unauthorized in @((Invoke-Raw -Port $port -Target '/api/prompts'), (Invoke-Raw -Port $port -Target '/api/state'), (Invoke-Raw -Port $port -Target '/'))) {
        foreach ($canary in $promptCanaries) {
            Assert-True (-not $unauthorized.Body.Contains($canary)) "unauthenticated or static response does not disclose $canary"
        }
    }
    $response = Invoke-Raw -Port $port -Target '/api/prompts' -Headers $auth
    Assert-True ($response.Status -eq 200 -and $response.Headers['content-type'] -like 'application/json*') 'prompts is 200 JSON'
    $prompts = $response.Body | ConvertFrom-Json
    $promptKeys = @($prompts.PSObject.Properties.Name | Sort-Object)
    Assert-True (($promptKeys -join ',') -ceq 'brief_available,codex_brief,max_bytes,original_available,original_prompt') "prompts returns only the intended fields ($($promptKeys -join ','))"
    Assert-True ($prompts.original_available -and $prompts.original_prompt -ceq $originalPrompt) 'original request survives exactly, including Georgian text'
    Assert-True ($prompts.brief_available -and $prompts.codex_brief -ceq $codexBrief) 'Codex brief survives exactly'
    Assert-True ($prompts.max_bytes -eq 1048576) 'prompts reports the 1 MiB bound'
    Assert-True (-not $response.Body.Contains('<b>') -and -not $response.Body.Contains('BRIEF-CANARY-91d2')) 'prompt markup is JSON-escaped and legacy brief.md is not served'
    Assert-True (-not $response.Body.Contains($token)) 'prompts holds no token'
    $stateBody = (Invoke-Raw -Port $port -Target '/api/state' -Headers $auth).Body
    foreach ($canary in $promptCanaries) {
        Assert-True (-not $stateBody.Contains($canary)) "state does not disclose prompt text $canary"
        foreach ($artifact in @($turn.Metadata, (Join-Path $turn.Directory 'progress.log'), (Join-Path $turn.Directory 'dashboard-endpoint.json'))) {
            Assert-True (-not (Read-Shared $artifact).Contains($canary)) "$([IO.Path]::GetFileName($artifact)) does not contain $canary"
        }
    }
    $noPromptTurn = New-TurnDirectory -Name 'turn-no-prompt' -Repository $repo -BridgeProcessId $PID
    [IO.File]::WriteAllText((Join-Path $noPromptTurn.Directory 'codex-brief.md'), $codexBrief, $utf8)
    $absent = Get-ClaudeCXDashboardPrompts -Metadata (Read-ClaudeCXDashboardMetadata -MetadataPath $noPromptTurn.Metadata)
    Assert-True (-not $absent.original_available -and $null -eq $absent.original_prompt -and $absent.brief_available) 'missing original prompt is a normal unavailable state'
    [IO.File]::WriteAllBytes((Join-Path $noPromptTurn.Directory 'original-prompt.md'), [byte[]](0x61, 0xC3, 0x28))
    [IO.File]::WriteAllText((Join-Path $noPromptTurn.Directory 'codex-brief.md'), ('x' * 1048577), $utf8)
    $invalid = Get-ClaudeCXDashboardPrompts -Metadata (Read-ClaudeCXDashboardMetadata -MetadataPath $noPromptTurn.Metadata)
    Assert-True (-not $invalid.original_available -and -not $invalid.brief_available) 'invalid UTF-8 and oversized prompt artifacts are not served'

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
    $fakeStdinFile = Join-Path $sandbox 'fake-claude-stdin.bin'
    $fakeCmd = @(
        '@echo off',
        'echo {"type":"system","subtype":"init","model":"fake-model"}',
        'echo partial> partial-edit.txt',
        ('"{0}" -NoProfile -NonInteractive -Command "$i = [Console]::OpenStandardInput(); $o = [IO.File]::Create(''{2}''); $i.CopyTo($o); $o.Close(); Set-Content -LiteralPath ''{1}'' -Value $PID; Start-Sleep -Seconds 120"' -f $pwshPath, $fakePidFile, $fakeStdinFile)
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
        # --- Prompt inputs fail closed before Claude starts ---
        Write-Host '[bridge inputs]'
        $inputRepo = New-TestRepository 'repo-inputs'
        $goodBrief = Join-Path $sandbox 'input-good-brief.md'
        [IO.File]::WriteAllText($goodBrief, "Good brief`n", $utf8)
        $insideFile = Join-Path $inputRepo 'inside-brief.md'
        [IO.File]::WriteAllText($insideFile, "Inside brief`n", $utf8)
        $oversized = Join-Path $sandbox 'input-oversized.md'
        [IO.File]::WriteAllText($oversized, ('x' * 1048577), $utf8)
        $invalidUtf8 = Join-Path $sandbox 'input-invalid.md'
        [IO.File]::WriteAllBytes($invalidUtf8, [byte[]](0x61, 0xC3, 0x28, 0x0A))
        $unbornRepo = Join-Path $sandbox 'repo-unborn'
        & git init -q $unbornRepo
        $inputCases = @(
            @{ Name = 'repository without commits'; Brief = $goodBrief; Original = $null; Repo = $unbornRepo; Expect = 'has no commits yet' },
            @{ Name = 'inside-repository brief'; Brief = $insideFile; Original = $null; Expect = 'BriefPath must be outside the repository' },
            @{ Name = 'inside-repository original prompt'; Brief = $goodBrief; Original = $insideFile; Expect = 'OriginalPromptPath must be outside the repository' },
            @{ Name = 'oversized brief'; Brief = $oversized; Original = $null; Expect = 'BriefPath exceeds the 1048576-byte limit' },
            @{ Name = 'missing original prompt'; Brief = $goodBrief; Original = (Join-Path $sandbox 'missing-original.md'); Expect = 'OriginalPromptPath is not a file' },
            @{ Name = 'invalid UTF-8 original prompt'; Brief = $goodBrief; Original = $invalidUtf8; Expect = 'OriginalPromptPath is not valid UTF-8' }
        )
        foreach ($case in $inputCases) {
            $caseState = Join-Path $sandbox ('input-state-' + [Guid]::NewGuid().ToString('N'))
            $caseRepo = if ($case.ContainsKey('Repo')) { $case.Repo } else { $inputRepo }
            $caseArgs = @('-NoProfile', '-NonInteractive', '-File', $bridgeScript, '-ProjectPath', $caseRepo, '-BriefPath', $case.Brief,
                '-StateRoot', $caseState, '-ProgressMode', 'None', '-TimeoutSeconds', '60', '-MaxTurns', '1', '-MaxBudgetUsd', '0.01')
            if ($case.Original) { $caseArgs += @('-OriginalPromptPath', $case.Original) }
            $caseInfo = [Diagnostics.ProcessStartInfo]::new()
            $caseInfo.FileName = $pwshPath
            $caseInfo.UseShellExecute = $false
            $caseInfo.CreateNoWindow = $true
            $caseInfo.RedirectStandardOutput = $true
            $caseInfo.RedirectStandardError = $true
            foreach ($argument in $caseArgs) { $caseInfo.ArgumentList.Add($argument) }
            $caseInfo.Environment['PATH'] = $searchPath
            $caseInfo.Environment.Remove('AGENT_HANDOFF_DEPTH') | Out-Null
            $caseInfo.Environment['LOCALAPPDATA'] = Join-Path $sandbox 'bridge-localappdata'
            $caseProcess = [Diagnostics.Process]::Start($caseInfo)
            $script:cleanup.Add($caseProcess)
            $caseErr = $caseProcess.StandardError.ReadToEndAsync()
            $null = $caseProcess.StandardOutput.ReadToEnd()
            $caseProcess.WaitForExit()
            $stateFiles = @(Get-ChildItem -LiteralPath $caseState -Recurse -File -ErrorAction SilentlyContinue)
            Assert-True ($caseProcess.ExitCode -ne 0 -and $caseErr.Result.Contains($case.Expect)) "$($case.Name) is refused ($($caseErr.Result.Trim()))"
            Assert-True (-not (Test-Path -LiteralPath $fakePidFile) -and $stateFiles.Count -eq 0) "$($case.Name) fails before any state is created or Claude starts"
        }

        $bridgeRepo = New-TestRepository 'repo-bridge'
        $stateRoot = Join-Path $sandbox 'bridge-state'
        $briefPath = Join-Path $sandbox 'bridge-brief.md'
        [IO.File]::WriteAllText($briefPath, "Fake brief BRIEF-CANARY-91d2`n## Constraints`n- keep it`n", $utf8)
        $originalPath = Join-Path $sandbox 'bridge-original.md'
        [IO.File]::WriteAllText($originalPath, "Original ORIGINAL-CANARY-4e1a: $([char]0x10D2)$([char]0x10D0)$([char]0x10DB)$([char]0x10D0)$([char]0x10E0)$([char]0x10EF)$([char]0x10DD)$([char]0x10D1)$([char]0x10D0)`n", $utf8)
        $bystander = Start-Sleeper
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $pwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $bridgeScript, '-ProjectPath', $bridgeRepo, '-BriefPath', $briefPath, '-OriginalPromptPath', $originalPath,
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
            $copiedBrief = [IO.File]::ReadAllBytes((Join-Path $script:bridgeTurn 'codex-brief.md'))
            $copiedOriginal = [IO.File]::ReadAllBytes((Join-Path $script:bridgeTurn 'original-prompt.md'))
            Assert-True ([Convert]::ToHexString($copiedBrief) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($briefPath))) 'codex-brief.md is a byte-exact copy of the brief'
            Assert-True ([Convert]::ToHexString($copiedOriginal) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($originalPath))) 'original-prompt.md is a byte-exact copy, including Georgian text'
            Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($fakeStdinFile)) -ceq [Convert]::ToHexString($copiedBrief)) 'Claude stdin is exactly the copied brief'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:bridgeTurn 'brief.md'))) 'no second brief copy is written'
            $bridgeLog = Read-Shared (Join-Path $script:bridgeTurn 'progress.log')
            Assert-True (-not $bridgeLog.Contains('ORIGINAL-CANARY-4e1a') -and -not $bridgeLog.Contains('BRIEF-CANARY-91d2') -and -not $bridgeLog.Contains($originalPath)) 'progress log holds no prompt text or prompt path'
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
