# AGENTS.md

Guidance for AI agents and contributors working in this repository.

This repo holds two Claude Code plugins published through one marketplace
catalog. `claude-statusline` is a width-aware statusline HUD with a compact
three-row layout and a full seven-row layout. `rate-limit-resume` is a
`StopFailure` hook that waits out a usage limit and then resumes the
interrupted turn. End-user documentation lives in [README.md](README.md); this
file covers how to change the code safely.

Each plugin owns a directory named after it, holding `.claude-plugin/plugin.json`,
`hooks/hooks.json`, `scripts/`, and `tests/`. `hooks.json` is auto-discovered;
do not also declare a `hooks` field in `plugin.json` (double-registration errors
out).

## Shell scripts: POSIX sh

Every shell script is POSIX `sh` (`#!/bin/sh`). Executable entrypoints use
`set -eu`; shared helpers loaded via `.` do not force shell options on their
caller. Avoid bashisms:

- `[[ ]]` -> `[ ]` or `case`
- arrays (`arr=()`, `${arr[@]}`) -> positional params (`$@`) or string splitting
- `=~` / `BASH_REMATCH` -> `case` patterns, `expr`, or `sed`
- `${var,,}` / `${var^^}` -> `tr`
- `<<<` here-strings -> `printf '%s' "$var" | ...`
- `(( ))` -> `$(( ))` or `[ "$a" -gt "$b" ]`
- `function foo()` -> `foo()`

`local` and `$(...)` are used and assumed available.

## Testing

Run every suite from the repo root; the exit code is the gate, so a suite that
fails to start fails the run rather than reporting zero failures:

```shell
sh -c 'rc=0; for t in */tests/*.test.sh; do sh "$t" || rc=1; done; exit "$rc"'
```

`statusline.test.sh` renders `statusline.sh` against fixture JSON and asserts
both layouts, gauges, colors, and indicators. `fit.test.sh` asserts
`fit-line1.awk`'s width calculation and cut behavior directly. `width.test.sh`
asserts tty discovery, caching, and width refresh behavior. `resume.test.sh`
asserts the retry cap, exit codes, and the prompt `resume.sh` injects; it
overrides the wait and the cap through environment variables so the suite
stays fast. Follow Red -> Green: add a failing test before a behavior change,
then make it pass. Report the pass/fail counts when you change behavior.

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

## Configuration is data, not code

The `gh@<account>` mapping is intentionally **not** in the source. It is read at
runtime from `${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts`.
Do not hardcode account names, labels, or colors in the scripts — keep the source
publishable.
