package costcache

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func write(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "cost-cache.env"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestLoadMissingFileIsUnavailable(t *testing.T) {
	if c := Load(t.TempDir()); c.Available {
		t.Errorf("파일이 없으면 사용 불가여야 한다: %+v", c)
	}
}

func TestLoadTreatsAnythingButTrueAsUnavailable(t *testing.T) {
	// 셸은 available 이 정확히 true 인 경우만 금액을 쓴다. 그 외에는 $-- 를 낸다.
	for _, v := range []string{"false", "", "TRUE", "1"} {
		if c := Load(write(t, "available="+v+"\nweekly=605\n")); c.Available {
			t.Errorf("available=%q 를 사용 가능으로 읽었다", v)
		}
	}
}

func TestLoadParsesEnvStyleFile(t *testing.T) {
	c := Load(write(t, "available=true\ndailyOpus=12\ndailySonnet=0.5\ndailyHaiku=3\nweekly=605\nmonthly=915\ncachedAt=1784000000\n"))
	if !c.Available {
		t.Fatal("available=true 인데 사용 불가로 읽었다")
	}
	if c.DailyOpus != 12 || c.DailySonnet != 0.5 || c.DailyHaiku != 3 {
		t.Errorf("일별 금액: %+v", c)
	}
	if c.Weekly != "605" || c.Monthly != "915" {
		t.Errorf("주간·월간은 파일의 문자열을 그대로 쓴다: %+v", c)
	}
}

func TestLoadKeepsWeeklyAndMonthlyVerbatim(t *testing.T) {
	// 셸은 이 두 값을 산술 없이 $ 뒤에 그대로 붙인다. 숫자로 다시 포맷하면 표기가 달라진다.
	c := Load(write(t, "available=true\nweekly=605.40\nmonthly=1,234\n"))
	if c.Weekly != "605.40" || c.Monthly != "1,234" {
		t.Errorf("문자열 그대로여야 한다: %+v", c)
	}
}

func TestDailySegmentsOmitModelsBelowOneDollar(t *testing.T) {
	// render-full.sh 의 ge_one 과 같은 규칙 — 1달러 미만 모델은 표시하지 않는다.
	cases := []struct {
		body string
		want []string
	}{
		{"available=true\ndailyOpus=12\ndailySonnet=0\ndailyHaiku=0\n", []string{"Opus|12"}},
		{"available=true\ndailyOpus=0.9\ndailySonnet=1\ndailyHaiku=0\n", []string{"Sonnet|1"}},
		{"available=true\ndailyOpus=1\ndailySonnet=2.4\ndailyHaiku=3.6\n",
			[]string{"Opus|1", "Sonnet|2", "Haiku|4"}},
		{"available=true\ndailyOpus=0\ndailySonnet=0\ndailyHaiku=0\n", nil},
	}
	for _, c := range cases {
		got := Load(write(t, c.body)).DailySegments()
		if len(got) != len(c.want) {
			t.Errorf("%q -> %v, want %v", c.body, got, c.want)
			continue
		}
		for i := range got {
			if got[i].Label+"|"+got[i].Amount != c.want[i] {
				t.Errorf("%q -> %v, want %v", c.body, got, c.want)
				break
			}
		}
	}
}

func TestDailyAmountsRoundHalfToEven(t *testing.T) {
	// 셸은 printf '%.0f' 로 찍는다. C 의 %f 는 절반을 짝수로 붙이므로 2.5 는 2, 3.5 는 4 다.
	c := Load(write(t, "available=true\ndailyOpus=2.5\ndailySonnet=3.5\ndailyHaiku=1.5\n"))
	got := c.DailySegments()
	want := []string{"2", "4", "2"}
	if len(got) != 3 {
		t.Fatalf("세 모델 모두 1달러 이상이다: %v", got)
	}
	for i, w := range want {
		if got[i].Amount != w {
			t.Errorf("%s = %s, want %s", got[i].Label, got[i].Amount, w)
		}
	}
}

func TestMonthDaysIsTheDaysInTheGivenMonth(t *testing.T) {
	cases := map[string]string{
		"2026-08-20": "31",
		"2026-02-10": "28",
		"2024-02-10": "29",
		"2026-04-01": "30",
	}
	for day, want := range cases {
		d, err := time.Parse("2006-01-02", day)
		if err != nil {
			t.Fatal(err)
		}
		if got := MonthDays(d); got != want {
			t.Errorf("MonthDays(%s) = %s, want %s", day, got, want)
		}
	}
}
