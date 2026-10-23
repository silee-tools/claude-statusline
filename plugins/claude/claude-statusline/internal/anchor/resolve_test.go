package anchor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// t0 is a process start time in unix milliseconds.
const t0 = int64(1_700_000_000_000)

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

// install makes the receiver's directory and a fresh heartbeat exist.
func (f *fixture) install(heartbeatAge time.Duration, now time.Time) {
	f.t.Helper()
	if err := os.MkdirAll(sessionsDir(f.state), 0o700); err != nil {
		f.t.Fatal(err)
	}
	if heartbeatAge < 0 {
		return
	}
	if err := TouchHeartbeat(f.state, now.Add(-heartbeatAge)); err != nil {
		f.t.Fatal(err)
	}
}

// proc writes the file Claude Code keeps for a running process.
func (f *fixture) proc(pid int, startedMs int64, sessionID string) {
	f.t.Helper()
	b, _ := json.Marshal(map[string]any{"pid": pid, "sessionId": sessionID, "startedAt": startedMs, "cwd": "/tmp/example"})
	if err := os.WriteFile(filepath.Join(f.config, "sessions", strconv.Itoa(pid)+".json"), b, 0o600); err != nil {
		f.t.Fatal(err)
	}
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

func at(ms int64) time.Time { return time.UnixMilli(ms) }

func (f *fixture) wantEmail(id string, now time.Time, want string) Result {
	f.t.Helper()
	got := f.resolve(id, now)
	if got.Email != want {
		f.t.Fatalf("Resolve(%s).Email = %q, want %q (%+v)", id, got.Email, want, got)
	}
	return got
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

func TestClearUsesTheSourceAnchorWhenItBecameNewerThanTheMirror(t *testing.T) {
	f := newFixture(t)
	now := time.Now()
	f.install(0, now)
	f.proc(11, t0, "s1")
	f.apply(login("s1", "a@example.com", t0+5000))
	f.wantEmail("s1", now, "a@example.com")
	f.apply(login("s1", "b@example.com", t0+8000)) // arrives after the last render, before /clear
	f.proc(11, t0, "s2")
	f.wantEmail("s2", now, "b@example.com")
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
	f.wantEmail("s1", now, "a@example.com")
	os.RemoveAll(filepath.Join(f.config, "sessions"))
	f.wantEmail("s1", now, "a@example.com")
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

// R5 — --resume and --continue emit their start events under a throwaway session id.

func (f *fixture) startAnchor(id, email string, ts int64) {
	f.t.Helper()
	f.apply(ev("managed_settings_resolved", id, email, ts))
}

func TestResumeAdoptsTheOrphanStartAnchorNearTheProcessStart(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.startAnchor("throwaway", "a@example.com", t0+20)
	got := f.wantEmail("real", now, "a@example.com")
	if got.AnchorTS != t0+20 {
		t.Errorf("AnchorTS = %d", got.AnchorTS)
	}
	// The adoption is kept with the process: the throwaway anchor may be pruned later.
	os.Remove(filepath.Join(sessionsDir(f.state), "throwaway.env"))
	f.wantEmail("real", now.Add(time.Minute), "a@example.com")
	// And survives /clear.
	f.proc(21, t0, "real2")
	f.wantEmail("real2", now.Add(2*time.Minute), "a@example.com")
}

func TestResumeIgnoresAnchorsOfOtherLiveProcesses(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.proc(22, t0+500, "live2") // another running session started at nearly the same time
	f.startAnchor("live2", "b@example.com", t0+520)
	f.startAnchor("throwaway", "a@example.com", t0+20)
	f.wantEmail("real", now, "a@example.com")
}

func TestResumeWithOnlyALiveProcessCandidateStaysUnknown(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.proc(22, t0+500, "live2")
	f.startAnchor("live2", "b@example.com", t0+520)
	f.wantEmail("real", now, "")
}

func TestResumeWithDisagreeingCandidatesIsUnknownAndNotSearchedAgain(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.startAnchor("throwaway1", "a@example.com", t0+20)
	f.startAnchor("throwaway2", "b@example.com", t0+900)
	f.wantEmail("real", now, "")
	os.Remove(filepath.Join(sessionsDir(f.state), "throwaway2.env"))
	f.wantEmail("real", now.Add(time.Minute), "") // the verdict was stored
}

func TestResumeAgreeingCandidatesAreAdopted(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.startAnchor("throwaway1", "a@example.com", t0+20)
	f.startAnchor("throwaway2", "a@example.com", t0+900)
	f.wantEmail("real", now, "a@example.com")
}

func TestResumeWaitsUntilTheProcessIsEightSecondsOld(t *testing.T) {
	f := newFixture(t)
	f.install(0, time.Now())
	f.proc(21, t0, "real")
	f.startAnchor("throwaway", "a@example.com", t0+20)
	f.wantEmail("real", at(t0+7_999), "") // too young: held, not decided
	f.wantEmail("real", at(t0+8_000), "a@example.com")
}

func TestResumeOnlyConsidersStartAnchorsWithinThreeSecondsOfTheProcessStart(t *testing.T) {
	cases := []struct {
		name string
		ts   int64
		want string
	}{
		{"+3초", t0 + 3000, "a@example.com"},
		{"-3초", t0 - 3000, "a@example.com"},
		{"+3.001초", t0 + 3001, ""},
		{"-3.001초", t0 - 3001, ""},
	}
	for _, c := range cases {
		f := newFixture(t)
		now := at(t0 + 10_000)
		f.install(0, now)
		f.proc(21, t0, "real")
		f.startAnchor("throwaway", "a@example.com", c.ts)
		if got := f.resolve("real", now).Email; got != c.want {
			t.Errorf("%s: Email = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestResumeIgnoresLoginAndLogoutAnchors(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.proc(21, t0, "real")
	f.apply(login("other-login", "a@example.com", t0+20))
	f.apply(logout("other-logout", t0+30))
	f.wantEmail("real", now, "")
}

func TestStartAnchorOfTheSessionItselfNeedsNoSearch(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 1_000) // younger than eight seconds
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
	f.proc(31, t0, "real")                               // claude --resume real: a new process
	f.startAnchor("throwaway", "new@example.com", t0+20) // its start events use another id
	f.wantEmail("real", now, "new@example.com")
}

func TestLoginAfterAResumeSurvivesClear(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.previousLife("real", t0-86_400_000, "old@example.com")
	f.proc(31, t0, "real")
	f.startAnchor("throwaway", "new@example.com", t0+20)
	f.wantEmail("real", now, "new@example.com")
	f.apply(login("real", "c@example.com", t0+12_000))
	f.wantEmail("real", now, "c@example.com")
	f.proc(31, t0, "cleared") // /clear
	f.wantEmail("cleared", now.Add(time.Minute), "c@example.com")
}

func TestResumedSessionWithoutStartAnchorsInThisLifeIsUnknown(t *testing.T) {
	f := newFixture(t)
	now := at(t0 + 10_000)
	f.install(0, now)
	f.previousLife("real", t0-86_400_000, "old@example.com")
	f.proc(31, t0, "real")
	f.wantEmail("real", now, "") // the old life's account says nothing about this process
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
