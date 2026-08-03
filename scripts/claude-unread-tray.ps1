# claude-unread-tray.ps1 — tray badge counting Claude Code sessions waiting on you.
#
# State is a directory of marker files, one per unread session:
#   %LOCALAPPDATA%\ClaudeCode\unread\<tag>.json  =  {title, launch, ts}
#
# claude-toast-watch.ps1 writes a marker when it raises a notification and
# removes it when it sees that conversation's tab get focus. This process also
# clears markers for whatever tab is currently open, which covers the case
# where a watcher hit its timeout and exited while the toast was still unread.
#
# Lifecycle: started on demand by the watcher, exits by itself once the count
# reaches zero, so nothing is left resident when there is nothing to show.
# A named mutex makes duplicate launches no-ops.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$BaseDir   = Join-Path $env:LOCALAPPDATA 'ClaudeCode'
$UnreadDir = Join-Path $BaseDir 'unread'
$LogFile   = Join-Path $BaseDir 'focus-tab.log'

function Write-Log {
    param([string]$Message)
    try {
        "{0}  tray: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message |
            Add-Content -Path $LogFile -Encoding UTF8
    } catch { }
}

# --- single instance ---------------------------------------------------------

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeCodeUnreadTray', [ref]$created)
if (-not $created) { exit 0 }

if (-not (Test-Path $UnreadDir)) { New-Item -ItemType Directory -Path $UnreadDir -Force | Out-Null }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace CcTray -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
'@

function Get-NormalizedName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $m = [regex]::Match($Name, '[\p{L}\p{N}].*$')
    if ($m.Success) { return $m.Value.Trim() }
    return $Name.Trim()
}

function Get-ActiveTabTitle {
    # Same cheap trick the watcher uses: Terminal mirrors the selected tab's
    # title into the window title, so this costs a fraction of a millisecond.
    $hwnd = [CcTray.Win32]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $sb = New-Object System.Text.StringBuilder 256
    [void][CcTray.Win32]::GetClassName($hwnd, $sb, $sb.Capacity)
    if ($sb.ToString() -ne 'CASCADIA_HOSTING_WINDOW_CLASS') { return $null }
    $wt = New-Object System.Text.StringBuilder 512
    [void][CcTray.Win32]::GetWindowText($hwnd, $wt, $wt.Capacity)
    return (Get-NormalizedName -Name $wt.ToString())
}

function Get-Unread {
    $out = @()
    foreach ($f in (Get-ChildItem -Path $UnreadDir -Filter '*.json' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime)) {
        try {
            $j = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $out += [pscustomobject]@{
                Tag    = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                Title  = [string]$j.title
                Launch = [string]$j.launch
                Path   = $f.FullName
            }
        } catch { }
    }
    return $out
}

# --- tray icon ---------------------------------------------------------------

$script:iconHandle = [IntPtr]::Zero

function New-CountIcon {
    param([int]$Count)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 203, 100, 62))
    $g.FillEllipse($bg, 0, 0, 31, 31)

    $text = if ($Count -gt 9) { '9+' } else { "$Count" }
    $size = if ($Count -gt 9) { 15 } else { 20 }
    $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF(0, 0, 32, 32)
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, $rect, $fmt)

    $g.Dispose(); $font.Dispose(); $bg.Dispose()

    $h = $bmp.GetHicon()
    $bmp.Dispose()
    # GetHicon hands back a handle the caller owns. Without DestroyIcon on the
    # previous one this leaks a GDI object on every single refresh.
    if ($script:iconHandle -ne [IntPtr]::Zero) { [void][CcTray.Win32]::DestroyIcon($script:iconHandle) }
    $script:iconHandle = $h
    return [System.Drawing.Icon]::FromHandle($h)
}

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Visible = $false
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$ni.ContextMenuStrip = $menu

function Invoke-Focus {
    param([string]$Launch)
    if (-not $Launch) { return }
    # Route through the registered claudetab: handler rather than calling the
    # focuser directly, so there is exactly one code path that focuses a tab.
    try { Start-Process $Launch } catch { Write-Log "focus failed: $($_.Exception.Message)" }
}

$ni.add_MouseClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $items = Get-Unread
    if ($items.Count -gt 0) { Invoke-Focus -Launch $items[0].Launch }
})

# --- poll --------------------------------------------------------------------

function Update-Tray {
    # Clear the marker for whatever tab is open right now. This is what makes
    # the count self-correct even when a watcher timed out and went away.
    $active = Get-ActiveTabTitle
    if ($active) {
        foreach ($u in (Get-Unread)) {
            if ((Get-NormalizedName -Name $u.Title) -eq $active) {
                Remove-Item -Path $u.Path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $items = Get-Unread
    $n = $items.Count

    if ($n -eq 0) {
        $ni.Visible = $false
        Write-Log "count 0, exiting"
        $script:timer.Stop()
        $ni.Dispose()
        if ($script:iconHandle -ne [IntPtr]::Zero) { [void][CcTray.Win32]::DestroyIcon($script:iconHandle) }
        [System.Windows.Forms.Application]::Exit()
        return
    }

    $ni.Icon = New-CountIcon -Count $n
    $ni.Text = if ($n -eq 1) { "1 Claude Code session waiting" } else { "$n Claude Code sessions waiting" }
    $ni.Visible = $true

    $menu.Items.Clear()
    foreach ($u in $items) {
        $launch = $u.Launch
        $mi = $menu.Items.Add($u.Title)
        $mi.Add_Click({ Invoke-Focus -Launch $launch }.GetNewClosure())
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $clear = $menu.Items.Add('Clear all')
    $clear.Add_Click({
        Get-ChildItem -Path $UnreadDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    })
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 1000
$script:timer.add_Tick({ try { Update-Tray } catch { Write-Log "tick failed: $($_.Exception.Message)" } })

Write-Log "started"
Update-Tray

# Guard: if there was nothing to show, Update-Tray already called
# Application::Exit() before the message loop existed, and entering Run() now
# would hang forever with no way out. Bail before starting the loop instead.
if ((Get-Unread).Count -eq 0) { exit 0 }

$script:timer.Start()
[System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
