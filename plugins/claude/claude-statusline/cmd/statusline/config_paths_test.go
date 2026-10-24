package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestClaudeConfigDirMatchesShellFixtures(t *testing.T) {
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
			if got := resolveConfigDir(home); got != want {
				t.Fatalf("config dir=%q want %q", got, want)
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
