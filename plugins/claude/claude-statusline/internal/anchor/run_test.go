package anchor

import (
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// A number says how recent an anchor is; the run says whose it is. Two receivers can reach the
// same number, so what the live lock's receiver did not store is doubted whatever the number.

func TestAnAnchorKeepsItsRunThroughTheFileAndTheProcessCarry(t *testing.T) {
	a := Anchor{Email: "a@example.com", Kind: KindLogin, TS: 5, Seen: 6, Gen: 7, Run: "run-1"}
	got, ok := decode(string(encode(a)))
	if !ok || got != a {
		t.Fatalf("decode(encode(a)) = %+v, %v; want %+v", got, ok, a)
	}
	// /clear gives the process a new session id, and the anchor it carries comes from the pid file.
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.clockAt(t0 + 1000)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+900))
	f.wantEmail("s1", now, "a@example.com")
	f.proc(11, t0, "s2")
	if got := f.wantEmail("s2", now, "a@example.com"); got.Suspect {
		t.Errorf("/clear 를 건넌 앵커가 run 을 잃었다: %+v", got)
	}
}

func TestAnAnchorOfAnotherRunIsDoubtedWhateverItsNumber(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.applyAs("a-receiver-that-was-replaced", login("s1", "a@example.com", t0+900))
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("같은 번호라도 다른 수신기가 저장한 앵커는 의심해야 한다: %+v", got)
	}
	f.apply(login("s1", "b@example.com", t0+950))
	if got := f.wantEmail("s1", now, "b@example.com"); got.Suspect {
		t.Errorf("잠금을 쥔 수신기의 앵커는 믿어야 한다: %+v", got)
	}
}

func TestAnAnchorWithoutARunIsDoubted(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	body := "email=a@example.com\nkind=login\nts=" + strconv.FormatInt(t0+900, 10) + "\nseen=" + strconv.FormatInt(t0+900, 10) + "\ngen=1\n"
	if err := os.WriteFile(filepath.Join(sessionsDir(f.state), "s1.env"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("run 이 없는 앵커는 누구의 것인지 알 수 없다: %+v", got)
	}
}

// A late write of a receiver that was replaced can leave its own run in the generation file. The
// anchors of the receiver that holds the lock then went by a count that is not theirs.
func TestAGenerationFileOfAnotherRunDoubtsEveryAnchor(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	if got := f.wantEmail("s1", now, "a@example.com"); got.Suspect {
		t.Fatalf("준비: 믿어야 한다: %+v", got)
	}
	if err := WriteGeneration(f.state, f.gen, "a-receiver-that-was-replaced"); err != nil {
		t.Fatal(err)
	}
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("다른 run 이 쓴 세대 파일을 믿었다: %+v", got)
	}
	if GenerationIs(f.state, f.gen, f.run) {
		t.Error("GenerationIs 가 다른 run 의 세대 파일을 이 수신기의 것이라고 한다")
	}
	if err := WriteGeneration(f.state, f.gen, f.run); err != nil {
		t.Fatal(err)
	}
	if !GenerationIs(f.state, f.gen, f.run) {
		t.Error("GenerationIs 가 제 세대 파일을 알아보지 못한다")
	}
	if got := f.wantEmail("s1", now, "a@example.com"); got.Suspect {
		t.Errorf("수신기가 세대 파일을 되돌리면 다시 믿어야 한다: %+v", got)
	}
}

// The run is read from the receiver that holds the live lock, not from a file a replaced
// receiver can still write: a generation file and an anchor of the same stale run agree with each
// other and not with the live lock.
func TestARunTheLiveLockDoesNotNameIsNotTrustedEvenWhenTheFilesAgree(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	stale := "a-receiver-that-was-replaced"
	if err := WriteGeneration(f.state, f.gen, stale); err != nil {
		t.Fatal(err)
	}
	f.applyAs(stale, login("s1", "a@example.com", t0+900))
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("서로 맞는 낡은 run 의 파일들을 믿었다: %+v", got)
	}
}

// A receiver listening where the sessions do not send their events is not the one the
// statusline can go by.
func TestAReceiverListeningElsewhereThanExpectedIsNotTrusted(t *testing.T) {
	f := newFixture(t)
	f.listen = "127.0.0.1:9"
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	in := func(addr string) Result {
		return Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: "s1", Now: now, Addr: addr})
	}
	if got := in(""); !got.Suspect || got.Email != "a@example.com" {
		t.Errorf("기본 주소가 아닌 수신기를 믿었다: %+v", got)
	}
	if got := in("127.0.0.1:9"); got.Suspect {
		t.Errorf("알려 준 주소에서 듣는 수신기는 믿어야 한다: %+v", got)
	}
	if got := in("127.0.0.1:10"); !got.Suspect {
		t.Errorf("다른 포트를 알려 줬는데 믿었다: %+v", got)
	}
	if got := in("not an address"); !got.Suspect {
		t.Errorf("읽히지 않는 설정은 기본 주소로 떨어지지 않고 의심해야 한다: %+v", got)
	}
	if got := in("127.0.0.1"); !got.Suspect {
		t.Errorf("포트 없는 설정을 믿었다: %+v", got)
	}
}

func TestTheDefaultAddressIsWhatAReceiverIsExpectedOn(t *testing.T) {
	f := newFixture(t) // listens on DefaultAddr
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	if got := f.wantEmail("s1", now, "a@example.com"); got.Suspect {
		t.Errorf("기본 주소의 수신기는 믿어야 한다: %+v", got)
	}
	if got := Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: "s1", Now: now, Addr: DefaultAddr}); got.Suspect {
		t.Errorf("기본 주소를 그대로 알려 줘도 같아야 한다: %+v", got)
	}
}

func TestAnIPv6AddressIsComparedByItsValue(t *testing.T) {
	f := newFixture(t)
	f.listen = "[::1]:14318"
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	if got := Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: "s1", Now: now, Addr: "[0:0:0:0:0:0:0:1]:14318"}); got.Suspect {
		t.Errorf("같은 IPv6 주소를 다르게 적어도 같아야 한다: %+v", got)
	}
}

// Between the moment a receiver takes the live lock and the moment it writes its run into it, a
// reader finds a lock with nothing in it. It does not go by that receiver.
func TestAReaderFindsNoRunInALockThatHoldsNothingYet(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	if err := os.Truncate(liveLockPath(f.state), 0); err != nil {
		t.Fatal(err)
	}
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("내용이 없는 준비 잠금의 수신기를 믿었다: %+v", got)
	}
}

// The lock file of a receiver that stopped keeps what it wrote. A start that has the lock and has
// not yet written over it is a different run from the one the file names.
func TestAStartThatHoldsTheLockOverTheLastRunsContentIsNotTrusted(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	f.stopReceiver() // the lock file keeps the run it named
	if err := WriteGeneration(f.state, f.gen+1, "the-next-run"); err != nil {
		t.Fatal(err)
	}
	live, err := lockFile(liveLockPath(f.state)) // taken, not yet written over
	if err != nil {
		t.Fatal(err)
	}
	defer live.f.Close()
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("이전 실행의 내용 위에 잠금만 쥔 시작을 믿었다: %+v", got)
	}
}

// Ready publishes the state of the run that calls it, whatever order the caller took. Moving it
// before the state is written would let the previous run's state be read as this one's.
func TestReadyRefusesStateThatIsNotThisRuns(t *testing.T) {
	cases := map[string]func(t *testing.T, state string){
		"no generation file": func(t *testing.T, state string) {
			TouchHeartbeat(state, time.Now())
		},
		"the generation of another run": func(t *testing.T, state string) {
			WriteGeneration(state, testGen, "the-last-run")
			TouchHeartbeat(state, time.Now())
		},
		"a generation file that names no run": func(t *testing.T, state string) {
			writeFile(t, generationPath(state), "1\n")
			TouchHeartbeat(state, time.Now())
		},
		"no heartbeat": func(t *testing.T, state string) {
			WriteGeneration(state, testGen, testRun)
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			state := otelDir(t)
			lock, err := LockReceiver(state)
			if err != nil {
				t.Fatal(err)
			}
			defer lock.Close()
			setup(t, state)
			if err := lock.Ready(Receiver{Run: testRun, Addr: DefaultAddr}); err != ErrNotReady {
				t.Fatalf("Ready = %v, want ErrNotReady", err)
			}
			if receiverAlive(state) {
				t.Error("Ready 가 실패했는데 준비 잠금이 잡혀 있다")
			}
		})
	}
}

func TestReadyPutsTheRunAndTheAddressInTheLiveLockAndKeepsTheLock(t *testing.T) {
	state := otelDir(t)
	lock := readyReceiver(t, state)
	held, self := probeLive(state)
	if !held || self != (Receiver{Run: testRun, Addr: DefaultAddr}) {
		t.Fatalf("probeLive = %v, %+v", held, self)
	}
	if err := lock.Held(); err != nil {
		t.Errorf("내용을 쓰고 나서 잠금이 경로의 파일이 아니다: %v", err)
	}
}

func TestReadyNeedsARunAndAnAddress(t *testing.T) {
	state := otelDir(t)
	publish(t, state, testRun)
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	for _, r := range []Receiver{{}, {Run: testRun}, {Addr: DefaultAddr}, {Run: "no spaces", Addr: DefaultAddr}} {
		if err := lock.Ready(r); err == nil {
			t.Errorf("Ready(%+v) 가 성공했다", r)
		}
	}
}

// A reader probes the live lock for an instant; a receiver that meets the probe is not blocked
// for good, and one that cannot get the lock in time gives up with an error.
func TestAReaderProbingTheLiveLockDoesNotFailReady(t *testing.T) {
	state := otelDir(t)
	publish(t, state, testRun)
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	probe := holdShared(t, liveLockPath(state))
	go func() { time.Sleep(lockWait / 4); probe.Close() }()
	if err := lock.Ready(Receiver{Run: testRun, Addr: DefaultAddr}); err != nil {
		t.Fatalf("읽는 쪽의 짧은 조사 때문에 Ready 가 실패했다: %v", err)
	}
}

func TestReadyGivesUpWhenTheLiveLockStaysTaken(t *testing.T) {
	state := otelDir(t)
	publish(t, state, testRun)
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	probe := holdShared(t, liveLockPath(state))
	defer probe.Close()
	if err := lock.Ready(Receiver{Run: testRun, Addr: DefaultAddr}); err == nil {
		t.Fatal("준비 잠금을 못 얻었는데 Ready 가 성공했다")
	}
}

func holdShared(t *testing.T, path string) *os.File {
	t.Helper()
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH); err != nil {
		t.Fatal(err)
	}
	return f
}

// A lock counts only on the file that is at the path once it is held. flock is replaced to swap
// the file in the instant between the open and the lock.
func TestALockOnAFileReplacedBeforeItWasHeldIsTakenAgain(t *testing.T) {
	state := otelDir(t)
	path := startLockPath(state)
	old := flock
	t.Cleanup(func() { flock = old })
	swaps := 0
	flock = func(fd, how int) error {
		err := old(fd, how)
		if swaps == 0 {
			swaps++
			os.Remove(path)
			os.WriteFile(path, nil, 0o600)
		}
		return err
	}
	h, err := lockFile(path)
	if err != nil {
		t.Fatalf("lockFile = %v", err)
	}
	defer h.f.Close()
	if err := h.stillOnPath(); err != nil {
		t.Errorf("얻은 잠금이 경로의 파일이 아니다: %v", err)
	}
	if swaps != 1 {
		t.Errorf("파일을 바꾼 횟수 %d", swaps)
	}
}

func TestALockOnAFileThatKeepsBeingReplacedGivesUp(t *testing.T) {
	state := otelDir(t)
	path := startLockPath(state)
	old := flock
	t.Cleanup(func() { flock = old })
	flock = func(fd, how int) error {
		err := old(fd, how)
		os.Remove(path)
		os.WriteFile(path, nil, 0o600)
		return err
	}
	if _, err := lockFile(path); err != ErrLockLost {
		t.Fatalf("lockFile = %v, want ErrLockLost", err)
	}
}

// Every state file is a regular file the receiver or the statusline wrote by renaming a temporary
// one over it. A link is not one, so what it points to is not state: not an anchor, not the
// generation.
func TestAStateFileThatIsALinkIsNotRead(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	moveBehindALink := func(path string) {
		t.Helper()
		target := filepath.Join(t.TempDir(), filepath.Base(path))
		if err := os.Rename(path, target); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
	}
	moveBehindALink(filepath.Join(sessionsDir(f.state), "s1.env"))
	if a, ok := Read(f.state, "s1"); ok {
		t.Errorf("링크로 바뀐 앵커가 읽혔다: %+v", a)
	}
	if got := f.resolve("s1", now); got.Email != "" {
		t.Errorf("링크로 바뀐 앵커의 계정을 보였다: %+v", got)
	}
	moveBehindALink(generationPath(f.state))
	if _, _, ok := readGeneration(f.state); ok {
		t.Error("링크로 바뀐 세대 파일이 읽혔다")
	}
	if _, err := NextGeneration(f.state); err != errDamagedGeneration {
		t.Errorf("NextGeneration = %v, want errDamagedGeneration", err)
	}
}

// The run is read from the file the probe met the lock on. Opening the path again would pair the
// lock of one file with the run of another when the path changes in between.
func TestTheRunIsReadFromTheFileTheLockWasMetOn(t *testing.T) {
	state := otelDir(t)
	readyReceiver(t, state)
	old := flock
	t.Cleanup(func() { flock = old })
	flock = func(fd, how int) error {
		err := old(fd, how)
		os.Remove(liveLockPath(state)) // the path now holds another file, with another run
		os.WriteFile(liveLockPath(state), []byte("run=other\naddr="+DefaultAddr+"\n"), 0o600)
		return err
	}
	held, self := probeLive(state)
	if !held || self.Run != testRun {
		t.Fatalf("probeLive = %v, %+v; want the run of the file that was locked", held, self)
	}
}

// A setting that does not read as an address is not the default address in disguise: a receiver
// that listens at the default is still not the one the user meant.
func TestAnUnreadableAddressSettingDoesNotFallBackToTheDefault(t *testing.T) {
	f := newFixture(t) // listens on DefaultAddr
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.apply(login("s1", "a@example.com", t0+900))
	for _, bad := range []string{"garbage", "127.0.0.1", ":14318", "localhost:14318", "127.0.0.1:"} {
		got := Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: "s1", Now: now, Addr: bad})
		if !got.Suspect {
			t.Errorf("Addr %q 를 기본 주소로 읽어 믿었다: %+v", bad, got)
		}
	}
}
