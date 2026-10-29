#Requires -Version 7.2
<#
.SYNOPSIS
Deterministic offline tests for ClaudeCX settings, protected paths, run discovery, log pruning,
and the control center.

.DESCRIPTION
Works in a temporary sandbox: CLAUDECX_HOME and LOCALAPPDATA point into it, run folders are
fabricated, and the control center server listens on 127.0.0.1 only and never opens a browser.
Does not contact Claude and does not touch the real Codex, Claude, or ClaudeCX configuration.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Common.psm1') -Force

$skillRoot = Get-ClaudeCXPackagedSkillRoot
$scriptsRoot = Join-Path $skillRoot 'scripts'
Import-Module (Join-Path $scriptsRoot 'ClaudeCX.Progress.psm1') -Force
Import-Module (Join-Path $scriptsRoot 'ClaudeCX.Dashboard.psm1') -Force
Import-Module (Join-Path $scriptsRoot 'ClaudeCX.Settings.psm1') -Force
Import-Module (Join-Path $scriptsRoot 'ClaudeCX.ControlCenter.psm1') -Force

$utf8 = [Text.UTF8Encoding]::new($false)
$pwshPath = [Environment]::ProcessPath
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "claudecx-center-test-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($sandbox) | Out-Null
$script:failures = [Collections.Generic.List[string]]::new()
$script:passed = 0
$script:cleanup = [Collections.Generic.List[Diagnostics.Process]]::new()
$savedEnvironment = @{}
foreach ($name in @('CLAUDECX_HOME', 'LOCALAPPDATA')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

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

function Start-Sleeper {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300')) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    $script:cleanup.Add($process)
    return $process
}

function New-FakeTurn {
    # Fabricates one bridge turn folder: metadata, prompts, progress, and optional result files.
    param(
        [string]$Root, [string]$RepoKey, [string]$Session, [string]$Turn, [string]$Repository,
        [string]$Status, [string]$Request, [int]$BridgePid = 0, [string]$BridgeStarted, [string]$RecordedRunDirectory,
        [switch]$Snapshot, [int]$AgeDays = 0
    )
    $sessionDir = Join-Path (Join-Path $Root $RepoKey) $Session
    $turnDir = Join-Path $sessionDir $Turn
    [IO.Directory]::CreateDirectory($turnDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $sessionDir 'session.json'), (@{ session_id = $Session; repository = $Repository } | ConvertTo-Json), $utf8)
    $metadata = [ordered]@{
        repository = $Repository
        repository_name = (Split-Path -Leaf $Repository)
        run_directory = $(if ($RecordedRunDirectory) { $RecordedRunDirectory } else { $turnDir })
        session_id = $Session
        resumed = $false
        bridge_pid = $BridgePid
        bridge_started_at = $BridgeStarted
        started_at = '2026-10-01T10:00:00+00:00'
        timeout_seconds = 3600
        max_turns = 60
        max_budget_usd = 5
        model = 'default'
        protected_paths = @('.claudecx.json')
        settings_notes = @()
    }
    [IO.File]::WriteAllText((Join-Path $turnDir 'dashboard.json'), ($metadata | ConvertTo-Json), $utf8)
    [IO.File]::WriteAllText((Join-Path $turnDir 'original-prompt.md'), "$Request`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $turnDir 'codex-brief.md'), "# Objective`nDo it.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $turnDir 'progress.log'), "10:00:00  Preparing Claude run`n", $utf8)
    if ($Status) {
        $done = Join-Path $turnDir 'progress.done'
        [IO.File]::WriteAllText($done, (@{ status = $Status; message = 'x'; finished_at = '2026-10-01T10:05:00+00:00' } | ConvertTo-Json -Compress), $utf8)
        [IO.File]::WriteAllText((Join-Path $turnDir 'claude-result.json'), '{"type":"result","num_turns":3,"duration_ms":300000,"total_cost_usd":1.25}', $utf8)
        if ($AgeDays -gt 0) { [IO.File]::SetLastWriteTimeUtc($done, [DateTime]::UtcNow.AddDays(-$AgeDays)) }
    }
    if ($Snapshot) {
        [IO.File]::WriteAllText((Join-Path $turnDir 'changes.json'), '{"status_text":" M app.txt","status_truncated":false,"diff_text":"diff --git a/app.txt b/app.txt","diff_truncated":false,"max_diff_bytes":2097152,"errors":[],"generated_at":"2026-10-01T10:05:00+00:00"}', $utf8)
    }
    return $turnDir
}

function Invoke-Center {
    param(
        [object]$Context, [string]$Method = 'GET', [string]$Target, [string]$Token, [string]$Body = '',
        [hashtable]$Headers = @{}, [string]$HostHeader
    )
    $all = [ordered]@{ host = $(if ($PSBoundParameters.ContainsKey('HostHeader')) { $HostHeader } else { "127.0.0.1:$($Context.Port)" }) }
    if ($Token) { $all['authorization'] = "Bearer $Token" }
    if ($Body) { $all['content-type'] = 'application/json' }
    foreach ($entry in $Headers.GetEnumerator()) { $all[$entry.Key] = $entry.Value }
    $response = Invoke-ClaudeCXCenterRequest -Context $Context -Method $Method -Target $Target -Headers $all -Body $Body
    $text = $utf8.GetString($response.Body)
    $json = $null
    if ($response.Headers['Content-Type'] -like 'application/json*') { $json = $text | ConvertFrom-Json }
    return [pscustomobject]@{ Status = $response.Status; Json = $json; Text = $text; Headers = $response.Headers }
}

try {
    $home_ = Join-Path $sandbox 'home'
    [Environment]::SetEnvironmentVariable('CLAUDECX_HOME', $home_)

    # --- Settings file ---
    Write-Host '[settings]'
    $defaults = Read-ClaudeCXUserSettings
    Assert-True (-not $defaults.Exists -and $defaults.Errors.Count -eq 0 -and $defaults.Values['max_budget_usd'] -eq 5 -and $defaults.Values['max_turns'] -eq 60) 'a missing settings file means the defaults'
    Assert-True ((Get-ClaudeCXSettingsPath) -eq (Join-Path $home_ 'settings.json')) 'settings live in CLAUDECX_HOME'
    $saved = Save-ClaudeCXUserSettings -Values ([ordered]@{ max_budget_usd = 2.5; model = 'sonnet'; protected_paths = @('.\.github\workflows\') })
    $reread = Read-ClaudeCXUserSettings
    Assert-True ($reread.Exists -and $reread.Values['max_budget_usd'] -eq 2.5 -and $reread.Values['model'] -ceq 'sonnet') 'saved settings read back'
    Assert-True ((@($reread.Values['protected_paths']) -join '|') -ceq '.github/workflows/') 'a one-item path list survives a save and is normalized'
    $fileText = [IO.File]::ReadAllText((Get-ClaudeCXSettingsPath))
    Assert-True (-not $fileText.Contains("`r") -and $fileText.EndsWith("`n")) 'settings are written with LF line endings'
    foreach ($bad in @(
            @{ Values = [ordered]@{ max_turns = 0 }; Expect = 'between 1 and 500' },
            @{ Values = [ordered]@{ max_turns = 2.5 }; Expect = 'whole number' },
            @{ Values = [ordered]@{ max_budget_usd = '5' }; Expect = 'must be a number' },
            @{ Values = [ordered]@{ model = 'gpt' }; Expect = 'must be one of' },
            @{ Values = [ordered]@{ open_center_on_new_run = 'yes' }; Expect = 'true or false' },
            @{ Values = [ordered]@{ protected_paths = @('../outside') }; Expect = "may not contain '..'" },
            @{ Values = [ordered]@{ protected_paths = @('C:/Windows') }; Expect = 'not a repository-relative path' },
            @{ Values = [ordered]@{ surprise = 1 }; Expect = "Unknown setting 'surprise'" })) {
        $message = Get-ThrownMessage { Save-ClaudeCXUserSettings -Values $bad.Values -Path (Join-Path $sandbox 'never.json') }
        Assert-True ($null -ne $message -and $message.Contains($bad.Expect) -and -not (Test-Path -LiteralPath (Join-Path $sandbox 'never.json'))) "invalid setting refused: $($bad.Expect)"
    }
    $handEdited = Join-Path $sandbox 'hand.json'
    [IO.File]::WriteAllBytes($handEdited, [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes('{"max_turns": 10, "colour": "blue"}'))
    $hand = Read-ClaudeCXUserSettings -Path $handEdited
    Assert-True ($hand.Errors.Count -eq 0 -and $hand.Values['max_turns'] -eq 10 -and $hand.Warnings.Count -eq 1) 'a hand-edited file with a BOM and an unknown key loads with a warning'
    [IO.File]::WriteAllText($handEdited, '{"max_turns": "ten"}', $utf8)
    Assert-True ((Read-ClaudeCXUserSettings -Path $handEdited).Errors.Count -eq 1) 'an invalid hand-edited value is reported as an error'
    [IO.File]::WriteAllText($handEdited, '{ not json', $utf8)
    Assert-True ((Read-ClaudeCXUserSettings -Path $handEdited).Errors[0].Contains('not valid JSON')) 'broken JSON is reported as an error'

    # --- Effective limits ---
    Write-Host '[effective limits]'
    $user = Get-ClaudeCXDefaultSettings
    $user['max_budget_usd'] = 4.0
    $user['max_turns'] = 50
    $user['protected_paths'] = @('*.lock')
    $resolved = Resolve-ClaudeCXRunSettings -User $user -Requested @{ MaxBudgetUsd = [decimal]1; MaxTurns = 80; TimeoutSeconds = 600 }
    Assert-True ($resolved.MaxBudgetUsd -eq 1 -and $resolved.MaxTurns -eq 50 -and $resolved.TimeoutSeconds -eq 600) 'Codex can lower a limit but not raise one'
    Assert-True (@($resolved.Notes | Where-Object { $_ -like '*80 turns*' }).Count -eq 1) 'a capped request is explained in a note'
    $project = (ConvertFrom-ClaudeCXSettingsText -Text '{"max_budget_usd": 0.5, "max_turns": 99, "model": "opus", "protected_paths": ["db/migrations/"]}' -Source '.claudecx.json' -Project)
    Assert-True (-not $project.Values.Contains('model') -and $project.Warnings.Count -eq 1) 'a project file cannot choose the model'
    $withProject = Resolve-ClaudeCXRunSettings -User $user -Project $project.Values
    Assert-True ($withProject.MaxBudgetUsd -eq 0.5 -and $withProject.MaxTurns -eq 50) 'a project file can lower limits but not raise them'
    Assert-True ((@($withProject.ProtectedPaths) -join '|') -ceq '.claudecx.json|*.lock|db/migrations/') 'protected paths combine, and .claudecx.json is always protected'
    Assert-True ((Resolve-ClaudeCXRunSettings -User (Get-ClaudeCXDefaultSettings)).ProgressMode -ceq 'Dashboard') 'the default live view is the dashboard'

    $projectRepo = New-TestRepository 'repo-project'
    [IO.File]::WriteAllText((Join-Path $projectRepo '.claudecx.json'), '{"max_turns": 5}', $utf8)
    Invoke-Git -Repository $projectRepo -Arguments @('add', '--', '.claudecx.json')
    Invoke-Git -Repository $projectRepo -Arguments @('commit', '-q', '-m', 'limits')
    [IO.File]::WriteAllText((Join-Path $projectRepo '.claudecx.json'), '{"max_turns": 400}', $utf8)
    $fromHead = Read-ClaudeCXProjectSettings -Repository $projectRepo
    Assert-True ($fromHead.Exists -and $fromHead.Values['max_turns'] -eq 5) 'the project file is read from HEAD, not the working tree'
    Assert-True (-not (Read-ClaudeCXProjectSettings -Repository (New-TestRepository 'repo-plain')).Exists) 'a repository without .claudecx.json has no project settings'

    # --- Protected paths ---
    Write-Host '[protected paths]'
    $matches_ = @{
        '.github/workflows/' = @(@('.github/workflows/ci.yml', $true), @('.github/dependabot.yml', $false))
        '*.lock' = @(@('yarn.lock', $true), @('pkg/sub/Cargo.lock', $true), @('lockfile.txt', $false))
        'secrets' = @(@('secrets', $true), @('secrets/key.pem', $true), @('app/secrets/x', $false))
        'src/**/*.sql' = @(@('src/a.sql', $true), @('src/db/m/b.sql', $true), @('test/a.sql', $false))
        'config/?.yml' = @(@('config/a.yml', $true), @('config/ab.yml', $false))
    }
    foreach ($entry in $matches_.GetEnumerator()) {
        foreach ($pair in $entry.Value) {
            $hit = @(Find-ClaudeCXProtectedChanges -ChangedPaths @($pair[0]) -Patterns @($entry.Key)).Count -eq 1
            Assert-True ($hit -eq $pair[1]) "pattern $($entry.Key) $(if ($pair[1]) { 'matches' } else { 'does not match' }) $($pair[0])"
        }
    }
    Assert-True (@(Find-ClaudeCXProtectedChanges -ChangedPaths @('YARN.LOCK') -Patterns @('*.lock')).Count -eq 1) 'matching ignores case, as Windows does'
    $changedRepo = New-TestRepository 'repo-changes'
    [IO.File]::WriteAllText((Join-Path $changedRepo 'new file.txt'), "x`n", $utf8)
    Invoke-Git -Repository $changedRepo -Arguments @('mv', 'app.txt', 'renamed.txt')
    $changed = @(Get-ClaudeCXChangedPaths -Repository $changedRepo)
    Assert-True ($changed -contains 'app.txt' -and $changed -contains 'renamed.txt' -and $changed -contains 'new file.txt') "changed paths include both sides of a rename and untracked files ($($changed -join ', '))"

    # --- Run discovery across log folders ---
    Write-Host '[run discovery]'
    $local = Join-Path $sandbox 'localappdata'
    $standard = Join-Path $local 'CodexClaude\handoffs'
    $packaged = Join-Path $local 'Packages\OpenAI.Codex_testpkg\LocalCache\Local\CodexClaude\handoffs'
    [IO.Directory]::CreateDirectory($standard) | Out-Null
    [IO.Directory]::CreateDirectory($packaged) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $local 'Packages\Unrelated_app\LocalCache')) | Out-Null
    $roots = @(Get-ClaudeCXStateRoots -LocalAppData $local)
    Assert-True ($roots.Count -eq 2 -and $roots[0].Kind -eq 'standard' -and $roots[1].Kind -eq 'packaged' -and $roots[1].App -eq 'OpenAI.Codex') 'the standard folder and a packaged app''s redirected folder are both found'
    Assert-True (@($roots | Where-Object { $_.Id -match '^[0-9a-f]{8}$' }).Count -eq 2 -and $roots[0].Id -ne $roots[1].Id) 'each log folder gets a distinct short id'

    $repoA = New-TestRepository 'repo-a'
    $repoKey = 'a' * 24
    $sessionOne = [Guid]::NewGuid().ToString('D')
    $sessionTwo = [Guid]::NewGuid().ToString('D')
    $oldTurn = New-FakeTurn -Root $standard -RepoKey $repoKey -Session $sessionOne -Turn '20261001-100000000' -Repository $repoA -Status 'success' -Request 'Old request' -AgeDays 40
    $appTurn = New-FakeTurn -Root $packaged -RepoKey $repoKey -Session $sessionTwo -Turn '20261002-100000000' -Repository $repoA -Status 'failed' -Request '[$claudecx](C:/skill/SKILL.md) fix the build' -RecordedRunDirectory 'C:\elsewhere\turn' -Snapshot
    $sleeper = Start-Sleeper
    $sleeperStart = $sleeper.StartTime.ToUniversalTime().ToString('o')
    $activeTurn = New-FakeTurn -Root $standard -RepoKey $repoKey -Session $sessionOne -Turn '20261003-100000000' -Repository $repoA -Status '' -Request 'Running request' -BridgePid $sleeper.Id -BridgeStarted $sleeperStart
    [IO.File]::WriteAllText((Join-Path (Join-Path $standard $repoKey) 'active.lock'), (@{ pid = $sleeper.Id } | ConvertTo-Json), $utf8)
    [IO.Directory]::CreateDirectory((Join-Path $standard 'not-a-key\x\y')) | Out-Null

    $token = New-ClaudeCXDashboardToken
    $assetRoot = Join-Path $skillRoot 'dashboard'
    $context = New-ClaudeCXCenterContext -Token $token -AssetRoot $assetRoot -Port 54321 -SkillRoot $skillRoot -LocalAppData $local

    $runs = (Invoke-Center -Context $context -Target '/api/runs' -Token $token).Json
    Assert-True ($runs.total -eq 3 -and (@($runs.runs | ForEach-Object { $_.status }) -join ',') -ceq 'active,failed,succeeded') "history lists every run newest first ($(@($runs.runs | ForEach-Object { $_.status }) -join ','))"
    $appRow = $runs.runs | Where-Object { $_.status -eq 'failed' }
    Assert-True ($appRow.source -ceq 'codex-app' -and $appRow.request -ceq '$claudecx fix the build') 'a packaged-app run is labelled and its request preview drops link markup'
    Assert-True ($runs.runs[2].total_cost_usd -eq 1.25 -and $runs.runs[2].num_turns -eq 3) 'history rows carry cost and turns'

    $overview = (Invoke-Center -Context $context -Target '/api/center' -Token $token).Json
    Assert-True (@($overview.active).Count -eq 1 -and $overview.active[0].request -ceq 'Running request') 'the overview finds the run in progress from its lock'
    Assert-True ($overview.latest.status -ceq 'active') 'the overview reports the latest run'

    $appId = $appRow.id
    $state = Invoke-Center -Context $context -Target "/api/run/state?run=$([Uri]::EscapeDataString($appId))" -Token $token
    Assert-True ($state.Status -eq 200 -and $state.Json.run_id -ceq $appId -and $state.Json.status -ceq 'failed') 'a run from the packaged folder opens even though it recorded another path'
    $changes = (Invoke-Center -Context $context -Target "/api/run/changes?run=$([Uri]::EscapeDataString($appId))" -Token $token).Json
    Assert-True ($changes.snapshot -eq $true -and $changes.status_text.Contains('app.txt')) 'a finished run shows the changes saved when it ended'
    $oldId = ($runs.runs | Where-Object { $_.status -eq 'succeeded' }).id
    $noSnapshot = (Invoke-Center -Context $context -Target "/api/run/changes?run=$([Uri]::EscapeDataString($oldId))" -Token $token).Json
    Assert-True ($noSnapshot.snapshot -eq $true -and $noSnapshot.diff_text -eq '' -and $noSnapshot.errors[0].Contains('not available')) 'an older run without a snapshot says so instead of showing today''s diff'
    $prompts = (Invoke-Center -Context $context -Target "/api/run/prompts?run=$([Uri]::EscapeDataString($oldId))" -Token $token).Json
    Assert-True ($prompts.original_prompt -ceq "Old request`n") 'a past run''s prompts are served'
    $report = Invoke-Center -Context $context -Target "/api/run/report?run=$([Uri]::EscapeDataString($oldId))" -Token $token
    Assert-True ($report.Status -eq 200 -and $report.Json.kind -ceq 'pending') 'a past run''s report route answers'

    $root0 = $roots[0].Id
    foreach ($badId in @('', 'x', "$root0/$repoKey/$sessionOne/../../x", "$root0/$repoKey/$sessionOne/20261001-10000000", "ffffffff/$repoKey/$sessionOne/20261001-100000000",
            "$root0/$repoKey/$sessionOne/20261009-100000000", "$root0\$repoKey\$sessionOne\20261001-100000000", "$root0/$($repoKey.ToUpperInvariant())/$sessionOne/20261001-100000000")) {
        $response = Invoke-Center -Context $context -Target "/api/run/state?run=$([Uri]::EscapeDataString($badId))" -Token $token
        Assert-True ($response.Status -eq 404) "run id refused: '$badId'"
    }
    Assert-True ((Invoke-Center -Context $context -Target '/api/run/state' -Token $token).Status -eq 404) 'a run route without an id is refused'

    $activeId = ($runs.runs | Where-Object { $_.status -eq 'active' }).id
    $stopFinished = Invoke-Center -Context $context -Method POST -Target "/api/run/stop?run=$([Uri]::EscapeDataString($oldId))" -Token $token
    Assert-True ($stopFinished.Status -eq 409) 'stopping a finished run is refused'
    $stopActive = Invoke-Center -Context $context -Method POST -Target "/api/run/stop?run=$([Uri]::EscapeDataString($activeId))" -Token $token
    Assert-True ($stopActive.Status -eq 202 -and (Test-Path -LiteralPath (Join-Path $activeTurn 'stop-request.json'))) 'stopping the active run writes the stop request for its bridge'

    # --- Request checks ---
    Write-Host '[control center requests]'
    Assert-True ((Invoke-Center -Context $context -Target '/api/center' -Token $token -HostHeader 'evil.example:54321').Status -eq 421) 'a foreign Host header is refused'
    Assert-True ((Invoke-Center -Context $context -Target '/api/center').Status -eq 401) 'a request without the token is refused'
    Assert-True ((Invoke-Center -Context $context -Target '/api/center' -Token ('A' * 43)).Status -eq 401) 'a wrong token is refused'
    $page = Invoke-Center -Context $context -Target '/'
    Assert-True ($page.Status -eq 200 -and $page.Headers['Content-Security-Policy'].Contains("default-src 'none'")) 'the page is served with the strict CSP'
    Assert-True ((Invoke-Center -Context $context -Method POST -Target '/app.js').Status -eq 405) 'static files are GET only'
    Assert-True ((Invoke-Center -Context $context -Target '/api/nothing' -Token $token).Status -eq 404) 'unknown routes are not found'
    Assert-True ((Invoke-Center -Context $context -Method DELETE -Target '/api/settings' -Token $token).Status -eq 405) 'settings accept only GET and POST'
    Assert-True ((Invoke-Center -Context $context -Method POST -Target '/api/runs' -Token $token).Status -eq 405) 'history is GET only'

    $settingsGet = (Invoke-Center -Context $context -Target '/api/settings' -Token $token).Json
    Assert-True (@($settingsGet.fields).Count -eq 8 -and @($settingsGet.locked).Count -ge 5 -and $settingsGet.values.max_budget_usd -eq 2.5) 'settings route returns fields, locked items, and current values'
    $evil = Invoke-Center -Context $context -Method POST -Target '/api/settings' -Token $token -Body '{"values":{}}' -Headers @{ origin = 'http://evil.example' }
    Assert-True ($evil.Status -eq 403) 'a settings change from another origin is refused'
    $plain = Invoke-ClaudeCXCenterRequest -Context $context -Method POST -Target '/api/settings' -Headers ([ordered]@{ host = '127.0.0.1:54321'; authorization = "Bearer $token"; 'content-type' = 'text/plain' }) -Body '{"values":{}}'
    Assert-True ($plain.Status -eq 415) 'a settings change that is not JSON is refused'
    $invalid = Invoke-Center -Context $context -Method POST -Target '/api/settings' -Token $token -Body '{"values":{"max_turns":9999}}'
    Assert-True ($invalid.Status -eq 422 -and $invalid.Json.messages[0].Contains('between 1 and 500') -and (Read-ClaudeCXUserSettings).Values['max_budget_usd'] -eq 2.5) 'an invalid settings change is refused and nothing is saved'
    $valid = Invoke-Center -Context $context -Method POST -Target '/api/settings' -Token $token -Body '{"values":{"max_turns":12,"protected_paths":["infra/"],"open_center_on_new_run":false}}' -Headers @{ origin = 'http://127.0.0.1:54321' }
    $after = Read-ClaudeCXUserSettings
    Assert-True ($valid.Status -eq 200 -and $after.Values['max_turns'] -eq 12 -and (@($after.Values['protected_paths']) -join '|') -ceq 'infra/' -and $after.Values['max_budget_usd'] -eq 5) 'a valid settings change is saved; omitted settings return to their defaults'
    Assert-True ((Invoke-Center -Context $context -Method POST -Target '/api/settings' -Token $token -Body 'nope').Status -eq 400) 'a malformed settings body is refused'

    $pruneBad = Invoke-Center -Context $context -Method POST -Target '/api/logs/prune' -Token $token -Body '{"days":0}'
    Assert-True ($pruneBad.Status -eq 422) 'pruning needs at least one day'
    $prune = Invoke-Center -Context $context -Method POST -Target '/api/logs/prune' -Token $token -Body '{"days":30}'
    Assert-True ($prune.Status -eq 200 -and $prune.Json.removed_runs -eq 1) 'pruning deletes only the finished run older than the limit'
    Assert-True (-not (Test-Path -LiteralPath $oldTurn) -and (Test-Path -LiteralPath $activeTurn) -and (Test-Path -LiteralPath $appTurn)) 'running and recent runs are kept'
    Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $standard $repoKey) $sessionOne)) 'a session that still has runs is kept'

    Assert-True ((Invoke-Center -Context $context -Method POST -Target '/api/center/quit' -Token $token).Status -eq 202 -and $context.QuitRequested) 'the page can stop the control center'

    # --- New-run detection ---
    $fresh = New-ClaudeCXCenterContext -Token $token -AssetRoot $assetRoot -Port 54321 -SkillRoot $skillRoot -LocalAppData $local
    Assert-True (@(Find-ClaudeCXNewRuns -Context $fresh).Count -eq 0) 'runs already in progress at start-up are not announced'
    $repoKeyB = 'b' * 24
    $null = New-FakeTurn -Root $packaged -RepoKey $repoKeyB -Session $sessionTwo -Turn '20261004-100000000' -Repository $repoA -Status '' -Request 'Second' -BridgePid $sleeper.Id -BridgeStarted $sleeperStart
    [IO.File]::WriteAllText((Join-Path (Join-Path $packaged $repoKeyB) 'active.lock'), (@{ pid = $sleeper.Id } | ConvertTo-Json), $utf8)
    $announced = @(Find-ClaudeCXNewRuns -Context $fresh)
    Assert-True ($announced.Count -eq 1 -and $announced[0].request -ceq 'Second') 'a run that starts later is announced once'
    Assert-True (@(Find-ClaudeCXNewRuns -Context $fresh).Count -eq 0) 'an announced run is not announced again'

    # --- The real server, started and stopped by the launcher ---
    Write-Host '[control center server]'
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $local)
    $launcher = Join-Path $scriptsRoot 'start-control-center.ps1'
    $status = & $pwshPath -NoProfile -NonInteractive -File $launcher -Status | ConvertFrom-Json
    Assert-True ($status.running -eq $false) 'the launcher reports when nothing is running'
    $startOutput = & $pwshPath -NoProfile -NonInteractive -File $launcher -NoBrowser 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "the launcher starts the server ($startOutput)"
    $running = Get-ClaudeCXControlCenter
    Assert-True ($null -ne $running) 'the running server is discoverable'
    if ($null -ne $running) {
        $script:cleanup.Add((Get-Process -Id $running.ProcessId))
        $files = Get-ClaudeCXControlCenterPaths
        $info = [IO.File]::ReadAllText($files.Info)
        Assert-True (-not $info.Contains('token') -and ([IO.File]::ReadAllText($files.Token).Trim().Length -eq 43)) 'the token is kept apart from the port file'
        $client = [Net.Http.HttpClient]::new()
        try {
            $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', [IO.File]::ReadAllText($files.Token).Trim())
            $live = $client.GetAsync("http://127.0.0.1:$($running.Port)/api/center").GetAwaiter().GetResult()
            Assert-True ([int]$live.StatusCode -eq 200) 'the running server answers on 127.0.0.1'
        }
        finally { $client.Dispose() }
        $second = & $pwshPath -NoProfile -NonInteractive -File $launcher -NoBrowser 2>&1
        Assert-True ((Get-ClaudeCXControlCenter).ProcessId -eq $running.ProcessId) "a second launch reuses the running server ($second)"
        $null = & $pwshPath -NoProfile -NonInteractive -File $launcher -Stop 2>&1
        Assert-True ($null -eq (Get-ClaudeCXControlCenter) -and -not (Test-Path -LiteralPath $files.Token)) 'the launcher stops the server and removes its files'
    }
}
finally {
    foreach ($process in $script:cleanup) {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
    }
    foreach ($entry in $savedEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value) }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host "test-control-center: $($script:failures.Count) failed, $($script:passed) passed" -ForegroundColor Red
    foreach ($failure in $script:failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "test-control-center: all $($script:passed) checks passed" -ForegroundColor Green
