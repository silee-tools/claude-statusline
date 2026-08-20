package theme

import (
	"regexp"
	"strings"
	"testing"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plain(s string) string          { return ansiRe.ReplaceAllString(s, "") }
func countCells(s string) int        { return len([]rune(plain(s))) }
func countRune(s string, r rune) int { return strings.Count(plain(s), string(r)) }
func containsRune(s string, r rune) bool {
	return strings.ContainsRune(plain(s), r)
}

func TestGaugeColorThresholds(t *testing.T) {
	// 컨텍스트는 40/70, rate 는 80/90 임계를 호출자가 넘긴다.
	cases := []struct {
		pct, warn, danger int
		want              string
	}{
		{39, 40, 70, ""}, {40, 40, 70, Yellow}, {69, 40, 70, Yellow}, {70, 40, 70, Red},
		{79, 80, 90, ""}, {80, 80, 90, Yellow}, {89, 80, 90, Yellow}, {90, 80, 90, Red},
	}
	for _, c := range cases {
		if got := GaugeColor(c.pct, c.warn, c.danger); got != c.want {
			t.Errorf("GaugeColor(%d,%d,%d) = %q, want %q", c.pct, c.warn, c.danger, got, c.want)
		}
	}
}

func TestBarIsTwentyCells(t *testing.T) {
	for _, pct := range []int{-5, 0, 24, 100, 150} {
		if n := countCells(Bar(pct, 0, "", "", "")); n != 20 {
			t.Errorf("pct=%d 막대 칸수 %d, want 20", pct, n)
		}
	}
}

func TestBarMarksCellsBeyondBudget(t *testing.T) {
	// 소진율 70% 는 14칸, 예산이 10칸이면 11~14번째 칸이 초과 표시가 된다.
	got := Bar(70, 10, "", "", "")
	if want := 4; countRune(got, '▓') != want {
		t.Errorf("초과 칸 %d, want %d — %q", countRune(got, '▓'), want, got)
	}
	if countRune(got, '█') != 10 {
		t.Errorf("예산 안 칸이 10이 아니다: %q", got)
	}
}

func TestBarWithoutBudgetNeverMarksOverflow(t *testing.T) {
	// 리셋 시각이 없으면 예산이 없다. 셸은 그때 빈 문자열을 넘겨 초과 표시를 끄는데,
	// 예산 0(창이 막 시작해 경과가 0)은 그것과 달라 채운 칸 전부가 초과가 된다.
	// NoBudget 을 0 과 같게 두면 이 두 상태가 한 출력으로 뭉개진다.
	if n := countRune(Bar(70, NoBudget, "", "", ""), '▓'); n != 0 {
		t.Errorf("예산 부재에 초과 칸 %d, want 0", n)
	}
	if n := countRune(Bar(70, 0, "", "", ""), '▓'); n != 14 {
		t.Errorf("예산 0 이면 채운 칸 전부가 초과여야 한다: %d, want 14", n)
	}
}

func TestBarKeepsCellColorsSelfContained(t *testing.T) {
	// 셸은 칸마다 색을 켜고 바로 끈다. 한 번만 켜고 끝에서 끄는 형태로 바꾸면 이어지는
	// 세그먼트가 막대 색을 물려받아 라벨과 숫자의 색이 조용히 달라진다.
	got := Bar(10, NoBudget, Red, Dim, "")
	if n := strings.Count(got, Reset); n != 20 {
		t.Errorf("칸마다 리셋이 붙어야 한다: %d, want 20 — %q", n, got)
	}
	if !strings.HasPrefix(got, Red+"█"+Reset) {
		t.Errorf("첫 칸이 채움색으로 열리지 않았다: %q", got)
	}
}

func TestFormatReset(t *testing.T) {
	const now = 1_800_000_000
	cases := []struct {
		target int64
		want   string
	}{
		{now - 100, "↺0m"},
		{now + 48*60, "↺48m"},
		{now + 3600 + 23*60, "↺1h23m"},
		{now + 2*86400 + 3*3600, "↺2d3h"},
	}
	for _, c := range cases {
		if got := FormatReset(c.target, now); got != c.want {
			t.Errorf("FormatReset(%d) = %q, want %q", c.target, got, c.want)
		}
	}
}

func TestFormatModel(t *testing.T) {
	// 기대값은 셸 format_model 을 실제로 돌려 뽑았다.
	cases := map[string]string{
		"Claude Opus 4.8":              "Opus 4.8",
		"Claude Sonnet 4.5":            "Sonnet 4.5",
		"Opus 4.8 (something)":         "Opus 4.8",
		"Weird Model":                  "Weird Model",
		"Claude Haiku 4.5":             "Haiku 4.5",
		"Claude Opus 4.8 (1M context)": "Opus 4.8",
		"":                             "",
		"Claude Sonnet":                "Sonnet",
		"claude-opus-5":                "claude-opus-5",
		"Claude Opus 4.8 [1m]":         "Opus 4.8",
		"Opus":                         "Opus",
		"4.8":                          "4.8",
		"Claude Weird (x) y":           "Weird",
	}
	for in, want := range cases {
		if got := FormatModel(in); got != want {
			t.Errorf("FormatModel(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEffortGlyphs(t *testing.T) {
	// 글리프는 페이스 마커(▲)와 겹치면 안 된다. 겹치면 회귀 테스트가 effort 를 특정하지 못한다.
	for level, want := range map[string]rune{
		"low": '○', "medium": '◐', "high": '●', "xhigh": '◉', "max": '◈', "ultracode": '✦',
	} {
		if !containsRune(EffortGlyph(level), want) {
			t.Errorf("EffortGlyph(%q) 에 %c 가 없다", level, want)
		}
	}
	if EffortGlyph("nope") != "" {
		t.Error("모르는 effort 는 빈 문자열이어야 한다")
	}
}

func TestEffortGlyphColors(t *testing.T) {
	// 색과 모양이 함께 단계를 표현한다. statusline.test.sh 의 T9 가 색+글리프 짝을
	// 원시 출력에서 단언하므로 이 짝이 어긋나면 그 스위트가 깨진다.
	cases := map[string]string{
		"low": Green + "○", "medium": Lime + "◐", "high": Yellow + "●",
		"xhigh": Amber214 + "◉", "max": Red + "◈", "ultracode": Magenta + "✦",
	}
	for level, want := range cases {
		if got := EffortGlyph(level); !strings.HasPrefix(got, want) {
			t.Errorf("EffortGlyph(%q) = %q, want prefix %q", level, got, want)
		}
	}
}

func TestLabelIsDimmed(t *testing.T) {
	if got, want := Label("ctx"), Dim+"ctx"+Reset; got != want {
		t.Errorf("Label = %q, want %q", got, want)
	}
}
