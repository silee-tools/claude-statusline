package anchor

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// ErrReceiverRunning is another receiver already holding the lock.
var ErrReceiverRunning = errors.New("anchor: another receiver holds the lock")

// ErrLockLost is a lock file that is no longer the file the receiver holds the lock on: it was
// removed or replaced, so a later receiver can lock the new file while this one still runs.
var ErrLockLost = errors.New("anchor: the lock file was removed or replaced")

// lockWait is how long a lock is waited for while it is held. A reader probes the lock for an
// instant, and a start that meets that probe is not a second receiver.
var lockWait = time.Second

// flock is syscall.Flock; tests replace it to fail the way a filesystem without locks does.
var flock = syscall.Flock

// openFlags keep an open from blocking on a FIFO and from following a link: a lock file is a
// regular file or it is nothing a receiver or a reader goes by.
const openFlags = syscall.O_NONBLOCK | syscall.O_NOFOLLOW

// The receiver holds two locks. The start lock is taken first, before it touches any state,
// and keeps a second receiver out. The live lock is taken last, once the generation and the
// heartbeat are written, and it is the one the statusline goes by: until it is held a start
// is not a receiver whose state can be trusted, whatever the previous run left behind.
func startLockPath(stateDir string) string { return filepath.Join(stateDir, "otel", "receiver.lock") }
func liveLockPath(stateDir string) string  { return filepath.Join(stateDir, "otel", "receiver.live") }

type heldLock struct {
	f    *os.File
	path string
}

// ReceiverLock is what a running receiver holds: the start lock, then the live lock.
type ReceiverLock struct {
	stateDir string
	start    *heldLock
	live     *heldLock
}

// LockReceiver takes the start lock. The kernel drops a flock when the process ends, whatever
// the way, so a stopped receiver is known without a write to the state directory, which a
// heartbeat file needs. A flock belongs to the open file and not to the process, so a probe
// from the same process sees it held. If a receiver is already ready (its live lock is held)
// the start lock's file was removed under it: this start gives way before it writes anything.
func LockReceiver(stateDir string) (*ReceiverLock, error) {
	start, err := lockFile(startLockPath(stateDir))
	if err != nil {
		return nil, err
	}
	if receiverAlive(stateDir) {
		start.f.Close()
		return nil, ErrReceiverRunning
	}
	return &ReceiverLock{stateDir: stateDir, start: start}, nil
}

// Ready takes the live lock. The receiver calls it once its generation and heartbeat are
// written, so the statusline finds a receiver only when the state it goes by is the run's own.
func (l *ReceiverLock) Ready() error {
	live, err := lockFile(liveLockPath(l.stateDir))
	if err != nil {
		return err
	}
	l.live = live
	return nil
}

// Held says whether the locks are still on the files at their paths. A removed or replaced
// file leaves this receiver unseen by the statusline and lets another one lock a new file, so
// the receiver checks before it writes and stops when this fails.
func (l *ReceiverLock) Held() error {
	for _, h := range []*heldLock{l.start, l.live} {
		if h == nil {
			continue
		}
		if err := h.stillOnPath(); err != nil {
			return err
		}
	}
	return nil
}

// Close lets go of the locks.
func (l *ReceiverLock) Close() error {
	var first error
	for _, h := range []*heldLock{l.live, l.start} {
		if h != nil {
			if err := h.f.Close(); err != nil && first == nil {
				first = err
			}
		}
	}
	return first
}

func (h *heldLock) stillOnPath() error {
	have, err := h.f.Stat()
	if err != nil {
		return err
	}
	now, err := os.Lstat(h.path)
	if err != nil || !now.Mode().IsRegular() || !os.SameFile(have, now) {
		return ErrLockLost
	}
	return nil
}

// lockFile opens path and takes an exclusive lock on it. An entry that is not a regular file
// (a FIFO or a link someone left there) cannot have a receiver behind it and is replaced. The
// lock counts only if the file is still the one at the path once it is held.
func lockFile(path string) (*heldLock, error) {
	deadline := time.Now().Add(lockWait)
	for {
		if fi, err := os.Lstat(path); err == nil && !fi.Mode().IsRegular() {
			if err := os.Remove(path); err != nil {
				return nil, err
			}
		}
		f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|openFlags, 0o600)
		if err != nil {
			return nil, err
		}
		for {
			err = flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
			if err == nil {
				break
			}
			if !errors.Is(err, syscall.EWOULDBLOCK) {
				f.Close()
				return nil, err
			}
			if time.Now().After(deadline) {
				f.Close()
				return nil, ErrReceiverRunning
			}
			time.Sleep(10 * time.Millisecond)
		}
		h := &heldLock{f: f, path: path}
		if h.stillOnPath() == nil {
			return h, nil
		}
		f.Close() // replaced between the open and the lock
		if time.Now().After(deadline) {
			return nil, ErrLockLost
		}
	}
}

// receiverAlive reports whether a receiver holds the live lock. Only a held lock says so: no
// lock file, a lock nobody holds, a file that is not a regular file (a FIFO, a link) and any
// error opening or probing it all say the receiver is not known to be running. The open does
// not block and the shared probe is let go of with the file at once.
func receiverAlive(stateDir string) bool {
	f, err := os.OpenFile(liveLockPath(stateDir), os.O_RDONLY|openFlags, 0)
	if err != nil {
		return false
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return false
	}
	return errors.Is(flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB), syscall.EWOULDBLOCK)
}
