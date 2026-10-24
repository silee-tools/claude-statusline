package anchor

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// t0 is a process start time in unix milliseconds.
const t0 = int64(1_700_000_000_000)

// The fixtures name pids no machine is known to run, so every process is taken as running
// unless a test says it ended (fixture.dead).
func init() {
	alive = func(int) bool { return true }
	lockWait = 50 * time.Millisecond
}

type fixture struct {
	t      *testing.T
	state  string
	config string
	gen    int64 // the receiver generation apply stores anchors under
	lock   *ReceiverLock
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{t: t, state: t.TempDir(), config: t.TempDir(), gen: testGen}
	if err := os.MkdirAll(filepath.Join(f.config, "sessions"), 0o755); err != nil {
		t.Fatal(err)
	}
	return f
}

// otherProfile is a second config directory that shares this fixture's state directory,
// as two Claude config directories of one user do.
func (f *fixture) otherProfile() *fixture {
	f.t.Helper()
	g := &fixture{t: f.t, state: f.state, config: f.t.TempDir(), gen: f.gen}
	if err := os.MkdirAll(filepath.Join(g.config, "sessions"), 0o755); err != nil {
		f.t.Fatal(err)
	}
	return g
}

// install makes the receiver's directory, a fresh heartbeat and the generation the tests
// store their anchors under exist, and holds the lock a running receiver holds.
func (f *fixture) install(heartbeatAge time.Duration, now time.Time) {
	f.t.Helper()
	if err := os.MkdirAll(sessionsDir(f.state), 0o700); err != nil {
		f.t.Fatal(err)
	}
	if f.lock == nil {
		lock, err := LockReceiver(f.state)
		if err != nil {
			f.t.Fatal(err)
		}
		f.lock = lock
		f.t.Cleanup(func() { lock.Close() })
	}
	if err := WriteGeneration(f.state, f.gen); err != nil {
		f.t.Fatal(err)
	}
	if heartbeatAge < 0 {
		return
	}
	if err := TouchHeartbeat(f.state, now.Add(-heartbeatAge)); err != nil {
		f.t.Fatal(err)
	}
}

// stopReceiver lets go of the lock, as a receiver that exits does.
func (f *fixture) stopReceiver() {
	f.t.Helper()
	if f.lock != nil {
		f.lock.Close()
		f.lock = nil
	}
}

// clockAt moves the time the receiver stamps anchors with.
func (f *fixture) clockAt(ms int64) {
	f.t.Helper()
	old := clock
	f.t.Cleanup(func() { clock = old })
	clock = func() time.Time { return time.UnixMilli(ms) }
}

// proc writes the file Claude Code keeps for a running process.
func (f *fixture) proc(pid int, startedMs int64, sessionID string) {
	f.t.Helper()
	b, _ := json.Marshal(map[string]any{"pid": pid, "sessionId": sessionID, "startedAt": startedMs, "cwd": "/tmp/example"})
	if err := os.WriteFile(filepath.Join(f.config, "sessions", strconv.Itoa(pid)+".json"), b, 0o600); err != nil {
		f.t.Fatal(err)
	}
}

// dead stands in for processes that ended while the files they left behind stayed.
func (f *fixture) dead(pids ...int) {
	f.t.Helper()
	old := alive
	f.t.Cleanup(func() { alive = old })
	gone := map[int]bool{}
	for _, p := range pids {
		gone[p] = true
	}
	alive = func(pid int) bool { return !gone[pid] }
}

func (f *fixture) apply(e Event) {
	f.t.Helper()
	if _, err := Apply(f.state, e, f.gen); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) resolve(id string, now time.Time) Result {
	return Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: id, Now: now})
}

func (f *fixture) resolveAs(id string, parent int, now time.Time) Result {
	return Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: id, Parent: parent, Now: now})
}

func at(ms int64) time.Time { return time.UnixMilli(ms) }

func (f *fixture) wantEmail(id string, now time.Time, want string) Result {
	f.t.Helper()
	got := f.resolve(id, now)
	if got.Email != want {
		f.t.Fatalf("Resolve(%s).Email = %q, want %q (%+v)", id, got.Email, want, got)
	}
	return got
}

func (f *fixture) startAnchor(id, email string, ts int64) {
	f.t.Helper()
	f.apply(ev("managed_settings_resolved", id, email, ts))
}

// R1 — the anchor is the only source of the account.

func TestWithoutTheReceiversDirectoryTheSlotIsNotInstalled(t *testing.T) {
	f := newFixture(t)
	// A settings file that names an account must not be read.
	os.WriteFile(filepath.Join(f.config, ".claude.json"), []byte(`{"oauthAccount":{"emailAddress":"file@example.com"}}`), 0o600)
	os.WriteFile(filepath.Join(f.state, "cc-account.env"), []byte("email=cache@example.com\n"), 0o600)
	got := f.resolve("s1", time.Now())
	if got.Installed || got.Email != "" {
		t.Errorf("Resolve = %+v, want not installed and no email", got)
	}
}

func TestInstalledWithoutAnAnchorForThisSessionHasNoEmail(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.apply(ev("managed_settings_resolved", "other", "other@example.com", t0))
	os.WriteFile(filepath.Join(f.config, ".claude.json"), []byte(`{"oauthAccount":{"emailAddress":"file@example.com"}}`), 0o600)
	got := f.wantEmail("s1", now, "")
	if !got.Installed {
		t.Error("디렉터리가 있으면 설치된 것이다")
	}
	if got.Level != Unknown {
		t.Errorf("앵커가 없으면 신뢰도는 Unknown: %+v", got)
	}
}

func TestTheAnchorWinsOverEveryOtherSource(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	os.WriteFile(filepath.Join(f.config, ".claude.json"), []byte(`{"oauthAccount":{"emailAddress":"file@example.com"}}`), 0o600)
	f.apply(ev("managed_settings_resolved", "s1", "a@example.com", t0))
	got := f.wantEmail("s1", now, "a@example.com")
	if got.AnchorTS != t0 {
		t.Errorf("AnchorTS = %d, want %d", got.AnchorTS, t0)
	}
}

func TestInvalidSessionIDsHaveNoEmail(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.apply(ev("managed_settings_resolved", "s1", "a@example.com", t0))
	for _, id := range []string{"", "../s1", "s1/../s1", "s1 ", "s1\n", "s1.env"} {
		f.wantEmail(id, now, "")
	}
}

// R10 — only an in-session login confirms an account; the settings file's account at the
// session start is an estimate, because the file is shared and the credentials are not.

func TestAStartAnchorIsAnEstimateAndALoginIsConfirmed(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.startAnchor("s1", "a@example.com", t0+20)
	if got := f.wantEmail("s1", now, "a@example.com"); got.Level != Estimate {
		t.Errorf("시작 앵커: %+v, want Estimate", got)
	}
	f.apply(login("s1", "b@example.com", t0+5000))
	if got := f.wantEmail("s1", now, "b@example.com"); got.Level != Confirmed {
		t.Errorf("로그인 앵커: %+v, want Confirmed", got)
	}
}

func TestClearKeepsTheConfidenceOfTheCarriedAnchor(t *testing.T) {
	for _, c := range []struct {
		name  string
		first Event
		want  Confidence
	}{
		{"시작", ev("managed_settings_resolved", "s1", "a@example.com", t0+20), Estimate},
		{"로그인", login("s1", "a@example.com", t0+5000), Confirmed},
	} {
		f := newFixture(t)
		now := time.Now()
		f.install(0, now)
		f.proc(11, t0, "s1")
		f.apply(c.first)
		f.wantEmail("s1", now, "a@example.com")
		f.proc(11, t0, "s2")
		if got := f.wantEmail("s2", now, "a@example.com"); got.Level != c.want {
			t.Errorf("%s: /clear 뒤 %+v, want %v", c.name, got, c.want)
		}
	}
}

// R9 — a receiver that is not running is shown as a doubt.

func TestStaleOrMissingHeartbeatMarksTheEmailSuspect(t *testing.T) {
	cases := []struct {
		name string
		age  time.Duration // negative: no heartbeat file
		want bool
	}{
		{"방금", 0, false},
		{"100초", 100 * time.Second, false},
		{"120초", 120 * time.Second, false},
		{"121초", 121 * time.Second, true},
		{"한 시간", time.Hour, true},
		{"하트비트 없음", -1, true},
	}
	for _, c := range cases {
		f := newFixture(t)
		now := time.Now()
		f.install(c.age, now)
		f.apply(ev("managed_settings_resolved", "s1", "a@example.com", t0))
		got := f.resolve("s1", now)
		if got.Suspect != c.want || got.Email != "a@example.com" {
			t.Errorf("%s: Resolve = %+v, want suspect=%v with the email", c.name, got, c.want)
		}
	}
}

func TestWithoutAnAnchorTheSlotStaysUnknownWhateverTheHeartbeat(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(time.Hour, now)
	f.wantEmail("s1", now, "")
}

// R11 — a restart of the receiver, or a failed write, may have lost a /login. An anchor
// of an earlier generation than the receiver's current one is doubted until an event
// replaces it.

func TestAnAnchorStoredBeforeTheReceiversGenerationIsSuspectUntilAnEventReplacesIt(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1000)
	f.startAnchor("s1", "a@example.com", t0+900)
	if got := f.resolve("s1", now); got.Suspect {
		t.Fatalf("같은 세대의 앵커는 의심하지 않는다: %+v", got)
	}
	// The receiver restarted: it may have missed a /login while it was down.
	f.gen++
	if err := WriteGeneration(f.state, f.gen); err != nil {
		t.Fatal(err)
	}
	got := f.resolve("s1", now)
	if !got.Suspect || got.Email != "a@example.com" {
		t.Fatalf("이전 세대의 앵커: %+v, want 이메일을 남기고 의심", got)
	}
	// A login the new generation saw replaces it and is trusted again.
	f.clockAt(t0 + 40_000)
	f.apply(login("s1", "b@example.com", t0+39_000))
	got = f.resolve("s1", now)
	if got.Suspect || got.Email != "b@example.com" || got.Level != Confirmed {
		t.Fatalf("새 세대의 로그인: %+v", got)
	}
}

func TestAMissingGenerationFileMakesEveryAnchorSuspect(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.startAnchor("s1", "a@example.com", t0)
	if err := os.Remove(filepath.Join(f.state, "otel", "generation")); err != nil {
		t.Fatal(err)
	}
	if got := f.resolve("s1", now); !got.Suspect {
		t.Errorf("세대를 알 수 없으면 의심: %+v", got)
	}
}

func TestACarriedAnchorKeepsTheGenerationItWasStoredIn(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.clockAt(t0 + 1000)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+900))
	f.wantEmail("s1", now, "a@example.com")
	if err := WriteGeneration(f.state, f.gen+1); err != nil {
		t.Fatal(err)
	}
	f.proc(11, t0, "s2") // /clear
	if got := f.wantEmail("s2", now, "a@example.com"); !got.Suspect {
		t.Errorf("/clear 로 이어진 앵커도 저장 시점의 세대를 따른다: %+v", got)
	}
}

// R12 — what the receiver has not renewed in 30 days is not used.

func TestAnAnchorOlderThanTheRetentionIsNotUsedEvenIfNoWriteEverPrunedIt(t *testing.T) {
	f := newFixture(t)
	f.install(0, at(t0))
	f.clockAt(t0)
	f.startAnchor("s1", "a@example.com", t0)
	month := retention.Milliseconds()
	if got := f.resolve("s1", at(t0+month)); got.Email != "a@example.com" {
		t.Errorf("보존 기간 안: %+v", got)
	}
	if got := f.resolve("s1", at(t0+month+1)); got.Email != "" || !got.Installed {
		t.Errorf("보존 기간이 지난 앵커: %+v, want 이메일 없음", got)
	}
}

func TestACarriedAnchorOlderThanTheRetentionIsNotUsed(t *testing.T) {
	f := newFixture(t)
	f.install(0, at(t0))
	f.clockAt(t0)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0))
	f.wantEmail("s1", at(t0), "a@example.com")
	f.proc(11, t0, "s2")
	f.wantEmail("s2", at(t0+retention.Milliseconds()+1), "")
}

func TestSweepPrunesAllThreeDirectoriesWithoutAnyNewEvent(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	old := now.Add(-retention - time.Hour)
	for _, rel := range []string{"otel/sessions/old.env", "pids/11-1.env", "pids/session-old.ref", "fingerprints/old.env"} {
		path := filepath.Join(f.state, rel)
		os.MkdirAll(filepath.Dir(path), 0o700)
		os.WriteFile(path, []byte("x\n"), 0o600)
		os.Chtimes(path, old, old)
	}
	keep := filepath.Join(f.state, "otel", "sessions", "recent.env")
	os.WriteFile(keep, []byte("x\n"), 0o600)
	Sweep(f.state, now)
	for _, rel := range []string{"otel/sessions/old.env", "pids/11-1.env", "pids/session-old.ref", "fingerprints/old.env"} {
		if _, err := os.Stat(filepath.Join(f.state, rel)); err == nil {
			t.Errorf("%s 가 남았다", rel)
		}
	}
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("최근 파일을 지웠다: %v", err)
	}
}

func TestSweepKeepsTheNewestFilesWithinTheLimitPerDirectory(t *testing.T) {
	defer func(n int) { maxFiles = n }(maxFiles)
	maxFiles = 3
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	for _, dir := range []string{"otel/sessions", "pids", "fingerprints"} {
		os.MkdirAll(filepath.Join(f.state, dir), 0o700)
		for i := 0; i < 6; i++ {
			path := filepath.Join(f.state, dir, "f"+strconv.Itoa(i)+".env")
			os.WriteFile(path, []byte("x\n"), 0o600)
			mod := now.Add(-time.Duration(10-i) * time.Minute)
			os.Chtimes(path, mod, mod)
		}
	}
	Sweep(f.state, now)
	for _, dir := range []string{"otel/sessions", "pids", "fingerprints"} {
		ents, _ := os.ReadDir(filepath.Join(f.state, dir))
		if len(ents) != 3 {
			t.Errorf("%s: %d files, want 3", dir, len(ents))
		}
	}
}

// R4 — /clear keeps the process's account.

func TestClearInheritsTheLoginOfThePreviousSessionID(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com") // the render before /clear records the process
	f.proc(11, t0, "s2")                    // /clear: same pid and startedAt, new sessionId
	got := f.wantEmail("s2", now, "a@example.com")
	if got.AnchorTS != t0+5000 {
		t.Errorf("AnchorTS = %d, want the inherited anchor's %d", got.AnchorTS, t0+5000)
	}
}

func TestSuccessiveClearsKeepInheriting(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com")
	for _, id := range []string{"s2", "s3", "s4"} {
		f.proc(11, t0, id)
		f.wantEmail(id, now, "a@example.com")
	}
	// A render of the same session again is steady.
	f.wantEmail("s4", now, "a@example.com")
}

func TestLoginAfterClearOverridesAndIsInheritedByTheNextClear(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com")
	f.proc(11, t0, "s2")
	f.wantEmail("s2", now, "a@example.com")
	f.apply(login("s2", "b@example.com", t0+9000))
	f.wantEmail("s2", now, "b@example.com")
	f.proc(11, t0, "s3")
	f.wantEmail("s3", now, "b@example.com")
}

func TestClearAfterLogoutStaysLoggedOut(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(ev("managed_settings_resolved", "s1", "a@example.com", t0))
	f.apply(logout("s1", t0+5000))
	f.wantEmail("s1", now, "")
	f.proc(11, t0, "s2")
	f.wantEmail("s2", now.Add(time.Minute), "")
}

func TestTwoSessionsOfOneConfigDirectoryNeverMix(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.proc(12, t0+1000, "s9")
	f.apply(ev("managed_settings_resolved", "s1", "a@example.com", t0))
	f.apply(ev("managed_settings_resolved", "s9", "b@example.com", t0+1000))
	f.wantEmail("s1", now, "a@example.com")
	f.wantEmail("s9", now, "b@example.com")
	// One session's /login moves only that session.
	f.apply(login("s9", "c@example.com", t0+20000))
	f.wantEmail("s9", now, "c@example.com")
	f.wantEmail("s1", now, "a@example.com")
	// And /clear in one keeps the other's account out of it.
	f.proc(11, t0, "s2")
	f.wantEmail("s2", now, "a@example.com")
	f.wantEmail("s9", now, "c@example.com")
}

func TestSessionOfAnUnknownProcessFallsBackToItsOwnAnchor(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	if got := f.wantEmail("s1", now, "a@example.com"); got.Level != Confirmed {
		t.Errorf("로그인한 프로세스를 아는 동안은 확정이다: %+v", got)
	}
	os.RemoveAll(filepath.Join(f.config, "sessions"))
	if got := f.wantEmail("s1", now, "a@example.com"); got.Level != Estimate {
		t.Errorf("프로세스를 모르면 로그인 앵커도 추정(~)으로만 보인다: %+v", got)
	}
}

func TestAResumedConversationWhoseProcessCannotBeFoundIsNeverShownAsConfirmed(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.crashedLife("real", t0-86_400_000, "a@example.com") // P1 logged in and was killed
	os.RemoveAll(filepath.Join(f.config, "sessions"))     // the new process has no sessions/<pid>.json yet
	os.MkdirAll(filepath.Join(f.config, "sessions"), 0o700)
	got := f.resolveAs("real", 31, now)
	if got.Email != "a@example.com" || got.Level != Estimate {
		t.Errorf("재개한 프로세스를 모르는 동안 이전 프로세스의 로그인이 확정으로 보인다: %+v", got)
	}
	f.proc(31, t0, "real")
	if got := f.resolveAs("real", 31, now); got.Email != "" {
		t.Errorf("프로세스를 알게 되면 이전 프로세스의 앵커는 빌리지 않는다: %+v", got)
	}
}

func TestUnknownProcessWithoutAnAnchorIsUnknown(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.wantEmail("s1", now, "") // no sessions/*.json names s1
}

func TestOnlyJSONFilesOfTheSessionsDirectoryAreRead(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com")
	// A *.key file naming s2 must never be consulted: it holds a secret in real life.
	b, _ := json.Marshal(map[string]any{"pid": 11, "sessionId": "s2", "startedAt": t0})
	os.WriteFile(filepath.Join(f.config, "sessions", "11.key"), b, 0o600)
	os.Remove(filepath.Join(f.config, "sessions", "11.json"))
	f.wantEmail("s2", now, "")
}

// R13 — what /clear leaves behind under the old session id is not the process's to
// follow. Another process that resumes that id can log in under it, and a later render of
// the cleared process must not take that account.

func TestAnotherProcessResumingTheOldIDAfterClearDoesNotMoveTheClearedProcess(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com")
	f.proc(11, t0, "s2") // P1: /clear
	f.wantEmail("s2", now, "a@example.com")
	// P2 resumes the conversation s1 and logs in as another account.
	f.proc(12, t0+60_000, "s1")
	f.apply(login("s1", "b@example.com", t0+70_000))
	if got := f.wantEmail("s2", now, "a@example.com"); got.AnchorTS != t0+5000 {
		t.Errorf("P1 의 앵커가 P2 의 로그인으로 바뀌었다: %+v", got)
	}
	f.wantEmail("s2", now.Add(time.Hour), "a@example.com") // and stays so
	// P2 itself shows its own login.
	f.wantEmail("s1", now, "b@example.com")
}

func TestAChangeUnderTheOldIDBeforeTheFirstRenderAfterClearLeavesTheProcessUnknown(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com")
	f.proc(11, t0, "s2") // P1: /clear, not rendered yet
	f.proc(12, t0+60_000, "s1")
	f.apply(login("s1", "b@example.com", t0+70_000)) // P2, or P1's own login just before /clear: unknowable
	f.wantEmail("s2", now, "")
	f.wantEmail("s2", now.Add(time.Minute), "") // the verdict is kept
	// P1's own login under the new id is trusted again.
	f.apply(login("s2", "c@example.com", t0+90_000))
	f.wantEmail("s2", now, "c@example.com")
}

func TestARemovedOldIDAnchorDoesNotUndoTheCarry(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com")
	os.Remove(filepath.Join(sessionsDir(f.state), "s1.env")) // pruned
	f.proc(11, t0, "s2")
	f.wantEmail("s2", now, "a@example.com")
}

// R5 — a resumed conversation sends its start events under a throwaway session id that
// nothing ties to the process, and the anchors of other ids are never borrowed on timing
// alone: any process of any config directory could have written them.

func TestResumedSessionNeverBorrowsTheStartAnchorOfAnotherID(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.startAnchor("throwaway", "a@example.com", t0+20) // started at the very time of the process
	got := f.resolve("real", now)
	if got.Email != "" || got.Level != Unknown {
		t.Errorf("Resolve = %+v, want unknown", got)
	}
	f.wantEmail("real", now.Add(time.Hour), "")
}

func TestAnotherProfilesEventsAreNotTakenWhenTheProcessOwnEventsAreMissing(t *testing.T) {
	f1 := newFixture(t)
	f2 := f1.otherProfile()
	now := at(t0 + 10_000)
	f1.install(0, now)
	f1.proc(21, t0, "real") // profile 1: a resumed conversation whose own start events never arrived
	f2.proc(22, t0+500, "other-real")
	f2.startAnchor("other-throwaway", "b@example.com", t0+520) // profile 2's, nearly simultaneous
	f2.startAnchor("other-fresh", "c@example.com", t0+400)
	f1.wantEmail("real", now, "")
	// Profile 2's own fresh session reads its own anchor.
	f2.proc(23, t0+300, "other-fresh")
	f2.wantEmail("other-fresh", now, "c@example.com")
}

func TestResumedSessionAnchorsOnItsFirstLoginAndKeepsItAcrossClear(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.wantEmail("real", now, "")
	f.apply(login("real", "c@example.com", t0+12_000))
	if got := f.wantEmail("real", now, "c@example.com"); got.Level != Confirmed {
		t.Errorf("로그인한 재개 세션: %+v", got)
	}
	f.proc(21, t0, "cleared") // /clear
	f.wantEmail("cleared", now.Add(time.Minute), "c@example.com")
}

func TestStartAnchorOfTheSessionItselfNeedsNoSearch(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 1_000)
	f.install(0, now)
	f.proc(21, t0, "s1")
	f.startAnchor("s1", "a@example.com", t0+20)
	f.wantEmail("s1", now, "a@example.com")
}

// A resumed session keeps the id of the conversation it resumes, so that id may carry an
// anchor and a ref from an earlier life of the same conversation, in a process that has
// ended. Both belong to that other process, not to this one.

func (f *fixture) previousLife(id string, startedMs int64, email string) {
	f.t.Helper()
	f.proc(30, startedMs, id)
	f.startAnchor(id, email, startedMs+20)
	f.wantEmail(id, at(startedMs+10_000), email) // the render that left a ref and a pid file behind
	os.Remove(filepath.Join(f.config, "sessions", "30.json"))
}

func TestResumedSessionIgnoresTheAnchorOfItsPreviousProcessLife(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.previousLife("real", t0-86_400_000, "old@example.com")
	f.proc(31, t0, "real")       // claude --resume real: a new process
	f.wantEmail("real", now, "") // the old life's account says nothing about this process
}

func TestLoginAfterAResumeSurvivesClear(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.previousLife("real", t0-86_400_000, "old@example.com")
	f.proc(31, t0, "real")
	f.wantEmail("real", now, "")
	f.apply(login("real", "c@example.com", t0+12_000))
	f.wantEmail("real", now, "c@example.com")
	f.proc(31, t0, "cleared") // /clear
	f.wantEmail("cleared", now.Add(time.Minute), "c@example.com")
}

func TestInSessionResumeOfAnOlderConversationKeepsTheProcessAccount(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.previousLife("older", t0-86_400_000, "old@example.com")
	f.proc(31, t0, "current")
	f.apply(login("current", "c@example.com", t0+5000))
	f.wantEmail("current", now, "c@example.com")
	f.proc(31, t0, "older") // /resume of the older conversation inside the same process
	f.wantEmail("older", now.Add(time.Minute), "c@example.com")
}

// R14 — the rate-limit windows a session kept belong to one account only within one
// boundary: the process that runs it and its last in-session login or logout.

func (f *fixture) boundary(id string, parent int, now time.Time) string {
	return Boundary(Input{StateDir: f.state, ConfigDir: f.config, SessionID: id, Parent: parent, Now: now})
}

func TestBoundaryNamesTheProcessAndTheLastLogin(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	want := "11-" + strconv.FormatInt(t0, 10) + "-0"
	if got := f.boundary("s1", 0, now); got != want {
		t.Fatalf("Boundary = %q, want %q", got, want)
	}
	f.startAnchor("s1", "a@example.com", t0+20) // a start anchor is not an authentication
	if got := f.boundary("s1", 0, now); got != want {
		t.Errorf("시작 앵커가 경계를 바꿨다: %q", got)
	}
	f.apply(login("s1", "a@example.com", t0+5000))
	if got := f.boundary("s1", 0, now); got != "11-"+strconv.FormatInt(t0, 10)+"-"+strconv.FormatInt(t0+5000, 10) {
		t.Errorf("로그인 뒤 Boundary = %q", got)
	}
	f.apply(logout("s1", t0+9000))
	if got := f.boundary("s1", 0, now); got != "11-"+strconv.FormatInt(t0, 10)+"-"+strconv.FormatInt(t0+9000, 10) {
		t.Errorf("로그아웃 뒤 Boundary = %q", got)
	}
}

func TestBoundaryDiffersWhenANewProcessResumesTheSameConversation(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(11, t0-86_400_000, "real")
	first := f.boundary("real", 0, now)
	f.proc(31, t0, "real") // claude --continue: another process, the same session id
	os.Remove(filepath.Join(f.config, "sessions", "11.json"))
	second := f.boundary("real", 0, now)
	if first == "" || second == "" || first == second {
		t.Errorf("재개한 프로세스의 경계가 같다: %q, %q", first, second)
	}
}

func TestBoundaryIgnoresALoginOfAnEarlierProcessLife(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.apply(login("real", "old@example.com", t0-86_400_000))
	f.proc(31, t0, "real")
	if got := f.boundary("real", 0, now); got != "31-"+strconv.FormatInt(t0, 10)+"-0" {
		t.Errorf("이전 삶의 로그인이 경계에 들어갔다: %q", got)
	}
}

func TestBoundaryIsEmptyWhenTheProcessCannotBeTold(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	if got := f.boundary("s1", 0, now); got != "" {
		t.Errorf("프로세스를 모르면 비어야 한다: %q", got)
	}
	f.proc(11, t0, "s1")
	for _, id := range []string{"", "../s1", "s1 "} {
		if got := f.boundary(id, 0, now); got != "" {
			t.Errorf("%q: %q", id, got)
		}
	}
}

func TestBoundaryWorksWithoutTheReceiver(t *testing.T) {
	f := newFixture(t) // no otel directory at all
	f.proc(11, t0, "s1")
	if got := f.boundary("s1", 0, at(t0+10_000)); got != "11-"+strconv.FormatInt(t0, 10)+"-0" {
		t.Errorf("수신기가 없어도 프로세스는 안다: %q", got)
	}
}

func TestTheParentProcessIsTrustedOnlyWhenItsOwnFileNamesTheSession(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.proc(12, t0+500, "s2")
	want := "11-" + strconv.FormatInt(t0, 10) + "-0"
	for _, parent := range []int{11, 0, 99, 12} { // the right one, none, no file, another session's
		if got := f.boundary("s1", parent, now); got != want {
			t.Errorf("parent %d: Boundary = %q, want %q", parent, got, want)
		}
	}
	// With the files gone the parent alone proves nothing.
	os.RemoveAll(filepath.Join(f.config, "sessions"))
	if got := f.boundary("s1", 11, now); got != "" {
		t.Errorf("파일이 없는데 부모만 믿었다: %q", got)
	}
}

// R15 — a sessions/<pid>.json whose process has ended (killed, crashed, rebooted) is not a
// process. A conversation a new process resumes must not inherit that process's confirmed
// account or rate-limit windows through it.

func (f *fixture) crashedLife(id string, startedMs int64, email string) {
	f.t.Helper()
	f.proc(11, startedMs, id)
	f.apply(login(id, email, startedMs+5_000))
	got := Resolve(Input{StateDir: f.state, ConfigDir: f.config, SessionID: id, Parent: 11, Now: at(startedMs + 10_000)})
	if got.Email != email || got.Level != Confirmed {
		f.t.Fatalf("the process that logs in shows its account: %+v", got)
	}
	f.dead(11) // killed: sessions/11.json stays
}

func TestADeadProcessFileDoesNotLendItsAccountToTheProcessThatResumesTheConversation(t *testing.T) {
	for _, parent := range []int{31, 0} { // Claude Code as the parent, and no parent at all
		f := newFixture(t)
		now := at(t0 + 10_000)
		f.install(0, now)
		f.crashedLife("real", t0-86_400_000, "a@example.com")
		f.proc(31, t0, "real") // claude --continue: a new process, the same conversation
		in := Input{StateDir: f.state, ConfigDir: f.config, SessionID: "real", Parent: parent, Now: now}
		if got := Resolve(in); got.Email != "" {
			t.Errorf("parent %d: 죽은 프로세스의 확정 계정을 물려받았다: %+v", parent, got)
		}
		if got := Boundary(in); !strings.HasPrefix(got, "31-") {
			t.Errorf("parent %d: 한도 경계가 새 프로세스가 아니다: %q", parent, got)
		}
	}
}

func TestTheRefOfAProcessThatNoLongerRunsIsNotTrusted(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.crashedLife("real", t0-86_400_000, "a@example.com") // leaves session-real.ref naming process 11
	if _, ok := readRef(f.state, "real"); !ok {
		t.Fatal("the render did not leave a ref")
	}
	f.dead(11)
	if got := f.boundary("real", 0, now); got != "" {
		t.Errorf("죽은 프로세스의 ref 를 믿었다: %q", got)
	}
}

func TestTheParentsOwnFileOutranksTheRefOfAnotherProcess(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(11, t0-86_400_000, "real")
	f.apply(login("real", "a@example.com", t0-86_400_000+5_000))
	f.wantEmail("real", at(t0-86_400_000+10_000), "a@example.com") // ref names 11, which still runs
	f.proc(31, t0, "real")                                         // both process files name the conversation
	if got := f.boundary("real", 31, now); !strings.HasPrefix(got, "31-") {
		t.Errorf("부모의 파일보다 이전 ref 를 먼저 믿었다: %q", got)
	}
	if got := f.resolveAs("real", 31, now); got.Email != "" {
		t.Errorf("이전 프로세스의 로그인을 물려받았다: %+v", got)
	}
}

func TestOfTwoLiveFilesForOneSessionTheLatestStartedProcessWins(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(11, t0-86_400_000, "real")
	f.proc(31, t0, "real")
	want := "31-" + strconv.FormatInt(t0, 10) + "-0"
	if got := f.boundary("real", 0, now); got != want {
		t.Errorf("파일명 순서로 먼저 나온 프로세스를 골랐다: %q, want %q", got, want)
	}
}

func TestTheLivenessCheckSeesThisProcessAndAnEndedOne(t *testing.T) {
	if !processAlive(os.Getpid()) {
		t.Error("이 프로세스는 살아 있다")
	}
	cmd := exec.Command(os.Args[0], "-test.run=NoSuchTest")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if processAlive(cmd.ProcessState.Pid()) {
		t.Error("끝난 프로세스를 살아 있다고 봤다")
	}
	if processAlive(0) || processAlive(-1) {
		t.Error("pid 0 과 음수는 프로세스가 아니다")
	}
}

// 세대는 시각이 아니라 번호라서 시계가 어디를 가리키든 앞선 세대의 앵커는 의심받는다.
func TestAnAnchorOfAnEarlierGenerationIsSuspectWhateverItsTimeSays(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.clockAt(t0 + 1_000_000_000) // the receiver's clock ran far ahead before it was corrected back
	f.apply(login("s1", "a@example.com", t0+900))
	f.wantEmail("s1", now, "a@example.com")
	f.gen++
	if err := WriteGeneration(f.state, f.gen); err != nil {
		t.Fatal(err)
	}
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("시각이 더 늦어도 앞선 세대의 앵커는 의심해야 한다: %+v", got)
	}
}

func TestAnAnchorWithoutAGenerationNumberIsSuspect(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	body := fmt.Sprintf("email=a@example.com\nkind=login\nts=%d\nseen=%d\n", t0+900, t0+900)
	if err := os.WriteFile(filepath.Join(sessionsDir(f.state), "s1.env"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("세대 번호가 없는 앵커는 어느 세대의 것인지 알 수 없다: %+v", got)
	}
}

func TestAnAppliedAnchorCarriesTheGenerationItWasStoredIn(t *testing.T) {
	dir := t.TempDir()
	if _, err := Apply(dir, login("s1", "a@example.com", t0), 7); err != nil {
		t.Fatal(err)
	}
	if got, ok := Read(dir, "s1"); !ok || got.Gen != 7 {
		t.Errorf("Read = %+v, %v; want gen 7", got, ok)
	}
	if _, err := Apply(dir, login("s1", "b@example.com", t0+1000), 9); err != nil {
		t.Fatal(err)
	}
	if got, _ := Read(dir, "s1"); got.Gen != 9 {
		t.Errorf("다시 저장한 앵커는 그때의 세대를 따른다: %+v", got)
	}
}

// 시작하는 수신기의 세대는 파일이 가리키는 번호와 이미 저장된 모든 앵커의 번호보다 크다.
func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func anchorBody(gen string) string {
	return fmt.Sprintf("email=a@example.com\nkind=login\nts=%d\nseen=%d\ngen=%s\n", t0, t0, gen)
}

func TestNextGenerationIsPastTheFileAndEveryStoredAnchor(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, state string)
		want  int64
	}{
		{"nothing stored", func(*testing.T, string) {}, 1},
		{"the file alone", func(t *testing.T, state string) { writeFile(t, generationPath(state), "5\n") }, 6},
		{"an old file that holds a time", func(t *testing.T, state string) { writeFile(t, generationPath(state), "1700000000000\n") }, 1_700_000_000_001},
		{"an anchor ahead of the file", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), "5\n")
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("9"))
		}, 10},
		{"an anchor when the file is gone", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("9"))
		}, 10},
		{"a carried anchor in the pid files", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), "5\n")
			writeFile(t, filepath.Join(state, "pids", "11-1.env"), "session=s1\nsrc=x\n"+anchorBody("12"))
		}, 13},
		{"the highest of several", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), "20\n")
			writeFile(t, filepath.Join(sessionsDir(state), "a.env"), anchorBody("9"))
			writeFile(t, filepath.Join(sessionsDir(state), "b.env"), anchorBody("30"))
			writeFile(t, filepath.Join(sessionsDir(state), "c.env"), anchorBody("4"))
		}, 31},
		{"files that are not anchors", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), "email=\nkind=login\nts=1\ngen=99\n") // no email: no anchor
			writeFile(t, filepath.Join(sessionsDir(state), "s2.env.tmp"), anchorBody("99"))
			writeFile(t, filepath.Join(state, "pids", "session-s1.ref"), "proc=11-1\nts=1\ngen=99\n")
			if err := os.MkdirAll(filepath.Join(sessionsDir(state), "dir.env"), 0o700); err != nil { // a directory is not an anchor
				t.Fatal(err)
			}
		}, 1},
		{"a link is followed as a reader follows it", func(t *testing.T, state string) {
			target := filepath.Join(t.TempDir(), "elsewhere.env")
			writeFile(t, target, anchorBody("9"))
			if err := os.MkdirAll(sessionsDir(state), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, filepath.Join(sessionsDir(state), "s1.env")); err != nil {
				t.Fatal(err)
			}
		}, 10},
		{"a link whose target is gone is skipped", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), "5\n")
			if err := os.MkdirAll(sessionsDir(state), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(filepath.Join(state, "nowhere.env"), filepath.Join(sessionsDir(state), "s1.env")); err != nil {
				t.Fatal(err)
			}
		}, 6},
		// An anchor number that is not a usable number counts as 0 for the scan, as it does for a
		// reader, which doubts the anchor: it neither fails the start nor lifts the count.
		{"a number out of range in an anchor", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("99999999999999999999"))
		}, 1},
		{"the largest int64 in an anchor", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("9223372036854775807"))
		}, 1},
		{"a negative number in an anchor", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("-5"))
		}, 1},
		{"text in an anchor", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), "5\n")
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("soon"))
		}, 6},
		{"the highest anchor a start counts on", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody(strconv.FormatInt(MaxGeneration-GenerationRunway, 10)))
		}, MaxGeneration - GenerationRunway + 1},
		{"one past the bound is no number", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody(strconv.FormatInt(MaxGeneration+1, 10)))
		}, 1},
		{"the highest file a start counts on", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), strconv.FormatInt(MaxGeneration-GenerationRunway, 10)+"\n")
		}, MaxGeneration - GenerationRunway + 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			state := t.TempDir()
			c.setup(t, state)
			got, err := NextGeneration(state)
			if err != nil || got != c.want {
				t.Errorf("NextGeneration = %d, %v; want %d", got, err, c.want)
			}
		})
	}
}

// 세대를 정할 수 없으면 추측하지 않고 오류를 돌려준다.
func TestNextGenerationFailsWhenTheStateCannotBeSeenWhole(t *testing.T) {
	root := os.Geteuid() == 0
	cases := []struct {
		name    string
		setup   func(t *testing.T, state string)
		needsFS bool // a permission the superuser ignores
	}{
		{"a generation file that is text", func(t *testing.T, state string) { writeFile(t, generationPath(state), "soon\n") }, false},
		{"an empty generation file", func(t *testing.T, state string) { writeFile(t, generationPath(state), "") }, false},
		{"a negative generation", func(t *testing.T, state string) { writeFile(t, generationPath(state), "-3\n") }, false},
		{"generation zero", func(t *testing.T, state string) { writeFile(t, generationPath(state), "0\n") }, false},
		{"a generation out of range", func(t *testing.T, state string) { writeFile(t, generationPath(state), "99999999999999999999\n") }, false},
		{"the largest int64 as the generation", func(t *testing.T, state string) { writeFile(t, generationPath(state), "9223372036854775807\n") }, false},
		{"a generation with nothing above it", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), strconv.FormatInt(MaxGeneration, 10)+"\n")
		}, false},
		{"a generation without the runway a run counts in", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), strconv.FormatInt(MaxGeneration-GenerationRunway+1, 10)+"\n")
		}, false},
		{"an anchor without the runway a run counts in", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody(strconv.FormatInt(MaxGeneration-GenerationRunway+1, 10)))
		}, false},
		{"an anchor at the bound", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody(strconv.FormatInt(MaxGeneration, 10)))
		}, false},
		{"a generation file that cannot be read", func(t *testing.T, state string) {
			writeFile(t, generationPath(state), "5\n")
			if err := os.Chmod(generationPath(state), 0o000); err != nil {
				t.Fatal(err)
			}
		}, true},
		{"an anchors directory that cannot be listed", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("9"))
			if err := os.Chmod(sessionsDir(state), 0o300); err != nil {
				t.Fatal(err)
			}
		}, true},
		{"an anchor that cannot be read", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(sessionsDir(state), "s1.env"), anchorBody("9"))
			writeFile(t, filepath.Join(sessionsDir(state), "s2.env"), anchorBody("3"))
			if err := os.Chmod(filepath.Join(sessionsDir(state), "s2.env"), 0o000); err != nil {
				t.Fatal(err)
			}
		}, true},
		{"a carried-anchors directory that cannot be listed", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(state, "pids", "11-1.env"), anchorBody("9"))
			if err := os.Chmod(filepath.Join(state, "pids"), 0o300); err != nil {
				t.Fatal(err)
			}
		}, true},
		{"a carried anchor that cannot be read", func(t *testing.T, state string) {
			writeFile(t, filepath.Join(state, "pids", "11-1.env"), anchorBody("9"))
			if err := os.Chmod(filepath.Join(state, "pids", "11-1.env"), 0o000); err != nil {
				t.Fatal(err)
			}
		}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.needsFS && root {
				t.Skip("root 는 읽기 권한 제한을 받지 않는다")
			}
			state := t.TempDir()
			t.Cleanup(func() { // let the temporary directory be removed
				filepath.WalkDir(state, func(path string, d fs.DirEntry, err error) error { os.Chmod(path, 0o700); return nil })
				filepath.WalkDir(state, func(path string, d fs.DirEntry, err error) error { os.Chmod(path, 0o700); return nil })
			})
			c.setup(t, state)
			if got, err := NextGeneration(state); err == nil {
				t.Errorf("NextGeneration = %d, nil; want an error", got)
			}
		})
	}
}

// 쓸 수 없는 세대(0, 음수, 범위 밖)는 기록하지 않는다.
func TestWriteGenerationRecordsOnlyAGeneration(t *testing.T) {
	for _, bad := range []int64{0, -1, math.MinInt64, math.MaxInt64, MaxGeneration + 1} {
		state := t.TempDir()
		if err := WriteGeneration(state, bad); err == nil {
			t.Errorf("WriteGeneration(%d) 가 기록했다", bad)
		}
		if _, err := os.Stat(generationPath(state)); err == nil {
			t.Errorf("WriteGeneration(%d) 가 파일을 남겼다", bad)
		}
	}
	for _, good := range []int64{1, 2, MaxGeneration} {
		state := t.TempDir()
		if err := WriteGeneration(state, good); err != nil {
			t.Errorf("WriteGeneration(%d): %v", good, err)
		}
	}
}

// 새 실행은 자기 세대를 쓰기 전까지 읽는 쪽이 믿을 세대와 하트비트가 없게 거둔다.
func TestWithdrawTakesBackTheGenerationAndTheHeartbeat(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 60_000)
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+900))
	if got := f.wantEmail("s1", now, "a@example.com"); got.Suspect {
		t.Fatalf("거두기 전에는 의심하지 않는다: %+v", got)
	}
	if err := Withdraw(f.state); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{generationPath(f.state), filepath.Join(f.state, "otel", "heartbeat")} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("거두지 않은 파일이 남았다: %s (%v)", path, err)
		}
	}
	if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
		t.Errorf("세대와 하트비트를 거둔 뒤에는 의심해야 한다: %+v", got)
	}
	if err := Withdraw(f.state); err != nil { // 이미 없어도 오류 없이 끝난다
		t.Errorf("이미 없는 파일을 거두려다 오류: %v", err)
	}
}

// 지울 수 없는 파일은 오류로 알린다(쓸 수 없는 디렉터리).
func TestWithdrawReportsAFileItCannotRemove(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 쓰기 권한 제한을 받지 않는다")
	}
	f := newFixture(t)
	f.install(0, at(t0))
	otel := filepath.Join(f.state, "otel")
	if err := os.Chmod(otel, 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(otel, 0o700)
	if err := Withdraw(f.state); err == nil {
		t.Error("지울 수 없는 파일을 오류 없이 지나쳤다")
	}
	if _, err := os.Stat(generationPath(f.state)); err != nil {
		t.Errorf("지우지 못한 세대 파일이 사라졌다: %v", err)
	}
}

// 수신기가 상한을 넘는 번호를 찍지 못한다.
func TestNextLossStopsAtTheBound(t *testing.T) {
	if n, ok := NextLoss(1); !ok || n != 2 {
		t.Errorf("NextLoss(1) = %d, %v", n, ok)
	}
	if n, ok := NextLoss(MaxGeneration - 1); !ok || n != MaxGeneration {
		t.Errorf("NextLoss(Max-1) = %d, %v", n, ok)
	}
	if n, ok := NextLoss(MaxGeneration); ok || n != MaxGeneration {
		t.Errorf("NextLoss(Max) = %d, %v; want the bound back and false", n, ok)
	}
}

// 쓸 수 없는 번호가 적힌 앵커는 세대 0 의 앵커처럼 의심한다(범위 오류가 가장 큰 번호로 읽히지 않는다).
func TestAnAnchorWhoseGenerationIsNotANumberIsSuspect(t *testing.T) {
	for _, gen := range []string{"99999999999999999999", "9223372036854775807", "-5", "soon", "", strconv.FormatInt(MaxGeneration+1, 10)} {
		t.Run(gen, func(t *testing.T) {
			f := newFixture(t)
			now := at(t0 + 60_000)
			f.install(0, now)
			f.proc(11, t0, "s1")
			writeFile(t, filepath.Join(sessionsDir(f.state), "s1.env"), anchorBody(gen))
			if got := f.wantEmail("s1", now, "a@example.com"); !got.Suspect {
				t.Errorf("번호를 읽을 수 없는 앵커는 의심해야 한다: %+v", got)
			}
		})
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

func TestReceiverAliveOnlyWhileTheLockIsHeld(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(filepath.Join(state, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	if receiverAlive(state) {
		t.Error("잠금 파일이 없는데 수신기가 산다고 한다")
	}
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	if !receiverAlive(state) {
		t.Error("잠금을 쥐고 있는데 수신기가 없다고 한다")
	}
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	if receiverAlive(state) {
		t.Error("잠금을 놓았는데 수신기가 산다고 한다")
	}
	if _, err := os.Stat(lockPath(state)); err != nil {
		t.Errorf("잠금 파일이 사라졌다: %v", err)
	}
}

func TestReceiverAliveIsFalseWhenTheLockFileCannotBeOpened(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 읽기 권한 제한을 받지 않는다")
	}
	state := t.TempDir()
	if err := os.MkdirAll(filepath.Join(state, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := os.Chmod(lockPath(state), 0o000); err != nil {
		t.Fatal(err)
	}
	if receiverAlive(state) {
		t.Error("열 수 없는 잠금 파일을 산 수신기로 본다")
	}
}

func TestASecondLockerIsRefusedWhileTheFirstHoldsTheLock(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(filepath.Join(state, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
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

// 읽는 쪽의 짧은 공유 잠금은 수신기가 시작하는 것을 막지 못한다.
func TestASharedProbeDoesNotKeepAReceiverFromLocking(t *testing.T) {
	old := lockWait
	lockWait = 2 * time.Second
	defer func() { lockWait = old }()
	state := t.TempDir()
	if err := os.MkdirAll(filepath.Join(state, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	probe, err := os.OpenFile(lockPath(state), os.O_RDWR|os.O_CREATE, 0o600)
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

// 잠금을 조사하지 못하면(잠금을 지원하지 않는 파일시스템 등) 수신기가 산다고 보지 않는다.
func TestReceiverAliveIsFalseWhenTheProbeFails(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(filepath.Join(state, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := LockReceiver(state)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	old := flock
	flock = func(int, int) error { return syscall.ENOLCK }
	defer func() { flock = old }()
	if receiverAlive(state) {
		t.Error("조사에 실패했는데 수신기가 산다고 본다")
	}
}

// 잠금을 얻지 못하는 파일시스템에서는 수신기가 시작하지 못한다(상태를 보증하지 못한다).
func TestLockReceiverFailsWhenTheFilesystemCannotLock(t *testing.T) {
	state := t.TempDir()
	if err := os.MkdirAll(filepath.Join(state, "otel"), 0o700); err != nil {
		t.Fatal(err)
	}
	old := flock
	flock = func(int, int) error { return syscall.ENOLCK }
	defer func() { flock = old }()
	if _, err := LockReceiver(state); err == nil || errors.Is(err, ErrReceiverRunning) {
		t.Errorf("LockReceiver = %v, want a lock error that is not ErrReceiverRunning", err)
	}
}
