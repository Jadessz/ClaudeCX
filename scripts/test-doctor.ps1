#Requires -Version 7.2
<#
.SYNOPSIS
Offline tests for doctor.ps1 and the installer's unblock and check steps.

.DESCRIPTION
Runs a copy of the repository's doctor and installer in a temporary sandbox with
sandboxed USERPROFILE, LOCALAPPDATA, CLAUDE_CONFIG_DIR, and Codex home, and with a PATH
that holds only a fake claude.cmd and Git. Never contacts Claude and never touches the
real Codex or Claude configuration.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Force

$repoRoot = Get-ClaudeCXRepositoryRoot
$pwshPath = [Environment]::ProcessPath
$utf8 = [Text.UTF8Encoding]::new($false)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "claudecx-doctor-test-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($sandbox) | Out-Null
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

# A copy of the parts of the repository that doctor.ps1 and install.ps1 use.
$package = Join-Path $sandbox 'ClaudeCX'
[IO.Directory]::CreateDirectory((Join-Path $package 'scripts')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $package 'skill')) | Out-Null
foreach ($file in @('doctor.ps1', 'install.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $package }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Destination (Join-Path $package 'scripts')
Copy-Item -LiteralPath (Get-ClaudeCXPackagedSkillRoot) -Destination (Join-Path $package 'skill\claudecx') -Recurse

# Fake Claude Code: answers --version, --help and auth status from text files next to it.
$fakeBin = Join-Path $sandbox 'fake-bin'
[IO.Directory]::CreateDirectory($fakeBin) | Out-Null
$fakeCmd = @(
    '@echo off',
    'if "%~1"=="--version" (type "%~dp0version.txt" & exit /b 0)',
    'if "%~1"=="--help" (type "%~dp0help.txt" & exit /b 0)',
    'if "%~1"=="auth" (type "%~dp0auth.txt" & exit /b 0)',
    'exit /b 1'
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $fakeBin 'claude.cmd'), $fakeCmd + "`r`n", $utf8)
$fullHelp = 'Options: --safe-mode --output-format <format> (choices: "text", "json", "stream-json") --json-schema --permission-mode (choices: "auto", "plan") --strict-mcp-config --mcp-config --settings --session-id --resume --max-budget-usd'
function Set-FakeClaude {
    param([string]$Help = $fullHelp, [string]$Auth = '{"loggedIn": true}')
    [IO.File]::WriteAllText((Join-Path $fakeBin 'version.txt'), "9.9.9 (Claude Code)`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fakeBin 'help.txt'), $Help + "`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fakeBin 'auth.txt'), $Auth + "`r`n", $utf8)
}

$gitDir = Split-Path -Parent (Get-Command git -CommandType Application | Select-Object -First 1).Source
$systemDir = [Environment]::SystemDirectory
$withClaude = @($fakeBin, $gitDir, $systemDir) -join [IO.Path]::PathSeparator
$withoutClaude = @($gitDir, $systemDir) -join [IO.Path]::PathSeparator
foreach ($dir in @($gitDir, $systemDir)) {
    foreach ($name in @('claude.exe', 'claude.cmd', 'claude')) {
        if (Test-Path -LiteralPath (Join-Path $dir $name)) { throw "Test PATH unexpectedly contains a real Claude: $dir\$name" }
    }
}

$profileRoot = Join-Path $sandbox 'profile'
$codexHome = Join-Path $sandbox 'codex-home'
[IO.Directory]::CreateDirectory($profileRoot) | Out-Null

function Invoke-Package {
    # Runs a script from the package copy in a child pwsh with a sandboxed environment and PATH.
    param([string]$Script, [string[]]$Arguments = @(), [string]$SearchPath = $withClaude)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwshPath
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $package $Script)) + $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['PATH'] = $SearchPath
    $info.Environment['USERPROFILE'] = $profileRoot
    $info.Environment['LOCALAPPDATA'] = Join-Path $profileRoot 'AppData\Local'
    $info.Environment['CLAUDE_CONFIG_DIR'] = Join-Path $profileRoot '.claude'
    $info.Environment.Remove('CODEX_HOME') | Out-Null
    $info.Environment.Remove('ANTHROPIC_API_KEY') | Out-Null
    $process = [Diagnostics.Process]::Start($info)
    $stderr = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Text = $stdout + $stderr.Result }
}

function Invoke-Doctor {
    param([string]$SearchPath = $withClaude)
    $result = Invoke-Package -Script 'doctor.ps1' -Arguments @('-CodexHome', $codexHome, '-Json') -SearchPath $SearchPath
    $report = $null
    try { $report = $result.Text | ConvertFrom-Json } catch {}
    $status = @{}
    if ($report) { foreach ($check in $report.checks) { if (-not $status.ContainsKey($check.id) -or $check.status -ne 'ok') { $status[$check.id] = $check.status } } }
    return [pscustomobject]@{ ExitCode = $result.ExitCode; Report = $report; Status = $status; Text = $result.Text }
}

$realSkill = Join-Path $env:USERPROFILE '.codex\skills\claudecx'
$realBefore = if (Test-Path -LiteralPath $realSkill) { (Get-ClaudeCXTreeManifest -Root $realSkill) -join "`n" } else { '' }

try {
    Write-Host '[doctor: before install]'
    Set-FakeClaude
    $r = Invoke-Doctor
    Assert-True ($null -ne $r.Report) "doctor -Json prints one JSON object ($($r.Text.Trim().Split("`n")[0]))"
    Assert-True ($r.ExitCode -eq 1 -and $r.Report.ready -eq $false) 'doctor reports not ready when the skill is not installed'
    Assert-True ($r.Status['skill-installed'] -eq 'fail') 'missing skill is a failure'
    Assert-True ($r.Status['claude-found'] -eq 'ok' -and $r.Status['claude-options'] -eq 'ok' -and $r.Status['claude-signin'] -eq 'ok') 'a current, signed-in Claude Code passes'
    Assert-True ($r.Status['git'] -eq 'ok') 'Git is found'
    $failFixes = @($r.Report.checks | Where-Object { $_.status -ne 'ok' -and -not $_.fix })
    Assert-True ($failFixes.Count -eq 0) 'every failure or warning comes with a fix'

    Write-Host '[installer: unblocks downloaded files and runs the checks]'
    $marked = Join-Path $package 'skill\claudecx\scripts\invoke-claude.ps1'
    Set-Content -LiteralPath $marked -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3"
    $r = Invoke-Doctor
    Assert-True ($r.Status['downloaded-files'] -eq 'fail') 'doctor flags scripts marked as internet downloads'
    $install = Invoke-Package -Script 'install.ps1' -Arguments @('-CodexHome', $codexHome)
    Assert-True ($install.ExitCode -eq 0) "install exits 0 ($(($install.Text -split "`n" | Select-Object -Last 1).Trim()))"
    Assert-True ($install.Text.Contains('ClaudeCX setup check')) 'install runs the setup checks by default'
    $installedFiles = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'skills\claudecx') -Recurse -File)
    $stillMarked = @($installedFiles | Where-Object { Get-Item -LiteralPath $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue })
    Assert-True ($installedFiles.Count -gt 0 -and $stillMarked.Count -eq 0) 'installed copy carries no internet-download mark'
    Remove-Item -LiteralPath $marked -Stream 'Zone.Identifier'

    $skip = Invoke-Package -Script 'install.ps1' -Arguments @('-CodexHome', $codexHome, '-Force', '-SkipChecks')
    Assert-True ($skip.ExitCode -eq 0 -and -not $skip.Text.Contains('ClaudeCX setup check')) '-SkipChecks skips the setup checks'

    Write-Host '[doctor: after install]'
    $r = Invoke-Doctor
    Assert-True ($r.Status['skill-installed'] -eq 'ok' -and $r.Status['downloaded-files'] -eq 'ok' -and $r.Status['log-folder'] -eq 'ok') 'installed, unblocked skill and a writable log folder pass'
    Assert-True ($r.ExitCode -eq 0 -and $r.Report.ready) 'doctor reports ready'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $profileRoot 'AppData\Local\CodexClaude'))) 'the log-folder check leaves no folder behind'

    Write-Host '[doctor: problems a newcomer can hit]'
    $r = Invoke-Doctor -SearchPath $withoutClaude
    Assert-True ($r.ExitCode -eq 1 -and $r.Status['claude-found'] -eq 'fail') 'missing Claude Code fails'
    Set-FakeClaude -Help 'Options: --output-format --permission-mode'
    $r = Invoke-Doctor
    Assert-True ($r.ExitCode -eq 1 -and $r.Status['claude-options'] -eq 'fail') 'an outdated Claude Code fails'
    Assert-True (@($r.Report.checks | Where-Object id -eq 'claude-options')[0].fix.Contains('claude update')) 'outdated Claude Code suggests claude update'
    Set-FakeClaude -Auth '{"loggedIn": false}'
    $r = Invoke-Doctor
    Assert-True ($r.ExitCode -eq 1 -and $r.Status['claude-signin'] -eq 'fail') 'a signed-out Claude Code fails'
    Set-FakeClaude
    $installedSkillMd = Join-Path $codexHome 'skills\claudecx\SKILL.md'
    [IO.File]::AppendAllText($installedSkillMd, "`nlocal change`n", $utf8)
    $r = Invoke-Doctor
    Assert-True ($r.ExitCode -eq 0 -and $r.Status['skill-installed'] -eq 'warn') 'an installed skill that differs is a warning, not a failure'

    $realAfter = if (Test-Path -LiteralPath $realSkill) { (Get-ClaudeCXTreeManifest -Root $realSkill) -join "`n" } else { '' }
    Assert-True ($realAfter -ceq $realBefore) 'the real installed skill was not touched'
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host "test-doctor: $($script:failures.Count) of $($script:passed + $script:failures.Count) checks failed" -ForegroundColor Red
    exit 1
}
Write-Host "test-doctor: all $script:passed checks passed"
exit 0
