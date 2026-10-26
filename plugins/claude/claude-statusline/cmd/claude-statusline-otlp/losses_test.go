package main

import (
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// A line of otel/losses holds these fields and nothing a request carried.
var lossLine = regexp.MustCompile(`^ts=\d+ gen=\d+ kind=[a-z-]+ cause=[a-z-]+ bytes=-?\d+$`)

// readLossRecord reads otel/losses as one map of fields per line.
func readLossRecord(t *testing.T, cfg config) []map[string]string {
	t.Helper()
	var out []map[string]string
	for _, line := range strings.Split(strings.TrimSuffix(readState(t, cfg, "losses"), "\n"), "\n") {
		if !lossLine.MatchString(line) {
			t.Errorf("유실 기록 줄이 고정 형식이 아니다: %q", line)
		}
		fields := map[string]string{}
		for _, kv := range strings.Fields(line) {
			k, v, _ := strings.Cut(kv, "=")
			fields[k] = v
		}
		out = append(out, fields)
	}
	return out
}

func TestALossIsRecordedWithItsCauseAndNoContent(t *testing.T) {
	const email, session = "leak@example.com", "leak-session"
	login := string(request(record("auth", 1_700_000_000_000*ms, str("session.id", session), str("user.email", email), str("action", "login"), boolean("success", true))))
	broken := `{"user.email":"` + email + `","session.id":"` + session + `", broken`
	protobuf := "\x0a\x2c\x0a\x2a" + session + "\x12" + email // the length byte is a comma: not JSON
	oversized := `{"resourceLogs":"` + email + ` ` + session + ` ` + strings.Repeat("x", maxBody) + `"}`
	firstPart := `{"user.email":"` + email + `","session.id":"` + session + `"` // of a body that claims 500 bytes
	asJSON := map[string]string{"Content-Type": "application/json"}

	cases := []struct {
		name        string
		timeout     time.Duration
		send        func(t *testing.T, cfg config, addr string) int
		status      int
		kind, cause string
		bytes       int
	}{
		{"empty body", 0, func(t *testing.T, _ config, addr string) int { return postWith(t, addr, "", asJSON) },
			http.StatusBadRequest, "bad-request", "eof", 0},
		{"broken JSON", 0, func(t *testing.T, _ config, addr string) int { return postWith(t, addr, broken, asJSON) },
			http.StatusBadRequest, "bad-request", "syntax", len(broken)},
		{"protobuf bytes sent as JSON", 0, func(t *testing.T, _ config, addr string) int { return postWith(t, addr, protobuf, asJSON) },
			http.StatusBadRequest, "bad-request", "syntax", len(protobuf)},
		{"gzip body", 0, func(t *testing.T, _ config, addr string) int {
			return postWith(t, addr, login, map[string]string{"Content-Type": "application/json", "Content-Encoding": "gzip"})
		}, http.StatusUnsupportedMediaType, "unreadable-encoding", "encoding", len(login)},
		{"body over 1 MiB", 0, func(t *testing.T, _ config, addr string) int { return postWith(t, addr, oversized, asJSON) },
			http.StatusRequestEntityTooLarge, "body-too-large", "too-large", len(oversized)},
		{"connection ends before the body does", 0, func(t *testing.T, _ config, addr string) int {
			c := openPost(t, addr, 500, firstPart)
			c.CloseWrite()
			return answer(t, c).StatusCode
		}, http.StatusServiceUnavailable, "read-failed", "unexpected-eof", 500},
		{"sender stalls past the read timeout", 300 * time.Millisecond, func(t *testing.T, _ config, addr string) int {
			return answer(t, openPost(t, addr, 500, firstPart)).StatusCode
		}, http.StatusServiceUnavailable, "read-failed", "timeout", 500},
		{"record cannot be stored", 0, func(t *testing.T, cfg config, addr string) int {
			sessions := filepath.Join(cfg.StateDir, "otel", "sessions")
			os.RemoveAll(sessions)
			os.WriteFile(sessions, []byte("x"), 0o600) // a file where the anchors go: no write can succeed, whoever runs it
			return postWith(t, addr, login, asJSON)
		}, http.StatusServiceUnavailable, "apply-failed", "apply", -1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := baseConfig(t)
			cfg.ReadTimeout = c.timeout
			addr, exit, _, cancel := start(t, cfg)
			defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
			before := generation(t, cfg)
			if got := c.send(t, cfg, addr); got != c.status {
				t.Fatalf("상태 %d, want %d", got, c.status)
			}
			if got := generation(t, cfg); got != before+1 {
				t.Fatalf("세대 %d, want %d", got, before+1)
			}
			lines := readLossRecord(t, cfg)
			if len(lines) != 1 {
				t.Fatalf("유실 기록 %d줄, want 1: %v", len(lines), lines)
			}
			want := map[string]string{"gen": strconv.FormatInt(before+1, 10), "kind": c.kind, "cause": c.cause, "bytes": strconv.Itoa(c.bytes)}
			for k, v := range want {
				if lines[0][k] != v {
					t.Errorf("%s=%s, want %s (%v)", k, lines[0][k], v, lines[0])
				}
			}
			if ts, _ := strconv.ParseInt(lines[0]["ts"], 10, 64); time.Since(time.UnixMilli(ts)) > time.Minute {
				t.Errorf("ts=%s 는 방금 센 유실의 시각이 아니다", lines[0]["ts"])
			}
			raw := readState(t, cfg, "losses")
			for _, leak := range []string{"leak", "127.0.0.1", "@"} {
				if strings.Contains(raw, leak) {
					t.Errorf("유실 기록에 요청 내용이나 주소 %q 가 섞였다:\n%s", leak, raw)
				}
			}
		})
	}
}

func TestTheLossRecordKeepsTheLastTwentyLines(t *testing.T) {
	cfg := baseConfig(t)
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	base := generation(t, cfg)
	for i := 0; i < 25; i++ {
		if code := postRaw(t, addr, `{broken`); code != http.StatusBadRequest {
			t.Fatalf("깨진 본문 상태 %d", code)
		}
	}
	lines := readLossRecord(t, cfg)
	if len(lines) != 20 {
		t.Fatalf("유실 기록 %d줄, want 20", len(lines))
	}
	for i, l := range lines {
		if want := strconv.FormatInt(base+6+int64(i), 10); l["gen"] != want {
			t.Errorf("%d번째 줄 gen=%s, want %s(25건 중 마지막 20건)", i, l["gen"], want)
		}
	}
	if size := len(readState(t, cfg, "losses")); size > 2048 {
		t.Errorf("유실 기록 크기 %d바이트, want 2048바이트 이하", size)
	}
}

func TestTheLossRecordStartsEmptyAndIsPrivate(t *testing.T) {
	cfg := baseConfig(t)
	path := filepath.Join(cfg.StateDir, "otel", "losses")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("ts=1 gen=1 kind=bad-request cause=syntax bytes=1\n"), 0o600); err != nil { // an earlier run's
		t.Fatal(err)
	}
	addr, exit, _, cancel := start(t, cfg)
	defer func() { cancel(); waitExit(t, exit, 3*time.Second) }()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("시작이 이전 실행의 유실 기록을 지우지 않았다: %v", err)
	}
	if code := postRaw(t, addr, `{broken`); code != http.StatusBadRequest {
		t.Fatalf("깨진 본문 상태 %d", code)
	}
	if info, err := os.Stat(path); err != nil {
		t.Fatal(err)
	} else if info.Mode().Perm() != 0o600 {
		t.Errorf("유실 기록 모드 %v, want 0600", info.Mode().Perm())
	}
	if lines := readLossRecord(t, cfg); len(lines) != 1 {
		t.Errorf("유실 기록 %d줄, want 이번 실행의 1줄", len(lines))
	}
	// 둘째 수신기는 잠금에서 포기하므로 떠 있는 수신기의 기록을 지우지 않는다.
	before := readState(t, cfg, "losses")
	if code := failedStart(t, cfg); code != exitFailed {
		t.Fatalf("둘째 수신기 종료코드 %d, want %d", code, exitFailed)
	}
	if got := readState(t, cfg, "losses"); got != before {
		t.Errorf("둘째 수신기가 떠 있는 수신기의 유실 기록을 건드렸다: %q → %q", before, got)
	}
}

// A receiver whose lock files were replaced writes nothing more, and a loss record is a write.
func TestALossIsNotRecordedByAReceiverThatLostItsLocks(t *testing.T) {
	cfg := baseConfig(t)
	cfg.BeatEvery = time.Hour
	addr1, exit1, _, cancel1 := start(t, cfg)
	defer cancel1()
	removeLocks(t, cfg)
	cfg2 := baseConfig(t)
	cfg2.StateDir = cfg.StateDir
	addr2, exit2, _, cancel2 := start(t, cfg2)
	defer func() { cancel2(); waitExit(t, exit2, 3*time.Second) }()
	if code := postRaw(t, addr1, "{"); code != http.StatusBadRequest {
		t.Fatalf("읽을 수 없는 요청 상태 %d, want 400", code)
	}
	if c := waitExit(t, exit1, 3*time.Second); c != exitFailed {
		t.Errorf("첫 수신기 종료코드 %d, want %d", c, exitFailed)
	}
	if _, err := os.Stat(filepath.Join(cfg.StateDir, "otel", "losses")); !os.IsNotExist(err) {
		t.Errorf("잠금 파일이 바뀐 첫 수신기가 유실 기록을 썼다: %v", err)
	}
	if code := postRaw(t, addr2, "{"); code != http.StatusBadRequest {
		t.Fatalf("둘째 수신기 상태 %d, want 400", code)
	}
	if lines := readLossRecord(t, cfg); len(lines) != 1 {
		t.Errorf("잠금을 쥔 수신기의 유실 기록 %d줄, want 1", len(lines))
	}
}
