# AGENTS.md

Guidance for AI agents and contributors working in this repository.

This repo holds two Claude Code plugins published through one marketplace
catalog. `claude-statusline` is a width-aware statusline HUD with a compact
three-row layout and a full seven-row layout. `stuck-resume` is a
`StopFailure` hook that waits out a usage limit or an expired login and then
resumes the interrupted turn. End-user documentation lives in
[README.md](README.md); this file covers how to change the code safely.

Each plugin owns a directory named after it, holding `.claude-plugin/plugin.json`,
`hooks/hooks.json`, `scripts/`, and `tests/`. `hooks.json` is auto-discovered;
do not also declare a `hooks` field in `plugin.json` (double-registration errors
out).

## The render path is Go

`claude-statusline` renders in one process: `cmd/statusline` reads the payload on
stdin and writes the rows, and `internal/` holds the packages it composes.
`scripts/statusline.sh` stays as a shim that `exec`s that binary, so the command
already recorded in `settings.json` keeps working.

The module uses **the standard library only**. This is a distribution constraint,
not a preference: the binary is built on the user's machine, so a single external
module would make the first session need the network, and the statusline would
not come up where the network is absent or a proxy blocks it. Verify with
`GOPROXY=off go build ./...` — it fails rather than fetching.

The binary is not committed. `scripts/build-binary.sh` builds it once per plugin
version into
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/bin/statusline-<version>-<GOOS>-<GOARCH>`
and writes that absolute path to `binary-path` beside it, which is the one line
the shim reads. The `SessionStart` hook detaches that build into the background
because the hook's timeout is 5 seconds and a cold build lands on it.

Two properties keep the port worth its while, so hold them when editing:

- The shim starts no child process. Computing the path per render with `uname`,
  or calling the build script, spends back the time the port saved.
- Read the clock once per render and pass that value down. Reading it per segment
  lets a second boundary fall between two of them and move a pace budget by a
  cell.

## Shell scripts: POSIX sh

Every remaining shell script is POSIX `sh` (`#!/bin/sh`). Executable entrypoints
use `set -eu`; shared helpers loaded via `.` do not force shell options on their
caller. Avoid bashisms:

- `[[ ]]` -> `[ ]` or `case`
- arrays (`arr=()`, `${arr[@]}`) -> positional params (`$@`) or string splitting
- `=~` / `BASH_REMATCH` -> `case` patterns, `expr`, or `sed`
- `${var,,}` / `${var^^}` -> `tr`
- `<<<` here-strings -> `printf '%s' "$var" | ...`
- `(( ))` -> `$(( ))` or `[ "$a" -gt "$b" ]`
- `function foo()` -> `foo()`

`local` and `$(...)` are used and assumed available.

`stuck-resume` stays POSIX `sh` permanently. It is a few dozen lines and runs
once per failed turn, so an interpreter start-up costs nothing worth optimizing
away.

## Testing

Run every suite from the repo root; the exit code is the gate, so a suite that
fails to start fails the run rather than reporting zero failures:

```shell
sh -c 'rc=0; for t in */tests/*.test.sh; do sh "$t" || rc=1; done; (cd claude-statusline && go test ./...) || rc=1; exit "$rc"'
```

A suite that cleans up in an `EXIT` trap has to carry a completion flag, because
bash 3.2 — the `/bin/sh` on macOS — resets `$?` to zero on entering that trap. A
trap that only removes its temp directory therefore reports a `set -eu` abort as
a clean exit, and the gate above cannot tell an aborted run from a passing one.
Each such suite sets `completed=0` before registering the trap, sets
`completed=1` immediately before its final `[ "$fail" -eq 0 ]`, and forces a
non-zero status in the trap when the flag never reached one. A new suite that
registers a cleanup trap without that flag silently opts out of the gate.

`statusline.test.sh` builds the binary, points the shim at it, and asserts both
layouts, gauges, colors, and indicators against fixture JSON. It fails outright
when that build fails, because a skipped build would report zero checks as a
pass. `shim.test.sh` asserts what the shim does with and without a binary and
that `build-binary.sh` is idempotent and never blocks session start.
`json.test.sh` and `settings.test.sh` cover the awk parser and rewriter the
`SessionStart` hook still uses. `resume.test.sh` asserts the exit codes, the prompt
`resume.sh` injects, the per-cause counters, and the per-cause attempt caps; it
overrides the wait through an environment variable, and reaches a cap by seeding
the counter file rather than running to it, so the suite stays fast.

The Go tests carry the boundaries the shell suite only sees through whole-output
comparison: display width and cutting, terminal-width decisions, path and branch
shortening, the gh cache decision table, gauge thresholds and reset formatting.
`internal/shorten` pins both the plain shortening and the colored output, because
a table that reads only the surviving words still passes when the rule that paints
the repository and current segments blue is broken.

Follow Red -> Green: add a failing test before a behavior change, then make it
pass. Report the pass/fail counts when you change behavior.

Test fixtures must not contain real people, accounts, or secrets. Use
placeholder logins (e.g. `octocat`) and RFC 2606 reserved domains
(`@example.com`) where an address is needed.

## Versioning

Each plugin is loaded from a **version-pinned cache**, so any change that should
reach installed users needs a version bump. On every functional change:

1. Bump `<plugin>/.claude-plugin/plugin.json` `version` (SemVer).
2. Set that plugin's entry `version` in `.claude-plugin/marketplace.json`
   to the same value.

Keep the two versions identical. Commits follow Conventional Commits
(`feat(...)`, `fix(...)`, `refactor(...)`, `chore(...)`, ...).

## The awk parser is not a duplicate

`scripts/hook-handler.sh` parses the hook payload and `settings.json` with
`scripts/json.awk`, and `tests/json.test.sh` covers it. It is the only
implementation of what it does, not a second copy of the Go parser, so it stays.

## Configuration is data, not code

The `gh@<account>` mapping is intentionally **not** in the source. It is read at
runtime from `${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts`.
Do not hardcode account names, labels, or colors in the scripts — keep the source
publishable.
