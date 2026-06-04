package localagent

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

func TestPingRequiresBearerToken(t *testing.T) {
	s := rpc.NewServer()
	ts := httptest.NewServer(NewHandler(s, Config{Token: "secret"}))
	t.Cleanup(ts.Close)

	resp, err := http.Get(ts.URL + "/v1/ping")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusUnauthorized)
	}

	req, err := http.NewRequest(http.MethodGet, ts.URL+"/v1/ping", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer secret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("authorized status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
}

func TestOperationStreamsProgressAndDone(t *testing.T) {
	s := rpc.NewServer()
	s.Register("demo.long", func(_ context.Context, _ json.RawMessage, note rpc.Notifier) (any, error) {
		note.Notify("progress", map[string]any{
			"phase":       "writing",
			"bytes_done":  5,
			"bytes_total": 10,
		})
		return map[string]any{"ok": true}, nil
	})
	ts := httptest.NewServer(NewHandler(s, Config{Token: "secret"}))
	t.Cleanup(ts.Close)

	body := bytes.NewBufferString(`{"method":"demo.long","params":{}}`)
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/operations", body)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("start status = %d, want %d", resp.StatusCode, http.StatusAccepted)
	}
	var start struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&start); err != nil {
		t.Fatal(err)
	}
	if start.ID == "" {
		t.Fatal("operation id is empty")
	}

	events, err := http.Get(ts.URL + "/v1/operations/" + start.ID + "/events?token=secret")
	if err != nil {
		t.Fatal(err)
	}
	defer events.Body.Close()
	if events.StatusCode != http.StatusOK {
		t.Fatalf("events status = %d, want %d", events.StatusCode, http.StatusOK)
	}
	raw, err := io.ReadAll(events.Body)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	for _, want := range []string{
		"event: progress",
		`"bytes_done":5`,
		"event: done",
		`"ok":true`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("SSE output missing %q: %s", want, text)
		}
	}
}

func TestRPCInvokesRegisteredMethod(t *testing.T) {
	s := rpc.NewServer()
	s.Register("demo.echo", func(_ context.Context, raw json.RawMessage, _ rpc.Notifier) (any, error) {
		var params map[string]any
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, err
		}
		return params, nil
	})
	ts := httptest.NewServer(NewHandler(s, Config{}))
	t.Cleanup(ts.Close)

	resp, err := http.Post(
		ts.URL+"/v1/rpc",
		"application/json",
		bytes.NewBufferString(`{"method":"demo.echo","params":{"value":42}}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	var out struct {
		Result map[string]any `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if got := out.Result["value"]; got != float64(42) {
		t.Fatalf("result value = %#v, want 42", got)
	}
}
