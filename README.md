# claude-wt-notify

Windows Terminal aware notifications for [Claude Code](https://claude.com/claude-code). Click the toast, land on the exact tab that raised it.

If you run several Claude Code sessions across Windows Terminal tabs, a generic "Claude needs your attention" toast tells you almost nothing. You still have to hunt through tabs to find which session is waiting. This wires the notification back to its origin.

## What it does

- **Clickable toasts.** Clicking the notification focuses the specific Windows Terminal tab the session is running in, not just the window.
- **Titled by conversation.** The toast title is the conversation's own name, with the message preview beneath it. Markdown is stripped, since toast text has no formatting.
- **Persistent until handled.** The toast stays on screen and flashes the taskbar button, then clears itself the moment you land on that tab, however you got there.
- **Unread counter.** A tray badge counting sessions waiting on you, decrementing as you visit each one. Click it to jump to the oldest.
- **Correctly attributed.** Toasts show as "Claude Code" with their own icon and their own row in Settings > Notifications, instead of "Windows PowerShell".

## The hard part

Windows Terminal tabs are not windows. Every tab in a window shares a single `HWND` of class `CASCADIA_HOSTING_WINDOW_CLASS`, so `SetForegroundWindow` can raise the window but can never select a tab. Tabs are XAML `TabViewItem`s, reachable only through UI Automation, where they expose `SelectionItemPattern`.

Two other things make it work:

**Finding the right tab.** Claude Code writes an `ai-title` record into the session transcript, and that string is exactly what it puts in the Windows Terminal tab title. Every hook payload carries `transcript_path`, so the hook can read the title and hand it to the click handler as the join key. The tab title is prefixed with a status glyph that animates, so matching normalizes it away.

**Surviving the hook exiting.** A hook process lives for about a second. Any click handler registered in-process dies with it. So the toast carries a `claudetab:` protocol activation URI, and a registered URI handler does the focusing whenever the click eventually happens.

## Requirements

- Windows 10 or 11 with Windows Terminal
- Claude Code running inside a Windows Terminal tab (WSL or native)
- PowerShell 5.1, which is in-box. No modules, no BurntToast.

## Install

```powershell
git clone https://github.com/312-dev/claude-wt-notify
cd claude-wt-notify
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

From WSL:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w ./install.ps1)"
```

This copies the scripts to `%LOCALAPPDATA%\ClaudeCode\` and registers the `claudetab:` scheme plus the toast identity. Everything is under `HKCU`, so there is no elevation prompt and nothing system-wide.

Then wire the hook. Copy `hooks/cc-notify.sh` somewhere on your machine (for example `~/.claude/hooks/`), make it executable, and reference it from `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/cc-notify.sh notify", "async": true }
        ]
      }
    ]
  }
}
```

The hook is cross-platform. It falls back to `osascript` on macOS and `notify-send` on Linux, so the same file works everywhere; the Windows Terminal features simply do not engage off Windows.

Optionally drop a 256px PNG at `%LOCALAPPDATA%\ClaudeCode\claude-icon.png` to give the toasts an icon. Everything degrades gracefully without one.

## How it works

```
Claude Code Notification hook
        |
        v
  cc-notify.sh          reads ai-title + last assistant message from the transcript
        |               checks the tab glyph, suppresses if the session is not waiting
        v
  WinRT toast           raised under the Claude.Code AUMID,
        |               carrying launch="claudetab:<base64url payload>"
        |
        +--> claude-toast-watch.ps1   flashes the taskbar, writes an unread marker,
        |                             polls for the tab, clears everything when found
        |
        +--> claude-unread-tray.ps1   tray badge counting unread markers
        |
        v
  user clicks
        |
        v
  claudetab: handler -> claude-focus-tab.ps1 -> UIA SelectionItemPattern.Select()
```

### Only notifying when a session is actually waiting

Claude Code's `Notification` hook fires more broadly than "this session wants you". It marks tab state in the title glyph instead:

| Codepoint | Glyph | Meaning |
| --- | --- | --- |
| `U+2733` | the eight-spoked asterisk | Awaiting the user |
| `U+2800` block | animating braille | Still working |
| none | | Not a Claude Code tab |

So the hook gates on the glyph rather than trusting the event, and suppresses the toast when the tab is not awaiting you. It retries briefly first, because the hook can fire fractionally before the title repaints. It is deliberately fail-open: if the tab cannot be found at all, it notifies anyway, on the grounds that a missed notification is worse than a spurious one. Suppressions are logged.

The watcher applies the same rule in reverse. If the glyph leaves `U+2733` while a toast is outstanding, the session went back to work and the toast is cleared as stale.

### Detecting that you opened the tab

The watcher polls four times a second, which is only affordable because the common check is cheap. Windows Terminal mirrors the selected tab's title into the window title, so `GetWindowText` answers "which tab is open" in about 0.2ms, against roughly 10ms for a UI Automation tree walk. UIA is kept as a periodic deep check every couple of seconds, because a profile setting `tabTitle` or `suppressApplicationTitle` breaks that mirroring.

### Notes on the Windows APIs

- **Toast identity.** Non-packaged apps inherit the AUMID of whatever raised the toast, hence "Windows PowerShell". Registering `HKCU\Software\Classes\AppUserModelId\Claude.Code` with a `DisplayName` is enough to override it. The Start Menu shortcut Microsoft's docs describe is not actually required.
- **Flashing.** `FlashWindowEx` is called with `FLASHW_TIMER`, not the more common `FLASHW_TIMERNOFG`. The latter stops as soon as the window is foregrounded, but foregrounding the window does not mean you opened the right tab. Note that Windows suppresses flashing on the window that is already in front.
- **Tagging.** Toasts are tagged with the session ID, so a second notification for the same conversation replaces the first rather than stacking, and the watcher has a handle for `History.Remove`.

## Uninstall

```powershell
.\install.ps1 -Uninstall
```

Removes the copied scripts, the `claudetab:` registration, and the AUMID. Toasts revert to the PowerShell identity.

## Troubleshooting

Everything logs to `%LOCALAPPDATA%\ClaudeCode\focus-tab.log`:

```
notify: suppressed (tab not awaiting, glyph U+2810): <conversation title>
watch:  flashing taskbar for '<title>' (hwnd 526746)
watch:  dismissed toast for '<title>' (tab focused)
tray:   started
```

- **Toast never appears.** Check the log for a `suppressed` line. If the glyph gate is wrong for your setup, confirm your tab titles actually carry the status prefix.
- **Toast appears but clicking does nothing.** Confirm the scheme is registered: `reg query HKCU\Software\Classes\claudetab`.
- **Toast still says "Windows PowerShell".** The AUMID key is missing; re-run the installer.

## License

MIT
