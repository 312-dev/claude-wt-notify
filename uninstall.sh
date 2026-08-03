#!/usr/bin/env bash
# uninstall.sh — remove claude-wt-notify.
#
# Reverses install.sh: unwires the Claude Code hook, removes the Windows-side
# scripts and registry entries, and deletes local runtime state.
#
# Flags:
#   --keep-settings  leave ~/.claude/settings.json untouched
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOK_DEST="$CLAUDE_DIR/hooks/cc-notify.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-wt-notify"

KEEP_SETTINGS=0
for arg in "$@"; do
    case "$arg" in
        --keep-settings) KEEP_SETTINGS=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SRC/install.ps1" ] || SRC="$SHARE_DIR"

echo "Windows side"
if [ -f "$SRC/install.ps1" ] && command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$SRC/install.ps1")" -Uninstall \
        | sed 's/\r$//' | sed 's/^/  /'
else
    echo "  install.ps1 not found; skipping the Windows-side removal."
fi

echo
echo "Runtime state"
APPDATA_DIR="$(powershell.exe -NoProfile -Command 'Write-Output $env:LOCALAPPDATA' 2>/dev/null | tr -d '\r' || true)"
if [ -n "$APPDATA_DIR" ]; then
    WSL_DIR="$(wslpath -u "$APPDATA_DIR" 2>/dev/null || true)/ClaudeCode"
    for f in "$WSL_DIR/focus-tab.log" "$WSL_DIR/unread"; do
        [ -e "$f" ] && rm -rf "$f" && echo "  removed $(basename "$f")"
    done
    rm -f "$WSL_DIR"/watch-*.pid 2>/dev/null || true
fi

echo
echo "Hook"
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

if [ ! -e "$HOOK_DEST" ]; then
    echo "  nothing to remove"
elif is_managed_tree "$HOOK_DEST" "$CLAUDE_DIR"; then
    # Never delete out of somebody's dotfiles repo. The path below is where the
    # file really lives, which is not obvious when a parent directory is the
    # symlink rather than the file itself.
    echo "  left $HOOK_DEST alone"
    echo "    it resolves into a managed tree: $(resolve_real "$HOOK_DEST")"
    echo "    remove it there yourself if you want it gone."
else
    rm -f "$HOOK_DEST" && echo "  removed $HOOK_DEST"
fi

if [ "$KEEP_SETTINGS" -eq 1 ]; then
    echo
    echo "Leaving settings.json untouched (--keep-settings)."
else
    echo
    echo "Claude Code settings"
    python3 - "$SETTINGS" <<'PY'
import json, os, shutil, sys

path = sys.argv[1]
if not os.path.isfile(path):
    print("  no settings.json"); sys.exit(0)
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception as e:
    print(f"  could not parse settings.json: {e}"); sys.exit(0)

entries = cfg.get("hooks", {}).get("Notification", [])
kept = []
removed = 0
for group in entries:
    hooks = [h for h in group.get("hooks", []) if "cc-notify.sh" not in str(h.get("command", ""))]
    removed += len(group.get("hooks", [])) - len(hooks)
    if hooks:
        group["hooks"] = hooks
        kept.append(group)

if not removed:
    print("  nothing wired"); sys.exit(0)

shutil.copy2(path, path + ".bak")
cfg["hooks"]["Notification"] = kept
if not kept:
    del cfg["hooks"]["Notification"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  removed {removed} hook entry/entries (backup at settings.json.bak)")
PY
fi

echo
echo "Done. Any running watcher or tray process exits on its own within 15 minutes."
