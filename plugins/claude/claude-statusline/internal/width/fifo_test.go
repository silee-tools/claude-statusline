package width

import (
	"os"
	"path/filepath"
	"strconv"
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

// The tty path cache is the statusline's own file: a FIFO in its place neither holds the read
// nor the write that follows the miss, and ps is asked again.
func TestAFifoWhereTheTTYPathCacheShouldBeDoesNotHoldTheRenderAndIsReplaced(t *testing.T) {
	dev, cache := t.TempDir(), t.TempDir()
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", dev)
	tally := fakePS(t, "ttys007 700")
	fifo := filepath.Join(cache, "tty-path.env")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	var path string
	var ok bool
	returnsInTime(t, fifo, func() { path, ok = ttyPath(cache) })
	if !ok || path != filepath.Join(dev, "ttys007") || tally() != 1 {
		t.Fatalf("ttyPath = %q, %v (ps %d회)", path, ok, tally())
	}
	if ppid, cached, exists := readCache(t, cache); !exists || cached != path || ppid != strconv.Itoa(os.Getppid()) {
		t.Errorf("FIFO 를 캐시 파일로 바꿔 두어야 한다: %q %q %v", ppid, cached, exists)
	}
}

func TestALinkWhereTheTTYPathCacheShouldBeIsNotRead(t *testing.T) {
	dev, cache := t.TempDir(), t.TempDir()
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", dev)
	tally := fakePS(t, "ttys007 700")
	elsewhere := filepath.Join(t.TempDir(), "tty-path.env")
	body := "ppid=" + strconv.Itoa(os.Getppid()) + "\npath=/dev/ttys999\n"
	if err := os.WriteFile(elsewhere, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(cache, "tty-path.env")
	if err := os.Symlink(elsewhere, link); err != nil {
		t.Fatal(err)
	}
	path, ok := ttyPath(cache)
	if !ok || path != filepath.Join(dev, "ttys007") || tally() != 1 {
		t.Errorf("링크의 캐시를 믿었다: %q, %v (ps %d회)", path, ok, tally())
	}
	if fi, err := os.Lstat(link); err != nil || !fi.Mode().IsRegular() {
		t.Errorf("링크를 일반 파일로 바꿔 두어야 한다: %v %v", fi, err)
	}
}
