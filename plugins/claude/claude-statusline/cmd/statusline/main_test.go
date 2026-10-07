package main

import (
	"path/filepath"
	"testing"
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
