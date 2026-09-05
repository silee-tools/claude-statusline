package segments

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAWSExpiredSuppressionUsesRenderTime(t *testing.T) {
	stubSaml2aws(t)
	dataDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dataDir, "saml2aws-login-suppress"),
		[]byte("value=2026-08-20\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AWS_SESSION_EXPIRATION", "2020-01-01T00:00:00+00:00")
	if got := plain(AWS("", dataDir, t.TempDir(), time.Date(2026, 8, 20, 0, 0, 0, 0, time.Local).Unix())); got != "aws:-" {
		t.Fatalf("render 시각의 억제를 써야 한다: %q", got)
	}
	if got := plain(AWS("", dataDir, t.TempDir(), time.Date(2026, 8, 21, 0, 0, 0, 0, time.Local).Unix())); got != "aws:expired" {
		t.Fatalf("다른 render 날짜에는 억제하지 않아야 한다: %q", got)
	}
}
