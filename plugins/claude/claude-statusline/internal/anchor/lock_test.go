package anchor

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"
)

func otelDir(t *testing.T) string {
	t.Helper()
	state := t.TempDir()
	if err := os.MkdirAll(filepath.Join(state, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	return state
}

func readyReceiver(t *testing.T, state string) *ReceiverLock {
	t.Helper()
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := lock.Ready(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lock.Close() })
	return lock
}

// within runs f and says whether it returned in time. A call that blocks is reported as a
// failure and not left to stall the suite: the caller gets the chance to release it.
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

// releaseFifo lets a reader stuck opening a FIFO through: a writer opens it.
func releaseFifo(path string) {
	if w, err := os.OpenFile(path, os.O_RDWR|syscall.O_NONBLOCK, 0); err == nil {
		w.Close()
	}
}

// 수신기가 멈추면(잠금이 풀리면) 하트비트와 세대가 멀쩡해도 앵커를 믿지 않는다.
func TestAnAnchorIsDoubtedOnceTheReceiverHoldsNoLock(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+900))
	if got := f.wantEmail("s1", now, "a@example.com"); got.Suspect {
		t.Fatalf("수신기가 도는 동안은 의심하지 않는다: %+v", got)
	}
	f.stopReceiver()
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("잠금이 풀렸는데 앵커를 믿는다: %+v", got)
	}
}

// 시작 잠금만 쥔 시작은 아직 준비된 수신기가 아니라 이전 실행의 상태가 남아 있어도 믿지 않는다.
func TestAnAnchorIsDoubtedWhileOnlyTheStartLockIsHeld(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+900))
	f.lock.live.f.Close() // the start has the start lock; it has not written its state yet
	f.lock.live = nil
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("준비 잠금이 없는데 앵커를 믿는다: %+v", got)
	}
}

func TestReceiverAliveOnlyWhileTheLiveLockIsHeld(t *testing.T) {
	state := otelDir(t)
	if receiverAlive(state) {
		t.Error("잠금 파일이 없는데 수신기가 산다고 한다")
	}
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	if receiverAlive(state) {
		t.Error("시작 잠금만 쥐었는데 수신기가 산다고 한다")
	}
	if err := lock.Ready(); err != nil {
		t.Fatal(err)
	}
	if !receiverAlive(state) {
		t.Error("준비 잠금을 쥐고 있는데 수신기가 없다고 한다")
	}
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	if receiverAlive(state) {
		t.Error("잠금을 놓았는데 수신기가 산다고 한다")
	}
	for _, p := range []string{startLockPath(state), liveLockPath(state)} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("잠금 파일이 사라졌다: %v", err)
		}
	}
}

func TestReceiverAliveIsFalseWhenTheLockFileCannotBeOpened(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 읽기 권한 제한을 받지 않는다")
	}
	state := otelDir(t)
	readyReceiver(t, state)
	if err := os.Chmod(liveLockPath(state), 0o000); err != nil {
		t.Fatal(err)
	}
	if receiverAlive(state) {
		t.Error("열 수 없는 잠금 파일을 산 수신기로 본다")
	}
}

func TestASecondLockerIsRefusedWhileTheFirstHoldsTheStartLock(t *testing.T) {
	state := otelDir(t)
	first, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := LockReceiver(state); !errors.Is(err, ErrReceiverRunning) {
		t.Errorf("둘째 잠금 = %v, want ErrReceiverRunning", err)
	}
	first.Close()
	again, err := LockReceiver(state)
	if err != nil {
		t.Fatalf("놓은 뒤에는 잠글 수 있어야 한다: %v", err)
	}
	again.Close()
}

// 시작 잠금 파일만 지워진 뒤에 시작한 수신기는 준비된 수신기를 알아보고 물러난다.
func TestALockerGivesWayToAReadyReceiverWhoseStartLockFileIsGone(t *testing.T) {
	state := otelDir(t)
	readyReceiver(t, state)
	if err := os.Remove(startLockPath(state)); err != nil {
		t.Fatal(err)
	}
	if lock, err := LockReceiver(state); !errors.Is(err, ErrReceiverRunning) {
		if lock != nil {
			lock.Close()
		}
		t.Errorf("지워진 시작 잠금 파일 뒤의 잠금 = %v, want ErrReceiverRunning", err)
	}
}

// 읽는 쪽의 짧은 공유 잠금은 수신기가 시작하는 것을 막지 못한다.
func TestASharedProbeDoesNotKeepAReceiverFromLocking(t *testing.T) {
	old := lockWait
	lockWait = 2 * time.Second
	defer func() { lockWait = old }()
	state := otelDir(t)
	probe, err := os.OpenFile(startLockPath(state), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(probe.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	go func() { time.Sleep(100 * time.Millisecond); probe.Close() }()
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatalf("공유 잠금이 풀리기를 기다리지 않고 포기했다: %v", err)
	}
	lock.Close()
}

// 다른 렌더가 공유 잠금으로 조사하는 동안에도 읽는 쪽은 수신기가 산다고 보지 않는다(조사를 배타
// 잠금으로 바꾸면 겹친 조사가 서로를 수신기로 오인한다).
func TestAReaderProbingDoesNotMakeAnotherReaderSeeAReceiver(t *testing.T) {
	state := otelDir(t)
	other, err := os.OpenFile(liveLockPath(state), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if err := syscall.Flock(int(other.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	if receiverAlive(state) {
		t.Error("다른 렌더가 조사 중인 것을 수신기로 본다")
	}
}

// 멈춘 수신기 앞에서 렌더가 겹쳐도 하나도 앵커를 믿지 않는다.
func TestConcurrentReadersNeverTrustAStoppedReceiver(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+900))
	f.stopReceiver()
	in := Input{StateDir: f.state, ConfigDir: f.config, SessionID: "s1", Now: now}
	var wg sync.WaitGroup
	trusted := make(chan struct{}, 8*200)
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				if r := Resolve(in); r.Email != "" && !r.Suspect {
					trusted <- struct{}{}
				}
			}
		}()
	}
	wg.Wait()
	if n := len(trusted); n != 0 {
		t.Errorf("겹친 렌더 %d건이 멈춘 수신기의 앵커를 믿었다", n)
	}
}

// 잠금 파일이 지워지거나 바뀌면 쥐고 있는 잠금이 경로의 파일이 아니라 알아낸다.
func TestHeldSeesALockFileThatWasRemovedOrReplaced(t *testing.T) {
	for _, which := range []string{"start", "live"} {
		path := map[string]func(string) string{"start": startLockPath, "live": liveLockPath}[which]
		for name, swap := range map[string]func(t *testing.T, path string){
			"removed": func(t *testing.T, path string) {
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
			},
			"recreated": func(t *testing.T, path string) {
				os.Remove(path)
				if err := os.WriteFile(path, nil, 0o600); err != nil {
					t.Fatal(err)
				}
			},
			"a link to the same file": func(t *testing.T, path string) {
				moved := path + ".moved"
				if err := os.Rename(path, moved); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(moved, path); err != nil {
					t.Fatal(err)
				}
			},
		} {
			t.Run(which+" "+name, func(t *testing.T) {
				state := otelDir(t)
				lock := readyReceiver(t, state)
				if err := lock.Held(); err != nil {
					t.Fatalf("바뀌기 전 Held = %v", err)
				}
				swap(t, path(state))
				if err := lock.Held(); !errors.Is(err, ErrLockLost) {
					t.Errorf("Held = %v, want ErrLockLost", err)
				}
			})
		}
	}
}

// 심어 둔 비정상 항목에는 잠금을 쥔 수신기가 있을 수 없으므로 수신기가 치우고 일반 파일을 만든다.
func TestLockReceiverReplacesAPlantedEntryThatIsNotARegularFile(t *testing.T) {
	for name, plant := range map[string]func(t *testing.T, path string){
		"fifo": func(t *testing.T, path string) {
			if err := syscall.Mkfifo(path, 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"link to a file": func(t *testing.T, path string) {
			target := filepath.Join(t.TempDir(), "elsewhere")
			if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, path); err != nil {
				t.Fatal(err)
			}
		},
		"empty directory": func(t *testing.T, path string) {
			if err := os.Mkdir(path, 0o700); err != nil {
				t.Fatal(err)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			state := otelDir(t)
			plant(t, startLockPath(state))
			var lock *ReceiverLock
			var err error
			if !within(2*time.Second, func() { lock, err = LockReceiver(state) }) {
				releaseFifo(startLockPath(state))
				t.Fatal("심어 둔 항목에서 시작이 멈췄다")
			}
			if err != nil {
				t.Fatalf("LockReceiver = %v", err)
			}
			defer lock.Close()
			if fi, err := os.Lstat(startLockPath(state)); err != nil || !fi.Mode().IsRegular() {
				t.Errorf("일반 파일로 바뀌지 않았다: %v %v", fi, err)
			}
			if err := lock.Held(); err != nil {
				t.Errorf("Held = %v", err)
			}
		})
	}
}

// 렌더러는 FIFO·링크로 바뀐 잠금 파일에서 멈추지 않고 수신기가 없다고 본다.
func TestReceiverAliveDoesNotBlockOnAFifoOrFollowALink(t *testing.T) {
	for name, plant := range map[string]func(t *testing.T, state string){
		"fifo": func(t *testing.T, state string) {
			if err := syscall.Mkfifo(liveLockPath(state), 0o600); err != nil {
				t.Fatal(err)
			}
		},
		"link to a fifo": func(t *testing.T, state string) {
			fifo := filepath.Join(state, "fifo")
			if err := syscall.Mkfifo(fifo, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(fifo, liveLockPath(state)); err != nil {
				t.Fatal(err)
			}
		},
		"link to a held lock file": func(t *testing.T, state string) {
			lock := readyReceiver(t, state)
			moved := liveLockPath(state) + ".moved"
			if err := os.Rename(liveLockPath(state), moved); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(moved, liveLockPath(state)); err != nil {
				t.Fatal(err)
			}
			_ = lock
		},
		"directory": func(t *testing.T, state string) {
			if err := os.Mkdir(liveLockPath(state), 0o700); err != nil {
				t.Fatal(err)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			state := otelDir(t)
			plant(t, state)
			var alive bool
			if !within(2*time.Second, func() { alive = receiverAlive(state) }) {
				releaseFifo(liveLockPath(state))
				releaseFifo(filepath.Join(state, "fifo"))
				t.Fatal("잠금 파일을 여는 데서 멈췄다")
			}
			if alive {
				t.Error("바뀐 잠금 파일을 산 수신기로 본다")
			}
		})
	}
}

// 잠금 파일이 FIFO 여도 Resolve 는 제한 시간 안에 ? 로 돌아온다.
func TestResolveReturnsInTimeWhenTheLockFileIsAFifo(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+900))
	f.stopReceiver()
	if err := os.Remove(liveLockPath(f.state)); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(liveLockPath(f.state), 0o600); err != nil {
		t.Fatal(err)
	}
	var r Result
	if !within(2*time.Second, func() {
		r = Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: "s1", Now: now})
	}) {
		releaseFifo(liveLockPath(f.state))
		t.Fatal("Resolve 가 FIFO 에서 멈췄다")
	}
	if r.Email != "a@example.com" || !r.Suspect {
		t.Errorf("FIFO 잠금 파일에서 ? 가 아니다: %+v", r)
	}
}

// 잠금을 조사하지 못하면(잠금을 지원하지 않는 파일시스템 등) 수신기가 산다고 보지 않는다.
func TestReceiverAliveIsFalseWhenTheProbeFails(t *testing.T) {
	state := otelDir(t)
	readyReceiver(t, state)
	old := flock
	flock = func(int, int) error { return syscall.ENOLCK }
	defer func() { flock = old }()
	if receiverAlive(state) {
		t.Error("조사에 실패했는데 수신기가 산다고 본다")
	}
}

// 잠금을 얻지 못하는 파일시스템에서는 수신기가 시작하지 못한다(상태를 보증하지 못한다).
func TestLockReceiverFailsWhenTheFilesystemCannotLock(t *testing.T) {
	state := otelDir(t)
	old := flock
	flock = func(int, int) error { return syscall.ENOLCK }
	defer func() { flock = old }()
	if _, err := LockReceiver(state); err == nil || errors.Is(err, ErrReceiverRunning) {
		t.Errorf("LockReceiver = %v, want a lock error that is not ErrReceiverRunning", err)
	}
}

// 상태 파일 자리에 FIFO 를 두어도 읽는 쪽은 멈추지 않는다(읽을 수 없는 파일은 없는 것과 같다).
func TestResolveReturnsInTimeWhenAStateFileIsAFifo(t *testing.T) {
	for name, plant := range map[string]func(f *fixture) string{
		"generation": func(f *fixture) string { return generationPath(f.state) },
		"anchor":     func(f *fixture) string { return filepath.Join(sessionsDir(f.state), "s1.env") },
		"process file": func(f *fixture) string {
			return filepath.Join(f.config, "sessions", "11.json")
		},
		"session ref": func(f *fixture) string { return refPath(f.state, "s1") },
	} {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			now := at(t0 + 60_000)
			f.install(0, now)
			f.proc(11, t0, "s1")
			f.apply(login("s1", "a@example.com", t0+900))
			path := plant(f)
			os.Remove(path)
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := syscall.Mkfifo(path, 0o600); err != nil {
				t.Fatal(err)
			}
			var r Result
			if !within(2*time.Second, func() {
				r = Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: "s1", Now: now})
			}) {
				releaseFifo(path)
				t.Fatal("상태 파일 자리의 FIFO 에서 Resolve 가 멈췄다")
			}
			if r.Email != "" && !r.Suspect && r.Level == Confirmed && name == "generation" {
				t.Errorf("읽을 수 없는 세대 파일인데 확정으로 보인다: %+v", r)
			}
		})
	}
}

// 훑기는 읽는 쪽이 읽지 못하는 FIFO 를 건너뛰고 멈추지 않는다.
func TestNextGenerationSkipsAFifoAndDoesNotBlock(t *testing.T) {
	state := otelDir(t)
	writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("4"))
	fifo := filepath.Join(sessionsDir(state), "x.env")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	var n int64
	var err error
	if !within(2*time.Second, func() { n, err = NextGeneration(state) }) {
		releaseFifo(fifo)
		t.Fatal("훑기가 FIFO 에서 멈췄다")
	}
	if err != nil || n != 5 {
		t.Errorf("NextGeneration = %d, %v; want 5", n, err)
	}
}

// 특수 파일에 잠금이 걸릴 수 있는 파일시스템을 가정해, 조사가 잠긴 것으로 답해도 일반 파일이
// 아니면 수신기가 산다고 보지 않는다(macOS 의 flock 은 FIFO 에서 ENOTSUP 이라 실제 잠금으로는 못 본다).
func TestReceiverAliveRequiresARegularFileEvenWhereASpecialFileCanBeLocked(t *testing.T) {
	old := flock
	flock = func(int, int) error { return syscall.EWOULDBLOCK }
	defer func() { flock = old }()
	for name, plant := range map[string]func(path string) error{
		"directory": func(p string) error { return os.Mkdir(p, 0o700) },
		"fifo":      func(p string) error { return syscall.Mkfifo(p, 0o600) },
		"regular":   func(p string) error { return os.WriteFile(p, nil, 0o600) },
	} {
		t.Run(name, func(t *testing.T) {
			state := otelDir(t)
			if err := plant(liveLockPath(state)); err != nil {
				t.Fatal(err)
			}
			var alive bool
			if !within(2*time.Second, func() { alive = receiverAlive(state) }) {
				releaseFifo(liveLockPath(state))
				t.Fatal("잠금 파일을 여는 데서 멈췄다")
			}
			if want := name == "regular"; alive != want {
				t.Errorf("receiverAlive = %v, want %v", alive, want)
			}
		})
	}
}
