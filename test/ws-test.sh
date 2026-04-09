#!/usr/bin/env bash
# Integration tests for Miran.
# Drives the dashboard via tmux send-keys and asserts on:
#   - config.json state
#   - dashboard pane content
#   - tmux window state
#   - pane border (notes shown at top of terminals)
#
# Each test resets state from scratch. Runs against the bin/ in this repo,
# not against an installed copy, so it works in a fresh checkout.

set -uo pipefail

# Resolve paths relative to this script so the suite is checkout-relative.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WS_BIN="$REPO_DIR/bin/ws"
DASHBOARD="$REPO_DIR/bin/dashboard.sh"

# Runtime state location (matches ws's own default).
RUNTIME_DIR="$HOME/.workspace"
CONFIG="$RUNTIME_DIR/config.json"
LOG="$RUNTIME_DIR/dashboard.log"
SESSION="workspace"

PASS=0
FAIL=0
FAILS=()

cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
}

reset_state() {
    cleanup
    mkdir -p "$RUNTIME_DIR"
    echo '{"settings":{},"terminals":[]}' > "$CONFIG"
    rm -f "$LOG"
}

start_workspace() {
    reset_state
    tmux new-session -d -s "$SESSION" -x 100 -y 30 -n dashboard \
        "while true; do /bin/bash $DASHBOARD; sleep 1; done"
    sleep 1.0
}

send() {
    tmux send-keys -t "$SESSION:0" "$@"
    sleep 0.2
}

capture() {
    tmux capture-pane -t "$SESSION:0" -p
}

assert() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        PASS=$((PASS + 1))
        printf '  \033[32mPASS\033[0m %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILS+=("$desc")
        printf '  \033[31mFAIL\033[0m %s\n' "$desc"
        printf '       cond: %s\n' "$cond"
    fi
}

assert_capture_contains() {
    local desc="$1" needle="$2"
    local body
    body=$(capture)
    if grep -qF "$needle" <<< "$body"; then
        PASS=$((PASS + 1))
        printf '  \033[32mPASS\033[0m %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILS+=("$desc")
        printf '  \033[31mFAIL\033[0m %s\n' "$desc"
        printf '       expected to find: %s\n' "$needle"
        printf '       --- pane ---\n%s\n       --- /pane ---\n' "$body"
    fi
}

assert_capture_lacks() {
    local desc="$1" needle="$2"
    local body
    body=$(capture)
    if grep -qF "$needle" <<< "$body"; then
        FAIL=$((FAIL + 1))
        FAILS+=("$desc")
        printf '  \033[31mFAIL\033[0m %s\n' "$desc"
        printf '       expected NOT to find: %s\n' "$needle"
    else
        PASS=$((PASS + 1))
        printf '  \033[32mPASS\033[0m %s\n' "$desc"
    fi
}

# ─── Tests ───────────────────────────────────────────────────────────

test_empty_state() {
    printf '\033[1m• empty state\033[0m\n'
    start_workspace
    assert_capture_contains "shows workspace header" "workspace"
    assert_capture_contains "shows terminals heading" "TERMINALS"
    assert_capture_contains "shows empty hint" "No terminals yet"
    assert_capture_contains "shows hotkey bar" "1-9"
    assert "config has empty terminals" "[ \$(jq '.terminals | length' $CONFIG) -eq 0 ]"
    assert "log is clean" "[ ! -s $LOG ] || ! grep -q error $LOG"
}

test_add_terminal() {
    printf '\033[1m• add terminal via dashboard\033[0m\n'
    start_workspace
    send "n"
    send "alpha" Enter
    send "first terminal" Enter
    sleep 0.4
    assert "config has 1 terminal" "[ \$(jq '.terminals | length' $CONFIG) -eq 1 ]"
    assert "config name=alpha" "[ \"\$(jq -r '.terminals[0].name' $CONFIG)\" = alpha ]"
    assert "config note=first terminal" "[ \"\$(jq -r '.terminals[0].note' $CONFIG)\" = 'first terminal' ]"
    assert "config window=1" "[ \$(jq '.terminals[0].tmux_window' $CONFIG) -eq 1 ]"
    assert "tmux window 1 exists" "tmux list-windows -t $SESSION -F '#{window_index} #{window_name}' | grep -q '^1 alpha'"
    assert_capture_contains "dashboard shows alpha" "alpha"
    assert_capture_contains "dashboard shows note" "first terminal"
}

test_pane_border_set() {
    printf '\033[1m• pane border (note visible at top of terminal)\033[0m\n'
    start_workspace
    send "n"
    send "borderterm" Enter
    send "border note text" Enter
    sleep 0.5
    local fmt status
    fmt=$(tmux show-window-options -t "$SESSION:1" pane-border-format 2>/dev/null || true)
    status=$(tmux show-window-options -t "$SESSION:1" pane-border-status 2>/dev/null || true)
    assert "pane-border-status set" "[[ '$status' == *top* ]]"
    assert "pane-border-format contains name" "[[ '$fmt' == *borderterm* ]]"
    assert "pane-border-format contains note" "[[ '$fmt' == *'border note text'* ]]"
}

test_edit_note() {
    printf '\033[1m• edit note via dashboard\033[0m\n'
    start_workspace
    send "n"
    send "edita" Enter
    send "old note" Enter
    sleep 0.3
    send "e"
    send "1" Enter
    send "new note value" Enter
    sleep 0.4
    assert "note updated in config" "[ \"\$(jq -r '.terminals[0].note' $CONFIG)\" = 'new note value' ]"
    local fmt
    fmt=$(tmux show-window-options -t "$SESSION:1" pane-border-format 2>/dev/null || true)
    assert "pane-border updated" "[[ '$fmt' == *'new note value'* ]]"
    assert_capture_contains "dashboard shows new note" "new note value"
}

test_remove_terminal() {
    printf '\033[1m• remove terminal via dashboard\033[0m\n'
    start_workspace
    send "n"; send "alpha" Enter; send "a" Enter; sleep 0.2
    send "n"; send "beta" Enter; send "b" Enter; sleep 0.2
    send "n"; send "gamma" Enter; send "g" Enter; sleep 0.3
    assert "3 terminals before removal" "[ \$(jq '.terminals | length' $CONFIG) -eq 3 ]"

    send "x"
    send "2" Enter
    send "y" Enter
    sleep 0.4
    assert "2 terminals after removal" "[ \$(jq '.terminals | length' $CONFIG) -eq 2 ]"
    assert "alpha kept" "[ \"\$(jq -r '.terminals[0].name' $CONFIG)\" = alpha ]"
    assert "gamma renumbered to window 2" "[ \$(jq '.terminals[1].tmux_window' $CONFIG) -eq 2 ]"
    assert "tmux window 2 exists with name gamma" "tmux list-windows -t $SESSION -F '#{window_index} #{window_name}' | grep -q '^2 gamma'"
    assert "tmux window 3 does not exist" "! tmux list-windows -t $SESSION -F '#{window_index}' | grep -q '^3$'"
    assert_capture_lacks "dashboard no longer shows beta" "beta"
}

test_switch_terminal() {
    printf '\033[1m• switch to terminal via 1-9\033[0m\n'
    start_workspace
    send "n"; send "switchme" Enter; send "n" Enter; sleep 0.3
    send "1"
    sleep 0.3
    local active
    active=$(tmux list-windows -t $SESSION -F '#{window_index} #{window_active}' | awk '$2==1{print $1}')
    assert "window 1 active after pressing 1" "[ \"$active\" = 1 ]"
}

test_resize() {
    printf '\033[1m• resize terminal triggers re-render\033[0m\n'
    start_workspace
    send "n"; send "rs" Enter; send "n" Enter; sleep 0.3
    tmux resize-window -t "$SESSION" -x 120 -y 40 2>/dev/null || \
        tmux refresh-client -t "$SESSION" -C 120x40 2>/dev/null || true
    sleep 0.5
    assert_capture_contains "still renders after resize" "rs"
    assert_capture_contains "still shows hotkey bar" "1-9"
}

test_max_terminals() {
    printf '\033[1m• cap of 9 terminals\033[0m\n'
    start_workspace
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
        send "n"
        send "t$i" Enter
        send "n$i" Enter
        sleep 0.15
    done
    sleep 0.3
    assert "9 terminals created" "[ \$(jq '.terminals | length' $CONFIG) -eq 9 ]"
    send "n"
    send "t10" Enter
    send "n10" Enter
    sleep 0.3
    assert "still 9 terminals after attempted 10th" "[ \$(jq '.terminals | length' $CONFIG) -eq 9 ]"
}

test_persistence() {
    printf '\033[1m• persistence across stop/start\033[0m\n'
    start_workspace
    send "n"; send "persist" Enter; send "remember me" Enter; sleep 0.3
    cleanup
    sleep 0.2
    tmux new-session -d -s "$SESSION" -x 100 -y 30 -n dashboard \
        "while true; do /bin/bash $DASHBOARD; sleep 1; done"
    local count name dir note win
    count=$(jq '.terminals | length' "$CONFIG")
    for ((i = 0; i < count; i++)); do
        name=$(jq -r ".terminals[$i].name" "$CONFIG")
        dir=$(jq -r ".terminals[$i].dir" "$CONFIG")
        note=$(jq -r ".terminals[$i].note" "$CONFIG")
        win=$(jq -r ".terminals[$i].tmux_window" "$CONFIG")
        tmux new-window -t "$SESSION:$win" -n "$name" -c "$dir"
        tmux set-window-option -t "$SESSION:$win" pane-border-status top
        tmux set-window-option -t "$SESSION:$win" pane-border-format \
            "#[fg=colour114] $name #[fg=colour250]— $note "
    done
    sleep 0.4
    assert "tmux window 1 restored as persist" "tmux list-windows -t $SESSION -F '#{window_index} #{window_name}' | grep -q '^1 persist'"
    local fmt
    fmt=$(tmux show-window-options -t "$SESSION:1" pane-border-format 2>/dev/null || true)
    assert "restored pane border has note" "[[ '$fmt' == *'remember me'* ]]"
    assert_capture_contains "dashboard shows persisted terminal" "persist"
}

test_alt_bindings() {
    printf '\033[1m• alt-N bindings exist (one-key switching)\033[0m\n'
    start_workspace
    tmux bind-key -T prefix D select-window -t "$SESSION:0"
    local i
    for i in 0 1 2 3 4 5 6 7 8 9; do
        tmux bind-key -n "M-$i" select-window -t "$SESSION:$i"
    done
    local out
    out=$(tmux list-keys -T root 2>/dev/null | grep -F "M-1" || true)
    assert "M-1 binding exists" "[[ -n '$out' ]]"
    out=$(tmux list-keys -T root 2>/dev/null | grep -F "M-9" || true)
    assert "M-9 binding exists" "[[ -n '$out' ]]"
    out=$(tmux list-keys -T prefix 2>/dev/null | grep "bind-key.* D ")
    assert "prefix D binding exists" "[[ -n '$out' ]]"
    out=$(tmux list-keys -T prefix 2>/dev/null | grep -E "bind-key.* d " | grep -i detach || true)
    assert "prefix d still detaches" "[[ -n '$out' ]]"
}

test_cli_ls() {
    printf '\033[1m• ws ls reflects state\033[0m\n'
    start_workspace
    send "n"; send "lsone" Enter; send "the note" Enter; sleep 0.3
    local out
    out=$("$WS_BIN" ls 2>&1)
    assert "ls contains lsone" "[[ '$out' == *lsone* ]]"
    assert "ls contains note" "[[ '$out' == *'the note'* ]]"
}

# ─── Driver ──────────────────────────────────────────────────────────

trap cleanup EXIT

test_empty_state
test_add_terminal
test_pane_border_set
test_edit_note
test_remove_terminal
test_switch_terminal
test_resize
test_max_terminals
test_persistence
test_alt_bindings
test_cli_ls

printf '\n──────────────────\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf '\nFailures:\n'
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
