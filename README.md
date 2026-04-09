# Miran

A terminal workspace dashboard. Manage many shells in one tmux session, each with a name and a free-text note that's visible inside the terminal itself. Switch between them with one keystroke from anywhere.

```
────────────────────────────────────────────────────────────────────────────
  workspace                                       3 terminals   Thu Apr 09  22:50
────────────────────────────────────────────────────────────────────────────

  TERMINALS

  ▎ [1] api                                                              2h 14m
  ▎ working on the new /search endpoint
  ▎ ● running · last activity 3m ago

  ▎ [2] db                                                                  41m
  ▎ psql against the staging snapshot
  ▎ ● running · last activity just now

  ▎ [3] notes                                                            1d 2h
  ▎ scratch buffer for the migration plan
  ▎ ⏸ idle · last activity 6h ago

────────────────────────────────────────────────────────────────────────────
  1-9 terminal  n new  e edit  x remove  r refresh  ? help  q detach
```

## What it is

Miran is a thin layer on top of [tmux](https://github.com/tmux/tmux). It gives you:

- **A home dashboard.** A first-class "what am I working on" view that lists every terminal in the workspace, each with a name, a note, how long it's been alive, and whether it's idle.
- **Notes that follow the terminal.** When you jump into a terminal, the note shows up at the top of the pane (via tmux's `pane-border-format`). You don't have to remember why you opened it.
- **One-keystroke switching.** From anywhere — inside any terminal — `Cmd+1` or `Option+1` (macOS) / `Alt+1` (Linux/Windows) jumps to terminal 1. `Cmd+0` / `Alt+0` returns to the dashboard. No prefix chord, no clicking.
- **Persistence.** Terminals survive `ws stop` / `ws start`. Names, notes, working directories all come back.
- **A small CLI.** `ws add`, `ws note`, `ws rm`, `ws ls` for scripting.

It is intentionally simple: ~800 lines of bash on top of `tmux` and `jq`. There are no daemons, no background services, no Node, no Rust. If you can run tmux, you can run Miran.

## Why

[tmux](https://github.com/tmux/tmux) gives you windows and panes; [Zellij](https://zellij.dev) gives you a polished UI; both treat each terminal as a featureless slot. After more than three or four open terminals, "what was I doing in this one?" becomes a real question. Miran's whole job is to answer that question without making you leave the terminal.

It does **not** try to be a multiplexer (tmux already is one), a session manager (tmux already is one), or a window manager. It just adds the dashboard + notes layer on top.

## Install

### Prerequisites

- macOS or Linux (Windows via WSL)
- `tmux` ≥ 2.6
- `jq`
- `bash` ≥ 3.2 (the version that ships with macOS works)

On macOS:
```sh
brew install tmux jq
```

### Install Miran

```sh
git clone https://github.com/<user>/Miran.git
cd Miran
./install.sh
```

`install.sh` is idempotent: it symlinks `bin/ws` and `bin/dashboard.sh` into `~/.local/bin`, creates `~/.workspace/` for runtime state, and tells you if `~/.local/bin` isn't in your `PATH` yet.

### One-time keyboard setup

Tmux can't see `Cmd+1..9` directly because the terminal emulator intercepts it first. The fix is to teach your terminal to send the same escape sequence as `Alt+N` when you press `Cmd+N`. After that, both work and feel identical.

The shortest path on **macOS Terminal.app** (the default):
1. Terminal menu → **Settings** (`⌘,`)
2. **Profiles** tab → select your profile
3. **Keyboard** sub-tab
4. Check **"Use Option as Meta key"**

That's it. Now `Option+1..9` jumps to terminal 1..9 from any pane. (Cmd is reserved by macOS for switching Terminal's own tabs and is hard to repurpose; see `ws keys` for the workaround if you really want it.)

For **iTerm2**, **Ghostty**, **Windows Terminal**, **Linux**, run:
```sh
ws keys
```
for the per-terminal recipe.

## Usage

```sh
ws start          # start the workspace and attach to the dashboard
```

Inside the dashboard:

| key | action |
| --- | --- |
| `n` | add a new terminal (you'll be prompted for a name and a note) |
| `e` | edit the note for an existing terminal |
| `x` | remove a terminal |
| `1`–`9` | switch to that terminal (only when focused on the dashboard) |
| `r` | force refresh |
| `?` | help screen |
| `q` | detach (terminals keep running) |

From inside any terminal:

| key | action |
| --- | --- |
| `Option+1`…`Option+9` *(macOS Terminal.app)* | jump to terminal N |
| `Cmd+1`…`Cmd+9` *(iTerm2 / Ghostty after `ws keys` setup)* | jump to terminal N |
| `Alt+1`…`Alt+9` *(Linux / Windows)* | jump to terminal N |
| `Option+0` / `Cmd+0` / `Alt+0` | jump to dashboard |
| `Ctrl+B d` | detach the entire session (default tmux) |

The CLI also exposes everything for scripting:

```sh
ws add api --note "search endpoint"   # add a terminal from anywhere
ws note 2 "now investigating cache"   # update a note
ws ls                                 # list terminals
ws rm api                             # interactive remove
ws rm --force api                     # non-interactive
ws stop                               # kill the entire workspace
ws keys                               # show terminal-specific keyboard setup
ws help                               # full CLI usage
```

## How it works

```
~/Desktop/Miran/                  ← code lives here, git tracked
├── bin/
│   ├── ws                        ← CLI (bash) — tmux + jq orchestration
│   └── dashboard.sh              ← TUI (bash) — the home view
├── test/
│   └── ws-test.sh                ← integration tests (drives tmux via send-keys)
├── docs/
│   └── architecture.md           ← deeper dive into how the pieces fit
├── install.sh
├── LICENSE                       ← MIT
└── README.md

~/.workspace/                     ← runtime state, created on first run
├── config.json                   ← terminals, notes, dirs, timestamps
├── config.json.bak               ← previous version (rolled on every write)
└── dashboard.log                 ← stderr from the dashboard for debugging
```

The code lives in the git checkout. The runtime state lives in `~/.workspace/`. They're decoupled — you can `git pull` without losing your terminals, and you can `rm -rf ~/.workspace/` to nuke your workspace without touching the code.

The dashboard is a tmux window (window 0) that runs `dashboard.sh` in a self-restarting `while true` loop. Every other terminal in the workspace is a normal tmux window with a `pane-border-status top` line at the top showing its name and note. Switching between them is just `tmux select-window`. Notes are stored in `~/.workspace/config.json`; rendering reads it once per second and on every `SIGWINCH` (terminal resize).

For more, see [`docs/architecture.md`](docs/architecture.md).

## Tested

```sh
./test/ws-test.sh
```

40 integration tests covering: empty render, add via dashboard prompts, pane border applied + restored, edit note, remove + window renumbering, 1–9 switching, terminal resize, 9-terminal cap enforcement, persistence across stop/start, Alt-key bindings, CLI parity. All run end-to-end against a real `tmux` session driven via `tmux send-keys`. Stable across consecutive runs under bash 3.2.

## Compatibility

- macOS 12+ — Terminal.app, iTerm2, Ghostty, Alacritty, kitty, wezterm
- Linux — any modern terminal
- Windows — via WSL2 + Windows Terminal
- bash 3.2+ — no associative arrays, no `mapfile`, no bash 4-only features

## Limits

- **9 terminals max.** The hotkey row goes 1..9. Trivial to expand later (paginate, two-key shortcuts), but I don't usually want more than 9 open at once anyway.
- **Single workspace.** All terminals live in one tmux session named `workspace`. Multi-workspace support would be a feature, not a bugfix.
- **macOS Terminal.app can't natively bind `Cmd+N`** to anything other than its own tab switcher. Use `Option+N` on Terminal.app, or switch to iTerm2 / Ghostty for true `Cmd+N`.

## License

[MIT](LICENSE).
