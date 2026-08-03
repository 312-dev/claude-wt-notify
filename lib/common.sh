# common.sh — helpers shared by install.sh and uninstall.sh.
#
# Sourced, not executed.

# is_managed_tree <target-path> <claude-dir>
#
# Returns 0 (true) when <target-path> lives in a tree owned by something other
# than Claude Code itself: GNU Stow, a dotfiles repo, a symlinked config.
#
# Testing whether the *file* is a symlink is not sufficient and is a genuine
# trap. Stow symlinks the enclosing directory, so ~/.claude/hooks can be a link
# while every file inside it stats as an ordinary file. A naive `[ -L "$file" ]`
# check passes straight through and writes into, or deletes from, the user's
# dotfiles repo. Resolve the parent and compare against the resolved config
# directory instead.
is_managed_tree() {
    local target="$1" claude_dir="$2"
    local dir
    dir="$(dirname "$target")"

    [ -L "$target" ] && return 0
    [ -L "$dir" ] && return 0

    local real_dir real_claude
    real_dir="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
    real_claude="$(readlink -f "$claude_dir" 2>/dev/null || echo "$claude_dir")"

    case "$real_dir" in
        "$real_claude"|"$real_claude"/*) return 1 ;;
        *) return 0 ;;
    esac
}

# resolve_real <path> — absolute path with all symlinks followed.
resolve_real() {
    readlink -f "$1" 2>/dev/null || echo "$1"
}
