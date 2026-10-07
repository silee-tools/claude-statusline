package render

import (
	"regexp"
	"strings"
	"testing"
	"time"

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
		Cost:    CostLine{Available: true, Daily: []string{"Opus $12"}, Weekly: "605", Monthly: "915", MonthDays: "31"},
		Version: "2.1.11", Session: session, Width: 120,
	}
}

func TestFullLayoutRowOrder(t *testing.T) {
	rows := strings.Split(plain(Full(sample(), 1_999_000_000)), "\n")
	if len(rows) != 7 {
		t.Fatalf("전체 레이아웃은 7행이다: %d행 — %q", len(rows), rows)
	}
	want := []string{"08:06", "gh@personal", "ctx", "5h", "7d", "cost", "v2.1.11"}
	for i, w := range want {
		if !strings.Contains(rows[i], w) {
			t.Errorf("행%d 에 %q 가 없다: %q", i+1, w, rows[i])
		}
	}
}

func TestFullLayoutRightAlignsTheGaugeLabels(t *testing.T) {
	// ctx·5h·7d·cost 는 같은 라벨 폭으로 세로 정렬한다. 정렬이 깨지면 네 행의 막대 시작
	// 열이 어긋나 전체 레이아웃의 읽는 방식이 달라진다.
	rows := strings.Split(plain(Full(sample(), 1_999_000_000)), "\n")
	for i, want := range map[int]string{2: " ctx ", 3: "  5h ", 4: "  7d ", 5: "cost "} {
		if !strings.HasPrefix(rows[i], want) {
			t.Errorf("행%d 라벨 = %q, want prefix %q", i+1, rows[i], want)
		}
	}
}

func TestFullLayoutDrawsTwentyCellBars(t *testing.T) {
	rows := strings.Split(plain(Full(sample(), 1_999_000_000)), "\n")
	for i := 2; i <= 4; i++ {
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
	if n := strings.Count(rows[3], theme.Red); n != 10 {
		t.Errorf("초과 구간 칸 %d, want 10 — %q", n, rows[3])
	}
	if n := strings.Count(rows[3], theme.Grey240); n != 10 {
		t.Errorf("예산 이내 칸 %d, want 10 — %q", n, rows[3])
	}
	if strings.Contains(plain(rows[3]), "▲") {
		t.Errorf("전체 레이아웃은 압축 페이스 기호를 쓰지 않는다: %q", rows[3])
	}
}

func TestBarStaysGreyWhileUsageKeepsPace(t *testing.T) {
	// 막대의 색은 페이스 초과 하나만 뜻한다. 그래서 소진율이 아무리 높아도 페이스를 지키는
	// 동안에는 막대에 경고색이 없고, 소진율의 심각도는 옆의 백분율이 혼자 말한다. 이 단언이
	// 무너지면 색 채널이 다시 두 가지를 뜻하게 되어 아래 경계 단언도 함께 의미를 잃는다.
	v := sample()
	v.Five = Gauge{Present: true, Pct: 92, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	rows := strings.Split(Full(v, 2_000_000_000-900), "\n")
	if n := strings.Count(rows[3], theme.Grey240); n != 20 {
		t.Errorf("페이스 이내면 20칸이 모두 회색이다: %d — %q", n, rows[3])
	}
	for _, color := range []string{theme.Yellow, theme.Red} {
		for _, cell := range []string{"█", "░"} {
			if strings.Contains(rows[3], color+cell) {
				t.Errorf("페이스 이내인데 막대 칸에 경고색이 붙었다: %q", rows[3])
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
	if n := strings.Count(rows[3], theme.Grey240); n != 4 {
		t.Errorf("예산 이내 칸 %d, want 4 — %q", n, rows[3])
	}
	if n := strings.Count(rows[3], theme.Red+"█") + strings.Count(rows[3], theme.Red+"░"); n != 16 {
		t.Errorf("초과 구간 칸 %d, want 16 — %q", n, rows[3])
	}
}

func TestFullLayoutKeepsTheWholeSessionID(t *testing.T) {
	// 전체 ID 를 남기는 이유는 사용자가 그것을 복사해 쓰기 때문이다.
	if !strings.Contains(plain(Full(sample(), 1_999_000_000)), session) {
		t.Fatal("전체 레이아웃은 세션 식별자를 자르지 않는다")
	}
}

func TestFullLayoutCostRow(t *testing.T) {
	got := plain(Full(sample(), 1_999_000_000))
	row := strings.Split(got, "\n")[5]
	if want := "cost 24h Opus $12 / 7d $605 / 31d $915"; row != want {
		t.Errorf("비용 행 = %q, want %q", row, want)
	}
}

func TestFullLayoutCostRowWithoutData(t *testing.T) {
	v := sample()
	v.Cost = CostLine{MonthDays: "30"}
	row := strings.Split(plain(Full(v, 1_999_000_000)), "\n")[5]
	if want := "cost 24h $-- / 7d $-- / 30d $--"; row != want {
		t.Errorf("비용 부재 행 = %q, want %q", row, want)
	}
}

func TestFullLayoutCostRowWithNoModelOverADollar(t *testing.T) {
	v := sample()
	v.Cost = CostLine{Available: true, Weekly: "5", Monthly: "9", MonthDays: "31"}
	row := strings.Split(plain(Full(v, 1_999_000_000)), "\n")[5]
	if want := "cost 24h $0 / 7d $5 / 31d $9"; row != want {
		t.Errorf("모델 부재 행 = %q, want %q", row, want)
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
	if strings.Contains(plain(rows[3]), "↺") {
		t.Fatalf("리셋 시각이 없으면 ↺ 를 그리지 않는다: %q", rows[3])
	}
	for _, color := range []string{theme.Yellow, theme.Red} {
		if strings.Contains(rows[3], color) {
			t.Fatalf("리셋 시각이 없으면 예산도 없어 초과 표시를 하지 않는다: %q", rows[3])
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
	if len(rows) != 5 {
		t.Fatalf("5h·7d 가 없으면 5행이다: %d행 — %q", len(rows), rows)
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
		row := strings.Split(Full(v, 1_999_000_000), "\n")[2]
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
