#Requires -Version 5.1
<#
.SYNOPSIS
    Runs tests\claude-sessions.Tests.ps1 with Pester.

.DESCRIPTION
    With -Shell all (the default), runs the tests once on each of PowerShell 7 (pwsh) and
    Windows PowerShell 5.1 (powershell) that is installed, each in its own process, and exits
    with 1 if any of them fails. -Shell pwsh / powershell runs them only on that one.

    Uses Pester 5 or later if it is installed globally. Otherwise looks in .tmp\modules under
    this project, and if it is not there either, prints installation instructions and exits.
    .tmp\modules is not tracked by git (a place for temporary development dependencies).
#>
param(
    [ValidateSet('all', 'pwsh', 'powershell')]
    [string]$Shell = 'all'
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

if ($Shell -eq 'all') {
    $shells = @('pwsh', 'powershell' | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
    if ($shells.Count -eq 0) {
        Write-Host 'Neither pwsh nor powershell was found.' -ForegroundColor Yellow
        exit 1
    }
    $failed = @()
    foreach ($name in $shells) {
        Write-Host "=== Running tests on $name ===" -ForegroundColor Cyan
        # A child started from pwsh inherits pwsh's PSModulePath, and Windows PowerShell 5.1 then
        # fails to load its own modules (such as Microsoft.PowerShell.Security). Leaving the
        # variable undefined (not empty) makes each child build its default value.
        $savedModulePath = $env:PSModulePath
        try {
            [System.Environment]::SetEnvironmentVariable('PSModulePath', $null, 'Process')
            & $name -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'run-tests.ps1') -Shell $name
            if ($LASTEXITCODE -ne 0) { $failed += $name }
        } finally {
            [System.Environment]::SetEnvironmentVariable('PSModulePath', $savedModulePath, 'Process')
        }
    }
    if ($failed.Count -gt 0) {
        Write-Host "Tests failed on: $($failed -join ', ')" -ForegroundColor Red
        exit 1
    }
    Write-Host "Tests passed on: $($shells -join ', ')" -ForegroundColor Green
    exit 0
}

$localModules = Join-Path $here '.tmp\modules'

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
if (-not $pester -and (Test-Path $localModules)) {
    $env:PSModulePath = "$localModules;$env:PSModulePath"
    $pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
}

if (-not $pester) {
    Write-Host "Pester 5 or later was not found on $Shell. Run one of the following:" -ForegroundColor Yellow
    # -SkipPublisherCheck: Windows PowerShell 5.1 ships Pester 3.4 signed by a different publisher,
    # which blocks installing a newer version without it.
    Write-Host '  Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck' -ForegroundColor DarkGray
    Write-Host "  Save-Module -Name Pester -MinimumVersion 5.0 -Path '$localModules' -Repository PSGallery" -ForegroundColor DarkGray
    exit 1
}

Import-Module $pester.Path -Force
$result = Invoke-Pester -Path (Join-Path $here 'tests\claude-sessions.Tests.ps1') -Output Detailed -PassThru
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
