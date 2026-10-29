#Requires -Version 7.2
<#
.SYNOPSIS
Shows or changes your ClaudeCX settings.

.DESCRIPTION
Settings live in %USERPROFILE%\.claudecx\settings.json (or CLAUDECX_HOME\settings.json) and apply
to the next run. With -ProjectPath it also shows the limits a run in that repository would get,
after the project's committed .claudecx.json has been applied. Safety switches are fixed and
cannot be changed here.

.EXAMPLE
pwsh -NoProfile -File .\claudecx-settings.ps1

.EXAMPLE
pwsh -NoProfile -File .\claudecx-settings.ps1 -Set max_budget_usd=10 -Set model=sonnet

.EXAMPLE
pwsh -NoProfile -File .\claudecx-settings.ps1 -Set "protected_paths=.github/workflows/,*.lock"

.EXAMPLE
pwsh -NoProfile -File .\claudecx-settings.ps1 -ProjectPath C:\src\app -Json
#>
[CmdletBinding()]
param(
    # name=value pairs. Lists (protected_paths) take comma-separated values; an empty value clears them.
    [string[]]$Set,

    # Setting names to put back to their defaults.
    [string[]]$Reset,

    # Put every setting back to its default.
    [switch]$ResetAll,

    # Also show the effective limits for a run in this Git repository.
    [string]$ProjectPath,

    # Print one JSON object instead of text.
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeCX.Settings.psm1') -Force

$fields = Get-ClaudeCXSettingsFields
$current = Read-ClaudeCXUserSettings

function ConvertFrom-SettingText {
    param([Collections.IDictionary]$Field, [string]$Text)

    switch ($Field.type) {
        'number' {
            $number = 0.0
            if (-not [double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { throw "$($Field.key) needs a number, for example $($Field.default)." }
            return $number
        }
        'integer' {
            $number = 0
            if (-not [int]::TryParse($Text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { throw "$($Field.key) needs a whole number, for example $($Field.default)." }
            return $number
        }
        'bool' {
            if ($Text -in 'true', 'yes', 'on', '1') { return $true }
            if ($Text -in 'false', 'no', 'off', '0') { return $false }
            throw "$($Field.key) needs true or false."
        }
        'paths' { return , @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        default { return $Text }
    }
}

$changing = $Set -or $Reset -or $ResetAll
if ($changing) {
    if ($current.Errors.Count -gt 0 -and -not $ResetAll) {
        throw "Your settings file has problems; fix them or use -ResetAll first: $($current.Errors -join ' ')"
    }
    $values = if ($ResetAll) { Get-ClaudeCXDefaultSettings } else { $current.Values }
    $defaults = Get-ClaudeCXDefaultSettings
    foreach ($name in @($Reset | Where-Object { $_ })) {
        if (-not $defaults.Contains($name)) { throw "Unknown setting '$name'. Known settings: $($fields.key -join ', ')." }
        $values[$name] = $defaults[$name]
    }
    foreach ($pair in @($Set | Where-Object { $_ })) {
        $split = $pair.IndexOf('=')
        if ($split -lt 1) { throw "Use name=value, for example max_budget_usd=10 (got '$pair')." }
        $name = $pair.Substring(0, $split).Trim()
        $field = $fields | Where-Object { $_.key -ceq $name } | Select-Object -First 1
        if ($null -eq $field) { throw "Unknown setting '$name'. Known settings: $($fields.key -join ', ')." }
        $values[$name] = ConvertFrom-SettingText -Field $field -Text $pair.Substring($split + 1).Trim()
    }
    $null = Save-ClaudeCXUserSettings -Values $values -Path $current.Path
    $current = Read-ClaudeCXUserSettings -Path $current.Path
}

$effective = $null
$project = $null
if ($ProjectPath) {
    $repository = (& git -C $ProjectPath rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $repository) { throw "Not a Git repository: $ProjectPath" }
    $project = Read-ClaudeCXProjectSettings -Repository $repository
    $effective = Resolve-ClaudeCXRunSettings -User $current.Values -Project $project.Values
}

if ($Json) {
    [ordered]@{
        path = $current.Path
        exists = $current.Exists
        values = $current.Values
        errors = @($current.Errors)
        warnings = @($current.Warnings)
        locked = @((Get-ClaudeCXLockedSettings) | ForEach-Object { $_.label })
        project = $(if ($null -ne $project) {
                [ordered]@{
                    file_found = $project.Exists
                    values = $project.Values
                    errors = @($project.Errors)
                    warnings = @($project.Warnings)
                    effective = [ordered]@{
                        max_budget_usd = $effective.MaxBudgetUsd
                        max_turns = $effective.MaxTurns
                        timeout_seconds = $effective.TimeoutSeconds
                        model = $effective.Model
                        protected_paths = @($effective.ProtectedPaths)
                    }
                }
            })
    } | ConvertTo-Json -Depth 6
    exit 0
}

Write-Host "ClaudeCX settings ($($current.Path)$(if (-not $current.Exists) { ', not created yet: showing defaults' }))"
foreach ($field in $fields) {
    $value = $current.Values[$field.key]
    $shown = if ($field.type -eq 'paths') { if (@($value).Count) { @($value) -join ', ' } else { '(none)' } } else { [string]$value }
    if ($field.type -eq 'bool') { $shown = $shown.ToLowerInvariant() }
    Write-Host ("  {0,-24} {1}" -f $field.key, $shown)
}
foreach ($message in $current.Errors) { Write-Host "  problem: $message" -ForegroundColor Red }
foreach ($message in $current.Warnings) { Write-Host "  note: $message" -ForegroundColor Yellow }
Write-Host 'Fixed (cannot be changed):'
foreach ($item in (Get-ClaudeCXLockedSettings)) { Write-Host "  - $($item.label)" }
if ($null -ne $effective) {
    Write-Host ''
    Write-Host "For a run in this project$(if ($project.Exists) { ' (with its .claudecx.json)' }):"
    Write-Host "  budget $($effective.MaxBudgetUsd) USD, $($effective.MaxTurns) turns, $([int]($effective.TimeoutSeconds / 60)) minutes, model $($effective.Model)"
    Write-Host "  protected: $(@($effective.ProtectedPaths) -join ', ')"
    foreach ($message in @($project.Errors)) { Write-Host "  problem: $message" -ForegroundColor Red }
    foreach ($message in @($effective.Notes) + @($project.Warnings)) { Write-Host "  note: $message" -ForegroundColor Yellow }
}
if ($changing) { Write-Host 'Saved. The new settings apply to the next run.' -ForegroundColor Green }
