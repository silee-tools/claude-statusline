package anchor

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func ev(name, id, email string, ts int64) Event {
	return Event{Name: name, SessionID: id, Email: email, TS: ts}
}

// testGen is the receiver generation the tests store their anchors under.
const testGen = int64(1)

func login(id, email string, ts int64) Event {
	return Event{Name: "auth", SessionID: id, Email: email, Action: "login", Success: "true", TS: ts}
}

func logout(id string, ts int64) Event {
	return Event{Name: "auth", SessionID: id, Action: "logout", Success: "true", TS: ts}
}

func mustApply(t *testing.T, dir string, e Event) bool {
	t.Helper()
	changed, err := Apply(dir, e, testGen)
	if err != nil {
		t.Fatalf("Apply(%+v): %v", e, err)
	}
	return changed
}

func wantAnchor(t *testing.T, dir, id string, want Anchor) {
	t.Helper()
	got, ok := Read(dir, id)
	got.Seen, got.Gen = 0, 0 // when and under which generation the receiver stored it is checked on its own
	if !ok || got != want {
		t.Fatalf("Read(%s) = %+v, %v; want %+v", id, got, ok, want)
	}
}

func wantNoAnchor(t *testing.T, dir, id string) {
	t.Helper()
	if got, ok := Read(dir, id); ok {
		t.Fatalf("Read(%s) = %+v, 앵커가 없어야 한다", id, got)
	}
}

func TestStartOnlyEventsCreateAStartAnchor(t *testing.T) {
	for _, name := range []string{"managed_settings_resolved", "plugin_loaded", "claude_code.managed_settings_resolved", "claude_code.plugin_loaded"} {
		dir := t.TempDir()
		if !mustApply(t, dir, ev(name, "s1", "a@example.com", 1000)) {
			t.Errorf("%s: 앵커를 쓰지 않았다", name)
		}
		wantAnchor(t, dir, "s1", Anchor{Email: "a@example.com", Kind: KindStart, TS: 1000})
	}
}

func TestNonStartEventsNeverCreateAnAnchor(t *testing.T) {
	// /clear 한 새 session.id 의 첫 이벤트는 user_prompt 이고 그 시점의 이메일은 설정 파일 값이다.
	for _, name := range []string{"user_prompt", "api_error", "api_request", "tool_result", "", "claude_code.user_prompt"} {
		dir := t.TempDir()
		if mustApply(t, dir, ev(name, "s1", "a@example.com", 1000)) {
			t.Errorf("%q: 앵커를 쓰면 안 된다", name)
		}
		wantNoAnchor(t, dir, "s1")
	}
}

func TestStartEventDoesNotOverwriteAnExistingAnchor(t *testing.T) {
	dir := t.TempDir()
	mustApply(t, dir, ev("managed_settings_resolved", "s1", "a@example.com", 1000))
	if mustApply(t, dir, ev("plugin_loaded", "s1", "b@example.com", 1100)) {
		t.Error("두 번째 시작 이벤트가 앵커를 덮었다")
	}
	wantAnchor(t, dir, "s1", Anchor{Email: "a@example.com", Kind: KindStart, TS: 1000})
}

func TestSuccessfulLoginReplacesTheAnchor(t *testing.T) {
	dir := t.TempDir()
	mustApply(t, dir, ev("managed_settings_resolved", "s1", "a@example.com", 1000))
	mustApply(t, dir, login("s1", "b@example.com", 2000))
	wantAnchor(t, dir, "s1", Anchor{Email: "b@example.com", Kind: KindLogin, TS: 2000})
}

func TestFailedOrIncompleteLoginIsIgnored(t *testing.T) {
	dir := t.TempDir()
	mustApply(t, dir, ev("managed_settings_resolved", "s1", "a@example.com", 1000))
	failed := login("s1", "b@example.com", 2000)
	failed.Success = "false"
	noEmail := login("s1", "", 2100)
	noSuccess := login("s1", "c@example.com", 2200)
	noSuccess.Success = ""
	other := login("s1", "d@example.com", 2300)
	other.Action = "refresh"
	for _, e := range []Event{failed, noEmail, noSuccess, other} {
		if mustApply(t, dir, e) {
			t.Errorf("%+v: 앵커를 바꾸면 안 된다", e)
		}
	}
	wantAnchor(t, dir, "s1", Anchor{Email: "a@example.com", Kind: KindStart, TS: 1000})
}

func TestLogoutClearsTheEmail(t *testing.T) {
	dir := t.TempDir()
	mustApply(t, dir, login("s1", "a@example.com", 1000))
	mustApply(t, dir, logout("s1", 2000))
	wantAnchor(t, dir, "s1", Anchor{Email: "", Kind: KindLogout, TS: 2000})
}

func TestFailedLogoutIsIgnored(t *testing.T) {
	dir := t.TempDir()
	mustApply(t, dir, login("s1", "a@example.com", 1000))
	failed := logout("s1", 2000)
	failed.Success = "false"
	if mustApply(t, dir, failed) {
		t.Error("실패한 로그아웃이 앵커를 지웠다")
	}
	wantAnchor(t, dir, "s1", Anchor{Email: "a@example.com", Kind: KindLogin, TS: 1000})
}

func TestEventsArrivingOutOfOrderKeepTheLatestByEventTime(t *testing.T) {
	dir := t.TempDir()
	// 로그인(2000)이 시작(1000)보다 먼저 도착해도 시작은 이미 있는 앵커를 덮지 못한다.
	mustApply(t, dir, login("s1", "b@example.com", 2000))
	mustApply(t, dir, ev("managed_settings_resolved", "s1", "a@example.com", 1000))
	wantAnchor(t, dir, "s1", Anchor{Email: "b@example.com", Kind: KindLogin, TS: 2000})
	// 로그아웃(3000) 뒤에 늦게 도착한 옛 로그인(2500)은 무시한다.
	mustApply(t, dir, logout("s1", 3000))
	if mustApply(t, dir, login("s1", "c@example.com", 2500)) {
		t.Error("더 이른 이벤트가 최신 앵커를 덮었다")
	}
	wantAnchor(t, dir, "s1", Anchor{Email: "", Kind: KindLogout, TS: 3000})
	// 같은 시각은 받아들인다.
	mustApply(t, dir, login("s1", "d@example.com", 3000))
	wantAnchor(t, dir, "s1", Anchor{Email: "d@example.com", Kind: KindLogin, TS: 3000})
}

func TestInvalidSessionIDsAndEmailsAreIgnored(t *testing.T) {
	dir := t.TempDir()
	long := strings.Repeat("a", 65)
	for _, id := range []string{"", "../x", "a/b", "a b", long, ".", ".."} {
		if mustApply(t, dir, ev("managed_settings_resolved", id, "a@example.com", 1000)) {
			t.Errorf("session.id %q 를 받아들였다", id)
		}
	}
	for _, email := range []string{"", "a@example.com\nkind=login", "a@example.com\x1b[31m", strings.Repeat("a", 300) + "@example.com"} {
		if mustApply(t, dir, ev("managed_settings_resolved", "s1", email, 1000)) {
			t.Errorf("email %q 를 받아들였다", email)
		}
	}
	wantNoAnchor(t, dir, "s1")
	// 상태 디렉터리 밖으로 쓰지 않았다.
	if ents, _ := os.ReadDir(filepath.Join(dir, "otel", "sessions")); len(ents) != 0 {
		t.Errorf("무효 입력이 파일을 남겼다: %v", ents)
	}
}

func TestAnchorFileIsPrivateAndHoldsOnlyTheFiveFields(t *testing.T) {
	dir := t.TempDir()
	old := clock
	t.Cleanup(func() { clock = old })
	clock = func() time.Time { return time.UnixMilli(5678) }
	mustApply(t, dir, ev("managed_settings_resolved", "s1", "a@example.com", 1234))
	path := filepath.Join(dir, "otel", "sessions", "s1.env")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "email=a@example.com\nkind=start\nts=1234\nseen=5678\ngen=1\n" {
		t.Errorf("파일 내용 = %q", b)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v", info.Mode().Perm())
	}
	if info, _ := os.Stat(filepath.Dir(path)); info.Mode().Perm() != 0o700 {
		t.Errorf("디렉터리 mode = %v", info.Mode().Perm())
	}
}

func TestReadRejectsDamagedFiles(t *testing.T) {
	dir := t.TempDir()
	sessions := filepath.Join(dir, "otel", "sessions")
	os.MkdirAll(sessions, 0o700)
	for name, body := range map[string]string{
		"nokind":       "email=a@example.com\nts=5\n",
		"badkind":      "email=a@example.com\nkind=weird\nts=5\n",
		"nots":         "email=a@example.com\nkind=login\n",
		"startnoemail": "kind=start\nts=5\n",
	} {
		os.WriteFile(filepath.Join(sessions, name+".env"), []byte(body), 0o600)
		if got, ok := Read(dir, name); ok {
			t.Errorf("%s: 손상된 파일을 앵커로 읽었다: %+v", name, got)
		}
	}
}

func TestApplyPrunesBeyondRetentionAndFileLimit(t *testing.T) {
	oldMax, oldRet := maxFiles, retention
	maxFiles, retention = 5, time.Hour
	defer func() { maxFiles, retention = oldMax, oldRet }()

	dir := t.TempDir()
	sessions := filepath.Join(dir, "otel", "sessions")
	os.MkdirAll(sessions, 0o700)
	stale := filepath.Join(sessions, "stale.env")
	os.WriteFile(stale, []byte("email=a@example.com\nkind=start\nts=1\n"), 0o600)
	at := time.Now().Add(-2 * time.Hour)
	os.Chtimes(stale, at, at)
	for i := 0; i < 8; i++ {
		mustApply(t, dir, ev("managed_settings_resolved", "n"+strconv.Itoa(i), "a@example.com", int64(1000+i)))
	}
	ents, _ := os.ReadDir(sessions)
	if len(ents) != 5 {
		t.Errorf("파일 %d개, 상한 5개", len(ents))
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("보존 기간이 지난 앵커가 남았다")
	}
	wantAnchor(t, dir, "n7", Anchor{Email: "a@example.com", Kind: KindStart, TS: 1007})
}

func TestAnAppliedAnchorRecordsWhenTheReceiverStoredIt(t *testing.T) {
	// 앵커는 이벤트 시각(ts)과 별개로 수신기가 저장한 시각(seen)을 가진다. 보존 기간의 기준은 seen 이다.
	old := clock
	t.Cleanup(func() { clock = old })
	clock = func() time.Time { return time.UnixMilli(5000) }
	dir := t.TempDir()
	mustApply(t, dir, ev("managed_settings_resolved", "s1", "a@example.com", 1000))
	got, ok := Read(dir, "s1")
	if !ok || got.TS != 1000 || got.Seen != 5000 {
		t.Fatalf("Read = %+v, %v; want ts 1000 and seen 5000", got, ok)
	}
	clock = func() time.Time { return time.UnixMilli(9000) }
	mustApply(t, dir, login("s1", "b@example.com", 2000))
	if got, _ := Read(dir, "s1"); got.TS != 2000 || got.Seen != 9000 {
		t.Errorf("로그인으로 바뀐 앵커 = %+v, want ts 2000 and seen 9000", got)
	}
}
