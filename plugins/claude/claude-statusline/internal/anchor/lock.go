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

// lockWait is how long LockReceiver keeps trying while the lock is held. A reader probes the
// lock for an instant, and a start that meets that probe is not a second receiver.
var lockWait = time.Second

// flock is syscall.Flock; tests replace it to fail the way a filesystem without locks does.
var flock = syscall.Flock

func lockPath(stateDir string) string { return filepath.Join(stateDir, "otel", "receiver.lock") }

// ReceiverLock is the lock a running receiver holds on otel/receiver.lock.
type ReceiverLock struct{ f *os.File }

// LockReceiver takes the lock that tells a reader a receiver is running. The kernel drops it
// when the process ends, whatever the way, so it needs no write to the state directory to
// say the receiver is gone, which a heartbeat file does. It is a flock, which belongs to the
// open file and not to the process, so a probe from the same process sees it held.
func LockReceiver(stateDir string) (*ReceiverLock, error) {
	f, err := os.OpenFile(lockPath(stateDir), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(lockWait)
	for {
		err = flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return &ReceiverLock{f}, nil
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
}

// Close lets go of the lock.
func (l *ReceiverLock) Close() error { return l.f.Close() }

// receiverAlive reports whether a receiver holds the lock. Only a held lock says so: no lock
// file, a lock nobody holds and any error opening or probing it all say the receiver is not
// known to be running. The shared probe is let go of with the file at once.
func receiverAlive(stateDir string) bool {
	f, err := os.Open(lockPath(stateDir))
	if err != nil {
		return false
	}
	defer f.Close()
	return errors.Is(flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB), syscall.EWOULDBLOCK)
}
