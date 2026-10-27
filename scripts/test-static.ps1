#Requires -Version 7.2
<#
.SYNOPSIS
Deterministic static validation for the ClaudeCX repository.

.DESCRIPTION
Parses every PowerShell and JSON file, validates the packaged skill, checks text
hygiene, rejects hard-coded user-specific data, and verifies the bridge safety
invariants. Requires Git (to enumerate non-ignored files). Does not contact
Claude or the network.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Force

$repoRoot = Get-ClaudeCXRepositoryRoot
$skillRoot = Get-ClaudeCXPackagedSkillRoot
$utf8 = [Text.UTF8Encoding]::new($false)

$script:failures = [Collections.Generic.List[string]]::new()
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passed++
    }
    else {
        $script:failures.Add($Message)
        Write-Host "  FAIL $Message" -ForegroundColor Red
    }
}

function Read-RepoText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    [IO.File]::ReadAllText((Join-Path $repoRoot $RelativePath), $utf8)
}

# --- Enumerate tracked and non-ignored untracked files ---
$listing = & git -C $repoRoot ls-files -z --cached --others --exclude-standard
if ($LASTEXITCODE -ne 0) {
    throw 'git ls-files failed; test-static.ps1 must run inside the ClaudeCX Git repository.'
}
$relativeFiles = @(($listing -join '') -split "`0" | Where-Object { $_ } | Sort-Object -Unique |
    Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf })
Write-Host "Checking $($relativeFiles.Count) files in $repoRoot"

$textExtensions = @('.ps1', '.psm1', '.psd1', '.json', '.md', '.yaml', '.yml', '.txt', '.html', '.css', '.js')
$textNames = @('.gitignore', '.gitattributes')
$textFiles = @($relativeFiles | Where-Object {
        $textExtensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant() -or
        $textNames -contains [IO.Path]::GetFileName($_)
    })

# --- Required repository files ---
Write-Host '[repository layout]'
foreach ($required in @(
        'README.md', 'SECURITY.md', 'CONTRIBUTING.md', 'AGENTS.md', 'docs/ARCHITECTURE.md',
        '.gitignore', '.gitattributes', 'install.ps1', 'uninstall.ps1',
        'scripts/ClaudeCX.Common.psm1', 'scripts/test-static.ps1', 'scripts/test-install.ps1', 'scripts/test-live.ps1', 'scripts/test-progress.ps1', 'scripts/test-dashboard.ps1')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $required) -PathType Leaf) "required file exists: $required"
}
foreach ($required in (Get-ClaudeCXRequiredSkillFiles)) {
    Assert-True ($relativeFiles -contains "skill/claudecx/$required") "skill file is tracked or staged for tracking: skill/claudecx/$required"
}

# --- PowerShell parsing ---
Write-Host '[powershell syntax]'
$powershellFiles = @($relativeFiles | Where-Object { [IO.Path]::GetExtension($_).ToLowerInvariant() -in '.ps1', '.psm1', '.psd1' })
Assert-True ($powershellFiles.Count -ge 7) "found PowerShell files ($($powershellFiles.Count))"
foreach ($file in $powershellFiles) {
    $errors = @(Test-ClaudeCXPowerShellSyntax -Path (Join-Path $repoRoot $file))
    Assert-True ($errors.Count -eq 0) "PowerShell parses: $file $($errors -join '; ')"
}

# --- JSON parsing ---
Write-Host '[json syntax]'
$jsonFiles = @($relativeFiles | Where-Object { [IO.Path]::GetExtension($_).ToLowerInvariant() -eq '.json' })
Assert-True ($jsonFiles.Count -ge 3) "found JSON files ($($jsonFiles.Count))"
foreach ($file in $jsonFiles) {
    $message = Test-ClaudeCXStrictJson -Path (Join-Path $repoRoot $file)
    Assert-True ($null -eq $message) "strict JSON parses: $file $message"
}

# --- Packaged skill metadata and invocation naming ---
Write-Host '[skill metadata]'
$problems = @(Get-ClaudeCXSkillProblems -SkillRoot $skillRoot)
Assert-True ($problems.Count -eq 0) "packaged skill validates: $($problems -join '; ')"
Assert-True ((Split-Path -Leaf $skillRoot) -ceq 'claudecx') 'skill folder name is lowercase claudecx'

# --- Text hygiene: LF line endings, no BOM ---
Write-Host '[text hygiene]'
foreach ($file in $textFiles) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repoRoot $file))
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-True (-not $hasBom) "no UTF-8 BOM: $file"
    Assert-True ([Array]::IndexOf($bytes, [byte]13) -lt 0) "LF line endings only: $file"
    Assert-True ($null -eq (Test-ClaudeCXStrictUtf8 -Bytes $bytes)) "valid UTF-8: $file"
}
$attributes = Read-RepoText '.gitattributes'
Assert-True ($attributes -match '(?m)^\*\s+text=auto\s+eol=lf\s*$') '.gitattributes enforces LF for text files'
$gitignoreLines = @((Read-RepoText '.gitignore') -split "`n" | ForEach-Object { $_.Trim() })
Assert-True (-not ($gitignoreLines -contains '*.lock')) '.gitignore does not hide dependency lockfiles with *.lock'

# --- No user-specific data ---
Write-Host '[user-specific data]'
$allowedEmailDomains = @('example.invalid', 'example.com', 'example.org', 'example.net')
$windowsUserPath = [Regex]::new('(?i)\b[a-z]:[\\/]+(users|documents and settings)[\\/]+(?![<%$\{*])[^\\/\s"''`]+')
$unixUserPath = [Regex]::new('(?<![\w.~])/(home|Users)/(?![<%$\{*])[A-Za-z0-9._-]+')
$emailPattern = [Regex]::new('[A-Za-z0-9._%+-]+@(?<domain>[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})')
$uuidPattern = [Regex]::new('(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b')
foreach ($file in $textFiles) {
    $text = Read-RepoText $file
    $windowsHit = $windowsUserPath.Match($text)
    Assert-True (-not $windowsHit.Success) "no hard-coded Windows user path in ${file}: $($windowsHit.Value)"
    $unixHit = $unixUserPath.Match($text)
    Assert-True (-not $unixHit.Success) "no hard-coded Unix user path in ${file}: $($unixHit.Value)"
    foreach ($email in $emailPattern.Matches($text)) {
        $domain = $email.Groups['domain'].Value.ToLowerInvariant()
        Assert-True ($allowedEmailDomains -contains $domain) "no personal email address in ${file}: $($email.Value)"
    }
    $uuidHit = $uuidPattern.Match($text)
    Assert-True (-not $uuidHit.Success) "no hard-coded UUID/session ID in ${file}: $($uuidHit.Value)"
}

# --- Structured operations only (no shell-string construction) ---
Write-Host '[structured operations]'
$forbiddenCommands = @('Invoke-' + 'Expression', 'iex', 'cmd', 'cmd.exe', 'Start-' + 'Process')
foreach ($file in $powershellFiles) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $file), [ref]$null, [ref]$null)
    $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    foreach ($forbidden in $forbiddenCommands) {
        Assert-True (-not ($commands -contains $forbidden)) "no $forbidden in $file"
    }
}

# --- Bridge invariants: invoke-claude.ps1 ---
Write-Host '[bridge invariants]'
$bridgeRelative = 'skill/claudecx/scripts/invoke-claude.ps1'
$bridgePath = Join-Path $repoRoot $bridgeRelative
$bridgeText = Read-RepoText $bridgeRelative
$bridgeAst = [Management.Automation.Language.Parser]::ParseFile($bridgePath, [ref]$null, [ref]$null)
$stringNodes = @($bridgeAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true))

function Test-InsideIf {
    param([Management.Automation.Language.Ast]$Node)
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.IfStatementAst]) { return $true }
        $parent = $parent.Parent
    }
    return $false
}

# Flags that must be sent on every call, initial and resumed alike.
foreach ($flag in @('-p', '--safe-mode', '--permission-mode', '--output-format', 'stream-json', '--verbose', '--json-schema', '--max-turns',
        '--max-budget-usd', '--settings', '--append-system-prompt-file', '--strict-mcp-config', '--mcp-config')) {
    $nodes = @($stringNodes | Where-Object { $_.Value -ceq $flag })
    Assert-True ($nodes.Count -ge 1) "bridge passes $flag"
    Assert-True ($nodes.Count -ge 1 -and @($nodes | Where-Object { -not (Test-InsideIf $_) }).Count -ge 1) "bridge passes $flag unconditionally (initial and resume)"
}
foreach ($flag in @('--session-id', '--resume')) {
    Assert-True (@($stringNodes | Where-Object { $_.Value -ceq $flag }).Count -ge 1) "bridge passes $flag"
}
foreach ($asset in @('assets\bridge-settings.json', 'assets\claude-role-prompt.md', 'assets\report-schema.json', 'assets\empty-mcp.json')) {
    Assert-True (@($stringNodes | Where-Object { $_.Value -ceq $asset }).Count -ge 1) "bridge references $asset"
}
$forbiddenFlags = @('--dangerously-skip-permissions', '--bare', 'bypassPermissions', 'acceptEdits', '--allow-dangerously-skip-permissions', '--include-partial-messages')
foreach ($scriptFile in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.json' })) {
    $text = [IO.File]::ReadAllText($scriptFile.FullName, $utf8)
    foreach ($forbidden in $forbiddenFlags) {
        Assert-True (-not $text.Contains($forbidden)) "no $forbidden in $($scriptFile.Name)"
    }
}

$parameters = @{}
foreach ($parameter in $bridgeAst.ParamBlock.Parameters) {
    $parameters[$parameter.Name.VariablePath.UserPath] = $parameter
}
$permission = $parameters['PermissionMode']
$validateSet = @(if ($permission) { $permission.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } })
$modes = if ($validateSet.Count -eq 1) { @($validateSet[0].PositionalArguments | ForEach-Object { $_.Value }) | Sort-Object } else { @() }
Assert-True (($modes -join ',') -ceq 'auto,plan') 'PermissionMode is restricted to auto and plan'
Assert-True ($permission -and $permission.DefaultValue -and $permission.DefaultValue.Value -ceq 'auto') 'PermissionMode defaults to auto'
$progressParameter = $parameters['ProgressMode']
$progressSet = @(if ($progressParameter) { $progressParameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } })
$progressModes = if ($progressSet.Count -eq 1) { @($progressSet[0].PositionalArguments | ForEach-Object { $_.Value }) | Sort-Object } else { @() }
Assert-True (($progressModes -join ',') -ceq 'Console,Dashboard,None,Window') 'ProgressMode is restricted to Dashboard, Window, Console, and None'
Assert-True ($progressParameter -and $progressParameter.DefaultValue -and $progressParameter.DefaultValue.Value -ceq 'Dashboard') 'ProgressMode defaults to Dashboard'
foreach ($name in @('MaxTurns', 'MaxBudgetUsd', 'TimeoutSeconds')) {
    $parameter = $parameters[$name]
    $hasRange = $parameter -and @($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' }).Count -eq 1
    Assert-True ([bool]$hasRange) "$name has a ValidateRange bound"
    Assert-True ($parameter -and $null -ne $parameter.DefaultValue) "$name has a default value"
}

$bridgeChecks = [ordered]@{
    'nested handoff guard' = 'AGENT_HANDOFF_DEPTH'
    'child marked as nested' = "`$startInfo.Environment['AGENT_HANDOFF_DEPTH'] = '1'"
    'auto-memory disabled' = "`$startInfo.Environment['CLAUDE_CODE_DISABLE_AUTO_MEMORY'] = '1'"
    'background tasks disabled' = "`$startInfo.Environment['CLAUDE_CODE_DISABLE_BACKGROUND_TASKS'] = '1'"
    'preassigned UUID' = "`$sessionId = [Guid]::NewGuid().ToString('D')"
    'resume ID must be a UUID' = '[Guid]::TryParse($ResumeSessionId'
    'clean tree for new sessions' = 'A new Claude bridge session requires a clean Git working tree, including untracked files.'
    'resume repository check' = 'Resume directory does not match the repository recorded for this session.'
    'resume HEAD check' = 'HEAD changed since this Claude session started. Refusing to resume.'
    'resume working-tree check' = 'The working tree changed outside the prior successful Claude turn. Refusing to resume.'
    'post-run HEAD check' = 'Claude changed Git HEAD from'
    'timeout budget' = '$timeoutMs = [int64]$TimeoutSeconds * 1000'
    'timeout enforced while streaming' = 'if ($remainingMs -le 0) {'
    'stream wait wakes to poll for a stop request' = '$lineTask.Wait([int][Math]::Min($remainingMs, $stopPollMs))'
    'stop request polled while streaming' = 'if (Test-ClaudeCXStopRequested -TurnDirectory $turnDir) {'
    'stop request polled after the stream ends' = '$stopRequested = Test-ClaudeCXStopRequested -TurnDirectory $turnDir'
    'stopped run recorded' = '$failureStatus = if ($stopRequested) { ''stopped'' } else { ''failed'' }'
    'stop kills only the Claude process tree' = 'if ($stopRequested) {'
    'dashboard module loaded' = "Join-Path `$PSScriptRoot 'ClaudeCX.Dashboard.psm1'"
    'dashboard server launched' = "Join-Path `$PSScriptRoot 'show-dashboard.ps1'"
    'progress display fallback chain' = 'Start-ClaudeCXProgressDisplay -Sink $progress -Mode $progressMode'
    'dashboard token kept out of the Claude environment' = '$startInfo.Environment.Remove((Get-ClaudeCXDashboardTokenVariable))'
    'timeout enforced after the stream ends' = '$process.WaitForExit([int][Math]::Min($remainingMs, $stopPollMs))'
    'stdout consumed incrementally' = '$process.StandardOutput.ReadLineAsync()'
    'raw event log kept' = "'claude-events.jsonl'"
    'progress log kept' = "'progress.log'"
    'stderr kept separately' = "'claude-stderr.txt'"
    'progress module loaded' = "Join-Path `$PSScriptRoot 'ClaudeCX.Progress.psm1'"
    'monitor script launched' = "Join-Path `$PSScriptRoot 'watch-progress.ps1'"
    'fail-closed result check' = 'Assert-ClaudeCXResultSuccess -Outer $outer -ExitCode $exitCode'
    'structured report extraction' = 'Get-ClaudeCXStructuredReport -Outer $outer'
    'monitor told of success' = "Complete-ClaudeCXProgress -Sink `$progress -Status 'success'"
    'monitor told of failure' = "Complete-ClaudeCXProgress -Sink `$progress -Status `$failureStatus -Message `$message"
    'monitor told when the bridge stops' = "Complete-ClaudeCXProgress -Sink `$progress -Status 'failed' -Message 'The bridge stopped"
    'process tree killed on timeout' = '$process.Kill($true)'
    'state under LOCALAPPDATA' = "Join-Path `$env:LOCALAPPDATA 'CodexClaude\handoffs'"
    'single active lock' = "'active.lock'"
    'structured process arguments' = '$startInfo.ArgumentList.Add($argument)'
    'brief sent through stdin' = '$process.StandardInput.Write($briefText)'
    'non-zero exit on failure' = 'exit 1'
}
foreach ($entry in $bridgeChecks.GetEnumerator()) {
    Assert-True ($bridgeText.Contains($entry.Value)) "bridge invariant: $($entry.Key)"
}
Assert-True ($bridgeText.IndexOf('Assert-ClaudeCXResultSuccess') -lt $bridgeText.IndexOf('Claude changed Git HEAD from')) 'result is checked before HEAD and report processing'

# --- Progress module and monitor ---
Write-Host '[progress module]'
$progressText = Read-RepoText 'skill/claudecx/scripts/ClaudeCX.Progress.psm1'
Assert-True ($progressText -match '\$ExitCode -ne 0 -or \$isError -or \(\$subtype -and \$subtype -ne ''success''\)') 'progress module fails closed on exit code, is_error, and non-success subtype'
Assert-True ($progressText -match "Get-ClaudeCXPropertyValue -Object \`$Outer -Name 'is_error'") 'progress module reads is_error'
Assert-True ($progressText -match "Get-ClaudeCXPropertyValue -Object \`$Outer -Name 'subtype'") 'progress module reads subtype'
Assert-True ($progressText -match "Get-ClaudeCXPropertyValue -Object \`$Outer -Name 'structured_output'") 'progress module reads structured_output'
Assert-True (-not ($progressText -match 'SafeText\s+-Text\s+\$command')) 'progress module never displays raw shell command text'
Assert-True ($progressText.Contains('Get-ClaudeCXCommandActivity -Command $command')) 'shell commands are reduced to an activity label'
Assert-True (-not ($progressText -match 'SafeText\s+-Text\s+\$(pattern|url|uri|query|prompt)') -and -not $progressText.Contains('.Host')) 'progress module never displays patterns, queries, prompts, URLs, or hosts'
Assert-True ($progressText.Contains('requesting URL') -and $progressText.Contains('searching')) 'URL and search tools use generic activity labels'
Assert-True ($progressText.Contains('$startInfo.ArgumentList.Add($argument)')) 'monitor launched with a structured argument list'
Assert-True ($progressText.Contains('$startInfo.UseShellExecute = $true') -and $progressText.Contains('[Diagnostics.ProcessWindowStyle]::Normal')) 'monitor opens in its own normal window without inherited handles'
Assert-True (-not $progressText.Contains('RedirectStandardInput')) 'monitor is never given a handle to Claude input'
$monitorText = Read-RepoText 'skill/claudecx/scripts/watch-progress.ps1'
Assert-True ($monitorText.Contains('[IO.FileShare]::ReadWrite') -and $monitorText.Contains('[IO.FileAccess]::Read')) 'monitor opens the progress log read-only'
Assert-True ($monitorText.Contains('Test-BridgeAlive')) 'monitor stops when the bridge process is gone'
foreach ($parameterName in @('ProgressPath', 'DonePath', 'BridgeProcessId', 'SuccessCloseSeconds', 'FailureCloseSeconds')) {
    Assert-True ($monitorText.Contains("`$$parameterName")) "monitor declares -$parameterName"
}

# --- Offline progress behavior tests ---
Write-Host '[progress behavior]'
$progressTest = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test-progress.ps1') 2>&1
$progressExit = $LASTEXITCODE
if ($progressExit -ne 0) {
    $progressTest | ForEach-Object { Write-Host "    $_" }
}
Assert-True ($progressExit -eq 0) "test-progress.ps1 passes ($(@($progressTest)[-1]))"

# --- Dashboard module, server, and UI ---
Write-Host '[dashboard]'
$dashboardText = Read-RepoText 'skill/claudecx/scripts/ClaudeCX.Dashboard.psm1'
$serverText = Read-RepoText 'skill/claudecx/scripts/show-dashboard.ps1'
Assert-True ($serverText.Contains('[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)')) 'dashboard server binds IPv4 loopback with an OS-assigned port'
Assert-True (-not ($dashboardText + $serverText).Contains('HttpListener') -and -not ($dashboardText + $serverText).Contains('IPAddress]::Any') -and -not ($dashboardText + $serverText).Contains('IPv6Any')) 'dashboard never uses HttpListener or wildcard addresses'
Assert-True ($dashboardText.Contains('[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)')) 'dashboard token has 256 bits of CSPRNG randomness'
Assert-True ($dashboardText.Contains('CryptographicOperations]::FixedTimeEquals')) 'dashboard token comparison is constant-time'
Assert-True ($dashboardText.Contains('#token=$token') -and $dashboardText.Contains("'Bearer '")) 'token travels in the URL fragment and the Authorization header'
Assert-True ($serverText.Contains('[Environment]::SetEnvironmentVariable($tokenVariable, [NullString]::Value)')) 'server removes the token from its environment'
Assert-True ($dashboardText.Contains("default-src 'none'") -and $dashboardText.Contains("frame-ancestors 'none'")) 'dashboard sends a strict CSP'
Assert-True ($dashboardText.Contains('$startInfo.ArgumentList.Add($argument)') -and $dashboardText.Contains("'--no-optional-locks'") -and $dashboardText.Contains("'--no-ext-diff'") -and $dashboardText.Contains("'--no-textconv'")) 'dashboard Git queries are fixed and read-only'
Assert-True ($dashboardText.Contains('-EscapeHandling EscapeHtml')) 'dashboard JSON escapes HTML-significant characters'
Assert-True (-not $dashboardText.Contains('RedirectStandardInput = $true') -or $dashboardText.Contains('$process.StandardInput.Close()')) 'dashboard Git child gets no interactive input'

Write-Host '[dashboard behavior]'
$dashboardTest = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test-dashboard.ps1') 2>&1
$dashboardExit = $LASTEXITCODE
if ($dashboardExit -ne 0) {
    $dashboardTest | ForEach-Object { Write-Host "    $_" }
}
Assert-True ($dashboardExit -eq 0) "test-dashboard.ps1 passes ($(@($dashboardTest)[-1]))"

# --- Bridge settings asset ---
Write-Host '[bridge settings]'
$settings = [Text.Json.Nodes.JsonNode]::Parse((Read-RepoText 'skill/claudecx/assets/bridge-settings.json'))
Assert-True ($null -ne $settings['disableAllHooks'] -and $settings['disableAllHooks'].ToJsonString() -ceq 'true') 'bridge settings disable all hooks'
Assert-True ($null -ne $settings['autoMemoryEnabled'] -and $settings['autoMemoryEnabled'].ToJsonString() -ceq 'false') 'bridge settings disable auto-memory'
$attribution = $settings['attribution']
Assert-True ($null -ne $attribution -and $attribution.ToJsonString() -ceq '{"commit":"","pr":"","sessionUrl":false}') 'bridge settings disable attribution'
$permissions = $settings['permissions']
Assert-True ($null -ne $permissions) 'bridge settings define permissions'
$denyRules = @(if ($null -ne $permissions -and $null -ne $permissions['deny']) { $permissions['deny'] | ForEach-Object { [string]$_ } })
foreach ($rule in @('mcp__*', 'Read(./.env)', 'Read(./**/.env)', 'Bash(git *commit*)', 'Bash(git *push*)', 'Bash(git *tag*)',
        'Bash(gh *pr create*)', 'Bash(codex *)', 'Bash(claude *)', 'Bash(npm publish*)', 'Bash(curl *)',
        'PowerShell(git *commit*)', 'PowerShell(git *push*)', 'PowerShell(codex *)', 'PowerShell(claude *)',
        'PowerShell(Invoke-WebRequest *)')) {
    Assert-True ($denyRules -contains $rule) "bridge settings deny $rule"
}
$allowRules = @(if ($null -ne $permissions -and $null -ne $permissions['allow']) { $permissions['allow'] })
Assert-True ($allowRules.Count -eq 0) 'bridge settings add no allow rules'
Assert-True ($null -eq $permissions -or $null -eq $permissions['defaultMode']) 'bridge settings do not set a default permission mode'
Assert-True ($null -eq $settings['hooks']) 'bridge settings define no hooks'
Assert-True ($null -eq $settings['enabledPlugins']) 'bridge settings enable no plugins'

$mcp = [Text.Json.Nodes.JsonNode]::Parse((Read-RepoText 'skill/claudecx/assets/empty-mcp.json'))
Assert-True ($mcp.ToJsonString() -ceq '{"mcpServers":{}}') 'MCP configuration is strictly empty'

$schema = [Text.Json.Nodes.JsonNode]::Parse((Read-RepoText 'skill/claudecx/assets/report-schema.json'))
$requiredFields = @($schema['required'] | ForEach-Object { [string]$_ }) | Sort-Object
Assert-True (($requiredFields -join ',') -ceq 'checks,commands_run,denied_actions,deviations_from_brief,files_changed,open_questions,risks,summary') 'report schema requires every report field'
Assert-True ($schema['additionalProperties'].ToJsonString() -ceq 'false') 'report schema rejects additional properties'

$rolePrompt = Read-RepoText 'skill/claudecx/assets/claude-role-prompt.md'
foreach ($phrase in @('Do not invoke Codex, Claude Code', 'Do not commit', 'push', 'deploy', 'external writes', 'Do not read `.env` files', 'safe mode', 'structured report')) {
    Assert-True ($rolePrompt.Contains($phrase)) "role prompt contains: $phrase"
}

# --- Live test wrapper is opt-in ---
Write-Host '[live test wrapper]'
$liveAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/test-live.ps1'), [ref]$null, [ref]$null)
$liveParameters = @($liveAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($name in @('ScratchRoot', 'MaxBudgetUsd', 'AcknowledgeUsage', 'ProgressMode')) {
    Assert-True ($liveParameters -contains $name) "test-live.ps1 declares -$name"
}
$liveText = Read-RepoText 'scripts/test-live.ps1'
Assert-True ($liveText.Contains('test-claude-bridge.ps1')) 'test-live.ps1 wraps the packaged bridge smoke test'

# --- Documentation consistency ---
Write-Host '[documentation]'
$readme = Read-RepoText 'README.md'
foreach ($phrase in @('$claudecx', 'install.ps1', 'uninstall.ps1', 'scripts\test-static.ps1', 'scripts\test-install.ps1',
        'scripts\test-live.ps1', '%LOCALAPPDATA%\CodexClaude\handoffs', 'PowerShell 7', 'Windows', '-Force',
        '-DisableClaudeAttribution', '-Yes', '-Permanent', 'active.lock', 'not a host sandbox',
        '-ProgressMode Console', '-ProgressMode None', '-ProgressMode Window', 'Dashboard', '127.0.0.1', 'Stop run', 'stop-request.json', 'claude-events.jsonl', 'progress.log', 'does not stop Claude')) {
    Assert-True ($readme.Contains($phrase)) "README mentions $phrase"
}
Assert-True ($readme.Contains('git clone https://github.com/Jadessz/ClaudeCX.git')) 'README clones the public repository URL'
Assert-True (-not $readme.Contains('<this-repository-url>')) 'README has no placeholder repository URL'
$hasLicense = @($relativeFiles | Where-Object { $_ -match '^(?i)(LICENSE|LICENCE|COPYING)(\.\w+)?$' }).Count -gt 0
if (-not $hasLicense) {
    foreach ($doc in @($relativeFiles | Where-Object { $_ -like '*.md' })) {
        Assert-True ((Read-RepoText $doc) -notmatch '(?i)\blicen[cs]e[ds]?\b|copyright') "no licensing claims without a license file: $doc"
    }
}
foreach ($doc in @('docs/ARCHITECTURE.md', 'SECURITY.md', 'skill/claudecx/SKILL.md')) {
    $docText = Read-RepoText $doc
    Assert-True ($docText.Contains('ProgressMode') -and $docText.Contains('progress.log')) "$doc documents progress modes and the progress log"
    Assert-True ($docText.Contains('Dashboard') -and $docText.Contains('127.0.0.1') -and $docText.Contains('Stop')) "$doc documents the dashboard and stop semantics"
}
$agents = Read-RepoText 'AGENTS.md'
Assert-True ($agents.Contains('scripts\test-static.ps1') -and $agents.Contains('scripts\test-install.ps1')) 'AGENTS.md names the static and install tests'

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host "test-static: $($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    exit 1
}
Write-Host "test-static: all $($script:passed) checks passed" -ForegroundColor Green
