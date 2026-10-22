package render

import (
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/silee-tools/claude-statusline/internal/shorten"
	"github.com/silee-tools/claude-statusline/internal/theme"
	"github.com/silee-tools/claude-statusline/internal/width"
)

const session = "11111111-2222-3333-4444-555555555555"

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plain(s string) string { return ansi.ReplaceAllString(s, "") }

func sample() View {
	return View{
		Clock: "08:06", Path: "~/proj", Branch: "main",
		Meta:  []string{"octocat@example.com", "gh@personal", "aws:✓"},
		Model: "Opus 4.8", Effort: "●", CtxPct: 20,
		Five:    Gauge{Present: true, Pct: 24, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000},
		Week:    Gauge{Present: true, Pct: 41, ResetsAt: 2_000_600_000, HasReset: true, Window: 604800},
		Version: "2.1.11", Session: session, Width: 120,
	}
}

func TestFullLayoutRowOrder(t *testing.T) {
	rows := strings.Split(plain(Full(sample(), 1_999_000_000)), "\n")
	if len(rows) != 4 {
		t.Fatalf("폭 안에 들면 전체 레이아웃은 4행이다: %d행 — %q", len(rows), rows)
	}
	want := []string{"08:06", "ctx", "5h", "7d"}
	for i, w := range want {
		if !strings.Contains(rows[i], w) {
			t.Errorf("행%d 에 %q 가 없다: %q", i+1, w, rows[i])
		}
	}
	for _, w := range []string{"gh@personal", "v2.1.11"} {
		if !strings.Contains(rows[0], w) {
			t.Errorf("첫 줄에 %q 가 없다: %q", w, rows[0])
		}
	}
}

// longHeader 는 경로와 브랜치를 길게 잡아 81~220열 안에서 세 단계가 모두 나오게 하는 입력이다.
func longHeader() View {
	v := sample()
	v.Path = "~/webapp/packages/app/src"
	v.Branch = "feature/PROJ-123-post-editor"
	return v
}

// inset 은 Claude Code 가 상태줄 양쪽에 남기는 칸(왼쪽 들여쓰기 2 + 오른쪽 비움 2)이다. 구현의
// statusInset 을 가져다 쓰지 않고 따로 선언하므로, 구현의 값이 바뀌면 이 시험이 잡는다.
const inset = 4

// spaced 는 두 묶음을 공백 두 칸으로 잇고 빈 묶음은 건너뛴다.
func spaced(a, b string) string {
	if a == "" || b == "" {
		return a + b
	}
	return a + "  " + b
}

// header 는 첫 줄의 두 덩어리를 이루는 묶음이다. 왼쪽 덩어리는 foot 과 meta, 오른쪽 덩어리는
// place 와 clock 이다.
type header struct{ foot, meta, place, clock string }

func (h header) left() string  { return spaced(h.foot, h.meta) }
func (h header) right() string { return spaced(h.place, h.clock) }

// headerGroups 는 첫 줄의 묶음을 입력 값에서 직접 만든다. 렌더 결과에서 읽으면 경계 계산이 검증
// 대상에 기대게 된다.
func headerGroups(v View) header {
	h := header{meta: strings.Join(v.Meta, " "), place: plain(v.Path), clock: v.Clock}
	if v.Branch != "" {
		h.place += " " + theme.BranchGlyph + v.Branch
	}
	if v.Version != "" {
		h.foot = "v" + v.Version
	}
	if v.Session != "" {
		if h.foot != "" {
			h.foot += " "
		}
		h.foot += theme.SessionGlyph + " " + v.Session
	}
	return h
}

func TestFullWithoutWidthJoinsInTheNewOrder(t *testing.T) {
	v := sample()
	v.Width = 0
	rows := strings.Split(plain(Full(v, 1_999_000_000)), "\n")
	if len(rows) != 4 {
		t.Fatalf("폭을 모르면 첫 줄을 정렬 없이 이어 붙여 4행이다: %d행 — %q", len(rows), rows)
	}
	h := headerGroups(v)
	if want := h.foot + "  " + h.meta + "  " + h.place + "  " + h.clock; rows[0] != want {
		t.Errorf("첫 줄 = %q, want %q", rows[0], want)
	}
	for i, want := range map[int]string{1: "ctx ", 2: " 5h ", 3: " 7d "} {
		if !strings.HasPrefix(rows[i], want) {
			t.Errorf("행%d 라벨 = %q, want prefix %q", i+1, rows[i], want)
		}
	}
}

func TestFullSkipsInvisiblePathBeforeJoiningGroups(t *testing.T) {
	v := sample()
	v.Path = shorten.Path("", "/Users/test")
	v.Branch = ""
	v.Meta = []string{"user@example.com", "aws:✓"}
	v.Width = 81
	if got := width.Visible(v.Path); got != 0 {
		t.Fatalf("빈 CWD 경로는 표시 폭 0이어야 한다: %d — %q", got, v.Path)
	}

	h := headerGroups(v)
	for _, tc := range []struct {
		name  string
		width int
		gap   int
	}{
		{"폭 81의 경계", 81, 81 - inset - width.Visible(h.left()) - width.Visible(h.clock)},
		{"폭을 모름", 0, 2},
	} {
		v.Width = tc.width
		rows := strings.Split(plain(Full(v, 1_999_000_000)), "\n")
		if len(rows) != 4 {
			t.Errorf("%s: 헤더와 게이지가 4행이어야 한다: %d행 — %q", tc.name, len(rows), rows)
			continue
		}
		want := h.left() + strings.Repeat(" ", tc.gap) + h.clock
		if rows[0] != want {
			t.Errorf("%s: 첫 줄 = %q, want %q", tc.name, rows[0], want)
		}
		if tc.width > 0 && width.Visible(rows[0]) != tc.width-inset {
			t.Errorf("%s: 첫 줄 폭 = %d, want %d", tc.name, width.Visible(rows[0]), tc.width-inset)
		}
	}
}

func TestFullFirstRowOrder(t *testing.T) {
	// 자주 바뀌지 않는 것(버전·세션, 계정)이 왼쪽에, 자주 바뀌는 것(경로·브랜치, 시각)이 오른쪽에 온다.
	v := longHeader()
	v.Width = 216
	rows := strings.Split(plain(Full(v, 1_999_000_000)), "\n")
	if len(rows) != 4 {
		t.Fatalf("폭 216 은 4행이다: %d행 — %q", len(rows), rows)
	}
	h := headerGroups(v)
	first, at := rows[0], -1
	for _, piece := range []string{h.foot, h.meta, h.place, h.clock} {
		i := strings.Index(first, piece)
		if i <= at {
			t.Errorf("첫 줄에서 %q 의 자리 %d 가 앞 묶음(%d) 뒤가 아니다: %q", piece, i, at, first)
		}
		at = i
	}
	if !strings.HasPrefix(first, h.foot) || !strings.HasSuffix(first, h.clock) {
		t.Errorf("첫 줄은 버전으로 시작해 시각으로 끝나야 한다: %q", first)
	}
}

func TestFullJustifiesToTheStatusLineWidth(t *testing.T) {
	// 두 덩어리가 들어가는 폭에서는 첫 줄이 Claude Code 가 쓰는 폭(칸 수 − 4)을 정확히 채우고,
	// 왼쪽 덩어리로 시작해 오른쪽 덩어리로 끝나며 그 사이는 공백 두 칸 이상이다.
	now := int64(1_999_000_000)
	for name, base := range map[string]View{"짧은 경로": sample(), "긴 경로": longHeader()} {
		for _, withBranch := range []bool{true, false} {
			for _, w := range []int{81, 100, 120, 216, 400} {
				v := base
				if !withBranch {
					v.Branch = ""
				}
				v.Width = w
				h := headerGroups(v)
				left, right := h.left(), h.right()
				fits := width.Visible(left)+2+width.Visible(right)+inset <= w
				if w >= 216 && !fits {
					t.Fatalf("%s 브랜치 %v 폭 %d: 양성 대조 — 이 입력은 1단계에 들어가야 한다", name, withBranch, w)
				}
				rows := strings.Split(plain(Full(v, now)), "\n")
				if (len(rows) == 4) != fits {
					t.Errorf("%s 브랜치 %v 폭 %d: 두 덩어리가 들면 %v, %d행 — %q", name, withBranch, w, fits, len(rows), rows)
					continue
				}
				if !fits {
					continue
				}
				first := rows[0]
				if got := width.Visible(first); got != w-inset {
					t.Errorf("%s 브랜치 %v 폭 %d: 첫 줄 폭 %d, want %d — %q", name, withBranch, w, got, w-inset, first)
				}
				if !strings.HasPrefix(first, left) || !strings.HasSuffix(first, right) || len(first) < len(left)+len(right) {
					t.Errorf("%s 브랜치 %v 폭 %d: 첫 줄이 %q 로 시작해 %q 로 끝나야 한다 — %q", name, withBranch, w, left, right, first)
					continue
				}
				if gap := first[len(left) : len(first)-len(right)]; len(gap) < 2 || strings.Trim(gap, " ") != "" {
					t.Errorf("%s 브랜치 %v 폭 %d: 두 덩어리 사이가 공백 두 칸 이상이어야 한다 — %q", name, withBranch, w, gap)
				}
			}
		}
	}
}

func TestFullRetreatsOneStageAtATimeAsWidthShrinks(t *testing.T) {
	// 두 덩어리가 칸 수 − 4 안에 정확히 들면 4행, 한 칸 모자라면 푸터(버전·세션)를 마지막 줄로 내린
	// 5행이다. 계정 덩어리와 오른쪽 덩어리가 정확히 들면 5행이고 한 칸 모자라면 위치·계정·게이지·푸터의 6행이다.
	now := int64(1_999_000_000)
	for name, branch := range map[string]string{"브랜치 있음": "feature/PROJ-123-post-editor", "브랜치 없음": ""} {
		v := longHeader()
		v.Branch = branch
		h := headerGroups(v)
		right := h.right()
		needAll := width.Visible(h.left()) + 2 + width.Visible(right) + inset
		needHead := width.Visible(h.meta) + 2 + width.Visible(right) + inset
		rowsAt := func(w int) []string {
			v.Width = w
			return strings.Split(plain(Full(v, now)), "\n")
		}
		gauges := strings.Join(rowsAt(needAll)[1:4], "\n")

		rows := rowsAt(needAll)
		if len(rows) != 4 || rows[0] != h.left()+"  "+right {
			t.Errorf("%s 폭 %d: 두 덩어리를 공백 두 칸으로 맞춘 4행이어야 한다 — %q", name, needAll, rows)
		}
		wide := rowsAt(needAll - 1)
		wantWide := h.meta + strings.Repeat(" ", needAll-1-inset-width.Visible(h.meta)-width.Visible(right)) + right
		if len(wide) != 5 || wide[0] != wantWide || wide[4] != h.foot || strings.Join(wide[1:4], "\n") != gauges {
			t.Errorf("%s 폭 %d: 계정+오른쪽 덩어리 첫 줄, 게이지, 푸터의 5행이어야 한다 — %q", name, needAll-1, wide)
		}
		rows = rowsAt(needHead)
		if len(rows) != 5 || rows[0] != h.meta+"  "+right || rows[4] != h.foot || strings.Join(rows[1:4], "\n") != gauges {
			t.Errorf("%s 폭 %d: 계정+오른쪽 덩어리를 공백 두 칸으로 맞춘 5행이어야 한다 — %q", name, needHead, rows)
		}
		rows = rowsAt(needHead - 1)
		want := strings.Join([]string{right, h.meta, gauges, h.foot}, "\n")
		if strings.Join(rows, "\n") != want {
			t.Errorf("%s 폭 %d: 위치, 계정, 게이지, 푸터의 6행이어야 한다 — %q, want %q", name, needHead-1, rows, want)
		}
	}
}

func TestFullFirstRowNeverOverflowsAndRetreatsOnlyAsFarAsNeeded(t *testing.T) {
	// 81~220열을 돌며 칸 수 − 4 안에 드는 가장 합쳐진 단계가 쓰이는지 본다. 세 단계가 모두 나타나야
	// 이 구간이 단계 전환을 실제로 지나간다는 양성 대조가 선다.
	now := int64(1_999_000_000)
	v := longHeader()
	h := headerGroups(v)
	needAll := width.Visible(h.left()) + 2 + width.Visible(h.right()) + inset
	needHead := width.Visible(h.meta) + 2 + width.Visible(h.right()) + inset
	stages := map[int]int{}
	for w := 81; w <= 220; w++ {
		v.Width = w
		out := plain(Full(v, now))
		rows := strings.Split(out, "\n")
		stages[len(rows)]++
		wantRows := 6
		switch {
		case w >= needAll:
			wantRows = 4
		case w >= needHead:
			wantRows = 5
		}
		if len(rows) != wantRows {
			t.Errorf("폭 %d: %d행, want %d행 — %q", w, len(rows), wantRows, rows)
		}
		if len(rows) < 6 {
			if got := width.Visible(rows[0]); got != w-inset {
				t.Errorf("폭 %d: 정렬한 첫 줄 폭 %d, want %d — %q", w, got, w-inset, rows[0])
			}
		}
		for _, piece := range []string{h.foot, h.meta, h.place, h.clock} {
			if !strings.Contains(out, piece) {
				t.Errorf("폭 %d: 표시 항목 %q 가 사라졌다", w, piece)
			}
		}
	}
	for _, n := range []int{4, 5, 6} {
		if stages[n] == 0 {
			t.Errorf("81~220열에 %d행 단계가 한 번도 나오지 않았다: %v", n, stages)
		}
	}
}

func TestFullSkipsEmptyHeaderGroupsWithoutGaps(t *testing.T) {
	// 빈 묶음은 건너뛰어 어긋난 공백을 남기지 않는다. 폭이 있으면 첫 줄은 두 덩어리 사이만 비우고,
	// 한쪽 덩어리만 남으면 정렬하지 않는다.
	now := int64(1_999_000_000)
	wideGap := regexp.MustCompile(` {3,}`)
	for _, tc := range []struct {
		name   string
		mutate func(*View)
		first  func(h header) string // 폭 0 의 첫 줄
		spread bool                  // 왼쪽 덩어리가 남아 있어 폭이 있으면 양끝으로 벌린다
	}{
		{"계정 없음", func(v *View) { v.Meta = nil }, func(h header) string { return h.foot + "  " + h.right() }, true},
		{"버전·세션 없음", func(v *View) { v.Version, v.Session = "", "" }, func(h header) string { return h.meta + "  " + h.right() }, true},
		{"세션 없음(버전만 남음)", func(v *View) { v.Session = "" }, func(h header) string { return h.foot + "  " + h.meta + "  " + h.right() }, true},
		{"계정·버전·세션 없음", func(v *View) { v.Meta, v.Version, v.Session = nil, "", "" }, func(h header) string { return h.right() }, false},
	} {
		v := longHeader()
		tc.mutate(&v)
		h := headerGroups(v)
		v.Width = 0
		rows := strings.Split(plain(Full(v, now)), "\n")
		if want := tc.first(h); len(rows) != 4 || rows[0] != want {
			t.Errorf("%s 폭 0: 첫 줄 %q (%d행), want %q (4행)", tc.name, rows[0], len(rows), want)
		}
		for _, w := range []int{0, 81, 90, 100, 120, 140, 220} {
			v.Width = w
			for i, row := range strings.Split(plain(Full(v, now)), "\n") {
				if strings.ContainsAny(row, "█░") {
					continue // 게이지 행은 라벨을 오른쪽 정렬하므로 공백 규칙이 다르다
				}
				if row == "" || row != strings.TrimSpace(row) {
					t.Errorf("%s 폭 %d 행%d 에 빈 줄이나 가장자리 공백이 있다: %q", tc.name, w, i+1, row)
				}
				gaps := wideGap.FindAllString(row, -1)
				if len(gaps) > 0 && (!tc.spread || i != 0 || len(gaps) != 1 || !strings.HasSuffix(row, h.right())) {
					t.Errorf("%s 폭 %d 행%d 에 두 덩어리 사이가 아닌 넓은 공백이 있다: %q", tc.name, w, i+1, row)
				}
				if !tc.spread && i == 0 && row != h.right() {
					t.Errorf("%s 폭 %d: 한쪽 덩어리만 남으면 정렬하지 않고 왼쪽에서 시작한다 — %q, want %q", tc.name, w, row, h.right())
				}
			}
		}
		// 양성 대조: 넓은 폭에서 두 덩어리를 가진 입력은 실제로 벌어진다.
		v.Width = 220
		first := strings.Split(plain(Full(v, now)), "\n")[0]
		if tc.spread != wideGap.MatchString(first) {
			t.Errorf("%s 폭 220: 첫 줄이 벌어졌는가 = %v, want %v — %q", tc.name, wideGap.MatchString(first), tc.spread, first)
		}
	}
}

func TestFullGaugeRowsDoNotDependOnWidth(t *testing.T) {
	// 폭은 첫 줄의 배치만 정한다. 게이지 세 줄(색 코드 포함)은 어느 단계에서도 같다.
	now := int64(1_999_000_000)
	gaugeRows := func(w int) string {
		v := longHeader()
		v.Width = w
		var kept []string
		for _, row := range strings.Split(Full(v, now), "\n") {
			if strings.ContainsAny(row, "█░") {
				kept = append(kept, row)
			}
		}
		return strings.Join(kept, "\n")
	}
	want := gaugeRows(0)
	if n := strings.Count(want, "\n"); n != 2 {
		t.Fatalf("양성 대조: 게이지 행이 세 줄이어야 한다: %q", want)
	}
	for _, w := range []int{81, 100, 105, 120, 153, 216, 400} {
		if got := gaugeRows(w); got != want {
			t.Errorf("폭 %d 의 게이지 행이 폭 0 과 다르다: %q, want %q", w, got, want)
		}
	}
}

func TestSpreadFitsGroupsIntoTheStatusLineWidth(t *testing.T) {
	// 사용 폭은 칸 수 − 4 이다. 두 덩어리는 사이가 두 칸 이상이어야 들어가고, 남는 칸은 사이를 채운다.
	// 한쪽만 있으면 정렬하지 않고 폭 안에 드는지만 본다. 한쪽 덩어리의 경계는 Full 의 출력에 드러나지
	// 않으므로(어느 쪽이든 같은 행이 나온다) 여기서 직접 확인한다.
	for _, tc := range []struct {
		name        string
		width       int
		left, right string
		want        string
		ok          bool
	}{
		{"폭을 모르면 이어 붙임", 0, "ab", "cd", "ab  cd", true},
		{"사이가 정확히 두 칸", 10 + inset, "abcd", "wxyz", "abcd  wxyz", true},
		{"사이가 한 칸이면 들지 않음", 9 + inset, "abcd", "wxyz", "", false},
		{"남는 칸은 사이를 채움", 14 + inset, "abcd", "wxyz", "abcd      wxyz", true},
		{"왼쪽만 정확히 듦", 4 + inset, "abcd", "", "abcd", true},
		{"왼쪽만 한 칸 넘침", 3 + inset, "abcd", "", "", false},
		{"오른쪽만 정확히 듦", 4 + inset, "", "wxyz", "wxyz", true},
		{"오른쪽만 한 칸 넘침", 3 + inset, "", "wxyz", "", false},
		{"오른쪽만 있으면 폭이 남아도 정렬하지 않음", 40, "", "wxyz", "wxyz", true},
	} {
		got, ok := spread(View{Width: tc.width}, tc.left, tc.right)
		if ok != tc.ok || (ok && got != tc.want) {
			t.Errorf("%s: spread(폭 %d, %q, %q) = %q, %v; want %q, %v", tc.name, tc.width, tc.left, tc.right, got, ok, tc.want, tc.ok)
		}
	}
}

func TestFullLayoutRightAlignsTheGaugeLabels(t *testing.T) {
	// ctx·5h·7d 는 같은 라벨 폭으로 세로 정렬한다. 정렬이 깨지면 세 행의 막대 시작
	// 열이 어긋나 전체 레이아웃의 읽는 방식이 달라진다.
	rows := strings.Split(plain(Full(sample(), 1_999_000_000)), "\n")
	for i, want := range map[int]string{1: "ctx ", 2: " 5h ", 3: " 7d "} {
		if !strings.HasPrefix(rows[i], want) {
			t.Errorf("행%d 라벨 = %q, want prefix %q", i+1, rows[i], want)
		}
	}
}

func TestFullLayoutDrawsTwentyCellBars(t *testing.T) {
	rows := strings.Split(plain(Full(sample(), 1_999_000_000)), "\n")
	for i := 1; i <= 3; i++ {
		if n := strings.Count(rows[i], "█") + strings.Count(rows[i], "░"); n != 20 {
			t.Errorf("행%d 막대 칸수 %d, want 20 — %q", i+1, n, rows[i])
		}
	}
}

func TestFullLayoutMarksPaceOvershootInTheBar(t *testing.T) {
	// 5시간 창의 절반이 지났으면 예산은 10칸이다. 소진율 70% 는 14칸이라 11번째 칸부터 끝까지
	// 열 칸이 초과 구간이 되고, 그 구간만 페이스 색으로 칠해진다.
	v := sample()
	v.Five = Gauge{Present: true, Pct: 70, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	rows := strings.Split(Full(v, 2_000_000_000-9000), "\n")
	if n := strings.Count(rows[2], theme.Red); n != 10 {
		t.Errorf("초과 구간 칸 %d, want 10 — %q", n, rows[2])
	}
	if n := strings.Count(rows[2], theme.Grey240); n != 10 {
		t.Errorf("예산 이내 칸 %d, want 10 — %q", n, rows[2])
	}
	if strings.Contains(plain(rows[2]), "▲") {
		t.Errorf("전체 레이아웃은 압축 페이스 기호를 쓰지 않는다: %q", rows[2])
	}
}

func TestBarStaysGreyWhileUsageKeepsPace(t *testing.T) {
	// 막대의 색은 페이스 초과 하나만 뜻한다. 그래서 소진율이 아무리 높아도 페이스를 지키는
	// 동안에는 막대에 경고색이 없고, 소진율의 심각도는 옆의 백분율이 혼자 말한다. 이 단언이
	// 무너지면 색 채널이 다시 두 가지를 뜻하게 되어 아래 경계 단언도 함께 의미를 잃는다.
	v := sample()
	v.Five = Gauge{Present: true, Pct: 92, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	rows := strings.Split(Full(v, 2_000_000_000-900), "\n")
	if n := strings.Count(rows[2], theme.Grey240); n != 20 {
		t.Errorf("페이스 이내면 20칸이 모두 회색이다: %d — %q", n, rows[2])
	}
	for _, color := range []string{theme.Yellow, theme.Red} {
		for _, cell := range []string{"█", "░"} {
			if strings.Contains(rows[2], color+cell) {
				t.Errorf("페이스 이내인데 막대 칸에 경고색이 붙었다: %q", rows[2])
			}
		}
	}
}

func TestHighUsageKeepsTheOvershootBoundaryVisible(t *testing.T) {
	// 소진율이 90% 를 넘으면 예전에는 막대 전체가 빨강이라 페이스 초과 경계가 사라졌다. 창의
	// 20% 만 지난 시점의 95% 는 예산 4칸에 소진 19칸이므로, 앞의 네 칸만 회색이고 나머지
	// 열여섯 칸이 초과 구간이다.
	v := sample()
	v.Five = Gauge{Present: true, Pct: 95, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	rows := strings.Split(Full(v, 2_000_000_000-14400), "\n")
	if n := strings.Count(rows[2], theme.Grey240); n != 4 {
		t.Errorf("예산 이내 칸 %d, want 4 — %q", n, rows[2])
	}
	if n := strings.Count(rows[2], theme.Red+"█") + strings.Count(rows[2], theme.Red+"░"); n != 16 {
		t.Errorf("초과 구간 칸 %d, want 16 — %q", n, rows[2])
	}
}

func TestFullLayoutKeepsTheWholeSessionID(t *testing.T) {
	// 전체 ID 를 남기는 이유는 사용자가 그것을 복사해 쓰기 때문이다. 첫 줄에 합치든(폭 0)
	// 마지막 줄로 내리든(130) 여섯 줄로 나누든(100) 같다.
	v := longHeader()
	for _, w := range []int{0, 130, 100} {
		v.Width = w
		if !strings.Contains(plain(Full(v, 1_999_000_000)), session) {
			t.Fatalf("폭 %d: 전체 레이아웃은 세션 식별자를 자르지 않는다", w)
		}
	}
}

func TestCompactLayoutIsTwoRows(t *testing.T) {
	v := sample()
	v.Width = 70
	v.Status = []string{"gh@personal"}
	rows := strings.Split(plain(Compact(v, 1_999_000_000)), "\n")
	if len(rows) != 2 {
		t.Fatalf("압축 레이아웃은 2행이다: %d행 — %q", len(rows), rows)
	}
	if want := theme.BranchGlyph + "main gh@personal"; rows[0] != want {
		t.Errorf("행1 = %q, want %q", rows[0], want)
	}
	for _, w := range []string{"ctx", "Opus 4.8", "5h", "7d"} {
		if !strings.Contains(rows[1], w) {
			t.Errorf("행2 에 %q 가 없다: %q", w, rows[1])
		}
	}
	if strings.Contains(rows[1], "█") || strings.Contains(rows[1], "░") {
		t.Errorf("압축 레이아웃에는 막대를 그리지 않는다: %q", rows[1])
	}
	out := plain(Compact(v, 1_999_000_000))
	for _, gone := range []string{"08:06", "~/proj", "octocat@example.com", "v2.1.11", theme.SessionGlyph, "aws:✓"} {
		if strings.Contains(out, gone) {
			t.Errorf("압축 레이아웃에 %q 가 남았다: %q", gone, out)
		}
	}
}

func TestCompactShowsUnknownIndicatorsToo(t *testing.T) {
	// 불명(?)도 이상과 같이 1행에 보인다. 침묵은 정상만 뜻하게 한다.
	v := sample()
	v.Width = 70
	v.Status = []string{"gh@personal?", "aws:?"}
	if row := strings.Split(plain(Compact(v, 1_999_000_000)), "\n")[0]; !strings.Contains(row, "gh@personal? aws:?") {
		t.Errorf("불명 지표가 1행에 없다: %q", row)
	}
}

func TestCompactOutsideARepositoryOmitsTheFirstRow(t *testing.T) {
	v := sample()
	v.Width, v.Branch, v.Status = 70, "", nil
	rows := strings.Split(plain(Compact(v, 1_999_000_000)), "\n")
	if len(rows) != 1 || !strings.HasPrefix(rows[0], "ctx") {
		t.Fatalf("저장소 밖 정상 상태는 게이지 행만 낸다: %q", rows)
	}
	v.Status = []string{"aws:expired"}
	rows = strings.Split(plain(Compact(v, 1_999_000_000)), "\n")
	if len(rows) != 2 || rows[0] != "aws:expired" {
		t.Fatalf("저장소 밖 aws 이상은 aws 만 1행에 낸다: %q", rows)
	}
}

func TestCompactNeverCutsTheIndicators(t *testing.T) {
	// 예산 = 폭 - 2(글리프) - 1(공백) - 지표 폭. 지표 "gh@personal aws:expired" 는 23열이다.
	v := sample()
	v.Branch = "feature/long-branch-name"
	v.Status = []string{"gh@personal", "aws:expired"}

	v.Width = 34 // 예산 8: 브랜치를 줄임표로 자른다
	row := strings.Split(plain(Compact(v, 1_999_000_000)), "\n")[0]
	if want := theme.BranchGlyph + "feature… gh@personal aws:expired"; row != want {
		t.Errorf("예산 8: %q, want %q", row, want)
	}

	v.Width = 33 // 예산 7: 브랜치를 통째로 뺀다
	row = strings.Split(plain(Compact(v, 1_999_000_000)), "\n")[0]
	if want := "gh@personal aws:expired"; row != want {
		t.Errorf("예산 7: %q, want %q", row, want)
	}

	v.Width = 30 // 지표만으로도 폭 안이다
	row = strings.Split(plain(Compact(v, 1_999_000_000)), "\n")[0]
	if want := "gh@personal aws:expired"; row != want {
		t.Errorf("폭 30: %q, want %q", row, want)
	}
}

func TestCompactBranchFillsWhatTheIndicatorsLeave(t *testing.T) {
	v := sample()
	v.Branch = "feature/PROJ-1469-connect-api-secrets"
	v.Status = []string{"gh@personal"}
	v.Width = 40 // 예산 40-2-1-11 = 26. 글리프를 2열로 잡지만 Visible 은 1열이라 행은 39열이다
	row := Compact(v, 1_999_000_000)
	first := strings.Split(row, "\n")[0]
	if got := width.Visible(first); got != 39 {
		t.Errorf("1행 폭 %d, want 39 — %q", got, plain(first))
	}
	if !strings.Contains(first, "…") {
		t.Errorf("넘치면 줄임표: %q", plain(first))
	}
}

func TestCompactTrimsTheGaugeRowInOrder(t *testing.T) {
	// 폭이 모자라면 🔥 → 7d 리셋 → 5h 리셋 → 모델·강도 순으로 뗀다. 각 단계 문자열의 폭에서는
	// 그 단계가, 폭이 1 줄면 다음 단계가 나온다.
	now := int64(1_999_991_000)
	v := sample()
	v.Branch, v.Status = "", nil
	v.Five = Gauge{Present: true, Pct: 70, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	v.Week = Gauge{Present: true, Pct: 10, ResetsAt: now + 200000, HasReset: true, Window: 604800}
	steps := []string{
		"ctx 20% Opus 4.8 ● 5h 70%▲ ↺2h30m (🔥1h) 7d 10% ↺2d7h",
		"ctx 20% Opus 4.8 ● 5h 70%▲ ↺2h30m 7d 10% ↺2d7h",
		"ctx 20% Opus 4.8 ● 5h 70%▲ ↺2h30m 7d 10%",
		"ctx 20% Opus 4.8 ● 5h 70%▲ 7d 10%",
		"ctx 20% 5h 70%▲ 7d 10%",
	}
	v.Width = 0
	if got := plain(Compact(v, now)); got != steps[0] {
		t.Errorf("폭 미지정은 절단하지 않는다: %q, want %q", got, steps[0])
	}
	for i, want := range steps {
		v.Width = width.Visible(want)
		if got := plain(Compact(v, now)); got != want {
			t.Errorf("단계 %d 폭 %d: %q, want %q", i, v.Width, got, want)
		}
		if i+1 < len(steps) {
			v.Width--
			if got := plain(Compact(v, now)); got != steps[i+1] {
				t.Errorf("단계 %d 폭 %d: %q, want %q", i+1, v.Width, got, steps[i+1])
			}
		}
	}
}

func TestCompactMarksPaceWithATriangle(t *testing.T) {
	// 7d 를 비워 ▲ 의 출처를 5h 하나로 좁힌다. 두 창을 함께 두면 다른 창의 초과가
	// 이 단언을 통과시켜 5h 의 페이스 판정을 검증하지 못한다.
	v := sample()
	v.Width, v.Week = 70, Gauge{}
	v.Five = Gauge{Present: true, Pct: 70, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	rows := strings.Split(plain(Compact(v, 2_000_000_000-9000)), "\n")
	if !strings.Contains(rows[1], "▲") {
		t.Errorf("초과 시 ▲ 표시: %q", rows[1])
	}
	v.Five.Pct = 40
	rows = strings.Split(plain(Compact(v, 2_000_000_000-9000)), "\n")
	if strings.Contains(rows[1], "▲") {
		t.Errorf("여유면 ▲ 없음: %q", rows[1])
	}
}

func TestPaceMarkerShowsOverpaceDurationAfterReset(t *testing.T) {
	reset := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.Local)
	now := time.Date(2026, time.August, 26, 8, 0, 0, 0, time.Local)
	v := sample()
	v.Five = Gauge{}
	v.Week = Gauge{Present: true, Pct: 70, ResetsAt: reset.Unix(), HasReset: true, Window: sevenDayWindow}
	want := "↺4d16h (🔥1d4h)"

	for name, out := range map[string]string{
		"full":    Full(v, now.Unix()),
		"compact": Compact(v, now.Unix()),
	} {
		if !strings.Contains(plain(out), want) {
			t.Errorf("%s 레이아웃의 오버페이스 시간 = %q, want %q", name, plain(out), want)
		}
	}
}

func TestPaceMarkerOmitsOverpaceWhenUsageKeepsPace(t *testing.T) {
	now := int64(2_000_000_000)
	v := sample()
	v.Week = Gauge{}
	v.Five = Gauge{Present: true, Pct: 30, ResetsAt: now + 2*60*60 + 18*60, HasReset: true, Window: 18000}

	for name, out := range map[string]string{
		"full":    Full(v, now),
		"compact": Compact(v, now),
	} {
		if strings.Contains(plain(out), "(🔥") {
			t.Errorf("%s 레이아웃이 정상 페이스에 오버페이스 괄호를 표시한다: %q", name, plain(out))
		}
	}
}

func TestCompactRowsFitEveryWidth(t *testing.T) {
	// 모든 행의 표시 폭이 감지 폭 이하다. 지표(gh·aws)는 자르지 않으므로 가장 긴 조합
	// "gh@personal! aws:expired"(24열)가 30열 안에 들어가는 것까지 함께 확인한다.
	hangul := "feature/한글-브랜치-이름-매우-길어서-절단된다"
	cases := map[string]func(*View){
		"정상 gh 상시 표시": func(v *View) { v.Status = []string{"gh@personal"} },
		"확정 이상":       func(v *View) { v.Status = []string{"gh@personal!", "aws:expired"}; v.Branch = hangul },
		"불명도 표시":      func(v *View) { v.Status = []string{"gh@personal?", "aws:?"} },
		"저장소 밖 1행 생략": func(v *View) { v.Branch, v.Status = "", nil },
		"gh 없음":       func(v *View) { v.Status = nil },
		"긴 브랜치":       func(v *View) { v.Status = []string{"gh@personal"}; v.Branch = "feature/PROJ-1469-connect-api-secrets" },
	}
	for name, mutate := range cases {
		for _, w := range []int{30, 40, 50, 60, 80} {
			v := sample()
			v.Five = Gauge{Present: true, Pct: 70, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
			v.Width = w
			mutate(&v)
			for i, row := range strings.Split(Compact(v, 1_999_991_000), "\n") {
				if got := width.Visible(row); got > w {
					t.Errorf("%s 폭 %d 행%d 표시 폭 %d: %q", name, w, i+1, got, plain(row))
				}
			}
		}
	}
}

func TestCompactTinyWidthStillPrintsTheGaugeRow(t *testing.T) {
	v := sample()
	v.Width = 3
	if out := Compact(v, 1_999_000_000); !strings.Contains(plain(out), "ctx") {
		t.Fatalf("좁은 폭에서 게이지 행이 사라졌다: %q", plain(out))
	}
}

func TestEmptyValuesDoNotProduceBlankLines(t *testing.T) {
	// 값이 없는 항목은 줄에서 자연히 빠지고, 줄 전체가 비면 그 줄을 내지 않는다.
	v := View{Clock: "08:06", Path: "~/proj", CtxPct: 5, Width: 120}
	out := Full(v, 1_999_000_000)
	for _, row := range strings.Split(out, "\n") {
		if strings.TrimSpace(plain(row)) == "" {
			t.Fatalf("빈 줄이 나왔다: %q", out)
		}
	}
	if strings.HasSuffix(out, "\n") {
		t.Fatal("출력 끝에 개행을 붙이지 않는다")
	}
	compact := Compact(v, 1_999_000_000)
	for _, row := range strings.Split(compact, "\n") {
		if strings.TrimSpace(plain(row)) == "" {
			t.Fatalf("압축에 빈 줄이 나왔다: %q", compact)
		}
	}
	if strings.HasSuffix(compact, "\n") {
		t.Fatal("압축 출력 끝에 개행을 붙이지 않는다")
	}
}

func TestGaugeWithoutResetOmitsTheResetToken(t *testing.T) {
	v := sample()
	v.Five = Gauge{Present: true, Pct: 24, Window: 18000}
	rows := strings.Split(Full(v, 1_999_000_000), "\n")
	if strings.Contains(plain(rows[2]), "↺") {
		t.Fatalf("리셋 시각이 없으면 ↺ 를 그리지 않는다: %q", rows[2])
	}
	for _, color := range []string{theme.Yellow, theme.Red} {
		if strings.Contains(rows[2], color) {
			t.Fatalf("리셋 시각이 없으면 예산도 없어 초과 표시를 하지 않는다: %q", rows[2])
		}
	}
}

func TestSevenDayPaceCountsWeekdaysContinuously(t *testing.T) {
	reset := time.Date(2026, time.August, 25, 0, 0, 0, 0, time.Local)
	fridayNoon := time.Date(2026, time.August, 21, 12, 0, 0, 0, time.Local)
	g := Gauge{HasReset: true, Pct: 70, ResetsAt: reset.Unix(), Window: 604800}

	budget, pace := paceOf(g, fridayNoon.Unix())
	if budget != 14 {
		t.Fatalf("금요일 정오의 업무일 페이스 예산 = %d, want 14", budget)
	}
	if pace != "" {
		t.Fatalf("금요일 정오에 페이스를 지키면 경고가 없다: %q", pace)
	}
}

func TestSevenDayPaceStopsAcrossWeekend(t *testing.T) {
	reset := time.Date(2026, time.August, 25, 0, 0, 0, 0, time.Local)
	g := Gauge{HasReset: true, ResetsAt: reset.Unix(), Window: 604800}

	for _, tc := range []struct {
		name string
		now  time.Time
		want int
	}{
		{name: "금요일 정오", now: time.Date(2026, time.August, 21, 12, 0, 0, 0, time.Local), want: 14},
		{name: "토요일 정오", now: time.Date(2026, time.August, 22, 12, 0, 0, 0, time.Local), want: 16},
		{name: "월요일 정오", now: time.Date(2026, time.August, 24, 12, 0, 0, 0, time.Local), want: 18},
	} {
		t.Run(tc.name, func(t *testing.T) {
			budget, _ := paceOf(g, tc.now.Unix())
			if budget != tc.want {
				t.Fatalf("업무일 페이스 예산 = %d, want %d", budget, tc.want)
			}
		})
	}
}

func TestAbsentGaugesDropTheirRows(t *testing.T) {
	v := sample()
	v.Five = Gauge{}
	v.Week = Gauge{}
	rows := strings.Split(plain(Full(v, 1_999_000_000)), "\n")
	if len(rows) != 2 || !strings.HasPrefix(rows[1], "ctx ") {
		t.Fatalf("5h·7d 가 없으면 합친 첫 줄과 ctx 의 2행이다: %d행 — %q", len(rows), rows)
	}
	compact := plain(Compact(v, 1_999_000_000))
	if strings.Contains(compact, "5h") || strings.Contains(compact, "7d") {
		t.Errorf("압축에서도 없는 창은 빠진다: %q", compact)
	}
	if !strings.Contains(strings.Split(compact, "\n")[1], "ctx") {
		t.Errorf("ctx 는 남는다: %q", compact)
	}
}

func TestContextColorThresholds(t *testing.T) {
	for _, c := range []struct {
		pct  int
		want string
	}{
		{30, ""}, {45, theme.Yellow}, {75, theme.Red},
	} {
		v := sample()
		v.CtxPct = c.pct
		v.Five, v.Week = Gauge{}, Gauge{}
		row := strings.Split(Full(v, 1_999_000_000), "\n")[1]
		if c.want == "" {
			if strings.Contains(row, theme.Yellow) || strings.Contains(row, theme.Red) {
				t.Errorf("ctx %d%% 에 경고색이 붙었다: %q", c.pct, row)
			}
			continue
		}
		if !strings.Contains(row, c.want+itoa(c.pct)+"%") {
			t.Errorf("ctx %d%% 숫자에 색이 안 붙었다: %q", c.pct, row)
		}
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
