package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
)

type claudePaths struct {
	Config, OAuthDir, AccountCache string
}

func resolveClaudePaths(home, cache string) claudePaths {
	config := os.Getenv("CLAUDE_CONFIG_DIR")
	if config == "" {
		config = filepath.Join(home, ".claude")
	}
	config, _ = filepath.Abs(config)
	base, _ := filepath.Abs(filepath.Join(home, ".claude"))
	p := claudePaths{Config: config, OAuthDir: config, AccountCache: cache}
	if config == base {
		p.OAuthDir = home
	} else {
		p.AccountCache = filepath.Join(cache, "accounts", fmt.Sprintf("%x", sha256.Sum256([]byte(config))))
	}
	return p
}
