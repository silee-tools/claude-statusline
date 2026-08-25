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
