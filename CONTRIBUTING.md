# Contributing to Miran

Bug reports, feature requests, and pull requests are welcome.

## Quick orientation

- The whole tool is two bash scripts: `bin/ws` (CLI) and `bin/dashboard.sh` (TUI).
- The integration test suite lives in `test/ws-test.sh` and drives a real tmux session.
- Read [`docs/architecture.md`](docs/architecture.md) for a deeper walkthrough.

## Local setup

```sh
git clone https://github.com/<user>/Miran.git
cd Miran
./install.sh
ws start
```

The installer symlinks `bin/ws` and `bin/dashboard.sh` into `~/.local/bin`. Editing the files in your checkout updates the installed copy immediately — no rebuild step.

## Running tests

```sh
./test/ws-test.sh
```

The suite runs the dashboard under `/bin/bash` (the system bash 3.2 on macOS) so that any bash-4-only features used by accident surface immediately. Tests reset state from scratch each time and clean up the `workspace` tmux session on exit.

If a test flakes, the most likely cause is a startup-timing race in `start_workspace` — bump the `sleep 1.0` if needed.

## Style

- **No `set -e` in dashboard.sh.** A transient `tput` failure on a weird terminal would kill the TUI. We use `set -uo pipefail` and check returns explicitly where it matters.
- **Bash 3.2 compatible.** No `declare -A`, no `mapfile`, no `${var,,}`. macOS still ships 3.2.
- **`config_read` and `config_write` use `"$@"`.** Forwarding only `"$1"` was a real bug — every multi-arg call silently failed. Don't reintroduce it.
- **Action handlers in `dashboard.sh` route through `ws`** instead of mutating `config.json` directly. This keeps the source of truth in one place.
- **Interactive prompts write to `/dev/tty`.** Otherwise command substitution captures the escape codes. See the comment in `read_input()` if this isn't obvious.

## Submitting a change

1. Open an issue describing the bug or proposed feature first if it's non-trivial. For typos, small fixes, or doc updates, just open the PR.
2. Run the test suite locally before pushing: `./test/ws-test.sh`. All 40 tests should pass.
3. Add tests for new behavior. The harness is small enough that adding a new `test_*` function is a few lines.
4. Keep PRs focused. One change per PR is much easier to review than a bundle of unrelated improvements.
5. Update `README.md` and/or `docs/architecture.md` if you change user-visible behavior or invariants.

## License

By contributing you agree your contribution will be licensed under the MIT license, the same as the rest of the project.
