package agentstatus

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

// plantFifo puts a FIFO where the snapshot of session s1 belongs.
func plantFifo(t *testing.T, root string) string {
	t.Helper()
	path := snapshotPath(root, "s1")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestAFifoWhereASessionsSnapshotShouldBeDoesNotHoldTheRender(t *testing.T) {
	root := t.TempDir()
	path := plantFifo(t, root)
	returnsInTime(t, path, func() {
		_ = RecordRender(root, Metadata{SessionID: "s1", Workspace: "/w"}, nil, 1)
	})
	if fi, err := os.Lstat(path); err != nil || !fi.Mode().IsRegular() {
		t.Fatalf("렌더가 FIFO 를 일반 파일로 바꿔 두어야 한다: %v %v", fi, err)
	}
}

func TestAFifoWhereASessionsSnapshotShouldBeDoesNotHoldTheHook(t *testing.T) {
	root := t.TempDir()
	path := plantFifo(t, root)
	returnsInTime(t, path, func() {
		_ = RecordHook(root, strings.NewReader(`{"hook_event_name":"Stop","session_id":"s1"}`), 1)
	})
}

// The snapshot is written by this program through a rename, so a link in its place is not
// something it wrote and is not read.
func TestALinkWhereASessionsSnapshotShouldBeIsNotRead(t *testing.T) {
	root := t.TempDir()
	if err := RecordRender(root, Metadata{SessionID: "s1"}, nil, 1); err != nil {
		t.Fatal(err)
	}
	path := snapshotPath(root, "s1")
	elsewhere := filepath.Join(t.TempDir(), "snapshot.json")
	if err := os.Rename(path, elsewhere); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, path); err != nil {
		t.Fatal(err)
	}
	if s := load(path, "s1"); s.SchemaVersion != 0 {
		t.Errorf("링크를 따라가 스냅숏을 읽었다: %+v", s)
	}
}
