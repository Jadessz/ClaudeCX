#Requires -Version 7.2
# Stream-json parsing, progress formatting, and progress sinks for the ClaudeCX bridge.
# Progress lines are deliberately terse: tool names and short, sanitized path summaries only.
# Shell command text, file contents, tool output, thinking, prompts, and raw JSON are never shown.

Set-StrictMode -Version Latest

$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:AnsiPattern = [Regex]::new('\x1B(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)?|[@-Z\\-_])')
$script:ControlPattern = [Regex]::new('[\p{Cc}\p{Cf}  ]+')
# Best-effort redaction of secret-looking values. Pattern and replacement pairs, applied in order.
$script:SecretRules = @(
    @([Regex]::new('(?i)\b(authorization|bearer|api[_-]?key|access[_-]?key|client[_-]?secret|secret|token|password|passwd|pwd|credentials?)(\s*[:=]\s*|\s+)("[^"]*"|''[^'']*''|\S+)'), '$1=<redacted>'),
    @([Regex]::new('\b(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})'), '<redacted>'),
    @([Regex]::new('://[^/\s:@]+:[^/\s@]+@'), '://<redacted>@'),
    @([Regex]::new('(?=[A-Za-z0-9+_=-]*\d)(?=[A-Za-z0-9+_=-]*[A-Za-z])[A-Za-z0-9+_=-]{40,}'), '<redacted>')
)
# Well-known program names that may be shown for a shell command. Arguments are never shown.
$script:ShownPrograms = @(
    'bun', 'bundle', 'cargo', 'cmake', 'composer', 'deno', 'dotnet', 'eslint', 'git', 'go', 'gradle', 'jest',
    'make', 'mvn', 'node', 'npm', 'npx', 'php', 'pip', 'pip3', 'pnpm', 'powershell', 'prettier', 'pwsh', 'py',
    'pytest', 'python', 'python3', 'rake', 'ruby', 'rustc', 'tsc', 'vitest', 'yarn'
)
$script:ProgramTokenPattern = [Regex]::new('^(?<name>[A-Za-z][A-Za-z0-9_-]*)(\.exe)?$')

function Get-ClaudeCXPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object -or $Object -isnot [Management.Automation.PSCustomObject]) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    # The comma keeps single-element arrays from being unrolled into their only element.
    return ,$property.Value
}

function ConvertTo-ClaudeCXSafeText {
    # Single line, no control or escape sequences, secret-like tokens redacted, truncated.
    param(
        [AllowNull()][AllowEmptyString()][object]$Text,
        [ValidateRange(8, 4000)][int]$MaxLength = 120,
        [switch]$KeepTail
    )

    if ($null -eq $Text) {
        return ''
    }
    $value = [string]$Text
    $lines = @($value -split "`r?`n" | Where-Object { $_.Trim() })
    $extraLines = [Math]::Max(0, $lines.Count - 1)
    $value = if ($lines.Count -gt 0) { $lines[0] } else { '' }
    $value = $script:AnsiPattern.Replace($value, '')
    $value = $script:ControlPattern.Replace($value, ' ')
    foreach ($rule in $script:SecretRules) {
        $value = $rule[0].Replace($value, $rule[1])
    }
    $value = ([Regex]::Replace($value, '\s+', ' ')).Trim()
    if ($extraLines -gt 0) {
        $value = "$value (+$extraLines more lines)"
    }
    if ($value.Length -gt $MaxLength) {
        if ($KeepTail) {
            $value = '...' + $value.Substring($value.Length - ($MaxLength - 3))
        }
        else {
            $value = $value.Substring(0, $MaxLength - 3) + '...'
        }
    }
    return $value
}

function Get-ClaudeCXSafePath {
    # Repository-relative when possible; keeps the informative tail when truncating.
    param(
        [AllowNull()][object]$Path,
        [AllowNull()][AllowEmptyString()][string]$RepositoryRoot
    )

    if ($null -eq $Path -or $Path -isnot [string] -or -not $Path.Trim()) {
        return ''
    }
    $value = $Path.Trim()
    if ($RepositoryRoot) {
        $root = $RepositoryRoot.TrimEnd('\', '/')
        foreach ($candidate in @($root, $root.Replace('\', '/'))) {
            if ($value.Equals($candidate, [StringComparison]::OrdinalIgnoreCase)) {
                $value = '.'
                break
            }
            foreach ($separator in @('\', '/')) {
                if ($value.StartsWith($candidate + $separator, [StringComparison]::OrdinalIgnoreCase)) {
                    $value = $value.Substring($candidate.Length + 1)
                    break
                }
            }
        }
    }
    return ConvertTo-ClaudeCXSafeText -Text $value -MaxLength 100 -KeepTail
}

function Get-ClaudeCXCommandActivity {
    # 'running <program>' only when the first token is a bare, allowlisted program name and the
    # command is a single line; otherwise the generic 'running command'. Never returns arguments.
    param([AllowNull()][object]$Command)

    $generic = 'running command'
    if ($Command -isnot [string]) {
        return $generic
    }
    $trimmed = $Command.Trim()
    if (-not $trimmed -or $trimmed.Contains("`n") -or $trimmed.Contains("`r")) {
        return $generic
    }
    $firstToken = ($trimmed -split '\s+', 2)[0]
    $match = $script:ProgramTokenPattern.Match($firstToken)
    if (-not $match.Success) {
        return $generic
    }
    $program = $match.Groups['name'].Value.ToLowerInvariant()
    if ($script:ShownPrograms -notcontains $program) {
        return $generic
    }
    return "running $program"
}

function Get-ClaudeCXToolSummary {
    # One concise line per tool call. Only allowlisted, non-content input fields are read.
    param(
        [AllowNull()][object]$ToolUse,
        [AllowNull()][AllowEmptyString()][string]$RepositoryRoot
    )

    $rawName = Get-ClaudeCXPropertyValue -Object $ToolUse -Name 'name'
    $name = if ($rawName -is [string] -and $rawName) { [Regex]::Replace($rawName, '[^A-Za-z0-9_.:-]', '') } else { '' }
    if (-not $name) { $name = 'unknown' }
    if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
    $toolInput = Get-ClaudeCXPropertyValue -Object $ToolUse -Name 'input'

    if ($name -eq 'StructuredOutput') {
        return 'Submitting the structured report'
    }

    $command = Get-ClaudeCXPropertyValue -Object $toolInput -Name 'command'
    if ($null -ne $command) {
        # The raw command stays in claude-events.jsonl only.
        return "Tool ${name}: $(Get-ClaudeCXCommandActivity -Command $command)"
    }
    foreach ($field in @('file_path', 'notebook_path')) {
        $pathValue = Get-ClaudeCXPropertyValue -Object $toolInput -Name $field
        $safePath = Get-ClaudeCXSafePath -Path $pathValue -RepositoryRoot $RepositoryRoot
        if ($safePath) {
            return "Tool ${name}: $safePath"
        }
    }
    # Free-form inputs (patterns, queries, URLs, prompts) are only used to pick a generic label.
    $safeDirectory = Get-ClaudeCXSafePath -Path (Get-ClaudeCXPropertyValue -Object $toolInput -Name 'path') -RepositoryRoot $RepositoryRoot
    if ($null -ne (Get-ClaudeCXPropertyValue -Object $toolInput -Name 'url')) {
        return "Tool ${name}: requesting URL"
    }
    if ($null -ne (Get-ClaudeCXPropertyValue -Object $toolInput -Name 'pattern') -or
        $null -ne (Get-ClaudeCXPropertyValue -Object $toolInput -Name 'query')) {
        if ($safeDirectory) {
            return "Tool ${name}: searching $safeDirectory"
        }
        return "Tool ${name}: searching"
    }
    $todos = Get-ClaudeCXPropertyValue -Object $toolInput -Name 'todos'
    if ($null -ne $todos -and $todos -is [Array]) {
        return "Tool ${name}: $(@($todos).Count) items"
    }
    if ($safeDirectory) {
        return "Tool ${name}: $safeDirectory"
    }
    return "Tool $name"
}

function Format-ClaudeCXStreamEvent {
    # Returns zero or more progress messages for one parsed stream-json event.
    param(
        [Parameter(Mandatory = $true)][object]$StreamEvent,
        [AllowNull()][AllowEmptyString()][string]$RepositoryRoot
    )

    $messages = [Collections.Generic.List[string]]::new()
    $type = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'type'
    $subtype = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'subtype'
    $safeSubtype = if ($subtype -is [string]) { [Regex]::Replace($subtype, '[^A-Za-z0-9_.-]', '') } else { '' }
    if ($safeSubtype.Length -gt 40) { $safeSubtype = $safeSubtype.Substring(0, 40) }

    switch ($type) {
        'system' {
            if ($safeSubtype -eq 'init') {
                $model = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'model'
                if ($model -is [string] -and $model) {
                    $messages.Add("Claude session started (model $(ConvertTo-ClaudeCXSafeText -Text $model -MaxLength 60))")
                }
                else {
                    $messages.Add('Claude session started')
                }
            }
            elseif ($safeSubtype) {
                $messages.Add("Claude system event: $safeSubtype")
            }
        }
        'assistant' {
            $message = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'message'
            $content = Get-ClaudeCXPropertyValue -Object $message -Name 'content'
            foreach ($block in @($content | Where-Object { $null -ne $_ })) {
                $blockType = Get-ClaudeCXPropertyValue -Object $block -Name 'type'
                if ($blockType -eq 'tool_use') {
                    $messages.Add((Get-ClaudeCXToolSummary -ToolUse $block -RepositoryRoot $RepositoryRoot))
                }
                elseif ($blockType -eq 'text') {
                    $messages.Add('Claude is working (response received)')
                }
            }
        }
        'user' {
            $message = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'message'
            $content = Get-ClaudeCXPropertyValue -Object $message -Name 'content'
            if ($content -isnot [string]) {
                foreach ($block in @($content | Where-Object { $null -ne $_ })) {
                    if ((Get-ClaudeCXPropertyValue -Object $block -Name 'type') -eq 'tool_result' -and
                        (Get-ClaudeCXPropertyValue -Object $block -Name 'is_error') -eq $true) {
                        $messages.Add('Tool reported an error or was denied (details in the event log)')
                    }
                }
            }
        }
        'result' {
            $details = [Collections.Generic.List[string]]::new()
            $turns = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'num_turns'
            if ($turns -is [ValueType]) { $details.Add("$([int64]$turns) turns") }
            $cost = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'total_cost_usd'
            if ($cost -is [ValueType]) { $details.Add('USD ' + ([decimal]$cost).ToString('0.00##', [Globalization.CultureInfo]::InvariantCulture)) }
            $duration = Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'duration_ms'
            if ($duration -is [ValueType]) { $details.Add(([Math]::Round([double]$duration / 1000.0, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) + 's') }
            $suffix = if ($details.Count -gt 0) { " ($($details -join ', '))" } else { '' }
            $isError = (Get-ClaudeCXPropertyValue -Object $StreamEvent -Name 'is_error') -eq $true
            if (-not $isError -and (-not $safeSubtype -or $safeSubtype -eq 'success')) {
                $messages.Add("Claude finished: success$suffix")
            }
            else {
                $label = if ($safeSubtype) { $safeSubtype } else { 'error' }
                $messages.Add("Claude finished with an error: $label$suffix")
            }
        }
    }
    return $messages.ToArray()
}

function New-ClaudeCXStreamState {
    # Collects the raw JSONL event log and the final result event.
    param(
        [Parameter(Mandatory = $true)][string]$EventsPath,
        [AllowNull()][AllowEmptyString()][string]$RepositoryRoot
    )

    $writer = [IO.StreamWriter]::new($EventsPath, $true, $script:Utf8)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    return [pscustomobject]@{
        EventsPath = $EventsPath
        RepositoryRoot = $RepositoryRoot
        Writer = $writer
        LineCount = 0
        ResultEvent = $null
        ResultLine = $null
        UnknownEventCount = 0
    }
}

function Add-ClaudeCXStreamLine {
    # Records one stdout line. Returns progress messages. Throws on a malformed non-empty line.
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [AllowNull()][AllowEmptyString()][string]$Line
    )

    if ($null -eq $Line -or -not $Line.Trim()) {
        return @()
    }
    $State.LineCount++
    if ($null -ne $State.Writer) {
        $State.Writer.WriteLine($Line)
    }
    $parsed = $null
    try {
        $parsed = $Line | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        $parsed = $null
    }
    if ($parsed -isnot [Management.Automation.PSCustomObject]) {
        throw "Claude Code emitted a malformed stream-json line ($($State.LineCount)). The bridge failed closed. See $($State.EventsPath)"
    }
    $type = Get-ClaudeCXPropertyValue -Object $parsed -Name 'type'
    if ($type -eq 'result') {
        $State.ResultEvent = $parsed
        $State.ResultLine = $Line
    }
    elseif ($type -notin @('system', 'assistant', 'user', 'stream_event')) {
        $State.UnknownEventCount++
    }
    return @(Format-ClaudeCXStreamEvent -StreamEvent $parsed -RepositoryRoot $State.RepositoryRoot)
}

function Close-ClaudeCXStreamState {
    param([Parameter(Mandatory = $true)][object]$State)

    if ($null -ne $State.Writer) {
        try { $State.Writer.Dispose() } catch { }
        $State.Writer = $null
    }
}

function Assert-ClaudeCXResultSuccess {
    # Fails closed on a missing result event, a non-zero exit, is_error, or a non-success subtype.
    param(
        [AllowNull()][object]$Outer,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$EventsPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    if ($null -eq $Outer) {
        throw "Claude Code returned no stream-json result event (exit code $ExitCode). See $EventsPath and $StderrPath"
    }
    $isErrorValue = Get-ClaudeCXPropertyValue -Object $Outer -Name 'is_error'
    $subtype = [string](Get-ClaudeCXPropertyValue -Object $Outer -Name 'subtype')
    $isError = ($isErrorValue -eq $true)
    if ($ExitCode -ne 0 -or $isError -or ($subtype -and $subtype -ne 'success')) {
        throw "Claude Code failed closed (exit code $ExitCode, is_error=$isError, subtype='$subtype'). See $EventsPath and $StderrPath"
    }
}

function Get-ClaudeCXStructuredReport {
    # structured_output first, then the compatible result fallback (JSON string or object).
    param([AllowNull()][object]$Outer)

    $report = Get-ClaudeCXPropertyValue -Object $Outer -Name 'structured_output'
    if ($null -eq $report) {
        $resultValue = Get-ClaudeCXPropertyValue -Object $Outer -Name 'result'
        if ($resultValue -is [string]) {
            try { $report = $resultValue | ConvertFrom-Json -Depth 100 -ErrorAction Stop } catch { $report = $null }
        }
        elseif ($null -ne $resultValue) {
            $report = $resultValue
        }
    }
    return $report
}

function New-ClaudeCXProgressSink {
    # Mode Dashboard, Window, and None only write the progress log; Console also writes to stderr, never stdout.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Dashboard', 'Window', 'Console', 'None')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ProgressPath,
        [Parameter(Mandatory = $true)][string]$DonePath,
        [IO.TextWriter]$ErrorWriter
    )

    $writer = [IO.StreamWriter]::new($ProgressPath, $true, $script:Utf8)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    return [pscustomobject]@{
        Mode = $Mode
        ProgressPath = $ProgressPath
        DonePath = $DonePath
        Writer = $writer
        ErrorWriter = $(if ($ErrorWriter) { $ErrorWriter } else { [Console]::Error })
        LastMessage = $null
        Completed = $false
        MonitorProcess = $null
    }
}

function Write-ClaudeCXProgress {
    param(
        [Parameter(Mandatory = $true)][object]$Sink,
        [AllowNull()][AllowEmptyString()][string]$Message
    )

    if ($Sink.Completed) {
        return
    }
    $safe = ConvertTo-ClaudeCXSafeText -Text $Message -MaxLength 300
    if (-not $safe -or $safe -ceq $Sink.LastMessage) {
        return
    }
    $Sink.LastMessage = $safe
    $line = [DateTimeOffset]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + '  ' + $safe
    try { $Sink.Writer.WriteLine($line) } catch { }
    if ($Sink.Mode -eq 'Console') {
        try { $Sink.ErrorWriter.WriteLine("[claudecx] $line") } catch { }
    }
}

function Complete-ClaudeCXProgress {
    # Idempotent. Always writes the completion marker so a monitor never tails forever.
    param(
        [Parameter(Mandatory = $true)][object]$Sink,
        [Parameter(Mandatory = $true)][ValidateSet('success', 'failed', 'stopped')][string]$Status,
        [AllowNull()][AllowEmptyString()][string]$Message
    )

    if ($Sink.Completed) {
        return
    }
    $final = switch ($Status) {
        'success' { 'ClaudeCX run finished successfully' }
        'stopped' { "ClaudeCX run stopped: $Message" }
        default { "ClaudeCX run failed: $Message" }
    }
    Write-ClaudeCXProgress -Sink $Sink -Message $final
    $Sink.Completed = $true
    try { $Sink.Writer.Dispose() } catch { }
    $marker = [ordered]@{
        status = $Status
        message = (ConvertTo-ClaudeCXSafeText -Text $Message -MaxLength 500)
        finished_at = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Compress
    $temporary = "$($Sink.DonePath).$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $marker, $script:Utf8)
        [IO.File]::Move($temporary, $Sink.DonePath, $true)
    }
    catch {
        try { [IO.File]::WriteAllText($Sink.DonePath, $marker, $script:Utf8) } catch { }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-ClaudeCXProgressWindow {
    # Opens the read-only monitor in its own console window. Returns $true on success.
    # The monitor only reads the progress log; it has no handle to Claude's stdin.
    param(
        [Parameter(Mandatory = $true)][object]$Sink,
        [Parameter(Mandatory = $true)][string]$MonitorScriptPath,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$RepositoryName,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$BridgeProcessId
    )

    if (-not $IsWindows) {
        throw 'The progress window is only available on Windows.'
    }
    if (-not (Test-Path -LiteralPath $MonitorScriptPath -PathType Leaf)) {
        throw "Progress monitor script is missing: $MonitorScriptPath"
    }
    $shellPath = [Environment]::ProcessPath
    if (-not $shellPath -or [IO.Path]::GetFileNameWithoutExtension($shellPath) -ne 'pwsh') {
        $pwshCommand = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwshCommand) {
            throw 'pwsh.exe was not found for the progress window.'
        }
        $shellPath = $pwshCommand.Source
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $shellPath
    $startInfo.UseShellExecute = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    foreach ($argument in @(
            '-NoProfile', '-NoLogo', '-File', $MonitorScriptPath,
            '-ProgressPath', $Sink.ProgressPath,
            '-DonePath', $Sink.DonePath,
            '-Title', $Title,
            '-RepositoryName', $RepositoryName,
            '-SessionId', $SessionId,
            '-BridgeProcessId', $BridgeProcessId.ToString([Globalization.CultureInfo]::InvariantCulture))) {
        $startInfo.ArgumentList.Add($argument)
    }
    $monitor = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $monitor) {
        throw 'The progress window process did not start.'
    }
    $Sink.MonitorProcess = $monitor
    return $true
}

Export-ModuleMember -Function @(
    'ConvertTo-ClaudeCXSafeText',
    'Get-ClaudeCXSafePath',
    'Get-ClaudeCXCommandActivity',
    'Get-ClaudeCXToolSummary',
    'Format-ClaudeCXStreamEvent',
    'New-ClaudeCXStreamState',
    'Add-ClaudeCXStreamLine',
    'Close-ClaudeCXStreamState',
    'Assert-ClaudeCXResultSuccess',
    'Get-ClaudeCXStructuredReport',
    'New-ClaudeCXProgressSink',
    'Write-ClaudeCXProgress',
    'Complete-ClaudeCXProgress',
    'Start-ClaudeCXProgressWindow'
)
