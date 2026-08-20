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

`statusline.test.sh` builds the binary, points the shim at it, and asserts both
layouts, gauges, colors, and indicators against fixture JSON. It fails outright
when that build fails, because a skipped build would report zero checks as a
pass. `shim.test.sh` asserts what the shim does with and without a binary and
that `build-binary.sh` is idempotent and never blocks session start.
`json.test.sh` and `settings.test.sh` cover the awk parser and rewriter the
`SessionStart` hook still uses. `resume.test.sh` asserts the retry cap, exit
codes, and the prompt `resume.sh` injects; it overrides the wait and the cap
through environment variables so the suite stays fast.

The Go tests carry the boundaries the shell suite only sees through whole-output
comparison: display width and cutting, terminal-width decisions, path and branch
shortening, the gh cache decision table, gauge thresholds and reset formatting.
Where a shell implementation of the same rule still lives in the repo,
`internal/shorten` compares against it byte for byte on every run, so the
expectations cannot drift from `scripts/shorten.sh`.

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

## Contracts still in transition

The render path is Go, but two shell files still implement rules the Go packages
also implement. This table records what does not hold yet, what violates it, and
what has to be true before the duplicate goes away. Keep it here rather than in a
pull request body: a merged body never reopens, so a note left there stops being
a place anyone looks.

| Does not hold yet | What violates it today | When it holds |
|---|---|---|
| One implementation of path and branch shortening | `scripts/shorten.sh` and `scripts/shorten-lib.sh` alongside `internal/shorten` | Once shortening is confirmed to have no consumer on any machine, delete both scripts and the differential test in `internal/shorten/shorten_test.go` that uses them as its oracle |
| The two implementations agree for every input | The shell's ticket detection depends on the collating locale: `case`'s `[A-Z]` range covers `b`–`z` under `en_US.UTF-8`, so it reads `lower-1-x-y-z` as a ticket and leaves it unshortened, while `LC_ALL=C` shortens it | Resolved by the row above. `internal/shorten` follows the rule `shorten-lib.sh` documents in its own comment — a key is a ticket only when it is all uppercase — and the differential test calls the shell with `LC_ALL=C` so both sides mean the same thing |

`scripts/json.awk` is not part of this table. `scripts/hook-handler.sh` parses the
hook payload and `settings.json` with it and `tests/json.test.sh` covers it, so it
is the only implementation of what it does, not a duplicate of the Go parser.

## Configuration is data, not code

The `gh@<account>` mapping is intentionally **not** in the source. It is read at
runtime from `${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts`.
Do not hardcode account names, labels, or colors in the scripts — keep the source
publishable.
