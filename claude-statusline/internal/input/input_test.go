package input

import (
	"strings"
	"testing"
)

func TestParseFullPayload(t *testing.T) {
	const raw = `{"session_id":"11111111-2222-3333-4444-555555555555",
	"workspace":{"current_dir":"/tmp"},
	"model":{"display_name":"Claude Opus 4.8"},
	"version":"2.1.11","effort":{"level":"high"},
	"context_window":{"context_window_size":200000,
	  "current_usage":{"input_tokens":40000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},
	"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":1799999999},
	  "seven_day":{"used_percentage":41.5,"resets_at":1800000000}}}`
	s, err := Parse(strings.NewReader(raw))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if s.CWD != "/tmp" || s.ModelDisplay != "Claude Opus 4.8" || s.Version != "2.1.11" {
		t.Fatalf("scalar fields wrong: %+v", s)
	}
	if s.Effort != "high" || s.SessionID == "" {
		t.Fatalf("effort/session wrong: %+v", s)
	}
	if got := s.ContextUsed(); got != 40000 {
		t.Fatalf("ContextUsed = %d, want 40000", got)
	}
	if !s.FiveHour.Present || s.FiveHour.Pct != 24 || s.FiveHour.ResetsAt != 1799999999 {
		t.Fatalf("five_hour wrong: %+v", s.FiveHour)
	}
	if s.SevenDay.Pct != 41 {
		t.Fatalf("소진율은 정수 부분만 쓴다: %+v", s.SevenDay)
	}
}

func TestParseMissingRateLimitsIsNotAnError(t *testing.T) {
	s, err := Parse(strings.NewReader(`{"workspace":{"current_dir":"/tmp"}}`))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if s.FiveHour.Present || s.SevenDay.Present {
		t.Fatalf("없는 rate_limits 를 있다고 판정하면 안 된다: %+v", s)
	}
	if s.WindowSize() != 200000 {
		t.Fatalf("context_window_size 부재 시 기본값 200000: %d", s.WindowSize())
	}
}

func TestParseStripsControlCharacters(t *testing.T) {
	s, err := Parse(strings.NewReader("{\"workspace\":{\"current_dir\":\"/tmp\\u001b[31m\"}}"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if strings.ContainsRune(s.CWD, 0x1b) {
		t.Fatalf("제어문자가 남았다: %q", s.CWD)
	}
}
