// Package shorten collapses a directory path and a branch name to the short forms
// the first row shows.
package shorten

import (
	"os"
	"strconv"
	"strings"

	"github.com/silee-tools/claude-statusline/internal/theme"
)

// Path shortens cwd for display. It collapses home to ~, keeps the first segment,
// every git repository along the way and the current folder, and replaces each run
// of hidden segments with ↪N. Repository names and the current folder are blue and
// everything else is dim.
func Path(cwd, home string) string {
	full := stripControl(cwd)
	home = normalizeHome(stripControl(home))

	display := full
	isHome := false
	if home != "" && home != "/" {
		switch {
		case full == home:
			display, isHome = "~", true
		case strings.HasPrefix(full, home+"/"):
			display, isHome = "~"+strings.TrimPrefix(full, home), true
		}
	}

	absolute := strings.HasPrefix(display, "/")
	if absolute {
		display = display[1:]
	}

	segs := splitFields(display, '/')
	threshold := 3
	if absolute {
		threshold = 2
	}
	if len(segs) <= threshold {
		if absolute {
			display = "/" + display
		}
		return theme.Dim + display + theme.Reset
	}

	repos := gitRepos(full, home)
	var b strings.Builder
	acc := ""
	prevShown, first := 0, true
	for i, p := range segs {
		n := i + 1
		switch {
		case n == 1 && isHome:
			acc = home
		case n == 1 && absolute:
			acc = "/" + p
		case n == 1:
			acc = p
		default:
			acc = strings.TrimSuffix(acc, "/") + "/" + p
		}

		isRepo := repos[acc]
		if n != 1 && n != len(segs) && !isRepo {
			continue
		}

		if first {
			first = false
		} else {
			b.WriteString(theme.Dim + "/" + theme.Reset)
		}
		if n-prevShown > 1 {
			b.WriteString(theme.Dim + "↪" + strconv.Itoa(n-prevShown-1) + theme.Reset)
			b.WriteString(theme.Dim + "/" + theme.Reset)
		}
		if n == len(segs) || isRepo {
			b.WriteString(theme.Blue + p + theme.Reset)
		} else {
			b.WriteString(theme.Dim + p + theme.Reset)
		}
		prevShown = n
	}

	if absolute {
		return theme.Dim + "/" + theme.Reset + b.String()
	}
	return b.String()
}

// normalizeHome drops trailing slashes so a HOME of "/opt/a/" or "////" compares as
// a path rather than as a string prefix.
func normalizeHome(home string) string {
	for home != "/" && strings.HasSuffix(home, "/") {
		home = strings.TrimSuffix(home, "/")
	}
	return home
}

// gitRepos collects the repository directories between full and home, keyed by full
// path. Matching by basename would flag a non-repo directory that merely shares a
// repository's name, such as a .worktrees container next to the real checkout.
func gitRepos(full, home string) map[string]bool {
	stop := home
	if stop == "" {
		stop = "/"
	}
	repos := map[string]bool{}
	for p := full; p != "/" && p != stop; {
		if fi, err := os.Stat(p + "/.git"); err == nil && (fi.IsDir() || fi.Mode().IsRegular()) {
			repos[p] = true
		}
		if i := strings.LastIndexByte(p, '/'); i >= 0 {
			p = p[:i]
			if p == "" {
				p = "/"
			}
		} else {
			p = "/"
		}
	}
	return repos
}

// Branch shortens {prefix/}{TICKET-ID-}{slug}. A slug of exactly four words keeps
// the first and last one, and a longer slug keeps the first two and last two.
func Branch(name string) string {
	branch := stripControl(name)
	const maxWords = 4

	prefix, rest := "", branch
	if i := strings.IndexByte(branch, '/'); i >= 0 {
		switch branch[:i] {
		case "feature", "hotfix", "bugfix", "release", "change":
			prefix, rest = branch[:i+1], branch[i+1:]
		}
	}

	ticket := ""
	if key, after, ok := strings.Cut(rest, "-"); ok && isUpper(key) {
		if num, tail, ok := strings.Cut(after, "-"); ok && isDigits(num) && tail != "" {
			ticket = key + "-" + num + "-"
		}
	}
	slug := strings.TrimPrefix(rest, ticket)

	words := splitFields(slug, '-')
	switch n := len(words); {
	case n == maxWords:
		slug = words[0] + "-↪" + strconv.Itoa(n-2) + "-" + words[n-1]
	case n > maxWords:
		slug = words[0] + "-" + words[1] + "-↪" + strconv.Itoa(n-4) + "-" + words[n-2] + "-" + words[n-1]
	}
	return prefix + ticket + slug
}

// splitFields reproduces POSIX field splitting on a single non-whitespace IFS
// character: a leading separator yields an empty leading field, a trailing one
// yields no trailing field, and an empty string yields no fields at all.
func splitFields(s string, sep byte) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, string(sep))
	if parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// isUpper and isDigits pin the ASCII ranges the shell's [A-Z] and [0-9] mean. The
// shell's own ranges widen under a collating locale, which makes a lowercase key
// read as a ticket; the rule this reproduces is the one shorten-lib.sh documents.
func isUpper(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 'A' || s[i] > 'Z' {
			return false
		}
	}
	return true
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func stripControl(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}
