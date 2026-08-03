#!/usr/bin/env bash
# install.sh — install claude-wt-notify from WSL.
#
# Handles the whole thing: preflight checks, the Linux-side hook, the
# Windows-side scripts and registry entries, and the Claude Code settings
# wiring.
#
# Works two ways:
#   from a clone:   ./install.sh
#   over the wire:  curl -fsSL <raw-url>/install.sh | bash
#
# Flags:
#   --check        run preflight only, change nothing
#   --no-settings  install everything but do not touch ~/.claude/settings.json
#   --force        overwrite an existing hook even if it is a symlink
set -euo pipefail

REPO_URL="https://github.com/312-dev/claude-wt-notify"
SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-wt-notify"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOK_DEST="$CLAUDE_DIR/hooks/cc-notify.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

CHECK_ONLY=0
SKIP_SETTINGS=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --check)       CHECK_ONLY=1 ;;
        --no-settings) SKIP_SETTINGS=1 ;;
        --force)       FORCE=1 ;;
        -h|--help)     sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

ok=0
fail=0
chk() {  # chk "<label>" <0|1> "<hint on failure>"
    if [ "$2" -eq 0 ]; then
        grn "  ok    $1"; ok=$((ok + 1))
    else
        red "  FAIL  $1"; [ -n "${3:-}" ] && printf '        %s\n' "$3"; fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------- preflight

bold "Preflight"

is_wsl=1
grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && is_wsl=0
chk "running under WSL" "$is_wsl" "This package bridges WSL to Windows. On native Windows run install.ps1 directly."

has_ps=1
command -v powershell.exe >/dev/null 2>&1 && has_ps=0
chk "powershell.exe reachable (WSL interop)" "$has_ps" \
    "Enable interop: WSL2 with /proc/sys/fs/binfmt_misc/WSLInterop present."

has_py=1
command -v python3 >/dev/null 2>&1 && has_py=0
chk "python3 present (used to parse hook payloads)" "$has_py" "apt install python3"

has_wt=1
if [ -n "${WT_SESSION:-}" ]; then
    has_wt=0
elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "if (Get-AppxPackage Microsoft.WindowsTerminal) { exit 0 } else { exit 1 }" \
        >/dev/null 2>&1 && has_wt=0
fi
chk "Windows Terminal installed" "$has_wt" \
    "Not fatal: toasts still work, but tab focusing and the tray badge will not."

if [ "$fail" -gt 0 ] && [ "$is_wsl" -ne 0 -o "$has_ps" -ne 0 -o "$has_py" -ne 0 ]; then
    echo
    red "Preflight failed on a required check. Nothing was changed."
    exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo; grn "Preflight only ($ok ok, $fail failed). Nothing was changed."
    exit 0
fi

# ------------------------------------------------------------- locate source

# Works whether this ran from a clone or was piped straight from curl.
SRC=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    maybe="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$maybe/install.ps1" ] && SRC="$maybe"
fi

if [ -z "$SRC" ]; then
    echo
    bold "Fetching source"
    if [ -d "$SHARE_DIR/.git" ]; then
        git -C "$SHARE_DIR" pull --quiet --ff-only && echo "  updated $SHARE_DIR"
    else
        mkdir -p "$(dirname "$SHARE_DIR")"
        git clone --quiet --depth 1 "$REPO_URL" "$SHARE_DIR" && echo "  cloned to $SHARE_DIR"
    fi
    SRC="$SHARE_DIR"
fi

# ------------------------------------------------------------- windows side

echo
bold "Windows side"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$SRC/install.ps1")" \
    | sed 's/\r$//' | sed 's/^/  /'

# --------------------------------------------------------------- linux hook

echo
bold "Hook"
mkdir -p "$CLAUDE_DIR/hooks"

# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

if is_managed_tree "$HOOK_DEST" "$CLAUDE_DIR" && [ "$FORCE" -eq 0 ]; then
    real_dest="$(resolve_real "$HOOK_DEST")"
    ylw "  skipped $HOOK_DEST"
    ylw "          that path resolves into a managed tree:"
    ylw "            $real_dest"
    ylw "          Copy or symlink $SRC/hooks/cc-notify.sh there yourself,"
    ylw "          or re-run with --force to overwrite it."
else
    install -m 0755 "$SRC/hooks/cc-notify.sh" "$HOOK_DEST"
    echo "  installed $HOOK_DEST"
fi

# ------------------------------------------------------------------ settings

if [ "$SKIP_SETTINGS" -eq 1 ]; then
    echo; ylw "Skipping settings.json (--no-settings)."
else
    echo
    bold "Claude Code settings"
    # Unlike the hook, settings.json has to be edited in place to wire anything
    # up, so a managed tree is a note rather than a refusal. Say plainly which
    # file is actually being written.
    if is_managed_tree "$SETTINGS" "$CLAUDE_DIR"; then
        ylw "  note: this resolves into a managed tree, editing $(resolve_real "$SETTINGS")"
    fi
    python3 - "$SETTINGS" "$HOOK_DEST" <<'PY'
import json, os, shutil, sys

path, hook = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:
        print(f"  could not parse {path}: {e}")
        print("  leaving it alone; add the Notification hook by hand.")
        sys.exit(0)

hooks = cfg.setdefault("hooks", {})
entries = hooks.setdefault("Notification", [])

# Idempotent: bail if any Notification hook already points at cc-notify.sh.
for group in entries:
    for h in group.get("hooks", []):
        if "cc-notify.sh" in str(h.get("command", "")):
            print("  already wired, left unchanged")
            sys.exit(0)

if os.path.isfile(path):
    shutil.copy2(path, path + ".bak")
    print(f"  backed up {os.path.basename(path)} -> {os.path.basename(path)}.bak")

entries.append({"hooks": [{"type": "command", "command": f"{hook} notify", "async": True}]})
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("  added Notification hook")
PY
fi

# ------------------------------------------------------------------- summary

echo
grn "Installed."
echo
echo "  Restart Claude Code (or start a new session) to pick up the hook."
echo "  Log:       %LOCALAPPDATA%\\ClaudeCode\\focus-tab.log"
echo "  Uninstall: $SRC/uninstall.sh"
