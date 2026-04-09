# Miran architecture

A walkthrough of how the pieces fit together. Read this if you want to hack on Miran or just understand why it works the way it does.

## TL;DR

```
       ┌──────────────────────────────────────────────┐
       │  tmux session:  "workspace"                  │
       │                                              │
       │   window 0  →  dashboard.sh  (the TUI)       │
       │   window 1  →  bash          (a terminal)    │
       │   window 2  →  bash          (a terminal)    │
       │   …                                          │
       └──────────────────────────────────────────────┘
                  ▲                          ▲
                  │ reads/writes             │ reads
                  ▼                          │
        ~/.workspace/config.json   ←─── ws CLI (mutates)
```

`ws` is the CLI: it spawns and configures the tmux session, mutates the JSON config, and exposes commands like `ws add`, `ws note`, `ws rm`. `dashboard.sh` is the TUI in window 0: it renders the config + tmux activity data and routes interactive input back through `ws`. Everything else is a normal tmux window.

There is **no daemon**. The dashboard is just a long-running bash process inside a tmux pane. The only persistent state is `~/.workspace/config.json`.

## Files

```
bin/
  ws            CLI — 526 lines of bash
  dashboard.sh  TUI — 484 lines of bash

~/.workspace/   (runtime state, created on first run)
  config.json       authoritative state — terminals[], settings{}
  config.json.bak   previous version, rolled on every write
  dashboard.log     stderr from dashboard.sh, persistent for debugging
```

The `bin/` directory ships with the repo. The `~/.workspace/` directory is created at runtime by `ws` (or `install.sh`). They are deliberately decoupled: deleting `~/.workspace/` does not break the code, and `git pull`ing the code does not touch your terminals.

## The `ws` CLI

`bin/ws` is the entry point and the only thing that mutates state. It does five jobs:

1. **Find itself.** Resolves its own directory through symlinks (so symlinking `bin/ws` into `~/.local/bin` works) and uses that to locate `dashboard.sh`.
2. **Manage the tmux session.** Creates the `workspace` session, sets options (theme, mouse, keybinds, no datetime in the status bar), and binds `Alt+0..9` for one-key window switching.
3. **Manage `config.json`.** Reads and writes via small `config_read` / `config_write` helpers that wrap `jq`. Both helpers forward all their arguments to `jq` (this used to be a bug — early versions only forwarded `$1` and silently broke every multi-arg call).
4. **Sync tmux state with config.** When you `ws add`, it both creates the tmux window AND appends to `config.json`. When you `ws rm`, it kills the window AND removes the entry AND renumbers the remaining windows.
5. **Handle the dashboard's restart loop.** `cmd_start` launches `dashboard.sh` wrapped in `while true; do ...; sleep 1; done` so the window survives if the dashboard ever crashes.

Sub-commands:

| command | what it does |
| --- | --- |
| `ws start` | start the workspace, restore terminals from config, attach |
| `ws add <name>` | add a terminal — creates the tmux window and appends config |
| `ws note <target> "..."` | update a terminal's note (also updates the live pane border) |
| `ws rm [--force] <target>` | remove a terminal, kill the window, renumber the rest |
| `ws ls` | list terminals (CLI parity with the dashboard) |
| `ws kill <name>` | alias for `rm --force` |
| `ws stop` | tear down the entire tmux session |
| `ws dash` | jump to the dashboard window |
| `ws config <key> <value>` | set a `settings.*` key in `config.json` |
| `ws keys` | print terminal-specific keyboard setup instructions |

A target is either a window number (1..9) or a terminal name.

## The dashboard (`bin/dashboard.sh`)

The dashboard is the TUI in window 0. It runs in a loop:

```
while true:
    render()                         ← cheap, ~5 ms
    if read -t1 key:                 ← block 1 second
        dispatch(key)
```

`read -t1` is the heartbeat. Bash 3.2 defers `SIGWINCH` until the read returns, so a 1-second timeout is the cap on resize lag. Keys are still instant — `read` returns immediately on input.

### Render loop

The render is intentionally cheap and intentionally non-flickering:

1. **No full screen clear** between frames. Cursor positioning (`\033[r;cH`) plus clear-to-EOL (`\033[K`) per line is enough to overwrite without flicker.
2. **One `tput ed`** at the bottom of the loop to wipe leftover content from the previous frame (e.g., after a removal).
3. **One `jq` call** per render returning all terminals as TSV. No subprocess per row.
4. **One `tmux list-windows`** per render returning all activity timestamps as TSV. No `tmux display-message` per row.
5. **Pure-shell time formatting.** `iso_to_epoch`, `format_duration`, `format_idle` use only bash arithmetic and a single cached `_now_epoch` per frame.
6. **Parallel indexed arrays** (not associative arrays — those are bash 4+) for the activity lookup.

A full re-render is forced (`NEEDS_FULL_REDRAW=1`) on startup, after `SIGWINCH`, after returning from the help screen, and after any state mutation (add/edit/remove).

### Input prompts

The trickiest bug in early Miran was that `name=$(read_input "Session name: ")` swallowed the prompt's escape codes into the variable instead of letting them reach the screen. The fix is to write prompts directly to `/dev/tty` and read input from `/dev/tty`, bypassing command substitution capture entirely.

```bash
read_input() {
    local prompt_text="$1"
    {
        prompt_at_bottom "$prompt_text"
        printf '%s' "$CNORM"        # show cursor
    } >/dev/tty                       # ← bypass $(...) capture
    local input=""
    IFS= read -r input </dev/tty
    {
        printf '%s' "$CIVIS"        # hide cursor
    } >/dev/tty
    printf '%s' "$input"
}
```

### Action handlers route through `ws`

`handle_new_session`, `handle_edit`, `handle_remove` all shell out to `ws add`, `ws note`, `ws rm --force` rather than re-implementing the same logic against `config.json`. This was lesson learned the hard way: an earlier version of `handle_remove` mutated config directly, skipping `_renumber_windows` and producing inconsistent state. Routing through `ws` keeps the source of truth in one place.

## State and the JSON config

Everything that needs to survive a `ws stop` lives in `~/.workspace/config.json`:

```json
{
  "settings": {},
  "terminals": [
    {
      "name": "api",
      "dir": "/Users/me/code/api",
      "note": "search endpoint",
      "created": "2026-04-09T18:24:37Z",
      "tmux_window": 1
    }
  ]
}
```

Writes go through `config_write`, which does `jq` → `tmpfile` → `mv`. A `.bak` is rolled on every write so you can always go back one step.

The `tmux_window` field is the index of the corresponding tmux window. After a removal, `_renumber_windows` walks the array and re-assigns indices to be sequential starting from 1, both in the config AND in tmux via `tmux move-window`. This is what makes the 1..9 hotkeys keep working without gaps after removals.

A legacy schema migration (drop a `chats[]` array if it exists) runs in `ensure_config`. This is harmless if the key isn't there.

## Notes at the top of every terminal

The "note shown at the top of the terminal" effect is pure tmux. For each window:

```
tmux set-window-option -t workspace:N pane-border-status top
tmux set-window-option -t workspace:N pane-border-format "...$name — $note "
```

`pane-border-status top` makes tmux draw a one-line strip at the top of the pane. `pane-border-format` is the content of that strip. `update_pane_border` in `ws` is called whenever a window is created or its note is edited, which keeps the strip in sync with config.

(Subtle bug from the early days: `set-option` instead of `set-window-option` silently fails for window-scoped options. Always use `set-window-option` for `pane-border-*`.)

## One-key switching from any pane

```bash
for i in 0 1 2 3 4 5 6 7 8 9; do
    tmux bind-key -n "M-$i" select-window -t "workspace:$i"
done
```

`bind-key -n` means "no prefix" — these fire directly. `M-N` is the tmux name for the escape sequence `ESC + N`, which is what your terminal sends when you press Alt+N (with Meta enabled). On macOS Terminal.app the user enables this with one checkbox; on iTerm2/Ghostty they remap `Cmd+N` → send `ESC+N` so `Cmd+N` fires the same binding.

This is the only way to do "press a key from inside a terminal and have something else handle it." The terminal sends bytes to the shell; tmux intercepts them before the shell sees them; only `bind-key -n` fires without a prefix.

## Things that look weird and aren't bugs

- **`set -uo pipefail` not `set -euo pipefail`** in `dashboard.sh`. With `set -e`, every transient `tput` failure on a strange terminal would kill the dashboard. Without it, but with `set -u`, we still catch unset-variable bugs (which are real risks in shell) without dying on every tput edge case.
- **`/bin/bash` 3.2 compatibility** is enforced. macOS still ships bash 3.2 and `#!/usr/bin/env bash` resolves to it unless homebrew bash is in PATH. We avoid `declare -A`, `mapfile`, `${var,,}`, and other bash 4-only features.
- **`read -rsn1 -t1`** is the heartbeat. Cutting it shorter (250ms) makes resize feel snappier but burns more idle CPU. 1 second is a good balance — the render is so cheap that even 100ms would be fine, but `read -t` granularity in bash is in seconds, not subseconds, on some systems.
- **Dashboard window has `remain-on-exit on`** AND is wrapped in `while true; do … sleep 1; done`. Belt-and-braces: even if the script crashes catastrophically, the window stays visible (with the error in the log) and the wrapper restarts it.

## Tests

`test/ws-test.sh` is an integration suite that drives a real tmux session via `tmux send-keys` and asserts on:
- the JSON config state
- the dashboard pane content (via `tmux capture-pane`)
- the tmux window list and active window
- the `pane-border-format` of each window
- tmux key bindings

It uses `/bin/bash` (the system bash 3.2) to run the dashboard, so any bash-4-only feature creeping in would surface immediately. It runs against the bin/ files in this checkout, not against an installed copy, so a fresh `git clone` can run the suite.

40 tests. Stable across consecutive runs.
