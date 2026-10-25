package gitinfo

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// returnsInTime fails the test if f is still running after two seconds. A read that waits for
// a writer of the FIFO is then released, so a failing test does not leave it behind.
func returnsInTime(t *testing.T, fifo string, f func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { f(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		if h, err := os.OpenFile(fifo, os.O_RDWR|syscall.O_NONBLOCK, 0); err == nil {
			h.Close()
		}
		t.Fatalf("%s: FIFO 에서 멈췄다", filepath.Base(fifo))
	}
}

func mkfifo(t *testing.T, path string) string {
	t.Helper()
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func symlink(t *testing.T, target, path string) {
	t.Helper()
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
}

// The cache sits in a directory the statusline writes, and git answers on a miss; a FIFO in
// its place must neither hold the read nor the write that follows the miss.
func TestAFifoWhereTheBranchCacheShouldBeDoesNotHoldTheRender(t *testing.T) {
	dir, cache := newRepo(t, "wip"), t.TempDir()
	fifo := mkfifo(t, filepath.Join(cache, cacheName))
	var got string
	returnsInTime(t, fifo, func() { got = Branch(dir, cache) })
	if got != "wip" {
		t.Errorf("Branch = %q, want wip", got)
	}
	if fi, err := os.Lstat(fifo); err != nil || !fi.Mode().IsRegular() {
		t.Fatalf("캐시 자리의 FIFO 를 일반 파일로 바꿔 두어야 한다: %v %v", fi, err)
	}
	tally := blockGit(t)
	if got := Branch(dir, cache); got != "wip" || tally() != 0 {
		t.Errorf("바꿔 둔 캐시에서 Branch = %q (git %d회), want wip (0회)", got, tally())
	}
}

// The cache is the statusline's own file, written through a rename, so a link in its place is
// not read: git is asked again and the link is replaced by a file of its answer.
func TestALinkWhereTheBranchCacheShouldBeIsNotRead(t *testing.T) {
	dir, cache := newRepo(t, "wip"), t.TempDir()
	Branch(dir, cache)
	path := filepath.Join(cache, cacheName)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	elsewhere := filepath.Join(t.TempDir(), cacheName)
	if err := os.WriteFile(elsewhere, []byte(strings.Replace(string(b), "branch=wip", "branch=linked", 1)), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Remove(path)
	symlink(t, elsewhere, path)
	if got := Branch(dir, cache); got != "wip" {
		t.Errorf("링크의 캐시를 믿었다: Branch = %q, want wip", got)
	}
	if fi, err := os.Lstat(path); err != nil || !fi.Mode().IsRegular() {
		t.Errorf("링크를 일반 파일로 바꿔 두어야 한다: %v %v", fi, err)
	}
}

// HEAD belongs to git, which follows links; the file it ends on is read only if regular.
func TestFirstLineFollowsALinkAndRefusesAFifoOrALinkToOne(t *testing.T) {
	dir := t.TempDir()
	head := filepath.Join(dir, "HEAD")
	if err := os.WriteFile(head, []byte("ref: refs/heads/wip\nrest\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "HEAD.link")
	symlink(t, head, link)
	if got, ok := firstLine(link); !ok || got != "ref: refs/heads/wip" {
		t.Errorf("링크의 HEAD = %q, %v", got, ok)
	}
	fifo := mkfifo(t, filepath.Join(dir, "HEAD.fifo"))
	fifoLink := filepath.Join(dir, "HEAD.fifolink")
	symlink(t, fifo, fifoLink)
	for _, path := range []string{fifo, fifoLink} {
		returnsInTime(t, fifo, func() {
			if got, ok := firstLine(path); ok || got != "" {
				t.Errorf("firstLine(%s) = %q, %v, want 없음", filepath.Base(path), got, ok)
			}
		})
	}
}

func TestReadRegularFollowsALinkAndRefusesAFifoOrALinkToOne(t *testing.T) {
	dir := t.TempDir()
	config := filepath.Join(dir, "config")
	if err := os.WriteFile(config, []byte("[remote \"origin\"]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "config.link")
	symlink(t, config, link)
	if b, ok := readRegular(link); !ok || string(b) != "[remote \"origin\"]\n" {
		t.Errorf("링크의 설정 = %q, %v", b, ok)
	}
	fifo := mkfifo(t, filepath.Join(dir, "config.fifo"))
	fifoLink := filepath.Join(dir, "config.fifolink")
	symlink(t, fifo, fifoLink)
	for _, path := range []string{fifo, fifoLink} {
		returnsInTime(t, fifo, func() {
			if b, ok := readRegular(path); ok || b != nil {
				t.Errorf("readRegular(%s) = %q, %v, want 없음", filepath.Base(path), b, ok)
			}
		})
	}
}

// A repository whose config is a link (a dotfile manager, a shared config) still has its origin.
func TestOriginReadsAConfigThatIsALink(t *testing.T) {
	root := t.TempDir()
	gitDir := filepath.Join(root, ".git")
	if err := os.Mkdir(gitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	shared := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(shared, []byte("[remote \"origin\"]\n\turl = git@example.com:o/r.git\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	symlink(t, shared, filepath.Join(gitDir, "config"))
	if got := Origin(root); got != "git@example.com:o/r.git" {
		t.Errorf("Origin = %q", got)
	}
}
