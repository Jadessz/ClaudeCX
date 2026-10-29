#Requires -Version 7.2
<#
.SYNOPSIS
Checks that this computer is ready to use ClaudeCX.

.DESCRIPTION
Runs read-only checks and prints a fix for every problem it finds: Windows,
PowerShell, script blocking, Git, Claude Code (found, new enough, signed in),
Codex, the installed skill, the run-log folder, and a default browser for the
dashboard. It never changes Codex or Claude settings. The only thing it writes
is a short-lived test file in %LOCALAPPDATA%\CodexClaude\handoffs, to prove the
bridge can write its logs there.

Exits 0 when nothing failed (warnings allowed) and 1 otherwise. With -Json it
prints one JSON object instead, for agents: {"ready": bool, "checks": [{"id",
"status", "message", "fix"}]}.

.EXAMPLE
pwsh -NoProfile -File .\doctor.ps1

.EXAMPLE
pwsh -NoProfile -File .\doctor.ps1 -Json
#>
[CmdletBinding()]
param(
    # Codex home directory. Defaults to CODEX_HOME, then %USERPROFILE%\.codex.
    [string]$CodexHome,

    # Print a single JSON object instead of the readable report.
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'scripts\ClaudeCX.Common.psm1') -Force

$script:results = [Collections.Generic.List[object]]::new()

function Write-Line {
    param([string]$Text = '', [string]$Color)
    if ($Json) { return }
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'warn', 'fail')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Fix
    )
    $script:results.Add([pscustomobject][ordered]@{ id = $Id; status = $Status; message = $Message; fix = $(if ($Fix) { $Fix } else { $null }) })
    if ($Json) { return }
    $color = @{ ok = 'Green'; warn = 'Yellow'; fail = 'Red' }[$Status]
    Write-Host ('  [{0}]' -f $Status).PadRight(9) -ForegroundColor $color -NoNewline
    Write-Host $Message
    if ($Fix) {
        foreach ($line in ($Fix -split "`n")) { Write-Host "         $line" -ForegroundColor DarkGray }
    }
}

function Invoke-Tool {
    # Runs a program with arguments (no shell string) and returns its output, with a timeout.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in '.cmd', '.bat') {
        # Batch shims (for example an npm-installed claude.cmd) run through cmd.exe, as the bridge does.
        $info.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
        foreach ($argument in @('/d', '/c', $Path) + $Arguments) { $info.ArgumentList.Add($argument) }
    }
    else {
        $info.FileName = $Path
        foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    try {
        $process = [Diagnostics.Process]::Start($info)
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message; TimedOut = $false }
    }
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch {}
        return [pscustomobject]@{ ExitCode = -1; Output = ''; TimedOut = $true }
    }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout.Result + $stderr.Result); TimedOut = $false }
}

function Get-BlockedFiles {
    # Files marked as downloaded from the internet, which PowerShell refuses to run under RemoteSigned.
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
        Where-Object { Get-Item -LiteralPath $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue })
}

$repoSkill = Get-ClaudeCXPackagedSkillRoot
$skillName = Get-ClaudeCXSkillName

Write-Line
Write-Line 'ClaudeCX setup check'
Write-Line

# --- Windows and PowerShell ---
if ($IsWindows) {
    Add-Result windows ok "Windows $([Environment]::OSVersion.Version)"
}
else {
    Add-Result windows fail 'ClaudeCX v1 runs on Windows only.' 'Use a Windows 10 or 11 computer.'
}
Add-Result powershell ok "PowerShell $($PSVersionTable.PSVersion)"

$policy = "$(Get-ExecutionPolicy)"
if ($policy -in 'Restricted', 'AllSigned') {
    Add-Result execution-policy fail "PowerShell's execution policy is $policy, so it will not run ClaudeCX's scripts." ("Fix: allow local scripts for your user account:`n  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
}
else {
    Add-Result execution-policy ok "PowerShell may run local scripts (execution policy: $policy)."
}

$blocked = @(Get-BlockedFiles -Root (Split-Path -Parent (Split-Path -Parent $repoSkill)))
if ($blocked.Count -gt 0) {
    Add-Result downloaded-files fail "$($blocked.Count) script(s) in this folder are marked as downloaded from the internet, so PowerShell blocks them." ("This happens when you download the ZIP instead of using git clone. Fix, from the ClaudeCX folder:`n  Get-ChildItem -Recurse | Unblock-File")
}
else {
    Add-Result downloaded-files ok 'No ClaudeCX scripts are blocked as internet downloads.'
}

# --- Git ---
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git) {
    $gitVersion = Invoke-Tool -Path $git.Source -Arguments @('--version') -TimeoutSeconds 15
    Add-Result git ok "Git found: $($gitVersion.Output.Trim())"
}
else {
    Add-Result git fail 'Git was not found.' ("Fix: install it, then open a new terminal:`n  winget install --id Git.Git -e --source winget")
}

# --- Claude Code (found the same way the bridge finds it) ---
$claude = Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $claude) { $claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not $claude) {
    Add-Result claude-found fail 'Claude Code was not found (the claude command).' ("Fix: install it from https://code.claude.com/docs/en/setup, then open a new terminal`n  and check that claude --version works.")
}
else {
    $version = Invoke-Tool -Path $claude.Source -Arguments @('--version') -TimeoutSeconds 30
    if ($version.ExitCode -ne 0) {
        Add-Result claude-found fail "Claude Code was found at $($claude.Source) but did not start." "Fix: run claude --version in a terminal and fix the error it shows, or reinstall Claude Code."
    }
    else {
        Add-Result claude-found ok "Claude Code found: $($version.Output.Trim())"
        $help = Invoke-Tool -Path $claude.Source -Arguments @('--help') -TimeoutSeconds 30
        # Only options that `claude --help` lists; the bridge also uses hidden ones
        # (--append-system-prompt-file, --max-turns) that every version with these has.
        $required = @('--safe-mode', '--output-format', 'stream-json', '--json-schema', '--permission-mode', 'auto',
            '--strict-mcp-config', '--mcp-config', '--settings', '--session-id', '--resume', '--max-budget-usd')
        $missing = @($required | Where-Object { -not $help.Output.Contains($_) })
        if ($missing.Count -gt 0) {
            Add-Result claude-options fail "This Claude Code version lacks options ClaudeCX needs: $($missing -join ', ')." ("Fix: update Claude Code, then run this check again:`n  claude update")
        }
        else {
            Add-Result claude-options ok 'Claude Code supports every option the bridge uses.'
        }

        $auth = Invoke-Tool -Path $claude.Source -Arguments @('auth', 'status') -TimeoutSeconds 30
        $loggedIn = $false
        try { $loggedIn = [bool](($auth.Output | ConvertFrom-Json -ErrorAction Stop).loggedIn) } catch {}
        if ($loggedIn) {
            Add-Result claude-signin ok 'Claude Code is signed in.'
        }
        elseif ($env:ANTHROPIC_API_KEY) {
            Add-Result claude-signin ok 'Claude Code will use the ANTHROPIC_API_KEY environment variable.'
        }
        else {
            Add-Result claude-signin fail 'Claude Code is not signed in.' ("Fix: run claude in a terminal, follow the sign-in steps, then type /exit.`n  claude auth status should then report that you are logged in.")
        }
    }
}

# --- Codex and the installed skill ---
$codexHomeFull = Resolve-ClaudeCXCodexHome -CodexHome $CodexHome
if (Test-Path -LiteralPath $codexHomeFull -PathType Container) {
    Add-Result codex-home ok "Codex home found: $codexHomeFull"
}
else {
    Add-Result codex-home warn "Codex home was not found at $codexHomeFull." "Fix: install Codex and open it once. If you use a custom CODEX_HOME, pass it with -CodexHome."
}
$installed = Join-Path $codexHomeFull (Join-Path 'skills' $skillName)
if (-not (Test-Path -LiteralPath (Join-Path $installed 'SKILL.md') -PathType Leaf)) {
    Add-Result skill-installed fail "The ClaudeCX skill is not installed in $installed." ("Fix, from the ClaudeCX folder:`n  pwsh -NoProfile -File .\install.ps1")
}
else {
    $problems = @(Get-ClaudeCXSkillProblems -SkillRoot $installed)
    if ($problems.Count -gt 0) {
        Add-Result skill-installed fail "The installed skill is incomplete: $($problems[0])" ("Fix: reinstall it:`n  pwsh -NoProfile -File .\install.ps1 -Force")
    }
    elseif (-not (Test-ClaudeCXTreeEqual -Expected $repoSkill -Actual $installed)) {
        Add-Result skill-installed warn 'The installed skill differs from this folder (an older or newer version).' ("Fix, to install this folder's version:`n  pwsh -NoProfile -File .\install.ps1 -Force")
    }
    else {
        Add-Result skill-installed ok "The ClaudeCX skill is installed and up to date: $installed"
    }
    $installedBlocked = @(Get-BlockedFiles -Root $installed)
    if ($installedBlocked.Count -gt 0) {
        Add-Result skill-unblocked fail 'The installed skill has scripts blocked as internet downloads, so Codex cannot run the bridge.' ("Fix: reinstall it; the installer unblocks the files:`n  pwsh -NoProfile -File .\install.ps1 -Force")
    }
}

# --- Run-log folder ---
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexClaude\handoffs'
if ($env:LOCALAPPDATA) { $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexClaude\handoffs' }
try {
    # Probe without leaving anything behind: folders this check creates are removed again.
    $created = [Collections.Generic.List[string]]::new()
    $walk = $stateRoot
    while ($walk -and -not [IO.Directory]::Exists($walk)) {
        $created.Insert(0, $walk)
        $walk = [IO.Path]::GetDirectoryName($walk)
    }
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $probe = Join-Path $stateRoot ".doctor-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force
    }
    finally {
        for ($index = $created.Count - 1; $index -ge 0; $index--) {
            try { [IO.Directory]::Delete($created[$index], $false) } catch { }
        }
    }
    Add-Result log-folder ok "The bridge can write its run logs to $stateRoot"
}
catch {
    Add-Result log-folder fail "The bridge cannot write its run logs to $stateRoot." "Fix: check that this folder is not read-only or blocked by security software."
}

# --- Default browser for the dashboard ---
$progId = $null
try {
    $progId = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -ErrorAction Stop).ProgId
}
catch {}
if ($progId) {
    Add-Result browser ok 'A default browser is set, so the live dashboard can open.'
}
else {
    Add-Result browser warn 'No default browser is set for web links.' "The run still works; the bridge falls back to a progress window. To get the dashboard, choose a default browser in Windows Settings > Apps > Default apps."
}

# --- Summary ---
$failures = @($script:results | Where-Object status -eq 'fail').Count
$warnings = @($script:results | Where-Object status -eq 'warn').Count
if ($Json) {
    [ordered]@{ ready = ($failures -eq 0); failures = $failures; warnings = $warnings; checks = @($script:results) } |
        ConvertTo-Json -Depth 4
    exit $(if ($failures -eq 0) { 0 } else { 1 })
}
Write-Line
if ($failures -eq 0) {
    $note = if ($warnings -gt 0) { " ($warnings warning$(if ($warnings -ne 1) { 's' }) above)" } else { '' }
    Write-Line "Ready: ClaudeCX can run on this computer$note." Green
    Write-Line 'Open a new Codex chat in a Git project and type $claudecx followed by your request.'
    exit 0
}
Write-Line "$failures problem$(if ($failures -ne 1) { 's' }) to fix before ClaudeCX can run. Follow the Fix lines above, then run this check again:" Red
Write-Line '  pwsh -NoProfile -File .\doctor.ps1'
exit 1
