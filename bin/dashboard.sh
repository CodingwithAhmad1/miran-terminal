#!/usr/bin/env bash
# Miran Terminal dashboard — TUI.
#
# Render strategy: cursor-position + clear-to-EOL per line, then clear-to-end
# of screen at the bottom. No full-screen clear between frames, so no flicker.
# A SIGWINCH (terminal resize) forces a full re-render.
#
# All interactive prompts read from /dev/tty so command substitution
# (`name=$(read_input ...)`) does not swallow the prompt's escape codes.

set -uo pipefail

# Resolve this script's real directory, following symlinks.
_resolve_self() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_self)"

WS_CMD="$SCRIPT_DIR/ws"

# Runtime state lives in ~/.workspace regardless of where the code is.
CONFIG_DIR="$HOME/.workspace"
CONFIG_FILE="$CONFIG_DIR/config.json"
SESSION_NAME="workspace"
LOG_FILE="$CONFIG_DIR/dashboard.log"
mkdir -p "$CONFIG_DIR"

# Persist stderr to a log so any future crash leaves a trail.
exec 2>>"$LOG_FILE"

# ── Colors (degrade gracefully if tput cannot resolve a code) ────────

_tput() { tput "$@" 2>/dev/null || true; }

C_RESET=$(_tput sgr0)
C_BOLD=$(_tput bold)
C_CYAN=$(_tput setaf 81)
C_GREEN=$(_tput setaf 114)
C_ORANGE=$(_tput setaf 214)
C_GRAY=$(_tput setaf 242)
C_LIGHT_GRAY=$(_tput setaf 250)
C_KEY_HINT=$(_tput setaf 246)
C_DIM=$(_tput setaf 240)
C_RED=$(_tput setaf 196)

EL=$(_tput el)   # clear to end of line
ED=$(_tput ed)   # clear from cursor to end of screen
SMCUP=$(_tput smcup) # enter alt screen
RMCUP=$(_tput rmcup) # leave alt screen
CIVIS=$(_tput civis) # hide cursor
CNORM=$(_tput cnorm) # show cursor

# ── State ────────────────────────────────────────────────────────────

COLS=80
LINES_COUNT=24
NEEDS_FULL_REDRAW=1   # set on startup and SIGWINCH
PROMPTING=0           # suppress re-renders while reading input
_INPUT=""             # return value from read_input (avoids subshell)

# ── Terminal control ─────────────────────────────────────────────────

get_dims() {
    local l c
    # stty size queries the kernel directly — reliable inside tmux where
    # tput may fall back to the default 24×80.
    if read -r l c < <(stty size </dev/tty 2>/dev/null); then
        [[ -n "$c" && "$c" -gt 0 ]] && COLS=$c
        [[ -n "$l" && "$l" -gt 0 ]] && LINES_COUNT=$l
    else
        c=$(_tput cols); l=$(_tput lines)
        [[ -n "$c" && "$c" -gt 0 ]] && COLS=$c
        [[ -n "$l" && "$l" -gt 0 ]] && LINES_COUNT=$l
    fi
}

# Position cursor at (row, col). Uses CSI directly to avoid an exec per call.
move_to() { printf '\033[%d;%dH' "$(( $1 + 1 ))" "$(( $2 + 1 ))"; }

# Print a line at row anchored at col, then clear to end of line.
draw_line() {
    local row="$1" col="$2" text="$3"
    move_to "$row" "$col"
    printf '%s%s' "$text" "$EL"
}

draw_hline() {
    local row="$1"
    move_to "$row" 0
    printf '%s' "$C_GRAY"
    printf '─%.0s' $(seq 1 "$COLS")
    printf '%s%s' "$C_RESET" "$EL"
}

# strlen(): visible character count, ignoring SGR escapes.
visible_len() {
    local s="$1"
    s="${s//$'\033'\[[0-9;]*m/}"
    printf '%d' "${#s}"
}

# ── Time formatting (pure shell, no subprocess) ──────────────────────

_now_epoch=0
refresh_now() { _now_epoch=$(date +%s); }

iso_to_epoch() {
    local iso="$1" epoch
    if [[ "$(uname)" == "Darwin" ]]; then
        epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) || epoch=$_now_epoch
    else
        epoch=$(date -d "$iso" +%s 2>/dev/null) || epoch=$_now_epoch
    fi
    printf '%d' "$epoch"
}

format_duration() {
    local diff="$1"
    (( diff < 0 )) && diff=0
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))
    if   (( days  > 0 )); then printf '%dd %dh' "$days" "$hours"
    elif (( hours > 0 )); then printf '%dh %dm' "$hours" "$mins"
    else printf '%dm' "$mins"
    fi
}

format_idle() {
    local s="$1"
    if   (( s < 60 ));   then printf 'just now'
    elif (( s < 3600 )); then printf '%dm ago' $((s / 60))
    else                      printf '%dh ago' $((s / 3600))
    fi
}

# ── Claude Code "needs input" detection ─────────────────────────────
#
# Captures the last 5 visible lines of a tmux pane and checks for known
# Claude Code approval-prompt patterns.  Returns 0 if waiting, 1 otherwise.

check_needs_input() {
    local win="$1"
    local pane_text
    pane_text=$(tmux capture-pane -t "$SESSION_NAME:$win" -p -S -5 2>/dev/null) || return 1
    [[ -z "$pane_text" ]] && return 1

    # Strip ANSI escape sequences for reliable matching.
    local clean
    clean=$(printf '%s' "$pane_text" | sed $'s/\033\[[0-9;]*m//g')

    # Tool-permission prompts:  "Allow Read …", "Allow Bash …", etc.
    if printf '%s' "$clean" | grep -qiE \
        'Allow .*(Read|Write|Edit|Bash|Glob|Grep|WebFetch|WebSearch|Agent|Skill|mcp_|NotebookEdit)'; then
        return 0
    fi
    # Confirmation prompts
    if printf '%s' "$clean" | grep -qiE \
        'Do you want to (proceed|continue)|approve this|allow once|allow always'; then
        return 0
    fi
    # Choice indicators
    if printf '%s' "$clean" | grep -qE \
        '\(y\)es.*\(n\)o|\(Y/n\)|\(y/N\)|\[Y/n\]|\[y/N\]'; then
        return 0
    fi

    return 1
}

# ── Data fetch (single jq call, single tmux call) ────────────────────

read_terminals() {
    jq -r '.terminals | to_entries[] |
        [(.key|tostring), .value.name, .value.note, .value.created,
         (.value.tmux_window|tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null || true
}

read_window_activity() {
    tmux list-windows -t "$SESSION_NAME" -F '#{window_index}	#{window_activity}' 2>/dev/null || true
}

# ── Render ───────────────────────────────────────────────────────────

render() {
    get_dims
    refresh_now

    if (( NEEDS_FULL_REDRAW )); then
        printf '\033[2J'
        NEEDS_FULL_REDRAW=0
    fi

    local term_lines act_lines
    term_lines=$(read_terminals)
    act_lines=$(read_window_activity)

    # Parallel arrays for activity lookup (bash 3.2 compatible — no `declare -A`).
    local -a act_idx act_val
    act_idx=()
    act_val=()
    if [[ -n "$act_lines" ]]; then
        local w_idx w_act
        while IFS=$'\t' read -r w_idx w_act; do
            [[ -z "$w_idx" ]] && continue
            act_idx+=("$w_idx")
            act_val+=("$w_act")
        done <<< "$act_lines"
    fi

    local term_count=0
    if [[ -n "$term_lines" ]]; then
        term_count=$(printf '%s\n' "$term_lines" | wc -l | tr -d ' ')
    fi

    # ── Header ───
    local summary="${term_count} terminal"
    (( term_count != 1 )) && summary+="s"
    summary+="   $(date '+%a %b %d  %H:%M')"

    draw_hline 0
    local title="${C_CYAN}${C_BOLD}Ahmad's Workspace${C_RESET}"
    draw_line 1 2 "$title"
    local sum_col=$(( COLS - $(visible_len "$summary") - 2 ))
    (( sum_col < 20 )) && sum_col=20
    move_to 1 "$sum_col"
    printf '%s%s%s%s' "$C_GRAY" "$summary" "$C_RESET" "$EL"
    draw_hline 2

    # ── Terminals section ───
    local row=4
    draw_line $row 2 "${C_GRAY}TERMINALS${C_RESET}"
    row=$(( row + 2 ))

    if (( term_count == 0 )); then
        draw_line $row 4 \
            "${C_DIM}No terminals yet. Press ${C_KEY_HINT}n${C_DIM} to add one.${C_RESET}"
        row=$(( row + 2 ))
    else
        local idx name note created tmux_window
        while IFS=$'\t' read -r idx name note created tmux_window; do
            [[ -z "$idx" ]] && continue

            local last_act=0 j
            for ((j = 0; j < ${#act_idx[@]}; j++)); do
                if [[ "${act_idx[j]}" == "$tmux_window" ]]; then
                    last_act=${act_val[j]}
                    break
                fi
            done
            local idle_seconds=0
            if [[ "$last_act" -gt 0 ]]; then
                idle_seconds=$(( _now_epoch - last_act ))
                (( idle_seconds < 0 )) && idle_seconds=0
            fi

            local status_text status_color needs_input=0

            # Check for Claude approval prompts (skip truly idle terminals).
            if (( idle_seconds <= 600 || idle_seconds == 0 )); then
                check_needs_input "$tmux_window" && needs_input=1
            fi

            if (( needs_input )); then
                status_text="⚠ needs input"
                status_color="$C_RED"
            elif (( idle_seconds > 300 )); then
                status_text="⏸ idle"
                status_color="$C_ORANGE"
            else
                status_text="● running"
                status_color="$C_GREEN"
            fi

            local created_epoch
            created_epoch=$(iso_to_epoch "$created")
            local duration
            duration=$(format_duration $(( _now_epoch - created_epoch )))
            local idle_str
            idle_str=$(format_idle "$idle_seconds")

            local title_line="${status_color}▎${C_RESET} ${status_color}${C_BOLD}[${tmux_window}] ${name}${C_RESET}"
            draw_line $row 2 "$title_line"
            local dur_col=$(( COLS - ${#duration} - 4 ))
            (( dur_col < 20 )) && dur_col=20
            move_to $row "$dur_col"
            printf '%s%s%s' "$C_GRAY" "$duration" "$C_RESET"
            row=$(( row + 1 ))

            # Truncate note to fit within the terminal width.
            # Prefix "▎ " is drawn at col 2, so usable chars ≈ COLS - 5.
            local max_note=$(( COLS - 5 ))
            (( max_note < 10 )) && max_note=10
            local display_note="$note"
            if (( ${#note} > max_note )); then
                display_note="${note:0:$((max_note - 1))}…"
            fi
            draw_line $row 2 \
                "${status_color}▎${C_RESET} ${C_LIGHT_GRAY}${display_note}${C_RESET}"
            row=$(( row + 1 ))

            draw_line $row 2 \
                "${status_color}▎${C_RESET} ${status_color}${status_text}${C_RESET} ${C_GRAY}· last activity ${idle_str}${C_RESET}"
            row=$(( row + 2 ))

            (( row >= LINES_COUNT - 3 )) && break
        done <<< "$term_lines"
    fi

    # ── Bottom bar (always pinned to the last two rows) ───
    local bar_line=$(( LINES_COUNT - 3 ))
    local bar_text_line=$(( LINES_COUNT - 2 ))

    # Wipe leftover content between the terminal list and the bottom bar.
    local r
    for (( r = row; r < bar_line; r++ )); do
        move_to $r 0
        printf '%s' "$EL"
    done

    draw_hline "$bar_line"

    # Build toolbar items, then center them across the full width.
    local bar_plain="1-9 terminal   n new   e edit   x remove   r refresh   ? help   q detach"
    local bar_len=${#bar_plain}
    local pad=$(( (COLS - bar_len) / 2 ))
    (( pad < 2 )) && pad=2

    move_to "$bar_text_line" "$pad"
    printf '%s1-9%s terminal   %sn%s new   %se%s edit   %sx%s remove   %sr%s refresh   %s?%s help   %sq%s detach%s' \
        "$C_KEY_HINT" "$C_GRAY" \
        "$C_KEY_HINT" "$C_GRAY" \
        "$C_KEY_HINT" "$C_GRAY" \
        "$C_KEY_HINT" "$C_GRAY" \
        "$C_KEY_HINT" "$C_GRAY" \
        "$C_KEY_HINT" "$C_GRAY" \
        "$C_KEY_HINT" "$C_GRAY" \
        "$C_RESET"
    printf '%s' "$EL"
}

# ── Inline prompts (read from /dev/tty so substitution doesn't swallow) ─

prompt_at_bottom() {
    local msg="$1"
    local row=$(( LINES_COUNT - 1 ))
    move_to "$row" 0
    printf '%s' "$EL"
    move_to "$row" 2
    printf '%s%s%s' "$C_CYAN" "$msg" "$C_RESET"
}

clear_prompt() {
    local row=$(( LINES_COUNT - 1 ))
    move_to "$row" 0
    printf '%s' "$EL"
}

read_input() {
    local prompt_text="$1"
    PROMPTING=1
    prompt_at_bottom "$prompt_text" >/dev/tty
    printf '%s' "$CNORM" >/dev/tty
    _INPUT=""
    IFS= read -r _INPUT </dev/tty || true
    printf '%s' "$CIVIS" >/dev/tty
    PROMPTING=0
}

# ── Action handlers (route through `ws` so logic stays in one place) ─

handle_new_session() {
    read_input "Session name: "
    local name="$_INPUT"
    [[ -z "$name" ]] && { clear_prompt >/dev/tty; return; }

    read_input "Note: "
    local note="$_INPUT"
    [[ -z "$note" ]] && note="$name"

    "$WS_CMD" add "$name" --dir "$HOME" --note "$note" >/dev/null 2>>"$LOG_FILE" || true
    clear_prompt >/dev/tty
    NEEDS_FULL_REDRAW=1
}

handle_edit() {
    read_input "Edit which terminal (number or name): "
    local target="$_INPUT"
    [[ -z "$target" ]] && { clear_prompt >/dev/tty; return; }

    read_input "New note: "
    local new_note="$_INPUT"
    [[ -z "$new_note" ]] && { clear_prompt >/dev/tty; return; }

    "$WS_CMD" note "$target" "$new_note" >/dev/null 2>>"$LOG_FILE" || true
    clear_prompt >/dev/tty
    NEEDS_FULL_REDRAW=1
}

handle_remove() {
    read_input "Remove which terminal (number or name): "
    local target="$_INPUT"
    [[ -z "$target" ]] && { clear_prompt >/dev/tty; return; }

    read_input "Remove \"$target\"? [y/N]: "
    if [[ "$_INPUT" =~ ^[Yy]$ ]]; then
        "$WS_CMD" rm --force "$target" >/dev/null 2>>"$LOG_FILE" || true
    fi
    clear_prompt >/dev/tty
    NEEDS_FULL_REDRAW=1
}

show_help() {
    NEEDS_FULL_REDRAW=1
    printf '\033[2J'
    get_dims

    local row=2
    draw_line $row 2 "${C_CYAN}${C_BOLD}Keyboard Shortcuts${C_RESET}"
    row=$(( row + 2 ))

    local -a items=(
        "1-9:On dashboard: switch to that terminal"
        "n:New terminal"
        "e:Edit note for a terminal"
        "x:Remove a terminal"
        "r:Refresh dashboard"
        "?:Show this help screen"
        "q:Detach (sessions keep running)"
    )

    local item key desc
    for item in "${items[@]}"; do
        key="${item%%:*}"
        desc="${item#*:}"
        move_to $row 4
        printf '%s%-6s%s %s%s%s' \
            "$C_KEY_HINT" "$key" "$C_RESET" \
            "$C_LIGHT_GRAY" "$desc" "$C_RESET"
        printf '%s' "$EL"
        row=$(( row + 1 ))
    done

    row=$(( row + 2 ))
    draw_line $row 4 "${C_GRAY}Status indicators:${C_RESET}"
    row=$(( row + 1 ))
    draw_line $row 6 "${C_RED}⚠ needs input${C_RESET}  ${C_LIGHT_GRAY}Claude is waiting for approval${C_RESET}"
    row=$(( row + 1 ))
    draw_line $row 6 "${C_GREEN}● running${C_RESET}      ${C_LIGHT_GRAY}Terminal active in last 5 min${C_RESET}"
    row=$(( row + 1 ))
    draw_line $row 6 "${C_ORANGE}⏸ idle${C_RESET}         ${C_LIGHT_GRAY}No activity for 5+ min${C_RESET}"

    row=$(( row + 2 ))
    draw_line $row 4 \
        "${C_GRAY}Switch from any terminal (one keystroke):${C_RESET}"
    row=$(( row + 1 ))

    # Pick the best label for this user's terminal emulator. The tmux binding
    # is always M-1..9; what changes is which physical key sends Meta.
    local switch_label dash_label setup_hint=""
    if [[ "$(uname)" == "Darwin" ]]; then
        case "${TERM_PROGRAM:-}" in
            Apple_Terminal)
                switch_label="Option+1..9"
                dash_label="Option+0"
                setup_hint="One-time setup: Settings → Profiles → Keyboard → Use Option as Meta key"
                ;;
            iTerm.app)
                switch_label="Cmd+1..9"
                dash_label="Cmd+0"
                setup_hint="One-time setup: run ${C_KEY_HINT}ws keys${C_DIM} in a shell (iTerm2 section)"
                ;;
            ghostty|Ghostty)
                switch_label="Cmd+1..9"
                dash_label="Cmd+0"
                setup_hint="One-time setup: run ${C_KEY_HINT}ws keys${C_DIM} in a shell (Ghostty section)"
                ;;
            *)
                switch_label="Option+1..9"
                dash_label="Option+0"
                setup_hint="If keys don't fire: run ${C_KEY_HINT}ws keys${C_DIM} for terminal-specific setup"
                ;;
        esac
    else
        switch_label="Alt+1..9"
        dash_label="Alt+0"
    fi

    draw_line $row 6 \
        "${C_KEY_HINT}${switch_label}${C_GRAY}    jump to terminal N${C_RESET}"
    row=$(( row + 1 ))
    draw_line $row 6 \
        "${C_KEY_HINT}${dash_label}${C_GRAY}       jump to dashboard${C_RESET}"
    if [[ -n "$setup_hint" ]]; then
        row=$(( row + 1 ))
        draw_line $row 6 "${C_DIM}${setup_hint}${C_RESET}"
    fi

    local bottom=$(( LINES_COUNT - 1 ))
    move_to "$bottom" 2
    printf '%s%s%s' "$C_GRAY" "Press any key to return..." "$C_RESET"

    IFS= read -rsn1 _ </dev/tty || true
}

# ── Main loop ────────────────────────────────────────────────────────

cleanup() {
    printf '%s%s' "$RMCUP" "$CNORM"
    exit 0
}

handle_winch() {
    NEEDS_FULL_REDRAW=1
    get_dims
    (( PROMPTING )) || render
}

trap cleanup EXIT INT TERM
trap handle_winch WINCH

printf '%s%s' "$SMCUP" "$CIVIS"

key=""
while true; do
    render

    # Block for keypress with a short timeout. Bash 3.2 defers SIGWINCH until
    # the read returns, so a short timeout keeps the dashboard responsive to
    # resize and external state changes without flicker (the render is cheap).
    if read -rsn1 -t1 key 2>/dev/null; then
        case "$key" in
            '?') show_help ;;
            [1-9])
                if jq -e --argjson w "$key" \
                    '.terminals | any(.tmux_window == ($w|tonumber))' \
                    "$CONFIG_FILE" >/dev/null 2>&1; then
                    tmux select-window -t "$SESSION_NAME:${key}" 2>/dev/null || true
                fi
                ;;
            n) handle_new_session ;;
            e) handle_edit ;;
            x) handle_remove ;;
            r) NEEDS_FULL_REDRAW=1 ;;
            q) tmux detach-client 2>/dev/null || true ;;
        esac
    fi
done
