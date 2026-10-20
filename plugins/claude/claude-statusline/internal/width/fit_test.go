package width

import (
	"testing"
	"unicode/utf8"
)

const esc = "\033"

func TestVisibleCountsWideRunesAsTwo(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"abc", 3},
		{"한글", 4},
		{esc + "[31mabc" + esc + "[0m", 3},
		{"↪2", 2},
		{"", 0},
		{"…", 1},          // … 줄임표
		{"", 1},          // 브랜치 아이콘은 사용자 영역이라 한 칸
		{"⧉", 1},          // ⧉ 세션 마커
		{"ｆｕｌｌ", 8},       // 전각은 두 칸
		{"\U0001f642", 2}, // 이모지 평면은 두 칸
	}
	for _, c := range cases {
		if got := Visible(c.in); got != c.want {
			t.Errorf("Visible(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestFit(t *testing.T) {
	cases := []struct {
		name  string
		in    string
		limit int
		want  string
	}{
		{"empty", "", 8, ""},
		{"already fits", "main", 8, "main"},
		{"exact fit", "main", 4, "main"},
		{"ellipsis", "feature/long-branch", 8, "feature…"},
		{"one column", "main", 1, "…"},
		{"wide rune", "한글브랜치", 6, "한글…"},
		{"color reset", esc + "[34mlong-branch" + esc + "[0m", 6, esc + "[34mlong-…" + esc + "[0m"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Fit(c.in, c.limit)
			if got != c.want {
				t.Errorf("Fit(%q, %d) = %q, want %q", c.in, c.limit, got, c.want)
			}
			if !utf8.ValidString(got) {
				t.Fatalf("invalid UTF-8: %q", got)
			}
			if Visible(got) > c.limit {
				t.Errorf("width %d exceeds %d: %q", Visible(got), c.limit, got)
			}
		})
	}
}
