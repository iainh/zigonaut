param(
    [ValidateSet('x86_64')]
    [string]$TargetArch = 'x86_64',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'Zigonaut.WinUI.Bridge.vcxproj'
$repository = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $repository 'zig-out\bin'

$msbuild = Get-Command MSBuild.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $msbuild) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $msbuild = & $vswhere -latest -products * -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    }
}
if (-not $msbuild) {
    throw 'MSBuild was not found. Install Visual Studio 2022 with Desktop development with C++.'
}

& $msbuild $project /restore /t:Build "/p:Configuration=$Configuration" /p:Platform=x64 /v:minimal
if ($LASTEXITCODE -ne 0) { throw "WinUI bridge build failed with exit code $LASTEXITCODE." }

$output = Join-Path $PSScriptRoot "x64\$Configuration"
New-Item -ItemType Directory -Force $destination | Out-Null
Copy-Item (Join-Path $output 'Zigonaut.WinUI.Bridge.dll') $destination -Force
Copy-Item (Join-Path $output 'Microsoft.WindowsAppRuntime.Bootstrap.dll') $destination -Force
Copy-Item (Join-Path $output 'Zigonaut.WinUI.Bridge.pri') (Join-Path $destination 'resources.pri') -Force

$runtime = Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.1.8' -ErrorAction SilentlyContinue |
    Where-Object Architecture -eq X64 |
    Select-Object -First 1
if (-not $runtime) {
    throw 'Windows App Runtime 1.8 x64 is required. Install it with: winget install -e --id Microsoft.WindowsAppRuntime.1.8'
}

Write-Host "WinUI bridge deployed to $destination"
