param(
    [ValidateSet('x86_64', 'arm64')]
    [string]$TargetArch = 'x86_64',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$DebugIcon
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'Zigonaut.WinUI.Bridge.vcxproj'
$repository = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $repository 'zig-out\bin'
$platform = if ($TargetArch -eq 'arm64') { 'ARM64' } else { 'x64' }
$runtimeArchitecture = if ($TargetArch -eq 'arm64') { 'Arm64' } else { 'X64' }

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

& $msbuild $project /restore /t:Build "/p:Configuration=$Configuration" "/p:Platform=$platform" /v:minimal
if ($LASTEXITCODE -ne 0) { throw "WinUI bridge build failed with exit code $LASTEXITCODE." }

$output = Join-Path $PSScriptRoot "$platform\$Configuration"
New-Item -ItemType Directory -Force $destination | Out-Null
Copy-Item (Join-Path $output 'Zigonaut.WinUI.Bridge.dll') $destination -Force
Copy-Item (Join-Path $output 'Microsoft.WindowsAppRuntime.Bootstrap.dll') $destination -Force
Copy-Item (Join-Path $output 'Zigonaut.WinUI.Bridge.pri') (Join-Path $destination 'resources.pri') -Force
Copy-Item (Join-Path $output 'conpty.dll') $destination -Force
foreach ($hostArchitecture in @('x64', 'arm64')) {
    $hostExecutable = Join-Path $output "$hostArchitecture\OpenConsole.exe"
    if (Test-Path $hostExecutable -PathType Leaf) {
        $hostDestination = Join-Path $destination $hostArchitecture
        New-Item -ItemType Directory -Force $hostDestination | Out-Null
        Copy-Item $hostExecutable $hostDestination -Force
    }
}
$aboutIcon = if ($DebugIcon -or $Configuration -eq 'Debug') {
    'assets\icons\zigonaut-debug-master.png'
} else {
    'assets\icons\zigonaut-about-1024.png'
}
Copy-Item (Join-Path $repository $aboutIcon) (Join-Path $destination 'zigonaut-about-1024.png') -Force

$runtime = Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.2' -ErrorAction SilentlyContinue |
    Where-Object { $_.Architecture -eq $runtimeArchitecture -and $_.Version -ge [version]'2.3.1.0' } |
    Select-Object -First 1
if (-not $runtime) {
    $installerArchitecture = $runtimeArchitecture.ToLowerInvariant()
    throw "Windows App Runtime 2.3.1 $runtimeArchitecture is required. Install it from https://aka.ms/windowsappsdk/2.3/2.3.1/windowsappruntimeinstall-$installerArchitecture.exe"
}

Write-Host "WinUI bridge deployed to $destination"
