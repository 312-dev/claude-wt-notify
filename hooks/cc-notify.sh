#!/bin/bash
# cc-notify.sh — cross-platform OS notifications for Claude Code hook events.
#
# Wired from ~/.claude/settings.json and ccmanager/config.json:
#   Notification                 → cc-notify.sh notify
#   PreToolUse(ExitPlanMode)     → cc-notify.sh plan
#   PostToolUse(gh pr create*)   → cc-notify.sh pr
#   PostToolUse(az repos pr*)    → cc-notify.sh pr
#   ccmanager status hooks       → cc-notify.sh notify
#
# stdin (when present) carries the Claude Code hook-event JSON, which includes
# `cwd` and `transcript_path` on every hook invocation. We use those to answer
# "which conversation" (cwd's basename) and to pull a snippet of Claude's most
# recent message from the transcript, so a Windows toast is enough to tell
# which tab needs attention and what it was about, without alt-tabbing through
# every open session first.
#
# Parsed with python3, not jq — jq isn't guaranteed installed everywhere this
# runs (WSL boxes may lack it), python3 is.
#
# Backends:
#   - macOS:  osascript (Notification Center toast)
#   - WSL:    powershell.exe + BurntToast/balloon
#   - Linux:  notify-send (libnotify)
# Falls through silently if no backend is available so the hook never breaks
# the calling flow.

set -u

kind="${1:-notify}"
title="Claude Code"

case "$kind" in
    notify) message="Claude needs attention" ;;
    plan)   message="Plan ready for review" ;;
    pr)     message="Pull request created" ;;
    *)      message="Event: $kind" ;;
esac

project=""
snippet=""
# base64url payload identifying this session's Windows Terminal tab; empty
# until the transcript has an ai-title, and unused outside WSL.
focus_token=""
# The conversation's own name, used as the Windows toast title so the toast
# reads as the chat rather than repeating the app name the shell already shows.
ai_title=""
session_id=""

PARSE_PY=$(cat <<'PY_EOF'
import base64, json, os, re, sys


def strip_md(s):
    """Flatten markdown to plain text for notification previews.

    Toast ToastGeneric <text> elements have no inline formatting, so bold is
    not renderable at any level; raw ** and backticks just leak into the
    preview as literal noise. Deliberately conservative: `_` emphasis and bare
    `*` globs are left alone so snake_case identifiers and shell patterns
    survive intact, which matters more here than catching every italic.
    """
    if not s:
        return ""
    s = re.sub(r"```[a-zA-Z0-9_+-]*", " ", s)          # fence markers
    s = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", s)    # images -> alt
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)     # links -> label
    s = re.sub(r"`+([^`]+)`+", r"\1", s)               # inline code
    s = re.sub(r"\*\*\*(.+?)\*\*\*", r"\1", s, flags=re.S)
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s, flags=re.S)
    s = re.sub(r"~~(.+?)~~", r"\1", s, flags=re.S)
    s = re.sub(r"\*(?!\s)([^*\n]+?)(?<!\s)\*", r"\1", s)
    s = re.sub(r"(?m)^\s{0,3}#{1,6}\s*", "", s)        # headers
    s = re.sub(r"(?m)^\s{0,3}>\s?", "", s)             # blockquotes
    s = re.sub(r"(?m)^\s{0,3}[-*+]\s+", "", s)         # bullets
    s = re.sub(r"(?m)^\s{0,3}\d+\.\s+", "", s)         # ordered lists
    s = re.sub(r"[─-╿]{2,}", " ", s)         # box-drawing rules
    s = re.sub(r"(?m)^\s{0,3}([-*_])\s*(?:\1\s*){2,}$", " ", s)  # hr
    s = s.replace("|", " ")                            # table pipes
    s = re.sub(r"(?<!\S)-{3,}(?!\S)", " ", s)          # table separator rows
    return s

try:
    payload = json.loads(sys.stdin.read() or "{}")
except Exception:
    payload = {}

def clean(s, limit):
    if not s:
        return ""
    s = " ".join(s.split())
    if len(s) > limit:
        s = s[: limit - 1].rstrip() + "…"
    return s

message = payload.get("message") or ""
cwd = payload.get("cwd") or ""
transcript_path = payload.get("transcript_path") or ""

project = os.path.basename(cwd.rstrip("/")) if cwd else ""

snippet = ""
ai_title = ""
if transcript_path and os.path.isfile(transcript_path):
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
        for line in reversed(lines[-40:]):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue
            if entry.get("type") != "assistant":
                continue
            content = (entry.get("message") or {}).get("content") or []
            texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
            text = " ".join(t for t in texts if t).strip()
            if text:
                snippet = text
                break

        # `ai-title` is the string Claude Code writes into the Windows Terminal
        # tab title, so it is the join key the toast's click handler uses to
        # find this session's tab. Scan the whole transcript, not just the
        # tail: the record is only re-emitted when the title actually changes,
        # which is usually far from the end of a long session.
        for line in reversed(lines):
            if '"ai-title"' not in line:
                continue
            try:
                entry = json.loads(line.strip())
            except Exception:
                continue
            if entry.get("type") == "ai-title" and entry.get("aiTitle"):
                ai_title = entry["aiTitle"]
                break
    except Exception:
        pass

# Pack the tab-focus payload as base64url so it survives being embedded in a
# URI and handed through the shell to the protocol handler.
token = ""
if ai_title:
    try:
        blob = json.dumps(
            {"title": ai_title, "project": project, "session": payload.get("session_id") or ""},
            ensure_ascii=False,
        ).encode("utf-8")
        token = base64.urlsafe_b64encode(blob).decode("ascii").rstrip("=")
    except Exception:
        token = ""

sep = "\x1f"
sys.stdout.write(sep.join([
    clean(strip_md(message), 120),
    project,
    clean(strip_md(snippet), 140),
    token,
    clean(ai_title, 90),
    payload.get("session_id") or "",
]))
PY_EOF
)

if ! [ -t 0 ]; then
    json="$(cat 2>/dev/null || true)"
    if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
        parsed="$(printf '%s' "$json" | python3 -c "$PARSE_PY" 2>/dev/null || true)"
        if [ -n "$parsed" ]; then
            IFS=$'\x1f' read -r p_message p_project p_snippet p_token p_aititle p_session <<EOF_R
$parsed
EOF_R
            if [ "$kind" = "notify" ] && [ -n "$p_message" ]; then
                message="$p_message"
            fi
            project="$p_project"
            snippet="$p_snippet"
            focus_token="$p_token"
            ai_title="$p_aititle"
            session_id="$p_session"
        fi
    fi
fi

if [ -n "$project" ]; then
    title="Claude Code — $project"
fi

notify_macos() {
    # AppleScript single-quotes need doubling. osascript itself takes -e args.
    local t="${title//\"/\\\"}"
    local body="$message"
    [ -n "$snippet" ] && body="$message: $snippet"
    local m="${body//\"/\\\"}"
    osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

notify_wsl() {
    # Windows toast via PowerShell, sent straight through the WinRT
    # ToastNotificationManager under our own AppUserModelID so it is
    # attributed to "Claude Code" and not "Windows PowerShell". BurntToast is
    # deliberately not used: as of 1.1.0 it has no -AppId on
    # Submit-BTNotification, so every toast it raises is stamped with the
    # PowerShell AUMID. Falls back to a 2-line balloon if WinRT is unavailable.
    esc() { printf '%s' "$1" | sed "s/'/''/g"; }

    # Title is the conversation's own name. Windows already renders "Claude
    # Code" as the source app directly above it, so putting it in the body too
    # was pure repetition. Falls back to the old app-and-project form only
    # before the session has been named.
    local toast_title="${ai_title:-$title}"
    # Body is just the preview: Claude's last message when there is one,
    # otherwise the hook's own reason for firing ("Plan ready for review").
    local toast_body="${snippet:-$message}"

    local ps_title; ps_title=$(esc "$toast_title")
    local ps_body; ps_body=$(esc "$toast_body")
    local ps_balloon_body; ps_balloon_body=$(esc "$toast_body")
    local ps_tag; ps_tag=$(esc "$session_id")
    # Empty when the session has no ai-title yet, in which case the toast is
    # still raised but is neither clickable nor auto-dismissed.
    local ps_launch=""
    [ -n "$focus_token" ] && ps_launch="claudetab:$(esc "$focus_token")"

    local PS_TEMPLATE
    PS_TEMPLATE=$(cat <<'PS_EOF'
$ErrorActionPreference = 'SilentlyContinue'
$t = '__TITLE__'
$b = '__BODY__'
$balloonBody = '__BALLOON_BODY__'
$launch = '__LAUNCH__'
$tag = '__TAG__'
$logo = "$env:LOCALAPPDATA\ClaudeCode\claude-icon.png"
$aumid = 'Claude.Code'
$group = 'claude-code'

function XmlEsc([string]$x) { [System.Security.SecurityElement]::Escape($x) }

function Write-CcLog([string]$m) {
    try {
        Add-Content -Path "$env:LOCALAPPDATA\ClaudeCode\focus-tab.log" -Encoding UTF8 `
            -Value ("{0}  notify: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}

# Returns the raw tab title (glyph included) for the tab whose name matches
# $Target, or $null if no such tab exists.
function Get-TabRawTitle([string]$Target) {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        $AE = [System.Windows.Automation.AutomationElement]
        $wc = New-Object System.Windows.Automation.PropertyCondition(
            $AE::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
        $tc = New-Object System.Windows.Automation.PropertyCondition(
            $AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
        foreach ($w in $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $wc)) {
            $tabs = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)
            for ($i = 0; $i -lt $tabs.Count; $i++) {
                $n = $tabs.Item($i).Current.Name
                $m = [regex]::Match($n, '[\p{L}\p{N}].*$')
                $norm = if ($m.Success) { $m.Value.Trim() } else { $n.Trim() }
                if ($norm -eq $Target) { return $n }
            }
        }
    } catch { }
    return $null
}

# Gate on the tab glyph, not on the hook event. Claude Code stamps U+2733 on
# the tab title when a session actually wants the user, and an animating
# braille spinner (U+2800 block) while it is still working. The Notification
# hook fires more broadly than that, which is why toasts were showing up for
# sessions that were neither finished nor waiting.
#
# Fail-open by design: if the tab cannot be found at all we still notify,
# because losing a real notification is worse than one spurious toast.
$AWAITING = 0x2733
$raw = $null
for ($try = 0; $try -lt 8; $try++) {
    $raw = Get-TabRawTitle -Target $t
    if (-not $raw) { break }                                   # no tab: fail open
    if ([int]$raw[0] -eq $AWAITING) { break }                  # awaiting: notify
    Start-Sleep -Milliseconds 250                              # still working: re-check
}
if ($raw -and [int]$raw[0] -ne $AWAITING) {
    Write-CcLog "suppressed (tab not awaiting, glyph U+$('{0:X4}' -f [int]$raw[0])): $t"
    return
}

try {
    # Register the AppUserModelID so Windows attributes the toast to "Claude
    # Code" with its own icon and its own row under Settings > Notifications.
    # A registry key alone is enough; the Start Menu shortcut Microsoft's docs
    # call for is not actually required. Idempotent and HKCU-scoped, so a
    # fresh machine self-heals on the first notification.
    $key = "HKCU:\Software\Classes\AppUserModelId\$aumid"
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name 'DisplayName' -Value 'Claude Code' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name 'ShowInSettings' -Value 1 -PropertyType DWord -Force | Out-Null
        if (Test-Path $logo) {
            New-ItemProperty -Path $key -Name 'IconUri' -Value $logo -PropertyType String -Force | Out-Null
        }
    }

    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime]

    $lines = "<text>$(XmlEsc $t)</text><text>$(XmlEsc $b)</text>"

    $img = ''
    if (Test-Path $logo) {
        $img = "<image placement='appLogoOverride' hint-crop='circle' src='$(XmlEsc ([Uri]$logo).AbsoluteUri)'/>"
    }

    # scenario=reminder keeps the toast on screen until it is acted on rather
    # than auto-hiding after a few seconds. Reminder-scenario toasts are
    # expected to carry at least one action, hence the explicit buttons.
    # activationType=protocol is what lets a click still work after this
    # process exits, which it does within a second of raising the toast.
    $attrs = " scenario='reminder'"
    $buttons = ''
    if ($launch) {
        $attrs = " launch='$(XmlEsc $launch)' activationType='protocol'" + $attrs
        $buttons = "<action content='Open tab' arguments='$(XmlEsc $launch)' activationType='protocol'/>"
    }
    $actions = "<actions>$buttons<action content='Dismiss' arguments='dismiss' activationType='system'/></actions>"

    $xml = "<toast$attrs><visual><binding template='ToastGeneric'>$lines$img</binding></visual>$actions</toast>"
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $doc

    # Tagging by session makes a later notification for the same conversation
    # replace the earlier one instead of stacking them, and gives the watcher
    # a handle to remove it by.
    if ($tag) {
        $toast.Tag = $tag
        $toast.Group = $group
    }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)

    # Hand off to a watcher that clears the toast once the conversation's tab
    # is actually on screen, so a persistent toast never outlives the thing it
    # is pointing at. Args are the launch URI and tag, both base64url/GUID
    # safe, so no quoting hazard crossing the wscript boundary.
    $watch = "$env:LOCALAPPDATA\ClaudeCode\claude-toast-watch.vbs"
    if ($tag -and $launch -and (Test-Path $watch)) {
        Start-Process -FilePath 'wscript.exe' `
            -ArgumentList "`"$watch`" `"$launch`" `"$tag`"" -WindowStyle Hidden
    }
    return
} catch {
    # Fall through to the balloon-tip backup below.
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Information
$ni.BalloonTipTitle = $t
$ni.BalloonTipText  = $balloonBody
$ni.Visible = $true
$ni.ShowBalloonTip(5000)
Start-Sleep -Seconds 6
$ni.Dispose()
PS_EOF
)

    local PS=${PS_TEMPLATE//__TITLE__/$ps_title}
    PS=${PS//__BODY__/$ps_body}
    PS=${PS//__BALLOON_BODY__/$ps_balloon_body}
    PS=${PS//__LAUNCH__/$ps_launch}
    PS=${PS//__TAG__/$ps_tag}

    if command -v iconv >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
        local enc
        enc=$(printf '%s' "$PS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
        powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$enc" >/dev/null 2>&1 &
    else
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$PS" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
}

notify_linux() {
    local body="$message"
    [ -n "$snippet" ] && body="$message: $snippet"
    notify-send "$title" "$body" >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

case "$(uname -s)" in
    Darwin)
        if command -v osascript >/dev/null 2>&1; then
            notify_macos
        fi
        ;;
    Linux)
        if command -v powershell.exe >/dev/null 2>&1; then
            notify_wsl
        elif command -v notify-send >/dev/null 2>&1; then
            notify_linux
        fi
        ;;
esac

exit 0
