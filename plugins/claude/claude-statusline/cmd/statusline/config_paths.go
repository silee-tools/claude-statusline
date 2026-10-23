package main

import (
	"os"
	"path/filepath"
)

// resolveConfigDir is the Claude config directory: CLAUDE_CONFIG_DIR, or ~/.claude when
// it is empty. It is made absolute and cleaned the way the shell scripts do it
// (scripts/config-paths.sh), without resolving symlinks.
func resolveConfigDir(home string) string {
	config := os.Getenv("CLAUDE_CONFIG_DIR")
	if config == "" {
		config = filepath.Join(home, ".claude")
	}
	config, _ = filepath.Abs(config)
	return config
}
