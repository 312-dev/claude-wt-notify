# claude-focus-tab.ps1 — focus the Windows Terminal tab of a Claude Code session.
#
# Invoked by the `claudetab:` protocol handler when a Claude Code toast is
# clicked. See install-claude-focus-tab.ps1 for registration.
#
# Usage:
#   claude-focus-tab.ps1 "claudetab:<base64url-json>"
#   claude-focus-tab.ps1 -Title "Some conversation title"     (manual/testing)
#
# The base64url payload decodes to {"title":..,"project":..,"session":..}.
# `title` is the session's ai-title, which is exactly the string Claude Code
# writes into the Windows Terminal tab title (prefixed with a status glyph
# such as U+2733 for "needs attention" or U+2802 for "working").
#
# Why UI Automation and not Win32: every Windows Terminal tab shares a single
# top-level HWND (class CASCADIA_HOSTING_WINDOW_CLASS). Tabs are XAML
# TabViewItems, reachable only through UIA, where they expose
# SelectionItemPattern. SetForegroundWindow can raise the window but can never
# choose the tab.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Argument,

    [string]$Title
)

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $env:LOCALAPPDATA 'ClaudeCode\focus-tab.log'

function Write-Log {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message |
            Add-Content -Path $LogFile -Encoding UTF8
    } catch { }
}

# --- decode the activation argument -----------------------------------------

function ConvertFrom-FocusToken {
    param([string]$Token)

    # Strip the scheme and any slashes the shell may have appended.
    $t = $Token -replace '^\s*claudetab:(//)?', ''
    $t = $t.TrimEnd('/')
    if (-not $t) { return $null }

    # base64url -> base64
    $b64 = $t.Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) {
        2 { $b64 += '==' }
        3 { $b64 += '=' }
        1 { return $null }
    }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
        return $json | ConvertFrom-Json
    } catch {
        Write-Log "decode failed for '$Token': $($_.Exception.Message)"
        return $null
    }
}

if (-not $Title -and $Argument) {
    $payload = ConvertFrom-FocusToken -Token $Argument
    if ($payload) { $Title = [string]$payload.title }
}

if (-not $Title) {
    Write-Log "no title resolved from argument '$Argument'; will raise the terminal only"
}

# --- Win32 foreground helpers ------------------------------------------------

Add-Type -Namespace CcFocus -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

function Set-Foreground {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return }

    # SW_RESTORE = 9. Un-minimize first or the window raises but stays iconic.
    if ([CcFocus.Win32]::IsIconic($Hwnd)) { [void][CcFocus.Win32]::ShowWindow($Hwnd, 9) }

    # Windows refuses SetForegroundWindow from a process that does not own the
    # foreground. Attaching our input queue to the current foreground thread is
    # the standard way around it, and unlike the ForegroundLockTimeout registry
    # tweak it needs no sign-out and no persistent system change.
    $fg = [CcFocus.Win32]::GetForegroundWindow()
    $fgThread = [CcFocus.Win32]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
    $ourThread = [CcFocus.Win32]::GetCurrentThreadId()

    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $ourThread) {
        $attached = [CcFocus.Win32]::AttachThreadInput($ourThread, $fgThread, $true)
    }
    try {
        [void][CcFocus.Win32]::BringWindowToTop($Hwnd)
        [void][CcFocus.Win32]::SetForegroundWindow($Hwnd)
    } finally {
        if ($attached) { [void][CcFocus.Win32]::AttachThreadInput($ourThread, $fgThread, $false) }
    }
}

# --- find and select the tab -------------------------------------------------

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]

function Get-TerminalWindows {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    return $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
}

function Get-NormalizedName {
    param([string]$Name)
    # Tab titles are "<status glyph> <ai-title>". Drop everything up to the
    # first letter or digit so the glyph (which changes as the session's state
    # changes) never affects matching.
    if (-not $Name) { return '' }
    $m = [regex]::Match($Name, '[\p{L}\p{N}].*$')
    if ($m.Success) { return $m.Value.Trim() }
    return $Name.Trim()
}

$targetNorm = (Get-NormalizedName -Name $Title)
$matched = $null
$matchedWindow = $null
$firstWindow = $null

foreach ($w in (Get-TerminalWindows)) {
    if (-not $firstWindow) { $firstWindow = $w }
    if (-not $targetNorm) { break }

    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $tabs = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)

    # Exact match on the normalized name first, then a contains-match so a
    # title that was truncated or has since drifted still lands.
    foreach ($pass in 1, 2) {
        for ($i = 0; $i -lt $tabs.Count; $i++) {
            $tab = $tabs.Item($i)
            $norm = Get-NormalizedName -Name $tab.Current.Name
            $hit = if ($pass -eq 1) {
                $norm -eq $targetNorm
            } else {
                $norm -and ($norm.IndexOf($targetNorm, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            }
            if ($hit) { $matched = $tab; $matchedWindow = $w; break }
        }
        if ($matched) { break }
    }
    if ($matched) { break }
}

if (-not $matchedWindow) { $matchedWindow = $firstWindow }

if (-not $matchedWindow) {
    Write-Log "no Windows Terminal window found; nothing to focus"
    exit 1
}

$hwnd = [IntPtr]$matchedWindow.Current.NativeWindowHandle
Set-Foreground -Hwnd $hwnd

if ($matched) {
    try {
        $pattern = $matched.GetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern)
        $pattern.Select()
        Write-Log "focused tab '$($matched.Current.Name)' for title '$Title'"
    } catch {
        Write-Log "select failed for '$Title': $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Log "no tab matched '$Title'; raised the terminal window only"
}

exit 0
