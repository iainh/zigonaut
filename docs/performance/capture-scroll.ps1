[CmdletBinding()]
param(
    [string]$Output = (Join-Path (Get-Location) 'zigonaut-scroll.etl'),
    [string]$Executable,
    [ValidateRange(1, 300)]
    [int]$DurationSeconds = 0,
    [switch]$EventsOnly
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell prompt.'
}

$profile = Join-Path $PSScriptRoot 'zigonaut-scroll.wprp'
$outputPath = [IO.Path]::GetFullPath($Output)
$outputDirectory = Split-Path -Parent $outputPath
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

if ($EventsOnly) {
    Write-Host 'Starting Zigonaut ETW collection.'
    & wpr.exe -start "${profile}!ZigonautScroll" -filemode
} else {
    Write-Host 'Starting CPU, scheduling, GPU, and Zigonaut ETW collection.'
    & wpr.exe -start GeneralProfile -start GPU -start "${profile}!ZigonautScroll" -filemode
}
if ($LASTEXITCODE -ne 0) {
    throw "WPR failed to start (exit code $LASTEXITCODE). Another WPR recording may already be active."
}

$started = $true
try {
    if ($Executable) {
        $resolvedExecutable = (Resolve-Path $Executable).Path
        Start-Process $resolvedExecutable
    }
    Write-Host ''
    Write-Host 'Populate scrollback, wait for output to stop, then reproduce the burst/pause scrolling.'
    if ($DurationSeconds -gt 0) {
        Write-Host "Capturing for $DurationSeconds seconds."
        Start-Sleep -Seconds $DurationSeconds
    } else {
        Read-Host 'Press Enter as soon as the pause has occurred'
    }
    & wpr.exe -marker 'Zigonaut scroll reproduction complete' -flush
} finally {
    if ($started) {
        Write-Host "Saving $outputPath"
        & wpr.exe -stop $outputPath 'Zigonaut burst/pause scroll reproduction'
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WPR failed to save the trace (exit code $LASTEXITCODE)."
        }
    }
}
