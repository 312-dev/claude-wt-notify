# claude-toast-watch.ps1 — clear a Claude Code toast once its tab is on screen.
#
# Launched (hidden, detached) by cc-notify.sh right after a toast is raised.
# The toast uses scenario="reminder", so it stays up until acted on; this
# watcher supplies the "acted on" signal that matters in practice, which is
# the user actually landing on the conversation's Windows Terminal tab. That
# covers arriving via the toast itself, via Alt-Tab, or via a plain tab click.
#
# Usage:
#   claude-toast-watch.ps1 "claudetab:<base64url-json>" "<tag>" [-TimeoutSeconds 900]
#
# Exits when: the tab is seen focused, the timeout expires, or another watcher
# for the same tag takes over (see the PID file below).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Argument,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Tag,

    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'

$Aumid   = 'Claude.Code'
$Group   = 'claude-code'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ClaudeCode'
$LogFile = Join-Path $BaseDir 'focus-tab.log'
$PidFile = Join-Path $BaseDir ("watch-{0}.pid" -f ($Tag -replace '[^0-9a-zA-Z-]', '_'))

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
        "{0}  watch: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message |
            Add-Content -Path $LogFile -Encoding UTF8
    } catch { }
}

# --- resolve the title we are waiting on ------------------------------------

function ConvertFrom-FocusToken {
    param([string]$Token)
    $t = ($Token -replace '^\s*claudetab:(//)?', '').TrimEnd('/')
    if (-not $t) { return $null }
    $b64 = $t.Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) { 2 { $b64 += '==' } 3 { $b64 += '=' } 1 { return $null } }
    try {
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64)) | ConvertFrom-Json
    } catch { return $null }
}

$payload = ConvertFrom-FocusToken -Token $Argument
$title = if ($payload) { [string]$payload.title } else { '' }
if (-not $title) {
    Write-Log "no title in token; nothing to watch"
    exit 1
}

function Get-NormalizedName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $m = [regex]::Match($Name, '[\p{L}\p{N}].*$')
    if ($m.Success) { return $m.Value.Trim() }
    return $Name.Trim()
}
$targetNorm = Get-NormalizedName -Name $title

# --- only one watcher per conversation --------------------------------------

# A newer notification for the same conversation replaces the toast (same Tag),
# so its watcher should replace ours too. Claiming the PID file is how the
# older watcher learns to stand down, without anyone killing processes.
if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
$myPid = $PID
Set-Content -Path $PidFile -Value $myPid -Encoding ASCII

# --- unread marker + tray badge ---------------------------------------------

# One marker file per conversation awaiting attention. Deliberately outlives
# this process: if the watcher times out while the toast is still unread, the
# tray keeps counting it and clears it itself once the tab is visited.
$UnreadDir  = Join-Path $BaseDir 'unread'
$MarkerFile = Join-Path $UnreadDir ("{0}.json" -f ($Tag -replace '[^0-9a-zA-Z-]', '_'))
if (-not (Test-Path $UnreadDir)) { New-Item -ItemType Directory -Path $UnreadDir -Force | Out-Null }
@{ title = $title; launch = $Argument; ts = (Get-Date).ToString('o') } |
    ConvertTo-Json -Compress | Set-Content -Path $MarkerFile -Encoding UTF8

# Fire-and-forget: the tray script holds a named mutex, so launching it when
# one is already running costs nothing and starting it here means there is no
# permanently resident process when there is nothing to count.
$trayVbs = Join-Path $BaseDir 'claude-unread-tray.vbs'
if (Test-Path $trayVbs) {
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$trayVbs`"" -WindowStyle Hidden
}

# --- win32 + UIA -------------------------------------------------------------

Add-Type -Namespace CcWatch -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
'@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]

# FlashWindowEx needs a struct, so this one cannot be done with the inline
# MemberDefinition shorthand used above.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CcFlash {
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }
    [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    private const uint FLASHW_STOP  = 0;
    private const uint FLASHW_ALL   = 3;   // caption + taskbar button
    private const uint FLASHW_TIMER = 4;   // keep flashing until told to stop

    private static FLASHWINFO Make(IntPtr h, uint flags, uint count) {
        FLASHWINFO fi = new FLASHWINFO();
        fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        fi.hwnd = h; fi.dwFlags = flags; fi.uCount = count; fi.dwTimeout = 0;
        return fi;
    }
    public static void Start(IntPtr h) {
        // Deliberately not FLASHW_TIMERNOFG: that stops the moment the window
        // comes to the foreground, but the whole point here is that the right
        // *tab* has to be open, which foregrounding the window does not imply.
        FLASHWINFO fi = Make(h, FLASHW_ALL | FLASHW_TIMER, uint.MaxValue);
        FlashWindowEx(ref fi);
    }
    public static void Stop(IntPtr h) {
        FLASHWINFO fi = Make(h, FLASHW_STOP, 0);
        FlashWindowEx(ref fi);
    }
}
'@

function Get-HostWindowHandle {
    # The window hosting our tab, whether or not it is focused or even visible.
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    $wins = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    foreach ($w in $wins) {
        try {
            $tabs = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
            for ($i = 0; $i -lt $tabs.Count; $i++) {
                if ((Get-NormalizedName -Name $tabs.Item($i).Current.Name) -eq $targetNorm) {
                    return [IntPtr]$w.Current.NativeWindowHandle
                }
            }
        } catch { }
    }
    return [IntPtr]::Zero
}

# Raw tab title (glyph included) for our conversation, or $null if the tab is
# gone. U+2733 means Claude Code is waiting on the user; anything else (the
# animating U+2800-block spinner) means it went back to work and the
# notification is stale.
$AWAITING_GLYPH = 0x2733
function Get-TabRawTitle {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    try {
        foreach ($w in $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
            $tabs = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
            for ($i = 0; $i -lt $tabs.Count; $i++) {
                $n = $tabs.Item($i).Current.Name
                if ((Get-NormalizedName -Name $n) -eq $targetNorm) { return $n }
            }
        }
    } catch { }
    return $null
}

$flashHwnd = [IntPtr]::Zero
$flashLogged = $false
function Start-Flash {
    if ($script:flashHwnd -eq [IntPtr]::Zero) { $script:flashHwnd = Get-HostWindowHandle }
    if ($script:flashHwnd -ne [IntPtr]::Zero) {
        [CcFlash]::Start($script:flashHwnd)
        # Logged once rather than every re-assert, so the log stays readable
        # but a "did the flash actually start" question is still answerable.
        if (-not $script:flashLogged) {
            Write-Log "flashing taskbar for '$title' (hwnd $($script:flashHwnd))"
            $script:flashLogged = $true
        }
    } elseif (-not $script:flashLogged) {
        Write-Log "could not resolve host window for '$title'; no taskbar flash"
        $script:flashLogged = $true
    }
}
function Stop-Flash {
    if ($script:flashHwnd -ne [IntPtr]::Zero) { [CcFlash]::Stop($script:flashHwnd) }
}

function Test-TabIsForeground {
    param([switch]$Deep)

    # Cheap gate first: unless a Windows Terminal window is actually in front,
    # there is nothing to check at all.
    $hwnd = [CcWatch.Win32]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $false }

    $sb = New-Object System.Text.StringBuilder 256
    [void][CcWatch.Win32]::GetClassName($hwnd, $sb, $sb.Capacity)
    if ($sb.ToString() -ne 'CASCADIA_HOSTING_WINDOW_CLASS') { return $false }

    # Primary signal: Terminal mirrors the selected tab's title into the window
    # title, and GetWindowText costs ~0.2ms against ~10ms for a UIA tree walk.
    # That 50x gap is what allows a 250ms poll instead of 1s, which is the
    # difference between dismissal feeling instant and feeling laggy.
    $wt = New-Object System.Text.StringBuilder 512
    [void][CcWatch.Win32]::GetWindowText($hwnd, $wt, $wt.Capacity)
    if ((Get-NormalizedName -Name $wt.ToString()) -eq $targetNorm) { return $true }

    # Safety net, run only every few ticks: a profile setting tabTitle or
    # suppressApplicationTitle decouples the window title from the tab, and
    # then UIA is the only reliable answer.
    if (-not $Deep) { return $false }

    try {
        $win = $AE::FromHandle($hwnd)
        if (-not $win) { return $false }
        $tabCond = New-Object System.Windows.Automation.PropertyCondition(
            $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
        $tabs = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
        for ($i = 0; $i -lt $tabs.Count; $i++) {
            $tab = $tabs.Item($i)
            $sel = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if (-not $sel.Current.IsSelected) { continue }
            return ((Get-NormalizedName -Name $tab.Current.Name) -eq $targetNorm)
        }
    } catch { return $false }
    return $false
}

function Remove-Toast {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($Tag, $Group, $Aumid)
        return $true
    } catch {
        Write-Log "remove failed for tag '$Tag': $($_.Exception.Message)"
        return $false
    }
}

# --- poll --------------------------------------------------------------------

Start-Flash

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$tick = 0
while ((Get-Date) -lt $deadline) {
    # Stand down if a newer watcher claimed this conversation.
    # Note: no Stop-Flash on this path. The newer watcher has already started
    # its own flash on the same window, so stopping here would cancel theirs.
    try {
        $owner = (Get-Content -Path $PidFile -ErrorAction Stop | Select-Object -First 1).Trim()
        if ($owner -ne "$myPid") { exit 0 }
    } catch { exit 0 }

    # Checked before the first sleep on purpose: if the user was already
    # sitting on this tab when the toast fired, it should clear immediately
    # rather than linger for a second announcing something they can see.
    if (Test-TabIsForeground -Deep:($tick % 8 -eq 0)) {
        Stop-Flash
        if (Remove-Toast) { Write-Log "dismissed toast for '$title' (tab focused)" }
        try { Remove-Item -Path $MarkerFile -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue } catch { }
        exit 0
    }

    # Stale check, on the same cadence as the deep check: if Claude went back
    # to work, whatever the toast was announcing is no longer true and the
    # notification should not keep flashing the taskbar at the user.
    if ($tick % 8 -eq 0) {
        $raw = Get-TabRawTitle
        if ($raw -and [int]$raw[0] -ne $AWAITING_GLYPH) {
            Stop-Flash
            if (Remove-Toast) { Write-Log "cleared stale toast for '$title' (session resumed)" }
            try { Remove-Item -Path $MarkerFile -Force -ErrorAction SilentlyContinue } catch { }
            try { Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue } catch { }
            exit 0
        }
    }

    # Re-assert every ~5s. Windows cancels a flash when the window is
    # activated, which happens whenever the user visits a *different* tab in
    # the same window, and the notification is still outstanding at that point.
    $tick++
    if ($tick % 20 -eq 0) { Start-Flash }

    Start-Sleep -Milliseconds 250
}

Stop-Flash
Write-Log "timed out after ${TimeoutSeconds}s waiting for '$title'; toast left in place"
try { Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue } catch { }
exit 0
