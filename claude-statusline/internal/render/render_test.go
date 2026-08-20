package render

import (
	"regexp"
	"strings"
	"testing"

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
		if n := strings.Count(rows[i], "█") + strings.Count(rows[i], "░") + strings.Count(rows[i], "▓"); n != 20 {
			t.Errorf("행%d 막대 칸수 %d, want 20 — %q", i+1, n, rows[i])
		}
	}
}

func TestFullLayoutMarksPaceOvershootInTheBar(t *testing.T) {
	// 5시간 창의 절반이 지났으면 예산은 10칸이다. 소진율 70% 는 14칸이라 네 칸이 초과다.
	v := sample()
	v.Five = Gauge{Present: true, Pct: 70, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	rows := strings.Split(plain(Full(v, 2_000_000_000-9000)), "\n")
	if n := strings.Count(rows[3], "▓"); n != 4 {
		t.Errorf("초과 칸 %d, want 4 — %q", n, rows[3])
	}
	if strings.Contains(rows[3], "▲") {
		t.Errorf("전체 레이아웃은 압축 페이스 기호를 쓰지 않는다: %q", rows[3])
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

func TestCompactLayoutIsThreeRows(t *testing.T) {
	v := sample()
	v.Width = 70
	rows := strings.Split(plain(Compact(v, 1_999_000_000)), "\n")
	if len(rows) != 3 {
		t.Fatalf("압축 레이아웃은 3행이다: %d행 — %q", len(rows), rows)
	}
	for _, w := range []string{"ctx", "Opus 4.8", "5h", "7d"} {
		if !strings.Contains(rows[2], w) {
			t.Errorf("행3 에 %q 가 없다: %q", w, rows[2])
		}
	}
	if strings.Contains(rows[2], "█") || strings.Contains(rows[2], "░") {
		t.Errorf("압축 레이아웃에는 막대를 그리지 않는다: %q", rows[2])
	}
}

func TestCompactShortensTheSessionIDToSixCharacters(t *testing.T) {
	v := sample()
	v.Width = 70
	out := plain(Compact(v, 1_999_000_000))
	if strings.Contains(out, session) {
		t.Fatal("압축 레이아웃은 전체 식별자를 넣지 않는다")
	}
	if !strings.Contains(out, session[:6]) {
		t.Fatalf("앞 6자가 없다: %q", out)
	}
}

func TestCompactKeepsAShortSessionIDWhole(t *testing.T) {
	// 6자 미만이면 접두 대신 전체 값을 쓴다. 그러지 않으면 마커만 남고 id 가 사라진다.
	v := sample()
	v.Width, v.Session = 70, "abc"
	if !strings.Contains(plain(Compact(v, 1_999_000_000)), theme.SessionGlyph+" abc") {
		t.Errorf("짧은 세션 id 전체 표시 실패: %q", plain(Compact(v, 1_999_000_000)))
	}
}

func TestCompactPutsVersionAndSessionOnTheIdentityRow(t *testing.T) {
	v := sample()
	v.Width = 70
	rows := strings.Split(plain(Compact(v, 1_999_000_000)), "\n")
	for _, w := range []string{"gh@personal", "v2.1.11", theme.SessionGlyph} {
		if !strings.Contains(rows[1], w) {
			t.Errorf("행2 에 %q 가 없다: %q", w, rows[1])
		}
	}
	if strings.Contains(rows[0], "v2.1.11") || strings.Contains(rows[0], "gh@") {
		t.Errorf("행1 은 시각·경로·브랜치만 담는다: %q", rows[0])
	}
}

func TestCompactMarksPaceWithATriangle(t *testing.T) {
	// 7d 를 비워 ▲ 의 출처를 5h 하나로 좁힌다. 두 창을 함께 두면 다른 창의 초과가
	// 이 단언을 통과시켜 5h 의 페이스 판정을 검증하지 못한다.
	v := sample()
	v.Width, v.Week = 70, Gauge{}
	v.Five = Gauge{Present: true, Pct: 70, ResetsAt: 2_000_000_000, HasReset: true, Window: 18000}
	rows := strings.Split(plain(Compact(v, 2_000_000_000-9000)), "\n")
	if !strings.Contains(rows[2], "▲") {
		t.Errorf("초과 시 ▲ 표시: %q", rows[2])
	}
	v.Five.Pct = 40
	rows = strings.Split(plain(Compact(v, 2_000_000_000-9000)), "\n")
	if strings.Contains(rows[2], "▲") {
		t.Errorf("여유면 ▲ 없음: %q", rows[2])
	}
}

func TestCompactFirstRowFitsTheDetectedWidth(t *testing.T) {
	// 브랜치가 있으면 예산이 폭-8, 없으면 폭-6 이다. 시각 5칸과 공백, 브랜치 아이콘이
	// 그 차이다. 이 예산을 렌더러가 다시 계산하면 조립부와 조용히 어긋난다.
	v := sample()
	v.Width = 40
	v.Path = "~/↪1/webapp/↪2/PROJ-1469-connect-api-gateway"
	v.Branch = "feature/PROJ-1469-connect-api-secrets"
	row1 := strings.Split(Compact(v, 1_999_000_000), "\n")[0]
	if got := width.Visible(row1); got > 40 {
		t.Errorf("첫 행 폭 %d, want <= 40 — %q", got, plain(row1))
	}
	if !strings.Contains(row1, "…") {
		t.Errorf("넘치면 줄임표를 붙인다: %q", plain(row1))
	}

	v.Branch = ""
	row1 = strings.Split(Compact(v, 1_999_000_000), "\n")[0]
	if got := width.Visible(row1); got != 40 {
		t.Errorf("브랜치 부재 시 첫 행 폭 %d, want 40 — %q", got, plain(row1))
	}
}

func TestCompactFirstRowSurvivesATinyWidth(t *testing.T) {
	// 예산이 1 미만으로 내려가도 1 로 붙잡아 경로가 통째로 사라지지 않게 한다.
	v := sample()
	v.Width = 3
	if out := Compact(v, 1_999_000_000); out == "" {
		t.Fatal("좁은 폭에서 출력이 비었다")
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
	rows := strings.Split(plain(Full(v, 1_999_000_000)), "\n")
	if strings.Contains(rows[3], "↺") {
		t.Fatalf("리셋 시각이 없으면 ↺ 를 그리지 않는다: %q", rows[3])
	}
	if strings.Contains(rows[3], "▓") {
		t.Fatalf("리셋 시각이 없으면 예산도 없어 초과 표시를 하지 않는다: %q", rows[3])
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
	if !strings.Contains(strings.Split(compact, "\n")[2], "ctx") {
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
