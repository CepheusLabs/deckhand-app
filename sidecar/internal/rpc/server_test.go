package rpc

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

// driveServer runs Server.Serve against the given input and returns a
// reader for the response stream. The previous test harness shared a
// *bytes.Buffer between the serve goroutine and the test body, which
// `go test -race` flagged as a data race on every test in this file.
// io.Pipe is the idiomatic fix: the serve goroutine writes to pw and
// the test reads from pr. No shared mutable state.
func driveServer(t *testing.T, s *Server, input string) (*bufio.Scanner, func()) {
	t.Helper()
	pr, pw := io.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer pw.Close()
		_ = s.Serve(ctx, strings.NewReader(input), pw)
	}()
	// Buffer sized generously to fit the longest single-line response
	// a test might hand out.
	scanner := bufio.NewScanner(pr)
	scanner.Buffer(make([]byte, 1<<16), 1<<20)
	return scanner, func() {
		cancel()
		<-done
	}
}

// readLine waits for the next response line with a per-test deadline.
// If nothing lands it fails the test with context rather than hanging.
func readLine(t *testing.T, scanner *bufio.Scanner) string {
	t.Helper()
	type result struct {
		line string
		ok   bool
	}
	ch := make(chan result, 1)
	go func() {
		ok := scanner.Scan()
		ch <- result{line: scanner.Text(), ok: ok}
	}()
	select {
	case r := <-ch:
		if !r.ok {
			t.Fatalf("scanner closed before a line appeared")
		}
		return r.line
	case <-time.After(1500 * time.Millisecond):
		t.Fatalf("no line written within deadline")
		return ""
	}
}

func TestServer_PingSuccess(t *testing.T) {
	s := NewServer()
	s.Register("ping", func(ctx context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		return map[string]any{"pong": true}, nil
	})
	scanner, stop := driveServer(t, s, `{"jsonrpc":"2.0","id":"1","method":"ping","params":{}}`+"\n")
	defer stop()

	line := readLine(t, scanner)
	if !strings.Contains(line, `"pong":true`) {
		t.Fatalf("unexpected response: %q", line)
	}
	if !strings.Contains(line, `"id":"1"`) {
		t.Fatalf("response missing id correlation: %q", line)
	}
}

func TestServer_MethodNotFound(t *testing.T) {
	s := NewServer()
	scanner, stop := driveServer(t, s, `{"jsonrpc":"2.0","id":"1","method":"nope","params":{}}`+"\n")
	defer stop()
	line := readLine(t, scanner)
	if !strings.Contains(line, `"code":-32601`) {
		t.Fatalf("expected method-not-found error, got: %q", line)
	}
}

func TestServer_ParseError(t *testing.T) {
	s := NewServer()
	scanner, stop := driveServer(t, s, "not-json\n")
	defer stop()
	line := readLine(t, scanner)
	if !strings.Contains(line, `"code":-32700`) {
		t.Fatalf("expected parse error code, got: %q", line)
	}
}

func TestServer_Notification(t *testing.T) {
	s := NewServer()
	s.Register("long_op", func(ctx context.Context, _ json.RawMessage, note Notifier) (any, error) {
		note.Notify("progress", map[string]any{"percent": 50})
		return map[string]any{"done": true}, nil
	})
	scanner, stop := driveServer(t, s, `{"jsonrpc":"2.0","id":"op-123","method":"long_op","params":{}}`+"\n")
	defer stop()

	notif := readLine(t, scanner)
	if !strings.Contains(notif, `"method":"progress"`) {
		t.Fatalf("first line should be notification, got: %q", notif)
	}
	if !strings.Contains(notif, `"operation_id":"op-123"`) {
		t.Fatalf("notification missing operation_id correlation: %q", notif)
	}
	resp := readLine(t, scanner)
	if !strings.Contains(resp, `"done":true`) {
		t.Fatalf("second line should be response, got: %q", resp)
	}
}

func TestServer_HandlerPanicCaughtAsInternalError(t *testing.T) {
	s := NewServer()
	s.Register("boom", func(ctx context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		panic("something went wrong")
	})
	scanner, stop := driveServer(t, s, `{"jsonrpc":"2.0","id":"42","method":"boom","params":{}}`+"\n")
	defer stop()
	line := readLine(t, scanner)

	for _, substr := range []string{`"error"`, `"code":-32603`, "something went wrong", `"id":"42"`} {
		if !strings.Contains(line, substr) {
			t.Fatalf("expected %q in response, got: %q", substr, line)
		}
	}
}

func TestServer_HandlerError_DefaultsToInternalError(t *testing.T) {
	s := NewServer()
	s.Register("nope", func(ctx context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		return nil, &customErr{"disk is offline"}
	})
	scanner, stop := driveServer(t, s, `{"jsonrpc":"2.0","id":"7","method":"nope","params":{}}`+"\n")
	defer stop()
	line := readLine(t, scanner)

	if !strings.Contains(line, `"code":-32603`) {
		t.Fatalf("expected code -32603, got: %q", line)
	}
	if !strings.Contains(line, "disk is offline") {
		t.Fatalf("expected handler error surfaced, got: %q", line)
	}
}

func TestServer_RPCError_UsesProvidedCode(t *testing.T) {
	s := NewServer()
	s.Register("disk_err", func(ctx context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		return nil, &Error{Code: CodeDisk + 1, Message: "elevation required", Data: map[string]any{"reason": "elevation_required"}}
	})
	scanner, stop := driveServer(t, s, `{"jsonrpc":"2.0","id":"99","method":"disk_err","params":{}}`+"\n")
	defer stop()
	line := readLine(t, scanner)

	if !strings.Contains(line, `"code":-33999`) {
		t.Fatalf("expected CodeDisk+1 = -33999, got: %q", line)
	}
	if !strings.Contains(line, `"reason":"elevation_required"`) {
		t.Fatalf("expected data.reason carried through, got: %q", line)
	}
}

type customErr struct{ msg string }

func (c *customErr) Error() string { return c.msg }

func TestServer_BadJSONRPCVersion_Rejected(t *testing.T) {
	s := NewServer()
	scanner, stop := driveServer(t, s, `{"jsonrpc":"1.0","id":"1","method":"x","params":{}}`+"\n")
	defer stop()
	line := readLine(t, scanner)
	if !strings.Contains(line, `"code":-32600`) {
		t.Fatalf("expected invalid-request code, got: %q", line)
	}
}

func TestServer_MultipleCallsShareOneStream(t *testing.T) {
	s := NewServer()
	s.Register("ping", func(ctx context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		return map[string]any{"ok": true}, nil
	})
	scanner, stop := driveServer(t, s,
		`{"jsonrpc":"2.0","id":"1","method":"ping","params":{}}`+"\n"+
			`{"jsonrpc":"2.0","id":"2","method":"ping","params":{}}`+"\n")
	defer stop()

	seen := map[string]bool{}
	// Two handlers dispatch concurrently in goroutines so the order
	// of response lines is not guaranteed; collect both by id.
	for i := 0; i < 2; i++ {
		line := readLine(t, scanner)
		switch {
		case strings.Contains(line, `"id":"1"`):
			seen["1"] = true
		case strings.Contains(line, `"id":"2"`):
			seen["2"] = true
		default:
			t.Fatalf("unexpected line: %q", line)
		}
	}
	if !seen["1"] || !seen["2"] {
		t.Fatalf("both ids must appear: seen=%v", seen)
	}
}

// Concurrent notifications should not interleave with each other or
// with the response. The outputWriter's mutex enforces that; this test
// proves it by hammering both writers from a handler and asserting
// each emitted JSON line parses cleanly.
func TestServer_ConcurrentNotifications_AreAtomic(t *testing.T) {
	s := NewServer()
	s.Register("spam", func(ctx context.Context, _ json.RawMessage, note Notifier) (any, error) {
		var wg sync.WaitGroup
		for i := 0; i < 20; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				note.Notify("tick", map[string]any{"i": i})
			}(i)
		}
		wg.Wait()
		return map[string]any{"ok": true}, nil
	})
	scanner, stop := driveServer(t, s, `{"jsonrpc":"2.0","id":"x","method":"spam","params":{}}`+"\n")
	defer stop()

	// Expect 21 lines - 20 notifications + 1 response - and each line
	// must parse cleanly as JSON.
	for i := 0; i < 21; i++ {
		line := readLine(t, scanner)
		var anyJSON map[string]any
		if err := json.Unmarshal([]byte(line), &anyJSON); err != nil {
			t.Fatalf("line %d did not parse as JSON: %v (%q)", i, err, line)
		}
	}
}
