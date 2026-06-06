package osimg

import (
	"os"
	"testing"
)

// TestMain enables loopback download approval for the package's tests,
// which serve OS-image fixtures from httptest servers on 127.0.0.1.
// Production binaries never run test code, so allowLoopbackDownloads stays
// false outside tests — see isApprovedDownloadHost.
func TestMain(m *testing.M) {
	allowLoopbackDownloads = true
	os.Exit(m.Run())
}

func TestIsApprovedDownloadHost_RejectsLoopbackInProduction(t *testing.T) {
	prev := allowLoopbackDownloads
	allowLoopbackDownloads = false
	t.Cleanup(func() { allowLoopbackDownloads = prev })

	for _, host := range []string{"localhost", "127.0.0.1", "::1", "127.0.0.53"} {
		if isApprovedDownloadHost(host) {
			t.Errorf("loopback host %q approved in production mode", host)
		}
	}
	// A legitimately-allowlisted host is still accepted.
	if len(approvedDownloadHostSuffixes) > 0 {
		ok := approvedDownloadHostSuffixes[0]
		if !isApprovedDownloadHost(ok) {
			t.Errorf("allowlisted host %q was rejected", ok)
		}
	}
}

func TestIsApprovedDownloadHost_AllowsLoopbackWhenEnabled(t *testing.T) {
	// TestMain set this true; assert the test-only path works so the rest
	// of the suite's httptest fixtures are reachable.
	if !allowLoopbackDownloads {
		t.Fatal("expected loopback enabled under TestMain")
	}
	for _, host := range []string{"localhost", "127.0.0.1", "::1"} {
		if !isApprovedDownloadHost(host) {
			t.Errorf("loopback host %q rejected with loopback enabled", host)
		}
	}
}
