// Package gitinfo reports the current branch, keeping git as the source of truth and
// caching only its answer.
package gitinfo

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const cacheName = "git-branch.env"

// Branch returns the branch checked out at cwd, or "" for a detached HEAD or a path
// that is not in a repository.
//
// Reading .git/HEAD directly would be cheaper and wrong: a subdirectory has no .git
// of its own, and in a linked worktree .git is a file holding a gitdir: pointer, so
// both would silently lose the branch. Instead git answers once on a cache miss and
// hands back the HEAD file path; later renders compare that file's first line with
// the stored token using only builtins. Comparing content rather than mtime catches
// a switch that happened inside the same second, which mtime's one-second resolution
// cannot.
func Branch(cwd, cacheDir string) string {
	if cwd == "" {
		return ""
	}
	if fi, err := os.Stat(cwd); err != nil || !fi.IsDir() {
		return ""
	}
	cache := ""
	if cacheDir != "" {
		cache = filepath.Join(cacheDir, cacheName)
	}

	if cache != "" {
		if branch, ok := cachedBranch(cache, cwd); ok {
			return branch
		}
	}

	if !insideRepository(cwd) {
		return ""
	}

	// One git call yields both the HEAD path and the branch name, two output lines.
	// The exit status is ignored on purpose: on an unborn branch git exits 128 while
	// still printing the HEAD path and the literal "HEAD", and the render depends on
	// both of those lines. Dropping stdout on a non-zero status would lose the HEAD
	// path and stop the cache from being written for a fresh repository.
	out, _ := exec.Command("git", "-C", cwd, "--no-optional-locks",
		"rev-parse", "--git-path", "HEAD", "--abbrev-ref", "HEAD").Output()
	headRel, branch := "", ""
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) > 0 {
		headRel = lines[0]
	}
	if len(lines) > 1 {
		branch = stripControl(lines[1])
	}
	if branch == "HEAD" {
		branch = ""
	}

	// git prints the HEAD path relative to cwd when run from a subdirectory, so store
	// it as an absolute path; the kernel resolves any ".." inside it.
	headAbs := ""
	switch {
	case headRel == "":
	case strings.HasPrefix(headRel, "/"):
		headAbs = headRel
	default:
		headAbs = cwd + "/" + headRel
	}

	token, tokenOK := firstLine(headAbs)
	if cache == "" {
		return branch
	}
	if !tokenOK {
		// Not a repository. Drop the cache so the next render decides again.
		os.Remove(cache)
		return branch
	}
	if os.MkdirAll(cacheDir, 0o755) == nil {
		_ = os.WriteFile(cache, []byte("cwd="+cwd+"\nhead="+headAbs+
			"\ntoken="+token+"\nbranch="+branch+"\n"), 0o600)
	}
	return branch
}

// insideRepository reports whether cwd or one of its ancestors holds a .git entry,
// which is the condition git itself walks. Answering it here costs a handful of stat
// calls where spawning git to hear "no" costs milliseconds, and outside a repository
// that spawn happened on every render because the cache never has anything to hit.
// The answer needs no cache of its own: the moment a directory gains a .git, the next
// render's walk sees it. GIT_DIR and GIT_WORK_TREE can place a repository where this
// walk cannot see it, so their presence hands the question back to git.
func insideRepository(cwd string) bool {
	if os.Getenv("GIT_DIR") != "" || os.Getenv("GIT_WORK_TREE") != "" {
		return true
	}
	for dir := cwd; ; {
		// A linked worktree holds a .git file rather than a directory, so the kind
		// is not checked — only that something by that name is there.
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return false
		}
		dir = parent
	}
}

func cachedBranch(cache, cwd string) (string, bool) {
	b, err := os.ReadFile(cache)
	if err != nil {
		return "", false
	}
	var cachedCWD, head, token, branch string
	for _, line := range strings.Split(string(b), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "cwd":
			cachedCWD = v
		case "head":
			head = v
		case "token":
			token = v
		case "branch":
			branch = v
		}
	}
	if cachedCWD != cwd || head == "" {
		return "", false
	}
	cur, ok := firstLine(head)
	if !ok || cur != token {
		return "", false
	}
	return branch, true
}

// firstLine reports the first line of a regular file. ok is false when the path is
// absent or is not a regular file, which is how a missing HEAD is told from an empty
// one.
func firstLine(path string) (string, bool) {
	if path == "" {
		return "", false
	}
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return line, true
}

func stripControl(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}
