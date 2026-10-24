package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
	"github.com/silee-tools/claude-statusline/internal/input"
)

func TestAgentStateDirUsesOverrideOrXDGDefault(t *testing.T) {
	t.Setenv("AGENT_STATUS_STATE_DIR", "/tmp/agent-status-override")
	if got := agentStateDir("/tmp/home"); got != "/tmp/agent-status-override" {
		t.Fatalf("override = %q", got)
	}

	t.Setenv("AGENT_STATUS_STATE_DIR", "")
	t.Setenv("XDG_STATE_HOME", "/tmp/xdg-state")
	want := filepath.Join("/tmp/xdg-state", "claude-statusline", "agent-status")
	if got := agentStateDir("/tmp/home"); got != want {
		t.Fatalf("XDG root = %q, want %q", got, want)
	}

	t.Setenv("XDG_STATE_HOME", "")
	want = filepath.Join("/tmp/home", ".local", "state", "claude-statusline", "agent-status")
	if got := agentStateDir("/tmp/home"); got != want {
		t.Fatalf("fallback root = %q, want %q", got, want)
	}
}

func TestCompactStatusKeepsGHAlwaysAndAWSOnlyWhenNotHealthy(t *testing.T) {
	cases := []struct {
		name, gh, aws string
		healthy       bool
		want          []string
	}{
		{"정상 gh 상시 표시", "gh@a", "aws:ok", true, []string{"gh@a"}},
		{"불명도 표시", "gh@a?", "aws:?", false, []string{"gh@a?", "aws:?"}},
		{"저장소 밖 aws 이상", "", "aws:expired", false, []string{"aws:expired"}},
		{"저장소 밖 정상", "", "aws:ok", true, nil},
		{"aws 캐시 없음", "gh@a", "", false, []string{"gh@a"}},
	}
	for _, c := range cases {
		got := compactStatus(c.gh, c.aws, c.healthy)
		if len(got) != len(c.want) {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s: %q, want %q", c.name, got, c.want)
			}
		}
	}
}

// testGen is the receiver generation the fixtures store their anchors under.
const testGen = int64(1)

// accountFixture is a state directory with the receiver "installed": its sessions
// directory exists and its heartbeat is fresh.
func accountFixture(t *testing.T, now time.Time) (stateDir, configDir string) {
	t.Helper()
	stateDir, configDir = t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(stateDir, "otel", "sessions"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := anchor.TouchHeartbeat(stateDir, now); err != nil {
		t.Fatal(err)
	}
	if err := anchor.WriteGeneration(stateDir, testGen); err != nil {
		t.Fatal(err)
	}
	return stateDir, configDir
}

// runningProcess lets the statusline find the process of a session: only a login anchor of a
// known, running process is shown as confirmed. The test process stands in for Claude Code.
func runningProcess(t *testing.T, configDir, sessionID string) {
	t.Helper()
	dir := filepath.Join(configDir, "sessions")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`{"pid":%d,"sessionId":%q,"startedAt":1}`, os.Getpid(), sessionID)
	if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%d.json", os.Getpid())), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func startEvent(id, email string, ts int64) anchor.Event {
	return anchor.Event{Name: "managed_settings_resolved", SessionID: id, Email: email, TS: ts}
}

func loginEvent(id, email string, ts int64) anchor.Event {
	return anchor.Event{Name: "auth", SessionID: id, Email: email, Action: "login", Success: "true", TS: ts}
}

func slotText(t *testing.T, stateDir, configDir string, status input.Status, now time.Time) string {
	t.Helper()
	in := anchor.Input{StateDir: stateDir, ConfigDir: configDir, SessionID: status.SessionID, Now: now}
	return ansi.ReplaceAllString(accountSlot(in, status), "")
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func TestAccountSlotFollowsTheSessionsAnchorThroughLoginAndLogout(t *testing.T) {
	now := time.Now()
	stateDir, configDir := accountFixture(t, now)
	runningProcess(t, configDir, "s1")
	status := input.Status{SessionID: "s1"}
	anchor.Apply(stateDir, startEvent("s1", "a@example.com", 1000), testGen)
	anchor.Apply(stateDir, startEvent("s2", "other@example.com", 1000), testGen)
	if got := slotText(t, stateDir, configDir, status, now); got != "~a@example.com" {
		t.Fatalf("시작 앵커는 추정이다: %q", got)
	}
	anchor.Apply(stateDir, loginEvent("s1", "b@example.com", 2000), testGen)
	if got := slotText(t, stateDir, configDir, status, now); got != "b@example.com" {
		t.Fatalf("/login 뒤: %q", got)
	}
	if got := slotText(t, stateDir, configDir, input.Status{SessionID: "s2"}, now); got != "~other@example.com" {
		t.Fatalf("다른 세션은 그대로여야 한다: %q", got)
	}
	anchor.Apply(stateDir, anchor.Event{Name: "auth", SessionID: "s1", Action: "logout", Success: "true", TS: 3000}, testGen)
	if got := slotText(t, stateDir, configDir, status, now); got != "?" {
		t.Fatalf("로그아웃 뒤: %q", got)
	}
}

func TestAccountSlotIsEmptyWithoutTheReceiverAndQuestionMarkWithoutAnAnchor(t *testing.T) {
	now := time.Now()
	status := input.Status{SessionID: "s1"}
	if got := slotText(t, t.TempDir(), t.TempDir(), status, now); got != "" {
		t.Errorf("수신기 미설치: %q", got)
	}
	stateDir, configDir := accountFixture(t, now)
	if got := slotText(t, stateDir, configDir, status, now); got != "?" {
		t.Errorf("앵커 없음: %q", got)
	}
	if got := slotText(t, stateDir, configDir, input.Status{}, now); got != "?" {
		t.Errorf("session_id 없음: %q", got)
	}
}

func TestAccountSlotDoubtsAStoppedReceiver(t *testing.T) {
	now := time.Now()
	stateDir, configDir := accountFixture(t, now.Add(-10*time.Minute))
	anchor.Apply(stateDir, startEvent("s1", "a@example.com", 1000), testGen)
	if got := slotText(t, stateDir, configDir, input.Status{SessionID: "s1"}, now); got != "~a@example.com?" {
		t.Errorf("하트비트 정체: %q", got)
	}
}

func TestAccountSlotDoubtsAWindowThatChangedBeforeItEnded(t *testing.T) {
	now := time.Now()
	stateDir, configDir := accountFixture(t, now)
	runningProcess(t, configDir, "s1")
	anchor.Apply(stateDir, startEvent("s1", "a@example.com", 1000), testGen)
	week := func(reset int64) input.Status {
		return input.Status{SessionID: "s1", SevenDay: input.Window{Present: true, HasReset: true, Pct: 10, ResetsAt: reset}}
	}
	later := func(sec int) time.Time { return now.Add(time.Duration(sec) * time.Second) }
	end := now.Unix() + 3*86400
	if got := slotText(t, stateDir, configDir, week(end), now); got != "~a@example.com" {
		t.Fatalf("기준선: %q", got)
	}
	if got := slotText(t, stateDir, configDir, week(end+5000), later(10)); got != "~a@example.com" {
		t.Fatalf("바뀐 값을 처음 본 렌더: %q", got)
	}
	if got := slotText(t, stateDir, configDir, week(end+5000), later(80)); got != "~a@example.com?" {
		t.Fatalf("60초 넘게 다른 값: %q", got)
	}
	// 새 로그인은 새 기준선이다.
	anchor.Apply(stateDir, loginEvent("s1", "b@example.com", 2000), testGen)
	if got := slotText(t, stateDir, configDir, week(end+5000), later(90)); got != "b@example.com" {
		t.Fatalf("로그인 뒤: %q", got)
	}
}

func TestAccountSlotDoubtsAFiveHourWindowThatChangedBeforeItEnded(t *testing.T) {
	now := time.Now()
	stateDir, configDir := accountFixture(t, now)
	anchor.Apply(stateDir, startEvent("s1", "a@example.com", 1000), testGen)
	five := func(reset int64) input.Status {
		return input.Status{SessionID: "s1", FiveHour: input.Window{Present: true, HasReset: true, Pct: 10, ResetsAt: reset}}
	}
	later := func(sec int) time.Time { return now.Add(time.Duration(sec) * time.Second) }
	end := now.Unix() + 3*3600
	if got := slotText(t, stateDir, configDir, five(end), now); got != "~a@example.com" {
		t.Fatalf("기준선: %q", got)
	}
	if got := slotText(t, stateDir, configDir, five(end+900), later(10)); got != "~a@example.com" {
		t.Fatalf("바뀐 값을 처음 본 렌더: %q", got)
	}
	if got := slotText(t, stateDir, configDir, five(end+900), later(80)); got != "~a@example.com?" {
		t.Fatalf("5시간 창이 끝나기 전에 60초 넘게 다른 값: %q", got)
	}
	// 창이 끝난 뒤의 새 값은 다음 창이다. 3시간 뒤라 수신기 하트비트도 새로 찍는다.
	anchor.TouchHeartbeat(stateDir, later(3*3600+60))
	if got := slotText(t, stateDir, configDir, five(end+5*3600), later(3*3600+60)); got != "~a@example.com" {
		t.Fatalf("창 종료 뒤: %q", got)
	}
}

func TestAccountSlotIgnoresPayloadWindowsWhenNoEmailIsKnown(t *testing.T) {
	now := time.Now()
	stateDir, configDir := accountFixture(t, now)
	status := input.Status{SessionID: "s1", SevenDay: input.Window{Present: true, HasReset: true, ResetsAt: now.Unix() + 86400}}
	slotText(t, stateDir, configDir, status, now)
	if _, err := os.Stat(filepath.Join(stateDir, "fingerprints")); !os.IsNotExist(err) {
		t.Error("계정을 모르는 세션이 지문 파일을 만들었다")
	}
}

func TestWindowsDropTheCachedOnesWhenANewProcessResumesTheConversation(t *testing.T) {
	// 계정 A 의 프로세스가 남긴 한도를 계정 B 의 새 프로세스가 --continue 한 직후에 그리지 않는다.
	now := time.Now()
	stateDir, configDir := accountFixture(t, now)
	cacheDir := t.TempDir()
	proc := func(pid int, started int64) {
		b := fmt.Sprintf(`{"pid":%d,"sessionId":"s1","startedAt":%d}`, pid, started)
		if err := os.WriteFile(filepath.Join(configDir, "sessions", fmt.Sprintf("%d.json", pid)), []byte(b), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	os.MkdirAll(filepath.Join(configDir, "sessions"), 0o755)
	in := anchor.Input{StateDir: stateDir, ConfigDir: configDir, SessionID: "s1", Now: now}
	reset := now.Unix() + 3600
	full := input.Status{SessionID: "s1",
		FiveHour: input.Window{Present: true, HasReset: true, Pct: 24, ResetsAt: reset},
		SevenDay: input.Window{Present: true, HasReset: true, Pct: 41, ResetsAt: reset + 86400}}

	// Only a running process counts, so the two processes are this test process and its parent.
	first, second := os.Getpid(), os.Getppid()
	proc(first, now.UnixMilli()-86_400_000)
	if got := windows(cacheDir, in, full); got.Five.Pct != 24 {
		t.Fatalf("payload 의 창: %+v", got)
	}
	if got := windows(cacheDir, in, input.Status{SessionID: "s1"}); got.Five.Pct != 24 || got.Week.Pct != 41 {
		t.Fatalf("같은 프로세스는 빠진 창을 캐시로 채운다: %+v", got)
	}

	os.Remove(filepath.Join(configDir, "sessions", fmt.Sprintf("%d.json", first)))
	proc(second, now.UnixMilli()-1000) // claude --continue: 새 프로세스, 같은 session id
	if got := windows(cacheDir, in, input.Status{SessionID: "s1"}); got.Five.Present || got.Week.Present {
		t.Fatalf("이전 프로세스의 창이 그려졌다: %+v", got)
	}
}
