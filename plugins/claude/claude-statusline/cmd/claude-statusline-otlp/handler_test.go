package main

import (
	"encoding/json"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
)

type attr map[string]any

func str(k, v string) attr { return attr{"key": k, "value": map[string]any{"stringValue": v}} }
func boolean(k string, v bool) attr {
	return attr{"key": k, "value": map[string]any{"boolValue": v}}
}
func integer(k string, v int) attr {
	return attr{"key": k, "value": map[string]any{"intValue": v}}
}

// record builds one OTLP log record the way Claude Code 2.1.x sends it: the event name
// in the body and in event.name, the session and the account in the record attributes.
func record(name string, tsNano int64, attrs ...attr) map[string]any {
	all := []attr{str("event.name", name)}
	all = append(all, attrs...)
	r := map[string]any{
		"body":       map[string]any{"stringValue": "claude_code." + name},
		"attributes": all,
	}
	if tsNano != 0 {
		r["timeUnixNano"] = strconv.FormatInt(tsNano, 10)
	}
	return r
}

func request(records ...map[string]any) []byte {
	b, _ := json.Marshal(map[string]any{"resourceLogs": []any{map[string]any{
		"resource":  map[string]any{"attributes": []attr{str("service.name", "claude-code")}},
		"scopeLogs": []any{map[string]any{"scope": map[string]any{"name": "com.anthropic.claude_code.events"}, "logRecords": records}},
	}}})
	return b
}

const ms = int64(time.Millisecond)

type recorder struct {
	mu     sync.Mutex
	events []anchor.Event
}

func (r *recorder) apply(e anchor.Event) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, e)
	return nil
}

func serveOnce(h http.Handler, method, path, contentType string, body []byte) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(string(body)))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

var fixedNow = func() time.Time { return time.UnixMilli(1_900_000_000_000) }

func TestHandlerAcceptsOnlyPostJSONToTheLogsPath(t *testing.T) {
	rec := &recorder{}
	h := newHandler(rec.apply, fixedNow, func(string) {})
	body := request(record("managed_settings_resolved", 1_700_000_000_000*ms, str("session.id", "s1"), str("user.email", "a@example.com")))
	cases := []struct {
		name, method, path, ctype string
		want                      int
	}{
		{"정상", "POST", "/v1/logs", "application/json", 200},
		{"charset 매개변수", "POST", "/v1/logs", "application/json; charset=utf-8", 200},
		{"GET 거부", "GET", "/v1/logs", "application/json", 405},
		{"PUT 거부", "PUT", "/v1/logs", "application/json", 405},
		{"지표 경로 거부", "POST", "/v1/metrics", "application/json", 404},
		{"뒤 슬래시 거부", "POST", "/v1/logs/", "application/json", 404},
		{"루트 거부", "POST", "/", "application/json", 404},
		{"protobuf 거부", "POST", "/v1/logs", "application/x-protobuf", 415},
		{"text/plain 거부", "POST", "/v1/logs", "text/plain", 415},
		{"타입 없음 거부", "POST", "/v1/logs", "", 415},
	}
	for _, c := range cases {
		rec.events = nil
		got := serveOnce(h, c.method, c.path, c.ctype, body)
		if got.Code != c.want {
			t.Errorf("%s: 상태 %d, want %d", c.name, got.Code, c.want)
		}
		if (c.want == 200) != (len(rec.events) == 1) {
			t.Errorf("%s: 반영한 이벤트 %d개", c.name, len(rec.events))
		}
	}
}

func TestHandlerAnswersOKWithAnEmptyJSONObject(t *testing.T) {
	h := newHandler((&recorder{}).apply, fixedNow, func(string) {})
	got := serveOnce(h, "POST", "/v1/logs", "application/json", request())
	if got.Code != 200 || strings.TrimSpace(got.Body.String()) != "{}" {
		t.Errorf("응답 = %d %q", got.Code, got.Body.String())
	}
	if ct := got.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type = %q", ct)
	}
}

func TestHandlerRejectsOversizedMalformedAndEncodedBodies(t *testing.T) {
	rec := &recorder{}
	var logged []string
	h := newHandler(rec.apply, fixedNow, func(kind string) { logged = append(logged, kind) })

	big := request(record("user_prompt", 0, str("session.id", "s1"), str("prompt", strings.Repeat("x", 1<<20+1))))
	if got := serveOnce(h, "POST", "/v1/logs", "application/json", big); got.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("1 MiB 초과 본문: %d", got.Code)
	}
	if got := serveOnce(h, "POST", "/v1/logs", "application/json", []byte(`{"resourceLogs": [SENTINEL`)); got.Code != http.StatusBadRequest {
		t.Errorf("깨진 JSON: %d", got.Code)
	}
	req := httptest.NewRequest("POST", "/v1/logs", strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Encoding", "gzip")
	gz := httptest.NewRecorder()
	h.ServeHTTP(gz, req)
	if gz.Code != http.StatusUnsupportedMediaType {
		t.Errorf("gzip 본문: %d", gz.Code)
	}
	if len(rec.events) != 0 {
		t.Errorf("거부한 요청이 이벤트를 반영했다: %v", rec.events)
	}
	for _, k := range logged {
		if strings.Contains(k, "SENTINEL") || strings.Contains(k, "xxxx") {
			t.Errorf("로그에 요청 내용이 섞였다: %q", k)
		}
	}
}

func TestHandlerKeepsOnlyTheAllowedKeys(t *testing.T) {
	rec := &recorder{}
	h := newHandler(rec.apply, fixedNow, func(string) {})
	body := request(record("user_prompt", 1_700_000_000_123*ms,
		str("session.id", "s1"), str("user.email", "a@example.com"),
		str("prompt", "SENTINEL_PROMPT"), str("prompt_text", "SENTINEL_TEXT"), str("tool_input", "SENTINEL_TOOL"),
		str("user.account_uuid", "SENTINEL_UUID"), integer("event.sequence", 3)))
	serveOnce(h, "POST", "/v1/logs", "application/json", body)
	want := anchor.Event{Name: "user_prompt", SessionID: "s1", Email: "a@example.com", TS: 1_700_000_000_123}
	if len(rec.events) != 1 || rec.events[0] != want {
		t.Fatalf("이벤트 = %+v, want [%+v]", rec.events, want)
	}
}

func TestHandlerNormalisesSuccessAndTimestamp(t *testing.T) {
	rec := &recorder{}
	h := newHandler(rec.apply, fixedNow, func(string) {})
	body := request(
		record("auth", 1_700_000_001_000*ms, str("session.id", "s1"), str("user.email", "b@example.com"), str("action", "login"), str("success", "true")),
		record("auth", 0, str("session.id", "s2"), str("action", "login"), boolean("success", true),
			str("event.timestamp", "2026-10-23T08:47:35.547Z")),
		record("auth", 0, str("session.id", "s3"), str("action", "logout"), boolean("success", false)),
	)
	serveOnce(h, "POST", "/v1/logs", "application/json", body)
	if len(rec.events) != 3 {
		t.Fatalf("이벤트 %d개", len(rec.events))
	}
	if e := rec.events[0]; e.Success != "true" || e.Action != "login" || e.TS != 1_700_000_001_000 {
		t.Errorf("문자열 success: %+v", e)
	}
	want := time.Date(2026, 10, 23, 8, 47, 35, 547_000_000, time.UTC).UnixMilli()
	if e := rec.events[1]; e.Success != "true" || e.TS != want {
		t.Errorf("불리언 success 와 event.timestamp 대체: %+v, want ts %d", e, want)
	}
	if e := rec.events[2]; e.Success != "false" || e.TS != fixedNow().UnixMilli() {
		t.Errorf("시각이 없으면 수신 시각: %+v", e)
	}
}

func TestHandlerFallsBackToTheBodyForTheEventName(t *testing.T) {
	rec := &recorder{}
	h := newHandler(rec.apply, fixedNow, func(string) {})
	r := record("plugin_loaded", 1_700_000_000_000*ms, str("session.id", "s1"))
	r["attributes"] = []attr{str("session.id", "s1")} // no event.name attribute
	serveOnce(h, "POST", "/v1/logs", "application/json", request(r))
	if len(rec.events) != 1 || rec.events[0].Name != "claude_code.plugin_loaded" {
		t.Errorf("본문에서 이름을 얻지 못했다: %+v", rec.events)
	}
}

// stateTree concatenates every file under dir with its path, to search for values that
// must not have been stored.
func stateTree(t *testing.T, dir string) string {
	t.Helper()
	var sb strings.Builder
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			b, _ := os.ReadFile(p)
			sb.WriteString(p + "\n" + string(b) + "\n")
		}
		return nil
	})
	return sb.String()
}

func realHandler(dir string) http.Handler {
	var mu sync.Mutex
	return newHandler(func(e anchor.Event) error {
		mu.Lock()
		defer mu.Unlock()
		_, err := anchor.Apply(dir, e)
		return err
	}, fixedNow, func(string) {})
}

func post(h http.Handler, records ...map[string]any) {
	serveOnce(h, "POST", "/v1/logs", "application/json", request(records...))
}

func TestStoredStateHoldsOnlyAllowedValues(t *testing.T) {
	dir := t.TempDir()
	h := realHandler(dir)
	post(h, record("managed_settings_resolved", 1_700_000_000_000*ms, str("session.id", "s1"), str("user.email", "a@example.com"),
		str("prompt", "SENTINEL_PROMPT"), str("user.account_uuid", "SENTINEL_UUID"), str("organization.id", "SENTINEL_ORG")))
	post(h, record("user_prompt", 1_700_000_001_000*ms, str("session.id", "s1"), str("user.email", "a@example.com"),
		str("prompt", "SENTINEL_PROMPT"), str("prompt_text", "SENTINEL_TEXT")))
	tree := stateTree(t, dir)
	for _, s := range []string{"SENTINEL", "uuid", "organization"} {
		if strings.Contains(tree, s) {
			t.Errorf("상태 디렉터리에 %q 가 남았다:\n%s", s, tree)
		}
	}
	if !strings.Contains(tree, "email=a@example.com\nkind=start") {
		t.Errorf("허용 값이 저장되지 않았다:\n%s", tree)
	}
}

func TestNotLoggedInSessionStillAnchorsOnItsStartEvent(t *testing.T) {
	// 실측: 「Not logged in」 화면의 세션도 시작 이벤트에 설정 파일의 계정을 싣는다. 로그인 시도가
	// 실패해도 앵커는 그 시작 값으로 남는다 — 인증 계정이라는 보장이 아니라 알려진 한계다.
	dir := t.TempDir()
	h := realHandler(dir)
	post(h, record("managed_settings_resolved", 1_700_000_000_000*ms, str("session.id", "s1"), str("user.email", "a@example.com")))
	post(h, record("auth", 1_700_000_005_000*ms, str("session.id", "s1"), str("user.email", "a@example.com"),
		str("action", "login"), str("success", "false")))
	wantAnchor(t, dir, "s1", anchor.Anchor{Email: "a@example.com", Kind: anchor.KindStart, TS: 1_700_000_000_000})
}

func wantAnchor(t *testing.T, dir, id string, want anchor.Anchor) {
	t.Helper()
	got, ok := anchor.Read(dir, id)
	if !ok || got != want {
		t.Fatalf("Read(%s) = %+v, %v; want %+v", id, got, ok, want)
	}
}

func TestClearedSessionsFirstUserPromptDoesNotAnchor(t *testing.T) {
	dir := t.TempDir()
	h := realHandler(dir)
	post(h, record("managed_settings_resolved", 1_700_000_000_000*ms, str("session.id", "s1"), str("user.email", "a@example.com")))
	post(h, record("user_prompt", 1_700_000_100_000*ms, str("session.id", "s2"), str("user.email", "other@example.com"), str("command_name", "clear")))
	if got, ok := anchor.Read(dir, "s2"); ok {
		t.Errorf("/clear 한 세션의 user_prompt 가 앵커를 만들었다: %+v", got)
	}
}

func TestLoginArrivingBeforeTheStartEventWins(t *testing.T) {
	dir := t.TempDir()
	h := realHandler(dir)
	post(h, record("auth", 1_700_000_005_000*ms, str("session.id", "s1"), str("user.email", "b@example.com"), str("action", "login"), str("success", "true")))
	post(h, record("managed_settings_resolved", 1_700_000_000_000*ms, str("session.id", "s1"), str("user.email", "a@example.com")))
	wantAnchor(t, dir, "s1", anchor.Anchor{Email: "b@example.com", Kind: anchor.KindLogin, TS: 1_700_000_005_000})
}
