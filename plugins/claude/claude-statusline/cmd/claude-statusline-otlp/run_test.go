package main

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
)

// The receiver checks that its lock files are the ones at their paths, then writes. A receiver
// held up between the two writes once more, after another receiver took over, and may count with
// the same number as that one. What it stores names its own run, and the statusline trusts only
// the run that holds the live lock.

// heldUp stops a receiver in the gap between its check of the lock files and the write after it.
type heldUp struct {
	op      string
	armed   atomic.Bool
	reached chan struct{}
	release chan struct{}
	once    sync.Once
}

func newHeldUp(t *testing.T, op string) *heldUp {
	h := &heldUp{op: op, reached: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(h.let)
	return h
}

func (h *heldUp) hook(op string) {
	if op == h.op && h.armed.CompareAndSwap(true, false) {
		close(h.reached)
		<-h.release
	}
}

func (h *heldUp) let() { h.once.Do(func() { close(h.release) }) }

func (h *heldUp) waitReached(t *testing.T) {
	t.Helper()
	select {
	case <-h.reached:
	case <-time.After(5 * time.Second):
		t.Fatalf("수신기가 %s 의 검사 뒤에 멈추지 않았다", h.op)
	}
}

// replaceReceiver does what takes a receiver's place: both lock files go, and a receiver on
// another port starts over the same state.
func replaceReceiver(t *testing.T, cfg config, beat time.Duration) (addr string, exit <-chan int, cancel context.CancelFunc) {
	t.Helper()
	removeLocks(t, cfg)
	next := baseConfig(t)
	next.StateDir, next.BeatEvery = cfg.StateDir, beat
	addr, exit, _, cancel = start(t, next)
	return addr, exit, cancel
}

func firstLineOf(t *testing.T, cfg config, name string) string {
	t.Helper()
	return firstLine(readState(t, cfg, name))
}

func TestAReceiverHeldUpAfterItsCheckStoresNothingTheStatuslineTrusts(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 쓰기 권한 제한을 받지 않아 세대 기록 실패를 만들 수 없다")
	}
	cfg := baseConfig(t)
	cfg.BeatEvery = time.Hour // only the requests move the receiver
	gate := newHeldUp(t, "apply")
	cfg.AfterGuard = gate.hook
	otel := filepath.Join(cfg.StateDir, "otel")
	t.Cleanup(func() { os.Chmod(otel, 0o700) })
	seed(t, cfg, "old", "o@example.com", time.Now().Add(-time.Hour).UnixMilli(), 1)
	addr1, exit1, _, cancel1 := start(t, cfg)
	defer func() { cancel1(); waitExit(t, exit1, 5*time.Second) }()

	if code := postLogin(t, addr1, "s0", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	// The generation cannot be written, so the loss is counted in memory only: the receiver is
	// one ahead of its file, which is where a receiver that starts next counts from.
	os.Chmod(otel, 0o500)
	postRaw(t, addr1, `{broken`)
	os.Chmod(otel, 0o700)

	gate.armed.Store(true)
	status := make(chan int, 1)
	go func() { status <- postLogin(t, addr1, "s1", "b@example.com", 1_700_000_001_000) }()
	gate.waitReached(t)

	addr2, exit2, cancel2 := replaceReceiver(t, cfg, time.Hour)
	defer func() { cancel2(); waitExit(t, exit2, 5*time.Second) }()
	ahead := firstLineOf(t, cfg, "generation")
	gate.let()
	if code := <-status; code != 200 {
		t.Fatalf("멈췄던 수신기의 응답 %d", code)
	}

	a, ok := anchor.Read(cfg.StateDir, "s1")
	if !ok || strconv.FormatInt(a.Gen, 10) != ahead {
		t.Fatalf("준비가 어긋났다: 앵커 %+v, 새 수신기의 세대 %s (같은 번호여야 한다)", a, ahead)
	}
	res := anchor.Resolve(anchor.Input{StateDir: cfg.StateDir, ConfigDir: t.TempDir(), SessionID: "s1", Now: time.Now(), Addr: addr2})
	if res.Email != "b@example.com" || !res.Suspect {
		t.Errorf("검사 뒤에 쓴 이전 수신기의 앵커가 새 수신기와 같은 번호로 믿어진다: %+v", res)
	}
}

// A late write that puts the old receiver's run in the generation file would make the anchors
// the old receiver stored current again, and the new receiver's pre-existing ones not.
func TestAReceiverHeldUpAfterItsCheckCannotMakeItsOwnCountTheCurrentOne(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 쓰기 권한 제한을 받지 않아 세대 기록 실패를 만들 수 없다")
	}
	cfg := baseConfig(t)
	cfg.BeatEvery = 30 * time.Millisecond
	gate := newHeldUp(t, "recovered")
	cfg.AfterGuard = gate.hook
	otel := filepath.Join(cfg.StateDir, "otel")
	t.Cleanup(func() { os.Chmod(otel, 0o700) })
	addr1, exit1, _, cancel1 := start(t, cfg)
	defer func() { cancel1(); waitExit(t, exit1, 5*time.Second) }()
	if code := postLogin(t, addr1, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}

	os.Chmod(otel, 0o500) // a loss that cannot be written down: the receiver has something to recover
	postRaw(t, addr1, `{broken`)
	gate.armed.Store(true)
	os.Chmod(otel, 0o700)
	gate.waitReached(t) // a beat found the store writable and is about to write the generation

	addr2, exit2, cancel2 := replaceReceiver(t, cfg, time.Hour)
	defer func() { cancel2(); waitExit(t, exit2, 5*time.Second) }()
	if code := postLogin(t, addr2, "s2", "b@example.com", 1_700_000_005_000); code != 200 {
		t.Fatalf("새 수신기 상태 %d", code)
	}
	if res, doubt := suspect(t, cfg, "s2"); res.Email != "b@example.com" || doubt {
		t.Fatalf("준비: 새 수신기의 앵커는 믿어야 한다: %+v 의심=%v", res, doubt)
	}
	mine := readState(t, cfg, "generation")
	gate.let()
	waitFor(t, "이전 수신기의 낡은 세대 기록", func() bool { return readState(t, cfg, "generation") != mine })

	if res, doubt := suspect(t, cfg, "s2"); res.Email != "b@example.com" || !doubt {
		t.Errorf("이전 수신기가 세대 파일에 자기 run 을 되돌렸는데 새 수신기의 앵커를 믿는다: %+v 의심=%v", res, doubt)
	}
}

// The stale write does not leave every account in doubt until the next restart: the receiver that
// holds the lock writes its own generation file back on its next beat.
func TestAReceiverPutsItsGenerationFileBackWhenAnotherRunLeftItsOwn(t *testing.T) {
	cfg := baseConfig(t)
	cfg.BeatEvery = 30 * time.Millisecond
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 5*time.Second) }()
	if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	mine := readState(t, cfg, "generation")
	if err := anchor.WriteGeneration(cfg.StateDir, 1, "a-receiver-that-was-replaced"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "세대 파일을 되돌림", func() bool { return readState(t, cfg, "generation") == mine })
	waitFor(t, "의심이 풀림", func() bool { _, doubt := suspect(t, cfg, "s1"); return !doubt })
}

// A receiver on another port than the sessions send to cannot be the one the statusline goes by,
// whatever it holds: the one on the right port is the receiver that gets the events, and it
// finds the locks taken.
func TestAReceiverOnAnotherPortThanTheStatuslineExpectsIsNotTrusted(t *testing.T) {
	cfg := baseConfig(t)
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	if addr == anchor.DefaultAddr {
		t.Skip("시험 수신기가 기본 주소에서 듣는다")
	}
	read := func(expect string) anchor.Result {
		return anchor.Resolve(anchor.Input{StateDir: cfg.StateDir, ConfigDir: t.TempDir(), SessionID: "s1", Now: time.Now(), Addr: expect})
	}
	if res := read(""); res.Email != "a@example.com" || !res.Suspect {
		t.Errorf("기본 주소가 아닌 곳에서 듣는 수신기의 앵커를 믿는다: %+v", res)
	}
	if res := read(addr); res.Suspect {
		t.Errorf("알려 준 주소에서 듣는 수신기는 믿어야 한다: %+v", res)
	}
	// The receiver for the right port cannot start while this one holds the locks.
	other := baseConfig(t)
	other.StateDir = cfg.StateDir
	if code := failedStart(t, other); code != exitFailed {
		t.Errorf("잠금을 쥔 수신기가 있는데 둘째 종료코드 %d, want %d", code, exitFailed)
	}
}

// A lock file replaced between taking the start lock and being ready is found before anything is
// served, not at the first event or beat.
func TestAStartWhoseLockFileIsReplacedBeforeItServesGivesUp(t *testing.T) {
	cfg := baseConfig(t)
	cfg.BeatEvery, cfg.WatchEvery = time.Hour, time.Hour
	startLock, _ := lockPaths(cfg)
	cfg.OnLocked = func() {
		os.Remove(startLock)
		os.WriteFile(startLock, nil, 0o600)
	}
	listened := false
	cfg.OnListen = func(net.Addr) { listened = true }
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	stderr := &syncBuffer{}
	if code := serve(ctx, cfg, stderr); code != exitFailed {
		t.Fatalf("종료코드 %d, want %d (stderr=%q)", code, exitFailed, stderr.String())
	}
	if listened {
		t.Error("잠금 파일이 바뀐 시작이 요청을 받기 시작했다")
	}
	if !strings.Contains(stderr.String(), "lock file removed or replaced") {
		t.Errorf("포기한 이유가 stderr 에 없다: %q", stderr.String())
	}
}

// Everything the receiver stores and the lock it holds name the same run, and the lock names
// where the receiver listens.
func TestEverythingAReceiverStoresNamesItsRun(t *testing.T) {
	cfg := baseConfig(t)
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	a, ok := anchor.Read(cfg.StateDir, "s1")
	if !ok || a.Run == "" {
		t.Fatalf("앵커가 run 을 싣지 않았다: %+v", a)
	}
	if gen := readState(t, cfg, "generation"); !strings.Contains(gen, "run="+a.Run+"\n") {
		t.Errorf("세대 파일 %q 이 앵커의 run %s 을 담지 않았다", gen, a.Run)
	}
	_, live := lockPaths(cfg)
	b, err := os.ReadFile(live)
	if err != nil {
		t.Fatal(err)
	}
	if want := "run=" + a.Run + "\naddr=" + addr + "\n"; string(b) != want {
		t.Errorf("준비 잠금 내용 %q, want %q", b, want)
	}
	if a.Run == "testrun" || len(a.Run) < 16 {
		t.Errorf("run %q 이 시작마다 새로 만든 불투명한 값이 아니다", a.Run)
	}
}

func TestEachStartOfTheReceiverHasItsOwnRun(t *testing.T) {
	cfg := afterARun(t)
	first, _ := anchor.Read(cfg.StateDir, "s1")
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if code := postLogin(t, addr, "s2", "b@example.com", 1_700_000_001_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	second, _ := anchor.Read(cfg.StateDir, "s2")
	if first.Run == "" || first.Run == second.Run {
		t.Errorf("두 시작의 run 이 같거나 비었다: %q, %q", first.Run, second.Run)
	}
	if res, doubt := suspect(t, cfg, "s1"); res.Email != "a@example.com" || !doubt {
		t.Errorf("이전 실행의 앵커는 의심해야 한다: %+v 의심=%v", res, doubt)
	}
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("기다리다 끝났다: %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// holdShared keeps a shared flock on a lock file the way a reader's probe does, until released.
func holdShared(t *testing.T, path string) *os.File {
	t.Helper()
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

// A reader probes the live lock for an instant. A start that meets the probe waits it out and
// becomes ready.
func TestAReaderProbingTheLiveLockDoesNotFailAStart(t *testing.T) {
	cfg := baseConfig(t)
	if err := os.MkdirAll(filepath.Join(cfg.StateDir, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	_, live := lockPaths(cfg)
	probe := holdShared(t, live)
	go func() { time.Sleep(150 * time.Millisecond); probe.Close() }()
	_, exit, stderr, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if got := readState(t, cfg, "receiver.live"); !strings.Contains(got, "run=") {
		t.Errorf("준비 잠금 내용 %q (stderr=%q)", got, stderr.String())
	}
}

// A start that cannot take the live lock does not serve without it: the supervisor restarts it.
func TestAStartThatCannotTakeTheLiveLockGivesUp(t *testing.T) {
	cfg := baseConfig(t)
	if err := os.MkdirAll(filepath.Join(cfg.StateDir, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	_, live := lockPaths(cfg)
	holdShared(t, live)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stderr := &syncBuffer{}
	if code := serve(ctx, cfg, stderr); code != exitFailed {
		t.Fatalf("종료코드 %d, want %d (stderr=%q)", code, exitFailed, stderr.String())
	}
	if !strings.Contains(stderr.String(), "lock unavailable") {
		t.Errorf("포기한 이유가 stderr 에 없다: %q", stderr.String())
	}
}
