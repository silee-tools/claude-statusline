package agentstatus

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type diskWindow struct {
	ID            string `json:"id"`
	Label         string `json:"label"`
	UsedPercent   int    `json:"usedPercent"`
	ResetsAt      int64  `json:"resetsAt"`
	WindowMinutes int    `json:"windowMinutes"`
}

type diskSnapshot struct {
	SchemaVersion int          `json:"schemaVersion"`
	Provider      string       `json:"provider"`
	SessionID     string       `json:"sessionID"`
	Workspace     string       `json:"workspace"`
	Model         string       `json:"model"`
	Activity      string       `json:"activity"`
	UsageWindows  []diskWindow `json:"usageWindows"`
	ObservedAt    int64        `json:"observedAt"`
}

func TestRenderAndHookUpdatesPreserveTheOtherProducerFields(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	sessionID := "../../placeholder-session"
	if err := RecordRender(root, Metadata{
		SessionID: sessionID,
		Workspace: "/tmp/example-project",
		Model:     "example-model",
	}, []Window{
		{ID: "five-hour", Label: "5 hour", UsedPercent: 24, ResetsAt: 1800000000, WindowMinutes: 300},
		{ID: "seven-day", Label: "7 day", UsedPercent: 101, ResetsAt: 1800600000, WindowMinutes: 10080},
	}, 1700000000); err != nil {
		t.Fatalf("RecordRender: %v", err)
	}

	path, body, got := readSnapshot(t, root)
	if filepath.Dir(path) != filepath.Join(root, "sessions", "claude") || filepath.Base(path) == sessionID {
		t.Fatalf("session ID가 안전한 파일명으로 바뀌지 않았다: %s", path)
	}
	if got.SchemaVersion != 1 || got.Provider != "claude" || got.Activity != "idle" {
		t.Fatalf("최초 render snapshot 계약이 다르다: %+v", got)
	}
	if got.SessionID != sessionID || got.Workspace != "/tmp/example-project" || got.Model != "example-model" {
		t.Fatalf("render metadata가 다르다: %+v", got)
	}
	if got.ObservedAt != 1700000000 || len(got.UsageWindows) != 1 || got.UsageWindows[0] != (diskWindow{
		ID: "five-hour", Label: "5 hour", UsedPercent: 24, ResetsAt: 1800000000, WindowMinutes: 300,
	}) {
		t.Fatalf("유효한 window만 기록해야 한다: %+v", got.UsageWindows)
	}
	assertMode(t, filepath.Dir(path), 0o700)
	assertMode(t, path, 0o600)

	const secret = "SENTINEL_PROMPT_AND_TOOL_ARGUMENT"
	hook := fmt.Sprintf(`{"hook_event_name":"PermissionRequest","session_id":%q,"cwd":"/tmp/changed","prompt":%q,"response":%q,"tool_input":{"value":%q}}`, sessionID, secret, secret, secret)
	if err := RecordHook(root, strings.NewReader(hook), 1700000100); err != nil {
		t.Fatalf("RecordHook: %v", err)
	}
	_, body, got = readSnapshot(t, root)
	if got.Activity != "waitingApproval" || got.ObservedAt != 1700000100 {
		t.Fatalf("hook activity가 갱신되지 않았다: %+v", got)
	}
	if got.Workspace != "/tmp/example-project" || got.Model != "example-model" || len(got.UsageWindows) != 1 {
		t.Fatalf("hook이 기존 metadata/usage를 덮었다: %+v", got)
	}
	if strings.Contains(string(body), secret) {
		t.Fatal("prompt, response 또는 tool arguments가 snapshot에 기록됐다")
	}

	if err := RecordRender(root, Metadata{
		SessionID: sessionID,
		Workspace: "/tmp/new-project",
		Model:     "new-model",
	}, []Window{{ID: "seven-day", Label: "7 day", UsedPercent: 41, ResetsAt: 1800600000, WindowMinutes: 10080}}, 1700000200); err != nil {
		t.Fatalf("두 번째 RecordRender: %v", err)
	}
	_, _, got = readSnapshot(t, root)
	if got.Activity != "waitingApproval" || got.Workspace != "/tmp/new-project" || got.Model != "new-model" || got.ObservedAt != 1700000200 {
		t.Fatalf("render가 activity를 보존하며 metadata를 갱신하지 않았다: %+v", got)
	}
	if len(got.UsageWindows) != 1 || got.UsageWindows[0].ID != "seven-day" {
		t.Fatalf("render가 usage를 교체하지 않았다: %+v", got.UsageWindows)
	}
}

func TestHookActivityMappings(t *testing.T) {
	tests := []struct {
		event, notification, want string
	}{
		{"SessionStart", "", "idle"},
		{"UserPromptSubmit", "", "working"},
		{"PermissionRequest", "", "waitingApproval"},
		{"Notification", "permission_prompt", "waitingApproval"},
		{"Notification", "idle_prompt", "waitingInput"},
		{"Stop", "", "idle"},
		{"SessionEnd", "", "inactive"},
	}
	for _, tt := range tests {
		t.Run(tt.event+tt.notification, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "state")
			payload := fmt.Sprintf(`{"hook_event_name":%q,"notification_type":%q,"session_id":"placeholder-session","cwd":"/tmp/example-project"}`, tt.event, tt.notification)
			if err := RecordHook(root, strings.NewReader(payload), 1700000000); err != nil {
				t.Fatalf("RecordHook: %v", err)
			}
			_, _, got := readSnapshot(t, root)
			if got.Activity != tt.want {
				t.Fatalf("activity = %q, want %q", got.Activity, tt.want)
			}
		})
	}
}

func TestConcurrentWritersLeaveOneCompleteJSONFile(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	const sessionID = "concurrent-placeholder-session"
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if i%2 == 0 {
				_ = RecordRender(root, Metadata{SessionID: sessionID, Workspace: "/tmp/example-project"}, nil, int64(1700000000+i))
				return
			}
			payload := fmt.Sprintf(`{"hook_event_name":"UserPromptSubmit","session_id":%q,"cwd":"/tmp/example-project"}`, sessionID)
			_ = RecordHook(root, strings.NewReader(payload), int64(1700000000+i))
		}(i)
	}
	wg.Wait()
	path, _, _ := readSnapshot(t, root)
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 1 || entries[0].Name() != filepath.Base(path) {
		t.Fatalf("부분 파일이나 임시 파일이 남았다: %v", entries)
	}
}

func readSnapshot(t *testing.T, root string) (string, []byte, diskSnapshot) {
	t.Helper()
	dir := filepath.Join(root, "sessions", "claude")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir(%s): %v", dir, err)
	}
	if len(entries) != 1 {
		t.Fatalf("snapshot 파일 수 = %d, want 1", len(entries))
	}
	path := filepath.Join(dir, entries[0].Name())
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	var got diskSnapshot
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("표준 JSON decoder가 snapshot을 거부했다: %v\n%s", err, body)
	}
	return path, body, got
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat(%s): %v", path, err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %#o, want %#o", path, got, want)
	}
}
