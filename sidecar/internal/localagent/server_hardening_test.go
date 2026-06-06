package localagent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// corsAllowed sends an OPTIONS preflight with the given Origin and reports
// whether the agent echoed an Access-Control-Allow-Origin header (i.e. the
// origin is trusted).
func corsAllowed(t *testing.T, ts *httptest.Server, origin string) bool {
	t.Helper()
	req, err := http.NewRequest(http.MethodOptions, ts.URL+"/v1/ping", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Origin", origin)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	return resp.Header.Get("Access-Control-Allow-Origin") == origin
}

func TestCORSDeniesArbitraryHTTPSOriginByDefault(t *testing.T) {
	ts := httptest.NewServer(NewHandler(rpc.NewServer(), Config{}))
	t.Cleanup(ts.Close)

	// The whole point: an arbitrary public site must NOT be able to reach
	// the privileged local agent through the browser.
	if corsAllowed(t, ts, "https://evil.example.com") {
		t.Fatal("arbitrary https:// origin was allowed by default")
	}
	// Loopback (the desktop-paired local web app) is trusted.
	for _, origin := range []string{
		"http://localhost:8080",
		"http://127.0.0.1:5173",
		"https://localhost",
	} {
		if !corsAllowed(t, ts, origin) {
			t.Fatalf("loopback origin %q was not allowed", origin)
		}
	}
}

func TestCORSHonorsExplicitAllowList(t *testing.T) {
	ts := httptest.NewServer(NewHandler(rpc.NewServer(), Config{
		AllowOrigins: []string{"https://deckhand.example.com"},
	}))
	t.Cleanup(ts.Close)

	if !corsAllowed(t, ts, "https://deckhand.example.com") {
		t.Fatal("explicitly allowed origin was rejected")
	}
	if corsAllowed(t, ts, "https://other.example.com") {
		t.Fatal("origin outside the allow list was accepted")
	}
}

func TestRPCRejectsOversizedBody(t *testing.T) {
	ts := httptest.NewServer(NewHandler(rpc.NewServer(), Config{}))
	t.Cleanup(ts.Close)

	big := strings.Repeat("a", maxRequestBodyBytes+1024)
	body := bytes.NewBufferString(`{"method":"demo.echo","params":{"v":"` + big + `"}}`)
	resp, err := http.Post(ts.URL+"/v1/rpc", "application/json", body)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusRequestEntityTooLarge)
	}
}

func TestRPCErrorIsSanitizedBeforeReachingWeb(t *testing.T) {
	s := rpc.NewServer()
	s.Register("demo.fail", func(_ context.Context, _ json.RawMessage, _ rpc.Notifier) (any, error) {
		// A handler error that embeds a URL with a credential + query —
		// exactly what must not leak verbatim to a browser.
		return nil, errors.New(
			"fetch failed: https://user:s3cr3t@mirror.example.com/img?token=LEAKME",
		)
	})
	ts := httptest.NewServer(NewHandler(s, Config{}))
	t.Cleanup(ts.Close)

	resp, err := http.Post(
		ts.URL+"/v1/rpc",
		"application/json",
		bytes.NewBufferString(`{"method":"demo.fail","params":{}}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	if strings.Contains(text, "s3cr3t") || strings.Contains(text, "LEAKME") {
		t.Fatalf("error response leaked a secret: %s", text)
	}
	if !strings.Contains(text, "[redacted]") && !strings.Contains(text, "redacted") {
		t.Fatalf("error response was not sanitized: %s", text)
	}
}
