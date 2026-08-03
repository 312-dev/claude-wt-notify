# claude-wt-notify

Windows Terminal aware notifications for [Claude Code](https://claude.com/claude-code). Click the toast, land on the exact tab that raised it.

If you run several Claude Code sessions across Windows Terminal tabs, a generic "Claude needs your attention" toast tells you almost nothing. You still have to hunt through tabs to find which session is waiting. This wires each notification back to its origin.

---

## What it does

- **Clickable toasts.** Clicking the notification focuses the specific Windows Terminal *tab* the session runs in, not just the window.
- **Titled by conversation.** The toast title is the conversation's own name, with the message preview beneath it. Markdown is stripped, since toast text has no formatting.
- **Persistent until handled.** The toast stays on screen and flashes the taskbar button, then clears itself the moment you land on that tab, however you got there.
- **Unread counter.** A tray badge counting sessions waiting on you, decrementing as you visit each. Click it to jump to the oldest.
- **Only when it matters.** Notifications are gated on Claude Code's own tab status glyph, so sessions that are still working do not toast.
- **Correctly attributed.** Toasts show as "Claude Code" with their own icon and their own row in Settings > Notifications, instead of "Windows PowerShell".

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11 |
| Terminal | Windows Terminal |
| Shell | WSL (the installer is WSL-first), or native Windows |
| Runtime | PowerShell 5.1, in-box. No modules, no BurntToast. |
| Also | `python3` inside WSL, used to parse hook payloads |

Claude Code must be running *inside* a Windows Terminal tab. That is what makes a tab addressable.

---

## Install

### Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/312-dev/claude-wt-notify/main/install.sh | bash
```

Clones to `~/.local/share/claude-wt-notify`, installs everything, and wires the hook.

### From a clone

```bash
git clone https://github.com/312-dev/claude-wt-notify ~/repos/claude-wt-notify
cd ~/repos/claude-wt-notify
./install.sh
```

### Check before committing to anything

```bash
./install.sh --check
```

Runs preflight only and changes nothing:

```
Preflight
  ok    running under WSL
  ok    powershell.exe reachable (WSL interop)
  ok    python3 present (used to parse hook payloads)
  ok    Windows Terminal installed
```

### Flags

| Flag | Effect |
|---|---|
| `--check` | Preflight only, change nothing |
| `--no-settings` | Install everything but leave `~/.claude/settings.json` alone |
| `--force` | Overwrite the hook even if it sits in a dotfiles-managed tree |

### What the installer touches

| Target | What |
|---|---|
| `%LOCALAPPDATA%\ClaudeCode\` | The six helper scripts |
| `HKCU\Software\Classes\claudetab` | URI scheme, so a toast click can focus a tab |
| `HKCU\Software\Classes\AppUserModelId\Claude.Code` | Toast identity and icon |
| `~/.claude/hooks/cc-notify.sh` | The hook itself |
| `~/.claude/settings.json` | A `Notification` hook entry (backed up first, idempotent) |

Everything is `HKCU` scope. No elevation, no UAC prompt, nothing system-wide.

Restart Claude Code afterwards to pick up the hook.

### Native Windows

Skip `install.sh` and run the Windows half directly, then wire the hook yourself:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

## Updating

```bash
cd ~/repos/claude-wt-notify && git pull && ./install.sh
```

The installer is idempotent. Re-running it re-copies the scripts and leaves an already-wired `settings.json` untouched.

## Uninstall

```bash
./uninstall.sh
```

Removes the scripts, both registry entries, the runtime state, the hook, and the `settings.json` entry. Pass `--keep-settings` to leave your config alone.

---

## Configuration

### The hook entry

The installer adds this to `~/.claude/settings.json`. Add it by hand if you used `--no-settings`:

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

The hook also accepts `plan` and `pr` as its argument, if you want to fire it from `PreToolUse(ExitPlanMode)` or after a PR is created.

It is cross-platform: it falls back to `osascript` on macOS and `notify-send` on Linux, so the same file works everywhere. The Windows Terminal features simply do not engage off Windows.

### Toast icon

Drop a 256px PNG at `%LOCALAPPDATA%\ClaudeCode\claude-icon.png`. Everything degrades gracefully without one.

### If your dotfiles manage `~/.claude`

The installer detects this and refuses to write into a managed tree, telling you where the path actually resolves:

```
Hook
  skipped /home/you/.claude/hooks/cc-notify.sh
          that path resolves into a managed tree:
            /home/you/dotfiles/claude/.claude/hooks/cc-notify.sh
```

Vendor `hooks/cc-notify.sh` into your dotfiles yourself, or re-run with `--force`. Note that GNU Stow symlinks the *directory*, so the file inside can look ordinary while its parent is a link.

---

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

### The hard part

Windows Terminal tabs are not windows. Every tab in a window shares a single `HWND` of class `CASCADIA_HOSTING_WINDOW_CLASS`, so `SetForegroundWindow` can raise the window but can never select a tab. Tabs are XAML `TabViewItem`s, reachable only through UI Automation, where they expose `SelectionItemPattern`.

Two other things make it work:

**Finding the right tab.** Claude Code writes an `ai-title` record into the session transcript, and that string is exactly what it puts in the tab title. Every hook payload carries `transcript_path`, so the hook can read the title and hand it to the click handler as a join key. The title carries an animating status glyph, so matching normalizes it away.

**Surviving the hook exiting.** A hook process lives for about a second, and any click handler registered in-process dies with it. So the toast carries a `claudetab:` protocol activation URI, and a registered handler does the focusing whenever the click eventually happens.

### Only notifying when a session is actually waiting

Claude Code's `Notification` hook fires more broadly than "this session wants you". It marks state in the tab title glyph instead:

| Codepoint | Glyph | Meaning |
| --- | --- | --- |
| `U+2733` | eight-spoked asterisk | Awaiting the user |
| `U+2800` block | animating braille | Still working |
| none | | Not a Claude Code tab |

So the hook gates on the glyph rather than the event. It retries briefly first, because the hook can fire fractionally before the title repaints. It is deliberately **fail-open**: if the tab cannot be found at all it notifies anyway, since a missed notification is worse than a spurious one. Suppressions are logged.

The watcher applies the rule in reverse. If the glyph leaves `U+2733` while a toast is outstanding, the session went back to work and the toast is cleared as stale.

### Detecting that you opened the tab

The watcher polls four times a second, affordable only because the common check is cheap. Windows Terminal mirrors the selected tab's title into the window title, so `GetWindowText` answers "which tab is open" in about 0.2ms, against roughly 10ms for a UI Automation tree walk. UIA is kept as a periodic deep check, because a profile setting `tabTitle` or `suppressApplicationTitle` breaks that mirroring.

### Notes on the Windows APIs

- **Toast identity.** Non-packaged apps inherit the AUMID of whatever raised the toast, hence "Windows PowerShell". Registering `HKCU\Software\Classes\AppUserModelId\Claude.Code` with a `DisplayName` is enough to override it; the Start Menu shortcut Microsoft's docs describe is not actually required. BurntToast cannot do this, since as of 1.1.0 `Submit-BTNotification` has no `-AppId`.
- **Flashing.** `FlashWindowEx` is called with `FLASHW_TIMER`, not the more common `FLASHW_TIMERNOFG`. The latter stops as soon as the window is foregrounded, but foregrounding the window does not mean you opened the right tab. Windows suppresses flashing on the window already in front.
- **Tagging.** Toasts are tagged with the session ID, so a second notification for the same conversation replaces the first rather than stacking, and the watcher gets a handle for `History.Remove`.

---

## Troubleshooting

Everything logs to `%LOCALAPPDATA%\ClaudeCode\focus-tab.log`:

```
notify: suppressed (tab not awaiting, glyph U+2810): <conversation title>
watch:  flashing taskbar for '<title>' (hwnd 526746)
watch:  dismissed toast for '<title>' (tab focused)
tray:   started
```

| Symptom | Check |
|---|---|
| No toast at all | Look for a `suppressed` line. If the gate is wrong for your setup, confirm your tab titles carry the status prefix. |
| Toast appears, click does nothing | `reg query HKCU\Software\Classes\claudetab` |
| Toast says "Windows PowerShell" | AUMID key missing, re-run the installer |
| Toast fires while a session is working | Confirm the hook is the installed version; the glyph gate is what suppresses these |
| Taskbar does not flash | Expected when Terminal is already the foreground window; Windows suppresses it |

## License

MIT
