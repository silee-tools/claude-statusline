// Package agentstatus writes Claude session snapshots for local consumers.
package agentstatus

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

// Metadata identifies the Claude session observed by the statusline.
type Metadata struct {
	SessionID string
	Workspace string
	Model     string
}

// Window is one valid provider usage window.
type Window struct {
	ID            string `json:"id"`
	Label         string `json:"label"`
	UsedPercent   int    `json:"usedPercent"`
	ResetsAt      int64  `json:"resetsAt"`
	WindowMinutes int    `json:"windowMinutes,omitempty"`
}

type snapshot struct {
	SchemaVersion int      `json:"schemaVersion"`
	Provider      string   `json:"provider"`
	SessionID     string   `json:"sessionID"`
	Workspace     string   `json:"workspace"`
	Model         string   `json:"model,omitempty"`
	Activity      string   `json:"activity"`
	UsageWindows  []Window `json:"usageWindows"`
	ObservedAt    int64    `json:"observedAt"`
}

type hookPayload struct {
	Event        string `json:"hook_event_name"`
	Notification string `json:"notification_type"`
	SessionID    string `json:"session_id"`
	CWD          string `json:"cwd"`
}

// RecordRender replaces metadata and usage while preserving the last hook activity.
func RecordRender(root string, metadata Metadata, windows []Window, observedAt int64) error {
	if metadata.SessionID == "" {
		return nil
	}
	return withLock(root, metadata.SessionID, func() error {
		previous := load(snapshotPath(root, metadata.SessionID), metadata.SessionID)
		activity := previous.Activity
		if !validActivity(activity) {
			activity = "idle"
		}
		return store(root, snapshot{
			SchemaVersion: 1,
			Provider:      "claude",
			SessionID:     metadata.SessionID,
			Workspace:     metadata.Workspace,
			Model:         metadata.Model,
			Activity:      activity,
			UsageWindows:  validWindows(windows),
			ObservedAt:    observedAt,
		})
	})
}

// RecordHook updates activity while preserving metadata and usage from the last render.
func RecordHook(root string, r io.Reader, observedAt int64) error {
	var payload hookPayload
	if err := json.NewDecoder(r).Decode(&payload); err != nil {
		return err
	}
	activity, ok := hookActivity(payload.Event, payload.Notification)
	if !ok || payload.SessionID == "" {
		return nil
	}
	return withLock(root, payload.SessionID, func() error {
		current := load(snapshotPath(root, payload.SessionID), payload.SessionID)
		if current.SchemaVersion == 0 {
			current = snapshot{
				SchemaVersion: 1,
				Provider:      "claude",
				SessionID:     payload.SessionID,
				Workspace:     payload.CWD,
				UsageWindows:  []Window{},
			}
		}
		current.Activity = activity
		current.ObservedAt = observedAt
		current.UsageWindows = validWindows(current.UsageWindows)
		return store(root, current)
	})
}

// withLock은 hook과 renderer 프로세스가 한 세션의 갱신을 잃지 않게 직렬화한다.
// flock은 보유 프로세스가 끝나면 자동으로 풀린다.
func withLock(root, sessionID string, fn func() error) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return err
	}
	lockDir := filepath.Join(root, "locks")
	if err := os.MkdirAll(lockDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(lockDir, 0o700); err != nil {
		return err
	}
	sum := sha256.Sum256([]byte(sessionID))
	f, err := os.OpenFile(filepath.Join(lockDir, hex.EncodeToString(sum[:])+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return fn()
}

func hookActivity(event, notification string) (string, bool) {
	switch event {
	case "SessionStart", "Stop":
		return "idle", true
	case "UserPromptSubmit":
		return "working", true
	case "PermissionRequest":
		return "waitingApproval", true
	case "SessionEnd":
		return "inactive", true
	case "Notification":
		switch notification {
		case "permission_prompt":
			return "waitingApproval", true
		case "idle_prompt":
			return "waitingInput", true
		}
	}
	return "", false
}

func snapshotPath(root, sessionID string) string {
	sum := sha256.Sum256([]byte(sessionID))
	return filepath.Join(root, "sessions", "claude", hex.EncodeToString(sum[:])+".json")
}

func load(path, sessionID string) snapshot {
	b, err := os.ReadFile(path)
	if err != nil {
		return snapshot{}
	}
	var s snapshot
	if json.Unmarshal(b, &s) != nil || s.SchemaVersion != 1 || s.Provider != "claude" || s.SessionID != sessionID {
		return snapshot{}
	}
	return s
}

func store(root string, s snapshot) error {
	dirs := []string{root, filepath.Join(root, "sessions"), filepath.Join(root, "sessions", "claude")}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	dir := dirs[len(dirs)-1]
	tmp, err := os.CreateTemp(dir, ".snapshot-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	ok := false
	defer func() {
		tmp.Close()
		if !ok {
			os.Remove(tmpName)
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		return err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, snapshotPath(root, s.SessionID)); err != nil {
		return err
	}
	ok = true
	return nil
}

func validWindows(windows []Window) []Window {
	valid := make([]Window, 0, len(windows))
	for _, window := range windows {
		if window.UsedPercent < 0 || window.UsedPercent > 100 {
			continue
		}
		valid = append(valid, window)
	}
	return valid
}

func validActivity(activity string) bool {
	switch activity {
	case "inactive", "idle", "working", "waitingInput", "waitingApproval", "rateLimited", "resuming", "failed", "stale":
		return true
	default:
		return false
	}
}
