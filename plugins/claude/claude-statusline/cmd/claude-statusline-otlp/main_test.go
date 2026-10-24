package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
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
			if code := postRaw(t, addr, c.body); code != c.want {
				t.Fatalf("상태 %d, want %d", code, c.want)
			}
			if _, doubt := suspect(t, cfg, "s1"); !doubt {
				t.Error("버려진 배치 안의 로그인이 유실됐을 수 있으니 앞서 저장된 앵커를 의심해야 한다")
			}
			// 이후에 도착한 새 이벤트는 다시 믿는다.
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
	if code := postLogin(t, addr, "s1", "b@example.com", 1_700_000_001_000); code != 200 { // stored between the two losses
		t.Fatalf("재시도 상태 %d, want 200", code)
	}
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
	os.Chmod(otel, 0o500) // the generation and the heartbeat cannot be written
	postRaw(t, addr, `{broken`)
	os.Chmod(otel, 0o700)
	before, _ := os.Stat(hb)
	waitHeartbeatAfter(t, cfg, before.ModTime())
	if _, doubt := suspect(t, cfg, "s1"); !doubt {
		t.Error("세대를 기록하지 못한 유실이 복구 때에도 기록되지 않았다")
	}
}

// postWith posts body to /v1/logs with the given headers and returns the status.
func postWith(t *testing.T, addr, body string, header map[string]string) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, "http://"+addr+"/v1/logs", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// An exporter with compression on sends a body this receiver does not read, so a /login in
// it is lost like one in a batch dropped for size. A request of another media type is not
// attributed to Claude Code, which PR B pins to JSON, so it leaves the anchors alone.
func TestAnUnreadableEncodingIsALossButAnotherMediaTypeIsNot(t *testing.T) {
	login := string(request(record("auth", 1_700_000_005_000*ms, str("session.id", "s1"), str("user.email", "b@example.com"), str("action", "login"), boolean("success", true))))
	for name, c := range map[string]struct {
		header map[string]string
		doubt  bool
	}{
		"gzip":     {map[string]string{"Content-Type": "application/json", "Content-Encoding": "gzip"}, true},
		"protobuf": {map[string]string{"Content-Type": "application/x-protobuf"}, false},
	} {
		t.Run(name, func(t *testing.T) {
			cfg := baseConfig(t)
			addr, exit, _, cancel := start(t, cfg)
			defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
			if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
				t.Fatalf("정상 상태 %d", code)
			}
			if code := postWith(t, addr, login, c.header); code != http.StatusUnsupportedMediaType {
				t.Fatalf("상태 %d, want 415", code)
			}
			res, doubt := suspect(t, cfg, "s1")
			if res.Email != "a@example.com" || doubt != c.doubt {
				t.Errorf("거부된 뒤 앵커 %+v 의심=%v, want 의심=%v", res, doubt, c.doubt)
			}
		})
	}
}

// seed stores an anchor file the way an earlier run of the receiver left it.
func seed(t *testing.T, cfg config, id, email string, ms, gen int64) {
	t.Helper()
	dir := filepath.Join(cfg.StateDir, "otel", "sessions")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf("email=%s\nkind=login\nts=%d\nseen=%d\ngen=%d\n", email, ms, ms, gen)
	if err := os.WriteFile(filepath.Join(dir, id+".env"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// What a restart doubts does not depend on the clock: an anchor the previous run stored
// with a time ahead of the clock the new run reads (the clock was corrected back in
// between) is still from before the restart.
func TestAnAnchorStoredBeforeARestartIsDoubtedWhateverTheClockSays(t *testing.T) {
	cfg := baseConfig(t)
	ahead := time.Now().Add(24 * time.Hour).UnixMilli()
	// The earlier run counted from a clock that ran ahead: its generation is a number the
	// corrected clock has not reached yet, which a restart that reads the clock would undercut.
	seed(t, cfg, "s1", "a@example.com", ahead, ahead)
	if err := os.WriteFile(filepath.Join(cfg.StateDir, "otel", "generation"), []byte(strconv.FormatInt(ahead, 10)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if res, doubt := suspect(t, cfg, "s1"); res.Email != "a@example.com" || !doubt {
		t.Errorf("시계보다 앞선 시각으로 저장된 앵커가 재시작 뒤에도 믿어진다: %+v 의심=%v", res, doubt)
	}
}

// A loss the receiver could not record leaves the generation file behind its own count;
// an anchor stored meanwhile carries that count, and a restart must still pass it.
func TestARestartAfterAnUnrecordedLossStillDoubtsTheAnchorStoredMeanwhile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 쓰기 권한 제한을 받지 않아 저장 실패를 만들 수 없다")
	}
	cfg := baseConfig(t)
	otel := filepath.Join(cfg.StateDir, "otel")
	addr, exit, _, cancel := start(t, cfg)
	t.Cleanup(func() { os.Chmod(otel, 0o700) })
	os.Chmod(otel, 0o500) // the generation cannot be written, the anchors still can
	postRaw(t, addr, `{broken`)
	if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("상태 %d, want 200", code)
	}
	cancel()
	waitExit(t, exit, 3*time.Second)
	os.Chmod(otel, 0o700)

	_, exit, _, cancel = start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if res, doubt := suspect(t, cfg, "s1"); res.Email != "a@example.com" || !doubt {
		t.Errorf("기록하지 못한 유실 사이에 저장된 앵커가 재시작 뒤 믿어진다: %+v 의심=%v", res, doubt)
	}
}

// A generation file that is gone does not let a restart start counting from the beginning
// again under anchors that carry higher numbers.
func TestARestartPassesTheNumberOfEveryStoredAnchorWhenTheGenerationFileIsGone(t *testing.T) {
	cfg := baseConfig(t)
	seed(t, cfg, "s1", "a@example.com", time.Now().Add(-time.Hour).UnixMilli(), 7)
	_, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if res, doubt := suspect(t, cfg, "s1"); res.Email != "a@example.com" || !doubt {
		t.Errorf("세대 파일이 없던 재시작 뒤 앵커가 믿어진다: %+v 의심=%v", res, doubt)
	}
}

// While the generation cannot be written the receiver keeps counting in memory and stamps the
// anchors it stores with that count, so the recovery that writes it down doubts what was stored
// before the loss and not what was stored after.
func TestAnAnchorStoredWhileALossCannotBeRecordedIsNotDoubtedByTheRecovery(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 쓰기 권한 제한을 받지 않아 저장 실패를 만들 수 없다")
	}
	cfg := baseConfig(t)
	otel := filepath.Join(cfg.StateDir, "otel")
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	t.Cleanup(func() { os.Chmod(otel, 0o700) })

	if code := postLogin(t, addr, "s0", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	os.Chmod(otel, 0o500) // the generation cannot be written, the anchors still can
	postRaw(t, addr, `{broken`)
	if code := postLogin(t, addr, "s1", "b@example.com", 1_700_000_001_000); code != 200 {
		t.Fatalf("세대를 기록하지 못하는 동안의 저장 %d, want 200", code)
	}
	os.Chmod(otel, 0o700)
	hb, _ := os.Stat(filepath.Join(otel, "heartbeat"))
	waitHeartbeatAfter(t, cfg, hb.ModTime())
	if res, doubt := suspect(t, cfg, "s1"); res.Email != "b@example.com" || doubt {
		t.Errorf("유실을 기록하지 못하던 동안 저장된 앵커가 복구 때문에 의심받는다: %+v", res)
	}
	if _, doubt := suspect(t, cfg, "s0"); !doubt {
		t.Error("유실 전에 저장된 앵커는 의심해야 한다")
	}
}

// failedStart runs a start that is expected to give up and returns its exit code. A start
// that does not give up is stopped after a while with the code of a normal stop.
func failedStart(t *testing.T, cfg config) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return serve(ctx, cfg, &syncBuffer{})
}

// afterARun leaves the state a receiver that ran and stopped leaves: a login stored under
// its generation, a fresh heartbeat and the generation file.
func afterARun(t *testing.T) config {
	t.Helper()
	cfg := baseConfig(t)
	addr, exit, _, cancel := start(t, cfg)
	if code := postLogin(t, addr, "s1", "a@example.com", 1_700_000_000_000); code != 200 {
		t.Fatalf("정상 상태 %d", code)
	}
	cancel()
	waitExit(t, exit, 3*time.Second)
	return cfg
}

func chmodFor(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	old, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(path, old.Mode().Perm()) })
}

// A start that cannot tell which generations the stored anchors belong to must not go on
// with a number it guessed: it withdraws the generation and the heartbeat, so every reader
// doubts every anchor at once instead of trusting the receiver that stopped, and gives up
// with the code that makes the supervisor try again.
func TestAStartThatCannotSettleItsGenerationWithdrawsTheStateSoEveryAnchorIsDoubted(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root 는 읽기 권한 제한을 받지 않아 읽기 실패를 만들 수 없다")
	}
	for name, c := range map[string]struct {
		damage     func(t *testing.T, cfg config)
		readsEmail bool // the anchor itself can still be read
	}{
		"generation file gone and the anchors cannot be listed": {func(t *testing.T, cfg config) {
			os.Remove(filepath.Join(cfg.StateDir, "otel", "generation"))
			chmodFor(t, filepath.Join(cfg.StateDir, "otel", "sessions"), 0o300)
		}, true},
		"generation file kept and the anchors cannot be listed": {func(t *testing.T, cfg config) {
			chmodFor(t, filepath.Join(cfg.StateDir, "otel", "sessions"), 0o300)
		}, true},
		"an anchor cannot be read": {func(t *testing.T, cfg config) {
			chmodFor(t, filepath.Join(cfg.StateDir, "otel", "sessions", "s1.env"), 0o000)
		}, false},
		"the carried anchors cannot be listed": {func(t *testing.T, cfg config) {
			pids := filepath.Join(cfg.StateDir, "pids")
			os.MkdirAll(pids, 0o700)
			chmodFor(t, pids, 0o300)
		}, true},
		"the generation file cannot be read": {func(t *testing.T, cfg config) {
			chmodFor(t, filepath.Join(cfg.StateDir, "otel", "generation"), 0o000)
		}, true},
		"the anchors directory cannot be prepared": {func(t *testing.T, cfg config) {
			sessions := filepath.Join(cfg.StateDir, "otel", "sessions")
			os.RemoveAll(sessions)
			os.WriteFile(sessions, []byte("x"), 0o600)
		}, false},
	} {
		t.Run(name, func(t *testing.T) {
			cfg := afterARun(t)
			c.damage(t, cfg)
			if code := failedStart(t, cfg); code != exitFailed {
				t.Fatalf("종료코드 %d, want %d", code, exitFailed)
			}
			if _, err := os.Stat(filepath.Join(cfg.StateDir, "otel", "heartbeat")); !os.IsNotExist(err) {
				t.Errorf("시작하지 못했는데 이전 하트비트가 남아 이전 수신기를 믿게 한다: %v", err)
			}
			if c.readsEmail {
				if res, doubt := suspect(t, cfg, "s1"); res.Email != "a@example.com" || !doubt {
					t.Errorf("읽을 수 있는 앵커가 의심 없이 보인다: %+v 의심=%v", res, doubt)
				}
			}
		})
	}
}

// A generation file that is damaged or out of range is not guessed at either; withdrawing it
// is what lets the next start, which finds no file, count from the anchors.
func TestADamagedGenerationFileFailsOneStartAndTheNextStartHealsIt(t *testing.T) {
	for name, body := range map[string]string{
		"text":         "soon\n",
		"empty":        "",
		"negative":     "-3\n",
		"zero":         "0\n",
		"out of range": "99999999999999999999\n",
		"max int64":    "9223372036854775807\n",
	} {
		t.Run(name, func(t *testing.T) {
			cfg := afterARun(t)
			gen := filepath.Join(cfg.StateDir, "otel", "generation")
			if err := os.WriteFile(gen, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if code := failedStart(t, cfg); code != exitFailed {
				t.Fatalf("종료코드 %d, want %d", code, exitFailed)
			}
			if _, err := os.Stat(gen); !os.IsNotExist(err) {
				t.Errorf("손상된 세대 파일이 남았다: %v", err)
			}
			_, exit, _, cancel := start(t, cfg)
			defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
			if res, doubt := suspect(t, cfg, "s1"); res.Email != "a@example.com" || !doubt {
				t.Errorf("다시 시작한 뒤 이전 세대의 앵커가 믿어진다: %+v 의심=%v", res, doubt)
			}
			b, err := os.ReadFile(gen)
			if n, perr := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err != nil || perr != nil || n < 2 {
				t.Errorf("다시 시작한 수신기의 세대 파일 = %q (%v %v), want 앵커의 번호 1 보다 큰 수", b, err, perr)
			}
		})
	}
}
