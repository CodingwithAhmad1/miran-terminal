#!/usr/bin/env bash
# Miran Terminal installer.
# Symlinks bin/ws and bin/dashboard.sh into ~/.local/bin and creates the
# runtime state directory at ~/.workspace.
#
# Idempotent: safe to re-run after `git pull`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BIN="$HOME/.local/bin"
RUNTIME_DIR="$HOME/.workspace"

YELLOW=$'\033[33m'
GREEN=$'\033[32m'
RED=$'\033[31m'
DIM=$'\033[2m'
RESET=$'\033[0m'

info()  { printf '%s•%s %s\n' "$GREEN" "$RESET" "$1"; }
warn()  { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail()  { printf '%sx%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

# ── Dependency check ─────────────────────────────────────────────────
missing=()
command -v tmux >/dev/null 2>&1 || missing+=(tmux)
command -v jq   >/dev/null 2>&1 || missing+=(jq)
if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing dependencies: ${missing[*]}"
    if [[ "$(uname)" == "Darwin" ]]; then
        warn "Install with: brew install ${missing[*]}"
    else
        warn "Install with your package manager (apt, dnf, pacman, ...)"
    fi
    fail "Aborting. Re-run install.sh after installing the missing tools."
fi
info "tmux and jq found"

# ── Make scripts executable ──────────────────────────────────────────
chmod +x "$REPO_DIR/bin/ws" "$REPO_DIR/bin/dashboard.sh"
chmod +x "$REPO_DIR/test/ws-test.sh" 2>/dev/null || true

# ── Symlink into ~/.local/bin ────────────────────────────────────────
mkdir -p "$TARGET_BIN"
ln -sfn "$REPO_DIR/bin/ws"           "$TARGET_BIN/ws"
ln -sfn "$REPO_DIR/bin/dashboard.sh" "$TARGET_BIN/dashboard.sh"
info "Symlinked ws → $TARGET_BIN/ws"
info "Symlinked dashboard.sh → $TARGET_BIN/dashboard.sh"

# ── Create runtime state dir ─────────────────────────────────────────
mkdir -p "$RUNTIME_DIR"
[[ -f "$RUNTIME_DIR/config.json" ]] || echo '{"settings":{},"terminals":[]}' > "$RUNTIME_DIR/config.json"
info "Runtime state directory: $RUNTIME_DIR"

# ── PATH check ───────────────────────────────────────────────────────
if ! printf '%s' ":$PATH:" | grep -q ":$TARGET_BIN:"; then
    warn "$TARGET_BIN is NOT in your PATH."
    printf '%s  Add this to your shell rc (~/.zshrc, ~/.bashrc):%s\n' "$DIM" "$RESET"
    printf '\n    export PATH="%s:$PATH"\n\n' "$TARGET_BIN"
    printf '%s  Then reload your shell, or run `source ~/.zshrc`.%s\n' "$DIM" "$RESET"
else
    info "$TARGET_BIN is already in PATH"
fi

# ── Done ─────────────────────────────────────────────────────────────
echo
info "Install complete."
echo
echo "Next steps:"
echo "  1. (macOS Terminal.app) Settings → Profiles → Keyboard → check 'Use Option as Meta key'"
echo "     For other terminals see:  ws keys"
echo "  2. ws start"
echo "  3. press n to add a terminal, ? for help"
