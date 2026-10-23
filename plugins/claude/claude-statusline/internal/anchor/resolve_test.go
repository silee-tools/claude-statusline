package anchor

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// t0 is a process start time in unix milliseconds.
const t0 = int64(1_700_000_000_000)

// The fixtures name pids no machine is known to run, so every process is taken as running
// unless a test says it ended (fixture.dead).
func init() { alive = func(int) bool { return true } }

type fixture struct {
	t      *testing.T
	state  string
	config string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{t: t, state: t.TempDir(), config: t.TempDir()}
	if err := os.MkdirAll(filepath.Join(f.config, "sessions"), 0o755); err != nil {
		t.Fatal(err)
	}
	return f
}

// otherProfile is a second config directory that shares this fixture's state directory,
// as two Claude config directories of one user do.
func (f *fixture) otherProfile() *fixture {
	f.t.Helper()
	g := &fixture{t: f.t, state: f.state, config: f.t.TempDir()}
	if err := os.MkdirAll(filepath.Join(g.config, "sessions"), 0o755); err != nil {
		f.t.Fatal(err)
	}
	return g
}

// install makes the receiver's directory, a fresh heartbeat and a generation older than
// every anchor the tests store exist.
func (f *fixture) install(heartbeatAge time.Duration, now time.Time) {
	f.t.Helper()
	if err := os.MkdirAll(sessionsDir(f.state), 0o700); err != nil {
		f.t.Fatal(err)
	}
	if err := WriteGeneration(f.state, time.UnixMilli(1)); err != nil {
		f.t.Fatal(err)
	}
	if heartbeatAge < 0 {
		return
	}
	if err := TouchHeartbeat(f.state, now.Add(-heartbeatAge)); err != nil {
		f.t.Fatal(err)
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
	if _, err := Apply(f.state, e); err != nil {
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
// stored before the receiver's current generation is doubted until an event replaces it.

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
	if err := WriteGeneration(f.state, at(t0+30_000)); err != nil {
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
	if err := WriteGeneration(f.state, at(t0+30_000)); err != nil {
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

func TestRaiseGenerationNeverMovesTheGenerationBack(t *testing.T) {
	state := t.TempDir()
	os.MkdirAll(filepath.Join(state, "otel"), 0o700)
	if err := RaiseGeneration(state, at(t0+5_000)); err != nil {
		t.Fatal(err)
	}
	if got, _ := readGeneration(state); got != t0+5_000 {
		t.Fatalf("파일이 없으면 기록한다: %d", got)
	}
	if err := RaiseGeneration(state, at(t0+1_000)); err != nil {
		t.Fatal(err)
	}
	if got, _ := readGeneration(state); got != t0+5_000 {
		t.Errorf("이른 시각이 세대를 되돌렸다: %d", got)
	}
	if err := RaiseGeneration(state, at(t0+9_000)); err != nil {
		t.Fatal(err)
	}
	if got, _ := readGeneration(state); got != t0+9_000 {
		t.Errorf("늦은 시각은 세대를 올린다: %d", got)
	}
	// 시작은 WriteGeneration 으로 이전 실행의 값을 그대로 덮는다.
	if err := WriteGeneration(state, at(t0)); err != nil {
		t.Fatal(err)
	}
	if got, _ := readGeneration(state); got != t0 {
		t.Errorf("WriteGeneration 은 덮어쓴다: %d", got)
	}
}
