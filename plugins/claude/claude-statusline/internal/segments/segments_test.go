package segments

import (
	"regexp"
	"strings"
	"testing"

	"github.com/silee-tools/claude-statusline/internal/theme"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plain(s string) string { return ansiRe.ReplaceAllString(s, "") }

// ghRoot does not exist on disk, so its cache file name is the path with / replaced by %.
func TestAccountIsEmptyWhenTheReceiverIsNotInstalled(t *testing.T) {
	// 수신기를 설치하지 않은 기계에서 칸에 ? 만 영원히 남지 않는다.
	if got := Account(false, "", false, false); got != "" {
		t.Errorf("미설치: %q", got)
	}
	if got := Account(false, "octocat@example.com", true, true); got != "" {
		t.Errorf("미설치는 값이 있어도 칸을 비운다: %q", got)
	}
}

func TestAccountShowsAGreyQuestionMarkWhenTheEmailIsUnknown(t *testing.T) {
	got := Account(true, "", false, false)
	if plain(got) != "?" || !strings.HasPrefix(got, theme.Dim) {
		t.Errorf("모름 = %q, 흐린 ? 여야 한다", got)
	}
}

func TestAccountShowsTheEmailInCoral(t *testing.T) {
	got := Account(true, "octocat@example.com", false, false)
	if plain(got) != "octocat@example.com" || !strings.HasPrefix(got, theme.Coral173) {
		t.Errorf("Account = %q", got)
	}
}

func TestAccountMarksAnEstimateWithADimTilde(t *testing.T) {
	// 시작 때 설정 파일에 있던 계정은 세션 자격 증명의 계정이라는 증거가 없어 물결표가 붙는다.
	got := Account(true, "octocat@example.com", true, false)
	if plain(got) != "~octocat@example.com" || !strings.HasPrefix(got, theme.Dim+"~"+theme.Reset+theme.Coral173) {
		t.Errorf("추정 = %q", got)
	}
	if plain(Account(true, "octocat@example.com", true, true)) != "~octocat@example.com?" {
		t.Errorf("추정+의심 = %q", plain(Account(true, "octocat@example.com", true, true)))
	}
}

func TestAccountMarksASuspectEmailWithAQuestionMark(t *testing.T) {
	got := Account(true, "octocat@example.com", false, true)
	if plain(got) != "octocat@example.com?" {
		t.Errorf("의심 = %q", plain(got))
	}
	if !strings.HasPrefix(got, theme.Coral173+"octocat@example.com") {
		t.Errorf("이메일은 coral 이어야 한다: %q", got)
	}
}

func TestAccountDropsControlCharacters(t *testing.T) {
	got := Account(true, "a@example.com\x1b]0;x\x07", false, false)
	if strings.ContainsAny(plain(got), "\x1b\x07") {
		t.Errorf("제어 문자가 남았다: %q", got)
	}
}
