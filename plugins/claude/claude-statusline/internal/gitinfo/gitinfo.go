// Package gitinfo reports the current branch, keeping git as the source of truth and
// caching only its answer, and the origin remote, which it reads from the config file.
package gitinfo

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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
	if Overridden() {
		return true
	}
	_, ok := Root(cwd)
	return ok
}

// Root returns the directory holding the nearest .git entry above cwd. It reports
// false outside a repository and whenever GIT_DIR or GIT_WORK_TREE is set, because
// the walk cannot see where those put the working tree.
func Root(cwd string) (string, bool) {
	if Overridden() {
		return "", false
	}
	for dir := cwd; ; {
		// A linked worktree holds a .git file rather than a directory, so the kind
		// is not checked — only that something by that name is there.
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

// Overridden reports whether GIT_DIR or GIT_WORK_TREE is set, which puts the repository
// where Root's walk cannot see it. Callers that must tell "outside a repository" from
// "somewhere unknown" check it first.
func Overridden() bool {
	return os.Getenv("GIT_DIR") != "" || os.Getenv("GIT_WORK_TREE") != ""
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

// originSection matches the header of the origin remote. Git compares the section name
// case-insensitively but the subsection name exactly.
var originSection = regexp.MustCompile(`^\[(?i:remote)[ \t]+"origin"\]`)

// Origin returns the URL of the origin remote of the repository whose working tree is
// root, or "" without one. It reads the config file rather than asking git so that a
// render serving the branch from its cache still starts no process; as a result
// insteadOf rewrites and included files are not applied.
//
// In a linked worktree or a submodule .git is a file holding a gitdir: pointer. A
// linked worktree keeps the shared config in the directory its commondir names.
func Origin(root string) string {
	if root == "" {
		return ""
	}
	gitDir := filepath.Join(root, ".git")
	if b, ok := readRegular(gitDir); ok {
		ptr, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir:")
		if !ok {
			return ""
		}
		gitDir = joinIfRelative(root, strings.TrimSpace(ptr))
		if b, ok := readRegular(filepath.Join(gitDir, "commondir")); ok {
			gitDir = joinIfRelative(gitDir, strings.TrimSpace(string(b)))
		}
	}
	cfg, ok := readRegular(filepath.Join(gitDir, "config"))
	if !ok {
		return ""
	}
	inOrigin := false
	for _, line := range strings.Split(string(cfg), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			inOrigin = originSection.MatchString(line)
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok && inOrigin && strings.EqualFold(strings.TrimSpace(k), "url") {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// maxGitFileBytes bounds what Origin reads: a git config or pointer file is a few
// lines, and a larger one is not worth the memory.
const maxGitFileBytes = 1 << 20

// readRegular reads path only if it is a regular file, and at most maxGitFileBytes of
// it. The render runs in whatever directory the session is in, so a .git that is a
// FIFO would block it and one that links to /dev/zero would never end.
func readRegular(path string) ([]byte, bool) {
	if fi, err := os.Stat(path); err != nil || !fi.Mode().IsRegular() {
		return nil, false
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxGitFileBytes))
	return b, err == nil
}

func joinIfRelative(base, p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(base, p)
}
