param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$executablePath = (Resolve-Path $Executable).Path
$process = Start-Process -FilePath $executablePath -PassThru

try {
    for ($attempt = 0; $attempt -lt 100 -and $process.MainWindowHandle -eq 0; $attempt++) {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }
    if ($process.MainWindowHandle -eq 0) { throw 'Zigonaut did not create a window.' }

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $processCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $process.Id
    )
    $window = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $processCondition)
    if ($null -eq $window) { throw 'Zigonaut window is not visible to UI Automation.' }

    $terminalCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        'ZigonautTerminalPane'
    )
    $keyboard = New-Object -ComObject WScript.Shell
    if (-not $keyboard.AppActivate($process.Id)) { throw 'Unable to activate Zigonaut.' }

    function Get-Terminal {
        return $window.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            $terminalCondition
        )
    }

    function Get-TerminalText {
        $terminal = Get-Terminal
        if ($null -eq $terminal) { return $null }
        try {
            $pattern = $terminal.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            return $pattern.DocumentRange.GetText(-1)
        } catch {
            return $null
        }
    }

    function Wait-ForTerminalText([string]$Token, [int]$TimeoutMilliseconds = 10000) {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        do {
            $text = Get-TerminalText
            if ($null -ne $text -and $text.Contains($Token)) { return $text }
            if ($process.HasExited) { throw "Zigonaut exited while waiting for '$Token'." }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "The active terminal did not render '$Token'."
    }

    function Wait-ForDifferentTerminal([string]$PreviousToken, [int]$TimeoutMilliseconds = 10000) {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        do {
            $text = Get-TerminalText
            if ($null -ne $text -and $text.Length -gt 0 -and -not $text.Contains($PreviousToken)) {
                return $text
            }
            if ($process.HasExited) { throw 'Zigonaut exited while changing tabs.' }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'The active terminal did not change after creating a tab.'
    }

    $terminal = Get-Terminal
    if ($null -eq $terminal) { throw 'Zigonaut did not create a terminal pane.' }
    $terminal.SetFocus()
    Start-Sleep -Milliseconds 250

    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    $firstToken = "FIRST$suffix"
    $secondToken = "SECOND$suffix"
    $returnToken = "RETURN$suffix"

    $keyboard.SendKeys("echo $firstToken{ENTER}")
    [void](Wait-ForTerminalText $firstToken)

    $keyboard.SendKeys('^+t')
    [void](Wait-ForDifferentTerminal $firstToken)
    $keyboard.SendKeys("echo $secondToken{ENTER}")
    [void](Wait-ForTerminalText $secondToken)

    $keyboard.SendKeys('^{TAB}')
    [void](Wait-ForTerminalText $firstToken)
    $keyboard.SendKeys("echo $returnToken{ENTER}")
    [void](Wait-ForTerminalText $returnToken)

    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($focused.Current.AutomationId -ne 'ZigonautTerminalPane') {
        throw "Focus moved to '$($focused.Current.AutomationId)' instead of the selected terminal."
    }

    Write-Host 'WinUI tab rendering and input routing passed.'
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}
