package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestClaudePathsMatchShellFixtures(t *testing.T) {
	data, err := os.ReadFile("../../tests/config-paths.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name, Config, Want string
		Default            bool
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	cwd, _ := os.Getwd()
	expand := strings.NewReplacer("$HOME", home, "$PWD", cwd)
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			config, want := expand.Replace(tc.Config), expand.Replace(tc.Want)
			t.Setenv("HOME", home)
			t.Setenv("CLAUDE_CONFIG_DIR", config)
			t.Setenv("XDG_CACHE_HOME", filepath.Join(home, "cache"))
			cache := filepath.Join(home, "cache", "claude-statusline")
			account, oauth := cache, want
			if tc.Default {
				oauth = home
			} else {
				account = filepath.Join(cache, "accounts", fmt.Sprintf("%x", sha256.Sum256([]byte(want))))
			}
			got := resolveClaudePaths(home, cache)
			if got.Config != want || got.AccountCache != account || got.OAuthDir != oauth {
				t.Fatalf("paths=%+v want %s %s %s", got, want, account, oauth)
			}
			cmd := exec.Command("sh", "-c", `. ../../scripts/config-paths.sh; printf '%s\n' "$CLAUDE_SETTINGS_DIR"`)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("shell: %v %s", err, out)
			}
			if string(out) != want+"\n" {
				t.Fatalf("shell=%q", out)
			}
		})
	}
}
