param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System.Runtime.InteropServices;
public static class TabTestPointer {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
}
'@
[void][TabTestPointer]::SetThreadDpiAwarenessContext([IntPtr](-4))

function Get-SlotPixels($Button) {
    $rect = $Button.Current.BoundingRectangle
    $bitmap = New-Object System.Drawing.Bitmap([int]$rect.Width, [int]$rect.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $stream = New-Object System.IO.MemoryStream
    try {
        $graphics.CopyFromScreen([int]$rect.Left, [int]$rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return [Convert]::ToBase64String($stream.ToArray())
    } finally {
        $stream.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

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

    $tabCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'CloseButton'
    )
    $firstTab = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tabCondition)
    $close = $firstTab.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    $windowBounds = $window.Current.BoundingRectangle
    [void][TabTestPointer]::SetCursorPos([int]($windowBounds.Left + 100), [int]($windowBounds.Top + 200))
    [TabTestPointer]::mouse_event(1, 1, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 250
    $closePixels = Get-SlotPixels $close

    # Keep the reporting process alive so shell integration does not end its status.
    $report = '[Console]::Write([string][char]27 + "]7501;state=working:id=tab-test" + [char]7); Start-Sleep -Seconds 60'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($report)).Replace('+', '{+}')
    $keyboard.SendKeys("powershell.exe -NoProfile -EncodedCommand $encoded{ENTER}")
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $statusTab = $null
    do {
        foreach ($tab in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCondition)) {
            if ($tab.Current.HelpText -eq 'Program status in this tab: Working') {
                $statusTab = $tab
                break
            }
        }
        if ($null -eq $statusTab) { Start-Sleep -Milliseconds 100 }
    } while ($null -eq $statusTab -and [DateTime]::UtcNow -lt $deadline)
    if ($null -eq $statusTab) { throw 'OSC 7501 status was not exposed in tab help text.' }

    $textStatusCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, 'Working'
    )
    if ($statusTab.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textStatusCondition).Count -ne 0) {
        throw 'The tab still displays a text status label instead of a glyph.'
    }
    $close = $statusTab.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    if ($null -eq $close -or [string]::IsNullOrEmpty($close.Current.Name)) {
        throw 'The status tab has no accessible close button.'
    }
    $bounds = $statusTab.Current.BoundingRectangle
    $slot = $close.Current.BoundingRectangle
    if ($slot.IsEmpty -or $slot.Width -le 0) { throw 'The status/close slot is not visible.' }
    $title = $statusTab.Current.Name
    # Sample several frames after the initial layout has settled: a static ring
    # replaces the close glyph too, but cannot pass this animation check.
    Start-Sleep -Milliseconds 500
    $frames = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($frame = 0; $frame -lt 10; $frame++) {
        [void]$frames.Add((Get-SlotPixels $close))
        Start-Sleep -Milliseconds 137
    }
    if ($frames.Count -lt 3) { throw 'The working status indicator is not visibly animated.' }
    Start-Sleep -Milliseconds 250
    if ((Get-SlotPixels $close) -eq $closePixels) {
        throw 'Program status did not visibly replace the native close glyph.'
    }
    $statusTab.SetFocus()
    $keyboard.SendKeys('{TAB}+{TAB}')
    Start-Sleep -Milliseconds 250
    if ((Get-SlotPixels $close) -ne $closePixels) {
        throw 'Keyboard focus did not restore the native close glyph.'
    }
    (Get-Terminal).SetFocus()
    Start-Sleep -Milliseconds 250
    # Enter the slot, leave over the title, then re-enter and click the native button.
    foreach ($x in @(($slot.Left + $slot.Width / 2), ($bounds.Left + 12), ($slot.Left + $slot.Width / 2))) {
        [void][TabTestPointer]::SetCursorPos([int]$x, [int]($slot.Top + $slot.Height / 2))
        [TabTestPointer]::mouse_event(1, 1, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 150
        if ($statusTab.Current.BoundingRectangle -ne $bounds -or $statusTab.Current.Name -ne $title) {
            throw 'Hovering the status/close slot changed the tab title or layout.'
        }
    }
    $tabCount = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCondition).Count
    [TabTestPointer]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [TabTestPointer]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $remaining = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCondition).Count
    } while ($remaining -eq $tabCount -and [DateTime]::UtcNow -lt $deadline)
    if ($remaining -ne $tabCount - 1) { throw 'Clicking the hovered status slot did not close exactly one tab.' }

    Write-Host 'WinUI tab rendering, input routing and status-slot closing passed.'
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}
