#Requires -Version 7.2
<#
.SYNOPSIS
Offline tests for ClaudeCX stream-json handling, progress sanitization, and the progress monitor.

.DESCRIPTION
Feeds representative stream-json fixtures to the packaged progress module, checks
final-result extraction and fail-closed behavior, verifies that progress output is
sanitized and kept off stdout, and runs the monitor script headlessly (redirected,
no window) to check completion signalling. Does not contact Claude or the network.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Force
$skillRoot = Get-ClaudeCXPackagedSkillRoot
$progressModule = Join-Path $skillRoot 'scripts\ClaudeCX.Progress.psm1'
$monitorScript = Join-Path $skillRoot 'scripts\watch-progress.ps1'
Import-Module $progressModule -Force

$utf8 = [Text.UTF8Encoding]::new($false)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "claudecx-progress-test-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($sandbox) | Out-Null
$shellPath = [Environment]::ProcessPath

$script:failures = [Collections.Generic.List[string]]::new()
$script:passed = 0

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
    try {
        & $Action | Out-Null
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

function ConvertTo-Line {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function New-CaseDirectory {
    param([string]$Name)
    Write-Host ''
    Write-Host "[$Name]"
    $path = Join-Path $sandbox $Name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Invoke-Lines {
    # Feeds lines to a fresh stream state and returns the state plus every progress message.
    param([string]$Directory, [string[]]$Lines, [string]$RepositoryRoot = 'C:\work\demo-repo')
    $state = New-ClaudeCXStreamState -EventsPath (Join-Path $Directory 'claude-events.jsonl') -RepositoryRoot $RepositoryRoot
    $messages = [Collections.Generic.List[string]]::new()
    try {
        foreach ($line in $Lines) {
            foreach ($message in @(Add-ClaudeCXStreamLine -State $state -Line $line)) { $messages.Add($message) }
        }
    }
    finally {
        Close-ClaudeCXStreamState -State $state
    }
    return [pscustomobject]@{ State = $state; Messages = $messages.ToArray() }
}

function Start-Child {
    # Starts pwsh without a window, with stdout and stderr captured separately.
    param([string[]]$Arguments)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $shellPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Close()
    return [pscustomobject]@{
        Process = $process
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
    }
}

function Wait-Child {
    param([object]$Child, [int]$TimeoutSeconds = 30)
    $exited = $Child.Process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { $Child.Process.Kill($true) } catch { }
    }
    $Child.Process.WaitForExit()
    return [pscustomobject]@{
        Exited = $exited
        ExitCode = $Child.Process.ExitCode
        Stdout = $Child.Stdout.GetAwaiter().GetResult()
        Stderr = $Child.Stderr.GetAwaiter().GetResult()
    }
}

function Get-MonitorArguments {
    param([string]$Directory, [int]$BridgeProcessId)
    return @('-NoProfile', '-NonInteractive', '-File', $monitorScript,
        '-ProgressPath', (Join-Path $Directory 'progress.log'),
        '-DonePath', (Join-Path $Directory 'progress.done'),
        '-Title', 'ClaudeCX - demo-repo', '-RepositoryName', 'demo-repo', '-SessionId', 'test-session',
        '-BridgeProcessId', [string]$BridgeProcessId,
        '-SuccessCloseSeconds', '0', '-FailureCloseSeconds', '0', '-PollMilliseconds', '100')
}

$briefSecret = 'BRIEF-ONLY-CANARY do not display the prompt'
$fileContentCanary = 'FILE-CONTENT-CANARY function secretImplementation'
$toolOutputCanary = 'TOOL-OUTPUT-CANARY 42 tests passed'
$thinkingCanary = 'THINKING-CANARY private reasoning'
$report = [ordered]@{
    summary = 'Implemented the feature.'
    files_changed = @('src/app.ps1')
    commands_run = @('pwsh -File tests.ps1')
    checks = @([ordered]@{ command = 'pwsh -File tests.ps1'; status = 'passed'; output_summary = 'ok' })
    denied_actions = @()
    open_questions = @()
    deviations_from_brief = @()
    risks = @()
}
$successLines = @(
    (ConvertTo-Line ([ordered]@{ type = 'system'; subtype = 'init'; session_id = 'x'; model = 'claude-test-model'; tools = @('Bash', 'Read'); cwd = 'C:\work\demo-repo' })),
    (ConvertTo-Line ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = $briefSecret } })),
    '',
    (ConvertTo-Line ([ordered]@{ type = 'assistant'; message = [ordered]@{ content = @(
                    [ordered]@{ type = 'thinking'; thinking = $thinkingCanary },
                    [ordered]@{ type = 'text'; text = "I will edit the file. $fileContentCanary" }) } })),
    (ConvertTo-Line ([ordered]@{ type = 'assistant'; message = [ordered]@{ content = @(
                    [ordered]@{ type = 'tool_use'; id = 't1'; name = 'Write'; input = [ordered]@{ file_path = 'C:\work\demo-repo\src\app.ps1'; content = $fileContentCanary } }) } })),
    (ConvertTo-Line ([ordered]@{ type = 'user'; message = [ordered]@{ content = @(
                    [ordered]@{ type = 'tool_result'; tool_use_id = 't1'; content = $toolOutputCanary }) } })),
    (ConvertTo-Line ([ordered]@{ type = 'assistant'; message = [ordered]@{ content = @(
                    [ordered]@{ type = 'tool_use'; id = 't2'; name = 'Bash'; input = [ordered]@{ command = "pwsh -File tests.ps1`nRemove-Item junk"; description = 'run tests' } }) } })),
    (ConvertTo-Line ([ordered]@{ type = 'user'; message = [ordered]@{ content = @(
                    [ordered]@{ type = 'tool_result'; tool_use_id = 't2'; is_error = $true; content = $toolOutputCanary }) } })),
    (ConvertTo-Line ([ordered]@{ type = 'assistant'; message = [ordered]@{ content = @(
                    [ordered]@{ type = 'tool_use'; id = 't3'; name = 'Edit'; input = [ordered]@{ file_path = 'C:\work\demo-repo\src\app.ps1'; old_string = $fileContentCanary; new_string = $fileContentCanary } }) } })),
    (ConvertTo-Line ([ordered]@{ type = 'assistant'; message = [ordered]@{ content = @(
                    [ordered]@{ type = 'tool_use'; id = 't4'; name = 'StructuredOutput'; input = $report }) } })),
    (ConvertTo-Line ([ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; num_turns = 5; total_cost_usd = 0.1234; duration_ms = 65432; result = ''; structured_output = $report }))
)

try {
    # --- Successful final-result extraction ---
    $dir = New-CaseDirectory 'success'
    $run = Invoke-Lines -Directory $dir -Lines $successLines
    $outer = $run.State.ResultEvent
    Assert-True ($null -ne $outer) 'result event captured'
    Assert-True ($null -eq (Get-ThrownMessage { Assert-ClaudeCXResultSuccess -Outer $outer -ExitCode 0 -EventsPath 'events' -StderrPath 'stderr' })) 'successful result passes the fail-closed checks'
    $extracted = Get-ClaudeCXStructuredReport -Outer $outer
    Assert-True ($null -ne $extracted -and $extracted.summary -ceq 'Implemented the feature.') 'structured_output report extracted'
    $eventLines = @([IO.File]::ReadAllLines((Join-Path $dir 'claude-events.jsonl'), $utf8))
    Assert-True ($eventLines.Count -eq ($successLines | Where-Object { $_ }).Count) 'every non-empty line saved to the raw event log'
    Assert-True ($run.State.ResultLine -ceq $successLines[-1]) 'raw result line kept verbatim'
    $joined = $run.Messages -join "`n"
    Assert-True ($joined.Contains('Claude session started (model claude-test-model)')) 'init event shown'
    Assert-True ($joined.Contains('Tool Write: src\app.ps1')) 'Write shows a repository-relative path'
    Assert-True ($joined.Contains('Tool Bash: running command')) 'multi-line Bash command shown generically'
    Assert-True (-not $joined.Contains('tests.ps1') -and -not $joined.Contains('Remove-Item')) 'Bash command arguments not shown'
    Assert-True ($joined.Contains('Tool Edit: src\app.ps1')) 'Edit shows the path only'
    Assert-True ($joined.Contains('Tool reported an error or was denied')) 'tool error is reported without output'
    Assert-True ($joined.Contains('Submitting the structured report')) 'StructuredOutput is summarized'
    Assert-True ($joined.Contains('Claude finished: success (5 turns, USD 0.1234, 65.4s)')) 'result summary shown'
    foreach ($canary in @($briefSecret, $fileContentCanary, $toolOutputCanary, $thinkingCanary, 'Implemented the feature', 'run tests', '{"')) {
        Assert-True (-not $joined.Contains($canary)) "progress does not disclose: $canary"
    }

    # --- Shell commands never disclose their text (regression) ---
    $dir = New-CaseDirectory 'command-disclosure'
    $commandCanary = 'BRIEF-CANARY-7f3a ClaudeCX live progress smoke test'
    $commandSecret = 'sk-livesmoketestsecretvalue1234'
    $leakyCommands = @(
        "printf '$commandCanary.\n' > hello.txt && od -c hello.txt && git status --porcelain",
        "npm test -- --grep `"$commandCanary`" --token=$commandSecret",
        "API_KEY=$commandSecret npm run deploy-check $commandCanary",
        "git commit -m `"$commandCanary`" --author $commandSecret",
        "`"C:\Program Files\nodejs\npm.cmd`" run $commandCanary",
        "./scripts/run.sh $commandCanary $commandSecret",
        "pwsh -Command `"Write-Output '$commandCanary'`"",
        "python -c `"print('$commandCanary')`"`nexit 0",
        "cat <<EOF > notes.md`n$commandCanary`nEOF",
        "curl https://example.com/${commandCanary}?key=$commandSecret"
    )
    $commandLines = @(foreach ($index in 0..($leakyCommands.Count - 1)) {
            foreach ($tool in @('Bash', 'PowerShell')) {
                ConvertTo-Line ([ordered]@{ type = 'assistant'; message = [ordered]@{ content = @(
                            [ordered]@{ type = 'tool_use'; id = "c$index$tool"; name = $tool; input = [ordered]@{ command = $leakyCommands[$index]; description = $commandCanary } }) } })
            }
        })
    $run = Invoke-Lines -Directory $dir -Lines $commandLines
    $sink = New-ClaudeCXProgressSink -Mode 'None' -ProgressPath (Join-Path $dir 'progress.log') -DonePath (Join-Path $dir 'progress.done')
    foreach ($message in $run.Messages) { Write-ClaudeCXProgress -Sink $sink -Message $message }
    Complete-ClaudeCXProgress -Sink $sink -Status 'success' -Message 'done'
    $progressText = [IO.File]::ReadAllText((Join-Path $dir 'progress.log'), $utf8)
    $joined = $run.Messages -join "`n"
    foreach ($leak in @('BRIEF-CANARY-7f3a', 'live progress smoke', $commandSecret, 'livesmoketest', 'hello.txt', 'porcelain', '--grep', 'API_KEY',
            'deploy-check', 'nodejs', 'run.sh', 'Write-Output', 'print(', 'notes.md', 'example.com', '-m ', '>', '&&', "'", '"')) {
        Assert-True (-not $joined.Contains($leak) -and -not $progressText.Contains($leak)) "command text not disclosed: $leak"
    }
    Assert-True (@($run.Messages | Where-Object { $_ -notmatch '^Tool (Bash|PowerShell): running (command|[a-z0-9]+)$' }).Count -eq 0) 'every shell message is a bare activity line'
    Assert-True ([IO.File]::ReadAllText((Join-Path $dir 'claude-events.jsonl'), $utf8).Contains('BRIEF-CANARY-7f3a')) 'raw command kept only in the event log'
    $expectedActivity = [ordered]@{
        'npm test' = 'running npm'; 'git status --porcelain' = 'running git'; 'pwsh.exe -NoProfile -File x.ps1' = 'running pwsh'
        'printf hi' = 'running command'; 'FOO=1 npm test' = 'running command'; '"npm" test' = 'running command'
        'C:\tools\npm.exe test' = 'running command'; './npm test' = 'running command'; "npm test`nnpm run build" = 'running command'
        '' = 'running command'; 'npm=1' = 'running command'
    }
    foreach ($entry in $expectedActivity.GetEnumerator()) {
        $actual = Get-ClaudeCXCommandActivity -Command $entry.Key
        Assert-True ($actual -ceq $entry.Value) "command activity for '$($entry.Key)' is '$($entry.Value)' ($actual)"
    }
    Assert-True ((Get-ClaudeCXCommandActivity -Command $null) -ceq 'running command') 'null command shown generically'
    Assert-True ((Get-ClaudeCXCommandActivity -Command 42) -ceq 'running command') 'non-string command shown generically'

    # --- Compatible result fallback ---
    $dir = New-CaseDirectory 'result-fallback'
    $reportJson = $report | ConvertTo-Json -Depth 10 -Compress
    $run = Invoke-Lines -Directory $dir -Lines @((ConvertTo-Line ([ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = $reportJson })))
    $extracted = Get-ClaudeCXStructuredReport -Outer $run.State.ResultEvent
    Assert-True ($null -ne $extracted -and $extracted.summary -ceq 'Implemented the feature.') 'JSON result string fallback extracted'
    $run = Invoke-Lines -Directory $dir -Lines @((ConvertTo-Line ([ordered]@{ type = 'result'; subtype = 'success'; result = 'plain prose, not JSON' })))
    Assert-True ($null -eq (Get-ClaudeCXStructuredReport -Outer $run.State.ResultEvent)) 'non-JSON result yields no report'

    # --- Failure result extraction ---
    $dir = New-CaseDirectory 'failure'
    $run = Invoke-Lines -Directory $dir -Lines @(
        (ConvertTo-Line ([ordered]@{ type = 'system'; subtype = 'init' })),
        (ConvertTo-Line ([ordered]@{ type = 'result'; subtype = 'error_max_turns'; is_error = $true; num_turns = 1 })))
    $message = Get-ThrownMessage { Assert-ClaudeCXResultSuccess -Outer $run.State.ResultEvent -ExitCode 1 -EventsPath 'E.jsonl' -StderrPath 'S.txt' }
    Assert-True ($null -ne $message -and $message.Contains("subtype='error_max_turns'") -and $message.Contains('E.jsonl')) "max-turns result fails closed ($message)"
    Assert-True (($run.Messages -join "`n").Contains('Claude finished with an error: error_max_turns')) 'failure result shown in progress'
    $okEvent = $successLines[-1] | ConvertFrom-Json
    Assert-True ($null -ne (Get-ThrownMessage { Assert-ClaudeCXResultSuccess -Outer $okEvent -ExitCode 2 -EventsPath 'E' -StderrPath 'S' })) 'non-zero exit fails closed despite a success event'
    $errEvent = (ConvertTo-Line ([ordered]@{ type = 'result'; subtype = 'success'; is_error = $true })) | ConvertFrom-Json
    Assert-True ($null -ne (Get-ThrownMessage { Assert-ClaudeCXResultSuccess -Outer $errEvent -ExitCode 0 -EventsPath 'E' -StderrPath 'S' })) 'is_error fails closed'
    $message = Get-ThrownMessage { Assert-ClaudeCXResultSuccess -Outer $null -ExitCode 0 -EventsPath 'E' -StderrPath 'S' }
    Assert-True ($null -ne $message -and $message.Contains('no stream-json result event')) 'missing result event fails closed'

    # --- Malformed JSONL ---
    $dir = New-CaseDirectory 'malformed'
    $badLine = '{"type":"assistant","message":'
    $message = Get-ThrownMessage { Invoke-Lines -Directory $dir -Lines @((ConvertTo-Line ([ordered]@{ type = 'system'; subtype = 'init' })), $badLine) }
    $eventsFile = Join-Path $dir 'claude-events.jsonl'
    Assert-True ($null -ne $message -and $message.Contains('malformed stream-json line (2)') -and $message.Contains($eventsFile)) "malformed line fails closed with the event log path ($message)"
    Assert-True ([IO.File]::ReadAllText($eventsFile, $utf8).Contains($badLine)) 'malformed raw line saved to the event log'
    $dir = New-CaseDirectory 'non-object'
    Assert-True ($null -ne (Get-ThrownMessage { Invoke-Lines -Directory $dir -Lines @('[1,2,3]') })) 'non-object JSON line fails closed'
    $dir = New-CaseDirectory 'json-null'
    Assert-True ($null -ne (Get-ThrownMessage { Invoke-Lines -Directory $dir -Lines @('null') })) 'JSON null line fails closed'

    # --- Unknown and missing optional fields ---
    $dir = New-CaseDirectory 'tolerant'
    $tolerantLines = @('{}', '{"type":"future_event","payload":{"x":1}}', '{"type":"assistant"}', '{"type":"assistant","message":{}}',
        '{"type":"assistant","message":{"content":"plain string"}}', '{"type":"assistant","message":{"content":[null,1,"x",{"type":"tool_use"}]}}',
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":null}]}}',
        '{"type":"user","message":{"content":[{"type":"tool_result"}]}}', '{"type":"system"}', '{"type":"system","subtype":"compact_boundary"}',
        '{"type":"stream_event","event":{"type":"content_block_delta"}}', '{"type":"result"}')
    $message = Get-ThrownMessage { $script:tolerant = Invoke-Lines -Directory $dir -Lines $tolerantLines }
    Assert-True ($null -eq $message) "unknown types and missing fields do not crash ($message)"
    if ($null -eq $message) {
        $joined = $script:tolerant.Messages -join "`n"
        Assert-True ($script:tolerant.State.UnknownEventCount -eq 2) 'unknown event types counted, not displayed'
        Assert-True (-not $joined.Contains('future_event') -and -not $joined.Contains('payload')) 'unknown event payload not displayed'
        Assert-True ($joined.Contains('Tool unknown') -and $joined.Contains('Tool Read')) 'tool_use without name or input handled'
        Assert-True ($joined.Contains('Claude system event: compact_boundary')) 'other system subtypes summarized'
        Assert-True ($joined.Contains('Claude finished: success')) 'result without optional fields summarized'
        Assert-True ($null -ne $script:tolerant.State.ResultEvent) 'minimal result event captured'
    }

    # --- Sanitization and truncation ---
    Write-Host ''
    Write-Host '[sanitization]'
    $escape = [char]27
    $dirty = "ls ${escape}[31mred${escape}[0m`t`u{202E}tab --token=abc123 password: hunter2 sk-abcdefghijklmnop https://user:pa55@example.com/x"
    $clean = ConvertTo-ClaudeCXSafeText -Text $dirty -MaxLength 300
    Assert-True (-not $clean.Contains([string]$escape) -and -not $clean.Contains("`t") -and -not $clean.Contains("`u{202E}")) "escape and control characters removed ($clean)"
    foreach ($secret in @('abc123', 'hunter2', 'sk-abcdefghijklmnop', 'pa55')) {
        Assert-True (-not $clean.Contains($secret)) "secret-like value redacted: $secret"
    }
    $longToken = 'Ab1' * 20
    Assert-True (-not (ConvertTo-ClaudeCXSafeText -Text "curl -H x $longToken").Contains($longToken)) 'long opaque tokens redacted'
    $long = ConvertTo-ClaudeCXSafeText -Text ('x' * 500) -MaxLength 50
    Assert-True ($long.Length -eq 50 -and $long.EndsWith('...')) 'long text truncated to the limit'
    $deepPath = 'C:\work\demo-repo\' + (('very-long-folder-name\' * 10)) + 'final-file.ts'
    $safePath = Get-ClaudeCXSafePath -Path $deepPath -RepositoryRoot 'C:\work\demo-repo'
    Assert-True ($safePath.Length -le 100 -and $safePath.StartsWith('...') -and $safePath.EndsWith('final-file.ts')) "long path keeps its tail ($safePath)"
    Assert-True ((Get-ClaudeCXSafePath -Path 'C:/work/demo-repo/a/b.txt' -RepositoryRoot 'C:\work\demo-repo') -ceq 'a/b.txt') 'forward-slash repository path made relative'
    $grep = Get-ClaudeCXToolSummary -ToolUse ((ConvertTo-Line ([ordered]@{ name = 'Grep'; input = [ordered]@{ pattern = 'needle'; path = 'C:\work\demo-repo\src' } })) | ConvertFrom-Json) -RepositoryRoot 'C:\work\demo-repo'
    Assert-True ($grep -ceq 'Tool Grep: searching src') "search summary hides the pattern ($grep)"
    $fetch = Get-ClaudeCXToolSummary -ToolUse ((ConvertTo-Line ([ordered]@{ name = 'WebFetch'; input = [ordered]@{ url = 'https://example.com/a?token=zzz'; prompt = $briefSecret } })) | ConvertFrom-Json)
    Assert-True ($fetch -ceq 'Tool WebFetch: requesting URL') "URL and host hidden ($fetch)"

    # --- Free-form tool inputs never disclosed (regression) ---
    $dir = New-CaseDirectory 'free-form-disclosure'
    $inputCanary = 'INPUT-CANARY-91c2 exact brief sentence'
    $inputSecret = 'ghp_abcdefghijklmnopqrstuvwxyz0123'
    $freeFormTools = @(
        [ordered]@{ name = 'Grep'; input = [ordered]@{ pattern = "$inputCanary|$inputSecret"; glob = "*$inputCanary*"; output_mode = 'content'; path = 'C:\work\demo-repo\src\lib' } },
        [ordered]@{ name = 'Grep'; input = [ordered]@{ pattern = $inputCanary; type = 'js' } },
        [ordered]@{ name = 'Glob'; input = [ordered]@{ pattern = "**/$inputCanary*.ts" } },
        [ordered]@{ name = 'WebFetch'; input = [ordered]@{ url = "https://internal-canary-host.example.org/$inputCanary"; prompt = $inputCanary } },
        [ordered]@{ name = 'WebFetch'; input = [ordered]@{ url = 'not a valid url canary-relative-host'; prompt = $inputCanary } },
        [ordered]@{ name = 'WebSearch'; input = [ordered]@{ query = "$inputCanary site:internal-canary-host.example.org"; allowed_domains = @('internal-canary-host.example.org') } },
        [ordered]@{ name = 'Task'; input = [ordered]@{ prompt = $inputCanary; description = $inputCanary; subagent_type = $inputCanary } },
        [ordered]@{ name = 'TodoWrite'; input = [ordered]@{ todos = @([ordered]@{ content = $inputCanary; status = 'pending'; activeForm = $inputCanary }) } },
        [ordered]@{ name = 'FutureTool'; input = [ordered]@{ anything = $inputCanary; nested = [ordered]@{ value = $inputSecret } } },
        [ordered]@{ name = 'Read'; input = [ordered]@{ file_path = 'C:\work\demo-repo\docs\guide.md'; offset = 10; limit = $inputCanary } },
        [ordered]@{ name = 'LS'; input = [ordered]@{ path = 'C:\work\demo-repo\src'; ignore = @($inputCanary) } }
    )
    $toolLines = @(foreach ($index in 0..($freeFormTools.Count - 1)) {
            ConvertTo-Line ([ordered]@{ type = 'assistant'; message = [ordered]@{ content = @(
                        [ordered]@{ type = 'tool_use'; id = "f$index"; name = $freeFormTools[$index].name; input = $freeFormTools[$index].input }) } })
        })
    $run = Invoke-Lines -Directory $dir -Lines $toolLines
    $sink = New-ClaudeCXProgressSink -Mode 'None' -ProgressPath (Join-Path $dir 'progress.log') -DonePath (Join-Path $dir 'progress.done')
    foreach ($message in $run.Messages) { Write-ClaudeCXProgress -Sink $sink -Message $message }
    Complete-ClaudeCXProgress -Sink $sink -Status 'success' -Message 'done'
    $progressText = [IO.File]::ReadAllText((Join-Path $dir 'progress.log'), $utf8)
    $joined = $run.Messages -join "`n"
    foreach ($leak in @('INPUT-CANARY-91c2', 'exact brief sentence', $inputSecret, 'ghp_', 'internal-canary-host', 'example.org', 'canary-relative-host',
            'https', 'site:', '*.ts', '**', 'content', 'subagent', 'nested', "'")) {
        Assert-True (-not $joined.Contains($leak) -and -not $progressText.Contains($leak)) "free-form tool input not disclosed: $leak"
    }
    $expectedToolMessages = @('Tool Grep: searching src\lib', 'Tool Grep: searching', 'Tool Glob: searching', 'Tool WebFetch: requesting URL',
        'Tool WebFetch: requesting URL', 'Tool WebSearch: searching', 'Tool Task', 'Tool TodoWrite: 1 items', 'Tool FutureTool',
        'Tool Read: docs\guide.md', 'Tool LS: src')
    Assert-True (($run.Messages -join '|') -ceq ($expectedToolMessages -join '|')) "only tool names, generic labels, and safe paths are shown ($($run.Messages -join '|'))"
    Assert-True ([IO.File]::ReadAllText((Join-Path $dir 'claude-events.jsonl'), $utf8).Contains('INPUT-CANARY-91c2')) 'raw tool input kept only in the event log'
    $task = Get-ClaudeCXToolSummary -ToolUse ((ConvertTo-Line ([ordered]@{ name = "Ta`e[2Jsk"; input = [ordered]@{ prompt = $briefSecret; description = $briefSecret } })) | ConvertFrom-Json)
    Assert-True ($task -ceq 'Tool Ta2Jsk') "tool name sanitized and prompt omitted ($task)"

    # --- Progress sink: dedupe, completion marker, idempotence ---
    $dir = New-CaseDirectory 'sink'
    $errorWriter = [IO.StringWriter]::new()
    $sink = New-ClaudeCXProgressSink -Mode 'None' -ProgressPath (Join-Path $dir 'progress.log') -DonePath (Join-Path $dir 'progress.done') -ErrorWriter $errorWriter
    Write-ClaudeCXProgress -Sink $sink -Message 'Claude is working'
    Write-ClaudeCXProgress -Sink $sink -Message 'Claude is working'
    Write-ClaudeCXProgress -Sink $sink -Message "multi`nline"
    Complete-ClaudeCXProgress -Sink $sink -Status 'failed' -Message 'Claude Code exceeded the 30-second timeout and was terminated.'
    Complete-ClaudeCXProgress -Sink $sink -Status 'success' -Message 'ignored'
    Write-ClaudeCXProgress -Sink $sink -Message 'after completion'
    $logLines = @([IO.File]::ReadAllLines((Join-Path $dir 'progress.log'), $utf8))
    Assert-True (@($logLines | Where-Object { $_.EndsWith('Claude is working') }).Count -eq 1) 'consecutive duplicate progress lines suppressed'
    Assert-True (@($logLines | Where-Object { $_.Contains('after completion') }).Count -eq 0) 'no progress written after completion'
    $marker = Get-Content -Raw -LiteralPath (Join-Path $dir 'progress.done') | ConvertFrom-Json
    Assert-True ($marker.status -ceq 'failed' -and ([string]$marker.message).Contains('timeout')) 'completion marker records the first (failure) status'
    Assert-True ($logLines[-1].Contains('ClaudeCX run failed: Claude Code exceeded')) 'failure reason written to the progress log'
    Assert-True ($errorWriter.ToString() -eq '') 'None mode writes nothing to stderr'
    Assert-True (@(Get-ChildItem -LiteralPath $dir -Filter '*.tmp').Count -eq 0) 'no temporary marker files left behind'

    # --- Console mode keeps stdout clean ---
    $dir = New-CaseDirectory 'console-mode'
    $childScript = Join-Path $dir 'console-child.ps1'
    [IO.File]::WriteAllText($childScript, @'
param([string]$ModulePath, [string]$Directory, [string]$Mode)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$sink = New-ClaudeCXProgressSink -Mode $Mode -ProgressPath (Join-Path $Directory "$Mode.log") -DonePath (Join-Path $Directory "$Mode.done")
Write-ClaudeCXProgress -Sink $sink -Message 'Tool Bash: running npm'
Complete-ClaudeCXProgress -Sink $sink -Status 'success' -Message 'done'
'{"status":"success"}'
'@, $utf8)
    foreach ($mode in @('Console', 'None', 'Window')) {
        $result = Wait-Child (Start-Child @('-NoProfile', '-NonInteractive', '-File', $childScript, '-ModulePath', $progressModule, '-Directory', $dir, '-Mode', $mode))
        Assert-True ($result.ExitCode -eq 0) "$mode child exits 0 ($($result.Stderr))"
        Assert-True ($result.Stdout.Trim() -ceq '{"status":"success"}') "$mode mode leaves only the final JSON on stdout"
        if ($mode -eq 'Console') {
            Assert-True ($result.Stderr.Contains('[claudecx]') -and $result.Stderr.Contains('Tool Bash: running npm')) 'Console mode writes progress to stderr'
        }
        else {
            Assert-True (-not $result.Stderr.Contains('[claudecx]')) "$mode mode writes no progress to stderr"
        }
    }

    # --- Monitor: success, failure, bridge exit, and being closed ---
    $dir = New-CaseDirectory 'monitor-success'
    $sink = New-ClaudeCXProgressSink -Mode 'Window' -ProgressPath (Join-Path $dir 'progress.log') -DonePath (Join-Path $dir 'progress.done')
    $monitor = Start-Child (Get-MonitorArguments -Directory $dir -BridgeProcessId $PID)
    Write-ClaudeCXProgress -Sink $sink -Message 'Tool Read: src\app.ps1'
    Start-Sleep -Milliseconds 300
    Write-ClaudeCXProgress -Sink $sink -Message 'Claude finished: success'
    Complete-ClaudeCXProgress -Sink $sink -Status 'success' -Message 'Structured report saved.'
    $result = Wait-Child $monitor
    Assert-True ($result.Exited -and $result.ExitCode -eq 0) "monitor exits 0 after a success marker ($($result.Stderr))"
    Assert-True ($result.Stdout.Contains('Tool Read: src\app.ps1') -and $result.Stdout.Contains('ClaudeCX run complete')) 'monitor shows progress and completion'
    Assert-True ($result.Stdout.Contains('demo-repo') -and $result.Stdout.Contains('Closing this window does not stop the run')) 'monitor shows repository context and close notice'

    $dir = New-CaseDirectory 'monitor-failure'
    $sink = New-ClaudeCXProgressSink -Mode 'Window' -ProgressPath (Join-Path $dir 'progress.log') -DonePath (Join-Path $dir 'progress.done')
    $monitor = Start-Child (Get-MonitorArguments -Directory $dir -BridgeProcessId $PID)
    Complete-ClaudeCXProgress -Sink $sink -Status 'failed' -Message 'Claude Code exceeded the 30-second timeout and was terminated.'
    $result = Wait-Child $monitor
    Assert-True ($result.Exited -and $result.ExitCode -eq 1) 'monitor exits 1 after a failure marker'
    Assert-True ($result.Stdout.Contains('ClaudeCX run FAILED') -and $result.Stdout.Contains('timeout')) 'monitor shows the failure reason'

    $dir = New-CaseDirectory 'monitor-bridge-gone'
    $probe = Start-Child @('-NoProfile', '-NonInteractive', '-Command', 'exit 0')
    $gonePid = $probe.Process.Id
    $null = Wait-Child $probe
    $result = Wait-Child (Start-Child (Get-MonitorArguments -Directory $dir -BridgeProcessId $gonePid))
    Assert-True ($result.Exited -and $result.ExitCode -eq 1) 'monitor stops when the bridge exits without a marker'
    Assert-True ($result.Stdout.Contains('without signalling completion')) 'monitor explains the missing completion signal'

    $dir = New-CaseDirectory 'monitor-closed'
    $sink = New-ClaudeCXProgressSink -Mode 'Window' -ProgressPath (Join-Path $dir 'progress.log') -DonePath (Join-Path $dir 'progress.done')
    $monitor = Start-Child (Get-MonitorArguments -Directory $dir -BridgeProcessId $PID)
    Start-Sleep -Milliseconds 800
    $monitor.Process.Kill($true)
    $null = Wait-Child $monitor
    $message = Get-ThrownMessage {
        Write-ClaudeCXProgress -Sink $sink -Message 'Tool Bash: running npm'
        Complete-ClaudeCXProgress -Sink $sink -Status 'success' -Message 'done'
    }
    Assert-True ($null -eq $message) "closing the monitor does not disturb the bridge ($message)"
    Assert-True (Test-Path -LiteralPath (Join-Path $dir 'progress.done') -PathType Leaf) 'completion marker still written after the monitor closed'

    # --- Packaging ---
    Write-Host ''
    Write-Host '[packaging]'
    $required = @(Get-ClaudeCXRequiredSkillFiles)
    foreach ($file in @('scripts/ClaudeCX.Progress.psm1', 'scripts/watch-progress.ps1')) {
        Assert-True ($required -contains $file) "required skill files include $file"
        Assert-True (Test-Path -LiteralPath (Join-Path $skillRoot $file) -PathType Leaf) "packaged skill contains $file"
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host "test-progress: $($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    foreach ($failure in $script:failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "test-progress: all $($script:passed) checks passed" -ForegroundColor Green
