# Minimal Zigonaut OSC 133/7 integration for Windows PowerShell 5.1 and PowerShell 7.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return }
if ($global:ZigonautShellIntegrationLoaded) { return }

$promptCommand = Get-Command Prompt -CommandType Function -ErrorAction SilentlyContinue
$readLineCommand = Get-Command PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
if (-not $promptCommand) { return }

$global:ZigonautShellIntegrationLoaded = $true
$global:ZigonautOriginalPrompt = $promptCommand.ScriptBlock
$global:ZigonautCommandOpen = $false
$global:ZigonautInputCancelled = $false

function global:ZigonautWriteOsc7 {
    try {
        $uri = (New-Object System.Uri -ArgumentList ([System.IO.Path]::GetFullPath($PWD.ProviderPath))).AbsoluteUri
        [Console]::Write("$([char]27)]7;$uri$([char]7)")
    } catch { }
}

if (-not $readLineCommand) {
    function global:Prompt {
        ZigonautWriteOsc7
        & $global:ZigonautOriginalPrompt
    }
    return
}

$global:ZigonautOriginalReadLine = $readLineCommand.ScriptBlock

function global:ZigonautInvokeOriginalPrompt([bool] $Succeeded) {
    if (-not $Succeeded) {
        Write-Error 'Zigonaut prompt status' -ErrorAction SilentlyContinue
    }
    & $global:ZigonautOriginalPrompt
}

function global:Prompt {
    $commandSucceeded = $?
    if ($global:ZigonautCommandOpen) {
        $status = if ($commandSucceeded) { 0 } else { 1 }
        [Console]::Write("$([char]27)]133;D;$status$([char]7)")
        $global:ZigonautCommandOpen = $false
    } elseif ($global:ZigonautInputCancelled) {
        [Console]::Write("$([char]27)]133;D$([char]7)")
        $global:ZigonautInputCancelled = $false
    }
    ZigonautWriteOsc7
    [Console]::Write("$([char]27)]133;A$([char]7)")
    $result = @(ZigonautInvokeOriginalPrompt $commandSucceeded)
    $marker = "$([char]27)]133;B$([char]7)"
    if ($result.Count -eq 0) { return $marker }
    $result[$result.Count - 1] = [string]$result[$result.Count - 1] + $marker
    return $result
}

function global:PSConsoleHostReadLine {
    try {
        $line = & $global:ZigonautOriginalReadLine
    } catch {
        $global:ZigonautInputCancelled = $true
        throw
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
        $global:ZigonautInputCancelled = $true
    } else {
        [Console]::Write("$([char]27)]133;C$([char]7)")
        $global:ZigonautCommandOpen = $true
    }
    return $line
}
