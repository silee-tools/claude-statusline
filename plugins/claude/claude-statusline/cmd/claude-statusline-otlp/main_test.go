package main

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
)

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// start runs serve on an ephemeral loopback port and returns its address, the exit code
// channel and the cancel function.
func start(t *testing.T, cfg config) (addr string, exit <-chan int, stderr *syncBuffer, cancel context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	stderr = &syncBuffer{}
	listening := make(chan string, 1)
	cfg.OnListen = func(a net.Addr) { listening <- a.String() }
	code := make(chan int, 1)
	go func() { code <- serve(ctx, cfg, stderr) }()
	select {
	case addr = <-listening:
	case c := <-code:
		t.Fatalf("수신기가 바로 끝났다: 종료코드 %d, stderr=%q", c, stderr.String())
	case <-time.After(5 * time.Second):
		t.Fatal("수신기가 뜨지 않았다")
	}
	return addr, code, stderr, cancel
}

func baseConfig(t *testing.T) config {
	t.Helper()
	exe := filepath.Join(t.TempDir(), "claude-statusline-otlp")
	os.WriteFile(exe, []byte("v1"), 0o755)
	return config{
		Addr: "127.0.0.1:0", StateDir: t.TempDir(), ExePath: exe,
		WatchEvery: 20 * time.Millisecond, BeatEvery: 20 * time.Millisecond,
	}
}

func waitExit(t *testing.T, exit <-chan int, within time.Duration) int {
	t.Helper()
	select {
	case c := <-exit:
		return c
	case <-time.After(within):
		t.Fatal("수신기가 끝나지 않았다")
		return -1
	}
}

func TestServeAnswersRequestsAndExitsZeroOnCancel(t *testing.T) {
	cfg := baseConfig(t)
	addr, exit, stderr, cancel := start(t, cfg)
	body := request(record("managed_settings_resolved", 1_700_000_000_000*ms,
		str("session.id", "s1"), str("user.email", "a@example.com")))
	resp, err := http.Post("http://"+addr+"/v1/logs", "application/json", strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("상태 %d", resp.StatusCode)
	}
	if b, err := os.ReadFile(filepath.Join(cfg.StateDir, "otel", "sessions", "s1.env")); err != nil || !strings.Contains(string(b), "email=a@example.com") {
		t.Errorf("앵커가 쓰이지 않았다: %q %v", b, err)
	}
	cancel()
	if c := waitExit(t, exit, 3*time.Second); c != 0 {
		t.Errorf("정상 종료코드 %d, want 0", c)
	}
	for _, secret := range []string{"a@example.com", "s1"} {
		if strings.Contains(stderr.String(), secret) {
			t.Errorf("stderr 에 값이 섞였다: %q", stderr.String())
		}
	}
}

func TestServeCreatesTheSessionsDirAndKeepsTheHeartbeatFresh(t *testing.T) {
	cfg := baseConfig(t)
	_, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if info, err := os.Stat(filepath.Join(cfg.StateDir, "otel", "sessions")); err != nil || !info.IsDir() {
		t.Fatalf("otel/sessions 가 없다: %v", err)
	}
	hb := filepath.Join(cfg.StateDir, "otel", "heartbeat")
	first, err := os.Stat(hb)
	if err != nil {
		t.Fatalf("시작 즉시 하트비트가 있어야 한다: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cur, err := os.Stat(hb); err == nil && cur.ModTime().After(first.ModTime()) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Error("하트비트가 갱신되지 않았다")
}

func TestServeExits75WhenItsExecutableIsReplaced(t *testing.T) {
	cfg := baseConfig(t)
	_, exit, stderr, cancel := start(t, cfg)
	defer cancel()
	select {
	case c := <-exit:
		t.Fatalf("교체 전에 끝났다: %d", c)
	case <-time.After(100 * time.Millisecond):
	}
	next := cfg.ExePath + ".next"
	os.WriteFile(next, []byte("v2"), 0o755)
	if err := os.Rename(next, cfg.ExePath); err != nil {
		t.Fatal(err)
	}
	if c := waitExit(t, exit, 3*time.Second); c != 75 {
		t.Errorf("교체 종료코드 %d, want 75", c)
	}
	if !strings.Contains(stderr.String(), "executable replaced") {
		t.Errorf("종료 이유가 stderr 에 없다: %q", stderr.String())
	}
}

func TestServeKeepsRunningWhenTheExecutableIsUntouched(t *testing.T) {
	cfg := baseConfig(t)
	_, exit, _, cancel := start(t, cfg)
	select {
	case c := <-exit:
		t.Fatalf("바뀌지 않았는데 끝났다: %d", c)
	case <-time.After(250 * time.Millisecond): // a dozen watch ticks
	}
	cancel()
	waitExit(t, exit, 3*time.Second)
}

func TestServeExits1WhenThePortIsTaken(t *testing.T) {
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	cfg := baseConfig(t)
	cfg.Addr = taken.Addr().String()
	stderr := &syncBuffer{}
	// A receiver that did bind would serve forever; the deadline turns that into a failure.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if c := serve(ctx, cfg, stderr); c != 1 {
		t.Errorf("바인드 실패 종료코드 %d, want 1", c)
	}
	if !strings.Contains(stderr.String(), "bind") {
		t.Errorf("원인이 stderr 에 없다: %q", stderr.String())
	}
}

func TestServeRefusesANonLoopbackAddress(t *testing.T) {
	for _, addr := range []string{"0.0.0.0:0", ":0", "192.0.2.1:0", "localhost.example.com:0", "[::]:0"} {
		cfg := baseConfig(t)
		cfg.Addr = addr
		stderr := &syncBuffer{}
		// Without the guard the address binds and serve runs on; the deadline ends it.
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		c := serve(ctx, cfg, stderr)
		cancel()
		if c != 1 {
			t.Errorf("%s: 종료코드 %d, want 1", addr, c)
		}
		// 바인드 실패도 종료코드 1 이므로, 종료코드만으로는 loopback 검사가 있다는 증거가 아니다.
		if !strings.Contains(stderr.String(), "loopback") {
			t.Errorf("%s: loopback 검사로 거부했다는 이유가 stderr 에 없다: %q", addr, stderr.String())
		}
		if _, err := os.Stat(filepath.Join(cfg.StateDir, "otel")); !os.IsNotExist(err) {
			t.Errorf("%s: 거부했는데 상태 디렉터리를 만들었다", addr)
		}
	}
}

func TestServeAcceptsIPv6Loopback(t *testing.T) {
	if ln, err := net.Listen("tcp", "[::1]:0"); err != nil {
		t.Skip("IPv6 loopback 없음")
	} else {
		ln.Close()
	}
	cfg := baseConfig(t)
	cfg.Addr = "[::1]:0"
	_, exit, _, cancel := start(t, cfg)
	cancel()
	waitExit(t, exit, 3*time.Second)
}

func postLogin(t *testing.T, addr, id, email string, tsMs int64) int {
	t.Helper()
	body := request(record("auth", tsMs*ms, str("session.id", id), str("user.email", email), str("action", "login"), boolean("success", true)))
	resp, err := http.Post("http://"+addr+"/v1/logs", "application/json", strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func TestServeStartsANewGenerationBeforeItListens(t *testing.T) {
	cfg := baseConfig(t)
	gen := filepath.Join(cfg.StateDir, "otel", "generation")
	before := time.Now().Add(-time.Second)
	_, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	info, err := os.Stat(gen)
	if err != nil {
		t.Fatalf("시작할 때 세대 파일이 있어야 한다: %v", err)
	}
	if info.ModTime().Before(before) {
		t.Error("세대 파일이 이번 시작의 것이 아니다")
	}
}

func TestServeSweepsStateOlderThanRetentionAtStart(t *testing.T) {
	cfg := baseConfig(t)
	old := filepath.Join(cfg.StateDir, "otel", "sessions", "old.env")
	os.MkdirAll(filepath.Dir(old), 0o700)
	os.WriteFile(old, []byte("email=a@example.com\nkind=start\nts=1\n"), 0o600)
	stale := time.Now().Add(-31 * 24 * time.Hour)
	os.Chtimes(old, stale, stale)
	_, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Error("보존 기간이 지난 앵커가 시작 때 지워지지 않았다")
	}
}

func TestServeSweepsPeriodicallyWithoutAnyEvent(t *testing.T) {
	cfg := baseConfig(t)
	cfg.SweepEvery = 20 * time.Millisecond
	_, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	old := filepath.Join(cfg.StateDir, "pids", "11-1.env")
	os.MkdirAll(filepath.Dir(old), 0o700)
	os.WriteFile(old, []byte("session=s\n"), 0o600)
	stale := time.Now().Add(-31 * 24 * time.Hour)
	os.Chtimes(old, stale, stale)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(old); os.IsNotExist(err) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Error("이벤트가 없어도 주기적으로 지워야 한다")
}

func TestServeAnswers503AndDoubtsItselfWhileItCannotStoreThenRecovers(t *testing.T) {
	cfg := baseConfig(t)
	sessions := filepath.Join(cfg.StateDir, "otel", "sessions")
	hb := filepath.Join(cfg.StateDir, "otel", "heartbeat")
	gen := filepath.Join(cfg.StateDir, "otel", "generation")
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()

	if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	genBefore, _ := os.Stat(gen)

	// 앵커 디렉터리 자리에 파일을 둬서 쓰기를 실패시킨다(권한과 무관하게 실패한다).
	os.RemoveAll(sessions)
	os.WriteFile(sessions, []byte("x"), 0o600)
	if code := postLogin(t, addr, "s1", "b@example.com", 1_700_000_005_000); code != http.StatusServiceUnavailable {
		t.Fatalf("저장 실패 상태 %d, want 503", code)
	}
	genAfter, _ := os.Stat(gen)
	if !genAfter.ModTime().After(genBefore.ModTime()) {
		t.Error("저장 실패 때 세대를 올리지 않았다")
	}
	// 실패하는 동안에는 하트비트를 찍지 않는다.
	failedAt, _ := os.Stat(hb)
	time.Sleep(150 * time.Millisecond) // 수 차례 박동 주기
	if cur, _ := os.Stat(hb); !cur.ModTime().Equal(failedAt.ModTime()) {
		t.Error("저장하지 못하는 동안 하트비트를 찍었다")
	}

	// 저장소가 돌아오면 하트비트가 다시 뛴다.
	os.Remove(sessions)
	os.MkdirAll(sessions, 0o700)
	deadline := time.Now().Add(3 * time.Second)
	for {
		if cur, _ := os.Stat(hb); cur.ModTime().After(failedAt.ModTime()) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("복구 뒤에도 하트비트가 재개되지 않았다")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if code := postLogin(t, addr, "s1", "b@example.com", 1_700_000_005_000); code != 200 {
		t.Errorf("복구 뒤 재시도 상태 %d, want 200", code)
	}
}

// suspect reads how the statusline would show the anchor of a session the receiver stored.
func suspect(t *testing.T, cfg config, id string) (anchor.Result, bool) {
	t.Helper()
	res := anchor.Resolve(anchor.Input{StateDir: cfg.StateDir, ConfigDir: t.TempDir(), SessionID: id, Now: time.Now()})
	return res, res.Suspect
}

// waitHeartbeatAfter waits for a heartbeat newer than t, which the receiver gives only once
// it can store again.
func waitHeartbeatAfter(t *testing.T, cfg config, since time.Time) {
	t.Helper()
	hb := filepath.Join(cfg.StateDir, "otel", "heartbeat")
	deadline := time.Now().Add(3 * time.Second)
	for {
		if cur, err := os.Stat(hb); err == nil && cur.ModTime().After(since) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("복구 뒤에도 하트비트가 재개되지 않았다")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func breakStore(t *testing.T, cfg config) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("root 는 쓰기 권한 제한을 받지 않아 저장 실패를 만들 수 없다")
	}
	if err := os.Chmod(filepath.Join(cfg.StateDir, "otel", "sessions"), 0o500); err != nil {
		t.Fatal(err)
	}
}

func mendStore(t *testing.T, cfg config) {
	t.Helper()
	if err := os.Chmod(filepath.Join(cfg.StateDir, "otel", "sessions"), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestAnAnchorStoredByARetryAfterAFailureIsNotDoubtedByTheRecovery(t *testing.T) {
	cfg := baseConfig(t)
	cfg.BeatEvery = 300 * time.Millisecond // the retry lands before the first beat that notices the recovery
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	t.Cleanup(func() { mendStore(t, cfg) })

	if code := postLogin(t, addr, "s0", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	time.Sleep(5 * time.Millisecond) // 세대와 저장 시각은 밀리초 단위라 같은 밀리초면 앞선 앵커를 가리지 못한다
	breakStore(t, cfg)
	if code := postLogin(t, addr, "s1", "b@example.com", 1_700_000_001_000); code != http.StatusServiceUnavailable {
		t.Fatalf("저장 실패 상태 %d, want 503", code)
	}
	mendStore(t, cfg)
	if code := postLogin(t, addr, "s1", "b@example.com", 1_700_000_001_000); code != 200 { // the exporter resends it
		t.Fatalf("재시도 상태 %d, want 200", code)
	}
	waitHeartbeatAfter(t, cfg, time.Now())
	if res, doubt := suspect(t, cfg, "s1"); res.Email != "b@example.com" || doubt {
		t.Errorf("실패 뒤 재시도로 저장된 앵커가 복구 때문에 의심받는다: %+v", res)
	}
	if _, doubt := suspect(t, cfg, "s0"); !doubt {
		t.Error("실패 전에 저장된 앵커는 의심해야 한다")
	}

	// 나중의 두 번째 실패는 그 앞에 저장된 앵커를 다시 의심하게 만든다.
	before := time.Now()
	breakStore(t, cfg)
	if code := postLogin(t, addr, "s2", "c@example.com", 1_700_000_002_000); code != http.StatusServiceUnavailable {
		t.Fatalf("두 번째 저장 실패 상태 %d, want 503", code)
	}
	mendStore(t, cfg)
	waitHeartbeatAfter(t, cfg, before)
	if _, doubt := suspect(t, cfg, "s1"); !doubt {
		t.Error("두 번째 실패 앞에 저장된 앵커는 의심해야 한다")
	}
}

func postRaw(t *testing.T, addr, body string) int {
	t.Helper()
	resp, err := http.Post("http://"+addr+"/v1/logs", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func TestARefusedBatchIsDroppedWholeSoItsLoginIsDoubted(t *testing.T) {
	for name, c := range map[string]struct {
		body string
		want int
	}{
		"oversized": {`{"resourceLogs":"` + strings.Repeat("x", maxBody+1024) + `"}`, http.StatusRequestEntityTooLarge},
		"malformed": {`{broken`, http.StatusBadRequest},
	} {
		t.Run(name, func(t *testing.T) {
			cfg := baseConfig(t)
			addr, exit, _, cancel := start(t, cfg)
			defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
			if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
				t.Fatalf("정상 상태 %d", code)
			}
			if _, doubt := suspect(t, cfg, "s1"); doubt {
				t.Fatal("정상 저장 직후에는 의심하지 않는다")
			}
			time.Sleep(5 * time.Millisecond)
			if code := postRaw(t, addr, c.body); code != c.want {
				t.Fatalf("상태 %d, want %d", code, c.want)
			}
			if _, doubt := suspect(t, cfg, "s1"); !doubt {
				t.Error("버려진 배치 안의 로그인이 유실됐을 수 있으니 앞서 저장된 앵커를 의심해야 한다")
			}
			// 이후에 도착한 새 이벤트는 다시 믿는다.
			time.Sleep(5 * time.Millisecond)
			if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_005_000); code != 200 {
				t.Fatalf("새 이벤트 %d", code)
			}
			if _, doubt := suspect(t, cfg, "s1"); doubt {
				t.Error("버려진 배치 뒤에 저장된 앵커까지 의심한다")
			}
		})
	}
}

func TestALossRecordedWhileDegradedSurvivesTheRecovery(t *testing.T) {
	cfg := baseConfig(t)
	cfg.BeatEvery = 300 * time.Millisecond // both requests land before the beat that notices the recovery
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	t.Cleanup(func() { mendStore(t, cfg) })

	breakStore(t, cfg)
	if code := postLogin(t, addr, "s0", "a@example.com", 1_700_000_000_000); code != http.StatusServiceUnavailable {
		t.Fatalf("저장 실패 상태 %d, want 503", code)
	}
	mendStore(t, cfg)
	time.Sleep(5 * time.Millisecond)
	if code := postLogin(t, addr, "s1", "b@example.com", 1_700_000_001_000); code != 200 { // stored between the two losses
		t.Fatalf("재시도 상태 %d, want 200", code)
	}
	time.Sleep(5 * time.Millisecond)
	if code := postRaw(t, addr, `{broken`); code != http.StatusBadRequest { // a later loss, before the recovery beat
		t.Fatalf("깨진 본문 상태 %d", code)
	}
	waitHeartbeatAfter(t, cfg, time.Now())
	if _, doubt := suspect(t, cfg, "s1"); !doubt {
		t.Error("복구가 더 늦은 유실의 세대를 이른 시각으로 되돌려 그 사이 저장된 앵커의 의심을 풀었다")
	}
}

func TestALossThatCannotBeRecordedWithholdsTheHeartbeatUntilItIs(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 쓰기 권한 제한을 받지 않아 저장 실패를 만들 수 없다")
	}
	cfg := baseConfig(t)
	otel := filepath.Join(cfg.StateDir, "otel")
	hb := filepath.Join(otel, "heartbeat")
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	t.Cleanup(func() { os.Chmod(otel, 0o700) })

	if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	time.Sleep(5 * time.Millisecond)
	os.Chmod(otel, 0o500) // the generation and the heartbeat cannot be written
	postRaw(t, addr, `{broken`)
	os.Chmod(otel, 0o700)
	before, _ := os.Stat(hb)
	waitHeartbeatAfter(t, cfg, before.ModTime())
	if _, doubt := suspect(t, cfg, "s1"); !doubt {
		t.Error("세대를 기록하지 못한 유실이 복구 때에도 기록되지 않았다")
	}
}
