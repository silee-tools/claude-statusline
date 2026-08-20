package width

import (
	"regexp"
	"strings"
	"testing"
	"unicode/utf8"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

const esc = "\033"

// line1Width 는 첫 행의 전체 폭이다. 시각 5칸과 공백 1칸이 고정이고, 브랜치가 있으면
// 공백 1칸과 아이콘 1칸을 더 쓴다. Fit 은 이 고정 폭을 계산하지 않으므로 호출자 쪽 산술을
// 여기서 재현해 두 값을 함께 단언한다.
func line1Width(path, branch string) int {
	w := Visible(path)
	if branch != "" {
		w += 1 + 1 + Visible(branch)
	}
	return 5 + 1 + w
}

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

// 아래 열 케이스가 예산 분배와 절단의 계약을 고정한다. 각 케이스의 기대 폭은 임의로 고른
// 값이 아니라 예산 산술이 정하는 유일한 값이므로, 분배 규칙을 바꾸면 여기서 먼저 깨진다.
func TestFitT1KeepsInputsInsideBudget(t *testing.T) {
	p, b := Fit("~/↪2/claude-statusline", "main", 66)
	if p != "~/↪2/claude-statusline" {
		t.Errorf("짧은 경로 그대로: %q", p)
	}
	if b != "main" {
		t.Errorf("짧은 브랜치 그대로: %q", b)
	}
}

func TestFitT2SplitsBudgetInHalfWhenBothOverflow(t *testing.T) {
	p, b := Fit("~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway",
		"feature/PROJ-1469-connect-api-secrets", 66)
	if got := Visible(p); got != 33 {
		t.Errorf("경로 33칼럼: %d (%q)", got, p)
	}
	if got := Visible(b); got != 33 {
		t.Errorf("브랜치 33칼럼: %d (%q)", got, b)
	}
	if got := line1Width(p, b); got != 74 {
		t.Errorf("첫 행 74칼럼: %d", got)
	}
}

func TestFitT3GivesTheLeftoverToThePath(t *testing.T) {
	p, _ := Fit("~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway-extra-long-name-here", "main", 66)
	if got := Visible(p); got != 62 {
		t.Errorf("브랜치가 짧으면 경로가 62칼럼까지: %d (%q)", got, p)
	}
}

func TestFitT4NeverSplitsAWideRune(t *testing.T) {
	p, b := Fit("~/↪2/helper/↪2/성과-여정-2분기-리뷰-아주-긴-이름-테스트-문자열",
		"성과-여정-2분기-리뷰-아주-긴-브랜치-이름", 66)
	if got := Visible(p); got != 32 {
		t.Errorf("한글 경로 짝수 폭: %d (%q)", got, p)
	}
	if got := Visible(b); got != 32 {
		t.Errorf("한글 브랜치 짝수 폭: %d (%q)", got, b)
	}
	if got := line1Width(p, b); got != 72 {
		t.Errorf("첫 행 72칼럼: %d", got)
	}
	if !utf8.ValidString(p) || !utf8.ValidString(b) {
		t.Fatalf("절단이 룬을 쪼갰다: %q %q", p, b)
	}
}

func TestFitT5AppendsAnEllipsisWhenItCuts(t *testing.T) {
	p, b := Fit("~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway",
		"feature/PROJ-1469-connect-api-secrets", 66)
	if !strings.HasSuffix(p, "…") {
		t.Errorf("경로 줄임표: %q", p)
	}
	if !strings.HasSuffix(b, "…") {
		t.Errorf("브랜치 줄임표: %q", b)
	}
}

func TestFitT6CountsColorAsZeroWidthAndClosesTheCut(t *testing.T) {
	colored := esc + "[2m~/" + esc + "[0m" + esc + "[34mvery-long-project-directory-name-that-overflows" + esc + "[0m"
	p, _ := Fit(colored, "feature/PROJ-1469-connect-api-secrets", 66)
	if got := Visible(p); got != 33 {
		t.Errorf("색 코드 제외 폭 33: %d (%q)", got, p)
	}
	if !strings.Contains(p, esc+"[34m") {
		t.Errorf("색 코드 보존: %q", p)
	}
	if !strings.HasSuffix(p, esc+"[0m") {
		t.Errorf("잘린 줄이 리셋으로 닫힘: %q", p)
	}
}

func TestFitT7GivesTheWholeBudgetToThePathWithoutABranch(t *testing.T) {
	p, _ := Fit("~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway-extra-long-name-here-more", "", 68)
	if got := Visible(p); got != 68 {
		t.Errorf("브랜치 부재 시 경로 68칼럼: %d (%q)", got, p)
	}
	if got := line1Width(p, ""); got != 74 {
		t.Errorf("첫 행 74칼럼: %d", got)
	}
}

func TestFitT8AddsNoEscapeToPlainInput(t *testing.T) {
	p, _ := Fit("~/short", "main", 66)
	if strings.Contains(p, esc+"[") {
		t.Errorf("색 없는 입력에 이스케이프 미추가: %q", p)
	}
}

func TestFitT9SplitsACallerBudgetOfThirtyTwo(t *testing.T) {
	p, b := Fit("~/very-long-project-directory-name", "feature/very-long-branch-name", 32)
	if got := Visible(p); got != 16 {
		t.Errorf("경로 몫 16칼럼: %d (%q)", got, p)
	}
	if got := Visible(b); got != 16 {
		t.Errorf("브랜치 몫 16칼럼: %d (%q)", got, b)
	}
	if got := line1Width(p, b); got != 40 {
		t.Errorf("첫 행 40칼럼: %d", got)
	}
}

func TestFitT10UsesTheWholeCallerBudgetWithoutABranch(t *testing.T) {
	p, _ := Fit("~/very-long-project-directory-name-that-overflows", "", 34)
	if got := Visible(p); got != 34 {
		t.Errorf("경로 34칼럼: %d (%q)", got, p)
	}
	if got := line1Width(p, ""); got != 40 {
		t.Errorf("첫 행 40칼럼: %d", got)
	}
}

func TestFitNeverSplitsAMultibyteRune(t *testing.T) {
	p, b := Fit("~/저장소/아주긴한글경로이름", "feature/한글브랜치", 20)
	if !utf8.ValidString(p) || !utf8.ValidString(b) {
		t.Fatalf("절단이 룬을 쪼갰다: %q %q", p, b)
	}
	if Visible(p)+Visible(b) > 20 {
		t.Fatalf("예산 20 을 넘었다: %d", Visible(p)+Visible(b))
	}
}
