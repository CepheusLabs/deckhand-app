package localagent

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

// captureHandler is a minimal slog.Handler that records emitted messages
// so a test can assert the bridge logged a given event.
type captureHandler struct {
	mu       sync.Mutex
	messages []string
}

func (h *captureHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h *captureHandler) Handle(_ context.Context, r slog.Record) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.messages = append(h.messages, r.Message)
	return nil
}

func (h *captureHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *captureHandler) WithGroup(string) slog.Handler       { return h }

func (h *captureHandler) saw(msg string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, m := range h.messages {
		if m == msg {
			return true
		}
	}
	return false
}

func TestAuthFailureIsLogged(t *testing.T) {
	cap := &captureHandler{}
	s := rpc.NewServer()
	s.SetLogger(slog.New(cap))
	ts := httptest.NewServer(NewHandler(s, Config{Token: "secret"}))
	t.Cleanup(ts.Close)

	resp, err := http.Get(ts.URL + "/v1/ping") // no bearer token
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
	if !cap.saw("localagent.auth_failed") {
		t.Fatalf("expected an auth_failed log, got %v", cap.messages)
	}
}
