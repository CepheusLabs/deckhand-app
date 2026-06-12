package relay

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"testing"
	"time"
)

// fakeConn is an in-memory Conn that lets a test drive the cloud side: it
// delivers queued inbound frames to the client's ReadJSON and records the
// frames the client writes. It is the relay's stand-in for a WebSocket with no
// network involved.
type fakeConn struct {
	inbound  chan Frame
	outbound chan Frame
	closed   chan struct{}
}

func newFakeConn() *fakeConn {
	return &fakeConn{
		inbound:  make(chan Frame, 8),
		outbound: make(chan Frame, 8),
		closed:   make(chan struct{}),
	}
}

func (c *fakeConn) ReadJSON(v any) error {
	select {
	case frame, ok := <-c.inbound:
		if !ok {
			return io.EOF
		}
		// Round-trip through JSON so the test exercises real encode/decode.
		raw, err := json.Marshal(frame)
		if err != nil {
			return err
		}
		return json.Unmarshal(raw, v)
	case <-c.closed:
		return io.EOF
	}
}

func (c *fakeConn) WriteJSON(v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	var frame Frame
	if err := json.Unmarshal(raw, &frame); err != nil {
		return err
	}
	select {
	case c.outbound <- frame:
		return nil
	case <-c.closed:
		return errors.New("write on closed conn")
	}
}

func (c *fakeConn) Close() error {
	select {
	case <-c.closed:
	default:
		close(c.closed)
	}
	return nil
}

func newTestClient(t *testing.T, conn Conn) *Client {
	t.Helper()
	module := NewDeckhandModule(newFakeInvoker())
	client, err := NewClient(Config{
		Endpoint:  "wss://example/edge",
		RuntimeID: "runtime-1",
		TenantID:  "t1",
	}, module)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	// Inject the fake conn instead of a real dial.
	client.dialer = func(context.Context, Config) (Conn, error) { return conn, nil }
	return client
}

func TestRegisterFrameRoundTrip(t *testing.T) {
	conn := newFakeConn()
	client := newTestClient(t, conn)

	// Stage the cloud ack so register() returns nil.
	ackBody, _ := json.Marshal(registerAckBody{ServerVersion: "pd-cortex-edge/1", MinProtocol: protocolVersion})
	conn.inbound <- Frame{Kind: kindRegisterAck, Body: ackBody}

	if err := client.register(conn); err != nil {
		t.Fatalf("register: %v", err)
	}

	// Inspect the register frame the client sent.
	select {
	case frame := <-conn.outbound:
		if frame.Kind != kindRegister {
			t.Fatalf("first frame kind = %q, want register", frame.Kind)
		}
		var body registerBody
		if err := json.Unmarshal(frame.Body, &body); err != nil {
			t.Fatalf("decode register body: %v", err)
		}
		if body.ProtocolVersion != protocolVersion {
			t.Fatalf("protocol_version = %q, want %q", body.ProtocolVersion, protocolVersion)
		}
		if body.RuntimeID != "runtime-1" {
			t.Fatalf("runtime_id = %q, want runtime-1", body.RuntimeID)
		}
		if len(body.Modules) != 1 || body.Modules[0].ModuleID != ModuleID {
			t.Fatalf("modules = %+v, want one deckhand module", body.Modules)
		}
		if len(body.Modules[0].CapabilityIDs) != len(CapabilityIDs()) {
			t.Fatalf("advertised %d caps, want %d", len(body.Modules[0].CapabilityIDs), len(CapabilityIDs()))
		}
	default:
		t.Fatal("client did not send a register frame")
	}
}

func TestRegisterNackIsAnError(t *testing.T) {
	conn := newFakeConn()
	client := newTestClient(t, conn)
	nackBody, _ := json.Marshal(registerNackBody{Reason: "runtime_id mismatch"})
	conn.inbound <- Frame{Kind: kindRegisterNack, Body: nackBody}
	// drain the register frame the client writes
	go func() { <-conn.outbound }()
	err := client.register(conn)
	if err == nil {
		t.Fatal("register should fail on a nack")
	}
}

func TestInboundActionInvokeRoundTrip(t *testing.T) {
	conn := newFakeConn()
	module := NewDeckhandModule(newFakeInvoker())
	client, err := NewClient(Config{Endpoint: "wss://example/edge", RuntimeID: "runtime-1"}, module)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}

	// Build a cloud->desktop action.invoke rpc request for a safe capability.
	invocation := productplatformInvocation(CapDisksInspect, map[string]any{})
	reqBody := mustJSON(t, map[string]any{
		"jsonrpc": "2.0",
		"id":      "42",
		"method":  "action.invoke",
		"params":  invocation,
	})
	conn.inbound <- Frame{Kind: kindRPC, Body: reqBody}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = client.pump(ctx, conn) }()

	select {
	case frame := <-conn.outbound:
		if frame.Kind != kindRPC {
			t.Fatalf("response frame kind = %q, want rpc", frame.Kind)
		}
		var resp struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Result  json.RawMessage `json:"result"`
			Error   json.RawMessage `json:"error"`
		}
		if err := json.Unmarshal(frame.Body, &resp); err != nil {
			t.Fatalf("decode response body: %v", err)
		}
		// The id MUST be echoed verbatim.
		if string(resp.ID) != `"42"` {
			t.Fatalf("response id = %s, want \"42\"", resp.ID)
		}
		if len(resp.Error) != 0 {
			t.Fatalf("unexpected error in response: %s", resp.Error)
		}
		// The result is an ActionResult with success status.
		var result productplatformResult
		if err := json.Unmarshal(resp.Result, &result); err != nil {
			t.Fatalf("decode action result: %v", err)
		}
		if result.Status != "success" {
			t.Fatalf("action result status = %q, want success", result.Status)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("client did not answer the inbound action.invoke")
	}
}

func TestPumpStopsOnContextCancel(t *testing.T) {
	conn := newFakeConn()
	client := newTestClient(t, conn)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- client.pump(ctx, conn) }()
	cancel()
	conn.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("pump did not return after context cancel + conn close")
	}
}

// helpers -----------------------------------------------------------------

// productplatformInvocation builds an ActionInvocation params object for an
// action.invoke request, matching the wire shape the cloud sends.
func productplatformInvocation(capID string, input map[string]any) map[string]any {
	return map[string]any{
		"capability_id": capID,
		"input":         input,
		"context":       map[string]any{"tenant_id": "t1"},
	}
}

type productplatformResult struct {
	Status string `json:"status"`
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw
}
