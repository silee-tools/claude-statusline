// Package input reads the statusline payload Claude Code writes to stdin.
package input

import (
	"encoding/json"
	"io"
	"strings"
)

// Window is one rate-limit window as the payload reports it.
// Present gates rendering: the payload omits used_percentage for a window the
// session has no sample for, and such a window renders nothing at all.
// HasReset is separate because the reset token and the pace budget need
// resets_at while the percentage alone still renders.
type Window struct {
	Present  bool
	HasReset bool
	Pct      int
	ResetsAt int64
}

// Status is the whole payload after control characters are stripped.
type Status struct {
	SessionID    string
	Version      string
	CWD          string
	ModelDisplay string
	Effort       string
	FiveHour     Window
	SevenDay     Window

	windowSize  int
	inputTokens int
	cacheCreate int
	cacheRead   int
}

// ContextUsed is the token count the context gauge divides by the window size.
func (s Status) ContextUsed() int { return s.inputTokens + s.cacheCreate + s.cacheRead }

// WindowSize is the context window size, or 200000 when the payload omits it.
func (s Status) WindowSize() int {
	if s.windowSize <= 0 {
		return 200000
	}
	return s.windowSize
}

type rawWindow struct {
	UsedPercentage *float64 `json:"used_percentage"`
	ResetsAt       *float64 `json:"resets_at"`
}

type rawStatus struct {
	SessionID string `json:"session_id"`
	Version   string `json:"version"`
	Workspace struct {
		CurrentDir string `json:"current_dir"`
	} `json:"workspace"`
	Model struct {
		DisplayName string `json:"display_name"`
	} `json:"model"`
	Effort struct {
		Level string `json:"level"`
	} `json:"effort"`
	ContextWindow struct {
		ContextWindowSize int `json:"context_window_size"`
		CurrentUsage      struct {
			InputTokens              int `json:"input_tokens"`
			CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     int `json:"cache_read_input_tokens"`
		} `json:"current_usage"`
	} `json:"context_window"`
	RateLimits struct {
		FiveHour rawWindow `json:"five_hour"`
		SevenDay rawWindow `json:"seven_day"`
	} `json:"rate_limits"`
}

// Parse reads the payload to EOF and decodes it. Draining stdin keeps the writer
// from taking SIGPIPE when the fields this program ignores come late in the JSON.
func Parse(r io.Reader) (Status, error) {
	b, err := io.ReadAll(r)
	if err != nil {
		return Status{}, err
	}
	var raw rawStatus
	if err := json.Unmarshal(b, &raw); err != nil {
		return Status{}, err
	}
	return Status{
		SessionID:    stripControl(raw.SessionID),
		Version:      stripControl(raw.Version),
		CWD:          stripControl(raw.Workspace.CurrentDir),
		ModelDisplay: stripControl(raw.Model.DisplayName),
		Effort:       stripControl(raw.Effort.Level),
		FiveHour:     window(raw.RateLimits.FiveHour),
		SevenDay:     window(raw.RateLimits.SevenDay),
		windowSize:   raw.ContextWindow.ContextWindowSize,
		inputTokens:  raw.ContextWindow.CurrentUsage.InputTokens,
		cacheCreate:  raw.ContextWindow.CurrentUsage.CacheCreationInputTokens,
		cacheRead:    raw.ContextWindow.CurrentUsage.CacheReadInputTokens,
	}, nil
}

// window truncates the percentage toward zero, matching the shell's ${pct%.*}.
func window(r rawWindow) Window {
	var w Window
	if r.UsedPercentage != nil {
		w.Present = true
		w.Pct = int(*r.UsedPercentage)
	}
	if r.ResetsAt != nil {
		w.HasReset = true
		w.ResetsAt = int64(*r.ResetsAt)
	}
	return w
}

// stripControl drops the bytes `tr -d '\000-\037\177'` dropped, so a payload
// cannot inject an escape sequence into the rendered line.
func stripControl(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}
