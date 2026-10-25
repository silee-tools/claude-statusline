package anchor

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// DefaultAddr is where the receiver listens unless told otherwise, and where the statusline
// expects it to: the OpenTelemetry settings of the machine send there.
const DefaultAddr = "127.0.0.1:14318"

// ErrReceiverRunning is another receiver already holding the lock.
var ErrReceiverRunning = errors.New("anchor: another receiver holds the lock")

// ErrNotReady is a receiver asking to be ready while the state it would publish is not its
// own: another run's generation, or no heartbeat.
var ErrNotReady = errors.New("anchor: the state to publish is not this run's")

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

// Receiver is what a ready receiver tells the statusline about itself through the live lock:
// which start it is (see NewRun) and the address it listens on.
type Receiver struct {
	Run  string
	Addr string
}

// Ready takes the live lock and puts self in it. The receiver calls it once its generation and
// heartbeat are written, and it refuses unless they are: the generation file must name
// self.Run and the heartbeat must exist, so the statusline finds a receiver only when the
// state it goes by is the run's own, whatever the order the caller took.
//
// The content is written through the held file and not by replacing the file, which would give
// it another inode and cost the receiver its own lock. A reader that meets the lock before the
// content finds no run and doubts, which is the safe side.
func (l *ReceiverLock) Ready(self Receiver) error {
	if !validRun(self.Run) || self.Addr == "" {
		return errors.New("anchor: a receiver names its run and address")
	}
	live, err := lockFile(liveLockPath(l.stateDir))
	if err != nil {
		return err
	}
	if _, run, err := loadGeneration(l.stateDir); err != nil || run != self.Run {
		live.f.Close()
		return ErrNotReady
	}
	if _, err := os.Stat(filepath.Join(l.stateDir, "otel", "heartbeat")); err != nil {
		live.f.Close()
		return ErrNotReady
	}
	if err := live.f.Truncate(0); err != nil {
		live.f.Close()
		return err
	}
	if _, err := live.f.WriteAt([]byte("run="+self.Run+"\naddr="+self.Addr+"\n"), 0); err != nil {
		live.f.Close()
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

// receiverAlive reports whether a receiver holds the live lock.
func receiverAlive(stateDir string) bool {
	held, _ := probeLive(stateDir)
	return held
}

// probeLive says whether a receiver holds the live lock and, if one does, what it put there.
// Only a held lock says a receiver runs: no lock file, a lock nobody holds, a file that is not
// a regular file (a FIFO, a link) and any error opening or probing it all say the receiver is
// not known to be running. The open does not block and the shared probe is let go of with the
// file at once. The content is read through the file the probe met the lock on, so the lock and
// the run it is read with belong to the same file, and that file counts only if the path still
// leads to it once both are read: a lock file replaced or removed in between belongs to a
// receiver the statusline no longer finds there. A replacement after this check is not seen.
func probeLive(stateDir string) (held bool, self Receiver) {
	path := liveLockPath(stateDir)
	f, err := os.OpenFile(path, os.O_RDONLY|openFlags, 0)
	if err != nil {
		return false, Receiver{}
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return false, Receiver{}
	}
	if !errors.Is(flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB), syscall.EWOULDBLOCK) {
		return false, Receiver{}
	}
	buf := make([]byte, 256)
	n, _ := f.Read(buf)
	if now, err := os.Lstat(path); err != nil || !os.SameFile(fi, now) {
		return false, Receiver{}
	}
	return true, parseReceiver(string(buf[:n]))
}

// parseReceiver reads what Ready wrote. A part that is missing or malformed stays empty, and a
// reader trusts a receiver only when both parts are there.
func parseReceiver(s string) Receiver {
	var r Receiver
	for _, line := range strings.Split(s, "\n") {
		k, v, found := strings.Cut(line, "=")
		switch {
		case !found:
		case k == "run" && validRun(v):
			r.Run = v
		case k == "addr" && len(v) <= 64 && !strings.ContainsAny(v, " \t\r"):
			r.Addr = v
		}
	}
	return r
}

// expectedAddr is the address a receiver must listen on to be trusted: DefaultAddr unless the
// statusline was told another, written as an IP literal and a port. A value that is not one
// matches no receiver and does not fall back to the default, so a mistyped setting shows as a
// doubt instead of being ignored.
func expectedAddr(want string) string {
	if want == "" {
		return DefaultAddr
	}
	host, port, err := net.SplitHostPort(want)
	ip := net.ParseIP(host)
	if err != nil || ip == nil || port == "" {
		return ""
	}
	return net.JoinHostPort(ip.String(), port)
}
