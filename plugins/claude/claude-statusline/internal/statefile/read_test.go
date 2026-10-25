package statefile

import (
	"errors"
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

func TestReadReturnsARegularFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.env")
	if err := Write(path, []byte("k=v\n")); err != nil {
		t.Fatal(err)
	}
	b, err := Read(path)
	if err != nil || string(b) != "k=v\n" {
		t.Fatalf("Read = %q, %v", b, err)
	}
}

func TestReadOfAMissingFileIsNotExist(t *testing.T) {
	if _, err := Read(filepath.Join(t.TempDir(), "nope")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Read(missing) = %v, want ErrNotExist", err)
	}
}

func TestReadRefusesWhatIsNotARegularFileWithoutBlocking(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target.env")
	if err := Write(target, []byte("k=v\n")); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(p string) error{
		"directory":              func(p string) error { return os.Mkdir(p, 0o700) },
		"fifo":                   func(p string) error { return syscall.Mkfifo(p, 0o600) },
		"link to a regular file": func(p string) error { return os.Symlink(target, p) },
		"link to a missing file": func(p string) error { return os.Symlink(filepath.Join(dir, "gone"), p) },
		"link to a fifo": func(p string) error {
			fifo := p + ".fifo"
			if err := syscall.Mkfifo(fifo, 0o600); err != nil {
				return err
			}
			return os.Symlink(fifo, p)
		},
	}
	for name, plant := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(dir, "case-"+name)
			if err := plant(path); err != nil {
				t.Fatal(err)
			}
			var err error
			if !within(2*time.Second, func() { _, err = Read(path) }) {
				// Release the read the test cannot otherwise end.
				if f, openErr := os.OpenFile(path, os.O_RDWR|syscall.O_NONBLOCK, 0); openErr == nil {
					defer f.Close()
				}
				t.Fatal("Read blocked")
			}
			if !errors.Is(err, ErrNotRegular) {
				t.Errorf("Read(%s) = %v, want ErrNotRegular", name, err)
			}
		})
	}
}

func TestReadFollowReadsARegularFileAndThroughALink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target.env")
	if err := Write(target, []byte("k=v\n")); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.env")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{target, link} {
		if b, err := ReadFollow(path); err != nil || string(b) != "k=v\n" {
			t.Errorf("ReadFollow(%s) = %q, %v", filepath.Base(path), b, err)
		}
	}
}

func TestReadFollowOfAMissingFileOrALinkToOneIsNotExist(t *testing.T) {
	dir := t.TempDir()
	dangling := filepath.Join(dir, "dangling")
	if err := os.Symlink(filepath.Join(dir, "gone"), dangling); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{filepath.Join(dir, "nope"), dangling} {
		if _, err := ReadFollow(path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("ReadFollow(%s) = %v, want ErrNotExist", filepath.Base(path), err)
		}
	}
}

// A link is followed, but what it ends on must still be a regular file, and the open must
// not wait for a writer on the way.
func TestReadFollowRefusesWhatTheLinkEndsOnIfItIsNotARegularFileWithoutBlocking(t *testing.T) {
	dir := t.TempDir()
	cases := map[string]func(p string) error{
		"directory": func(p string) error { return os.Mkdir(p, 0o700) },
		"fifo":      func(p string) error { return syscall.Mkfifo(p, 0o600) },
		"link to a directory": func(p string) error {
			if err := os.Mkdir(p+".dir", 0o700); err != nil {
				return err
			}
			return os.Symlink(p+".dir", p)
		},
		"link to a fifo": func(p string) error {
			if err := syscall.Mkfifo(p+".fifo", 0o600); err != nil {
				return err
			}
			return os.Symlink(p+".fifo", p)
		},
		"link to itself": func(p string) error { return os.Symlink(p, p) },
	}
	for name, plant := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(dir, "case-"+name)
			if err := plant(path); err != nil {
				t.Fatal(err)
			}
			var err error
			if !within(2*time.Second, func() { _, err = ReadFollow(path) }) {
				if f, openErr := os.OpenFile(path, os.O_RDWR|syscall.O_NONBLOCK, 0); openErr == nil {
					defer f.Close()
				}
				t.Fatal("ReadFollow blocked")
			}
			if !errors.Is(err, ErrNotRegular) {
				t.Errorf("ReadFollow(%s) = %v, want ErrNotRegular", name, err)
			}
		})
	}
}

// What is read is a few lines of state, cache or config; a regular file past maxRead is cut
// there, so one that is endless in practice cannot hold the render either.
func TestReadAndReadFollowStopAtmaxRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "big.env")
	if err := os.WriteFile(path, make([]byte, maxRead+4096), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, read := range map[string]func(string) ([]byte, error){"Read": Read, "ReadFollow": ReadFollow} {
		if b, err := read(path); err != nil || len(b) != maxRead {
			t.Errorf("%s read %d bytes, %v, want %d", name, len(b), err, maxRead)
		}
	}
}
