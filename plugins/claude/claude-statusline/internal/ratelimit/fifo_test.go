package ratelimit

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// within runs f and says whether it returned in time, so a read that blocks fails the test
// instead of stalling the suite.
func within(d time.Duration, f func()) bool {
	done := make(chan struct{})
	go func() { f(); close(done) }()
	select {
	case <-done:
		return true
	case <-time.After(d):
		return false
	}
}

// release lets a read that waits for a writer end, so a failing test does not leave it behind.
func release(path string) {
	if f, err := os.OpenFile(path, os.O_RDWR|syscall.O_NONBLOCK, 0); err == nil {
		f.Close()
	}
}

// The files the account slot and the gauges read are where a FIFO can be left to hold the
// statusline: neither read may wait for a writer.
func TestAFifoWhereASessionsFingerprintBaselineShouldBeDoesNotHoldTheRender(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s1.env")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if !within(2*time.Second, func() {
		Fingerprint(dir, "s1", 1000, []Window{WindowFive}, Pair{}, 1_700_000_000)
	}) {
		release(path)
		t.Fatal("Fingerprint waits for a writer of the baseline file")
	}
}

func TestAFifoWhereASessionsWindowsShouldBeDoesNotHoldTheRender(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s1.env")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	var p Pair
	if !within(2*time.Second, func() { p = Load(path) }) {
		release(path)
		t.Fatal("Load waits for a writer of the session file")
	}
	if p.Five.Present || p.Week.Present {
		t.Errorf("FIFO 에서 한도를 읽었다: %+v", p)
	}
}

func TestALinkWhereASessionsWindowsShouldBeIsNotRead(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "elsewhere")
	if err := os.WriteFile(target, []byte("fivePct=10\nfiveReset=1700000000\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "s1.env")
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if p := Load(path); p.Five.Present {
		t.Errorf("링크를 따라가 한도를 읽었다: %+v", p)
	}
}
