package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"time"

	productplatform "github.com/cepheuslabs/printdeck_product_platform"
	"github.com/gorilla/websocket"
)

const (
	// protocolVersion is the wire-protocol identifier sent in the register
	// frame. It must match the cloud's edgeProtocolVersion ("edge/1").
	protocolVersion = "edge/1"
)

// Frame is the outer envelope on the wire: one JSON object per WS text message.
// Body carries a verbatim productplatform JSON-RPC message for the rpc/event
// kinds. The field shapes mirror the cloud's envelope exactly.
type Frame struct {
	Kind string          `json:"kind"`
	Body json.RawMessage `json:"body,omitempty"`
}

const (
	kindRegister     = "register"
	kindRegisterAck  = "register_ack"
	kindRegisterNack = "register_nack"
	kindRPC          = "rpc"
	kindEvent        = "event"
)

// registerBody is the desktop's first frame body: the advertised module set and
// runtime id. The cloud never trusts these to describe capabilities — it
// intersects them with its embedded manifest and allow-list — but they MUST be
// sent so the cloud knows which modules to wire for this runtime.
type registerBody struct {
	ProtocolVersion string         `json:"protocol_version"`
	RuntimeID       string         `json:"runtime_id"`
	Modules         []moduleAdvert `json:"modules"`
}

type moduleAdvert struct {
	ModuleID      string   `json:"module_id"`
	CapabilityIDs []string `json:"capability_ids"`
}

// registerAckBody is the cloud's accept response: the surviving module/cap set.
type registerAckBody struct {
	ServerVersion string         `json:"server_version"`
	MinProtocol   string         `json:"min_protocol"`
	Accepted      []moduleAdvert `json:"accepted"`
}

// registerNackBody is the cloud's reject response; the connection then closes.
type registerNackBody struct {
	Reason string `json:"reason"`
}

// Conn is the minimal WebSocket transport the client needs. *websocket.Conn
// satisfies it in production; tests pass an in-memory fake so the handshake and
// the action.invoke round-trip can be exercised with no network.
type Conn interface {
	ReadJSON(v any) error
	WriteJSON(v any) error
	Close() error
}

// Config is the relay client's runtime configuration, sourced from the
// sidecar's pairing/config (the bearer token + tenant + endpoint).
type Config struct {
	// Endpoint is the cortex WSS edge URL, e.g. "wss://cortex.example/edge".
	Endpoint string
	// Token is the bearer/runtime token presented to the gateway. The gateway
	// validates it and fills the AuthResult; the wire register frame is never
	// trusted for identity.
	Token string
	// TenantID and RuntimeID identify this desktop runtime. RuntimeID is echoed
	// in the register frame and must match the gateway-validated identity.
	TenantID  string
	RuntimeID string
	// MinBackoff / MaxBackoff bound the reconnect backoff. Zero values fall back
	// to sane defaults (1s..30s).
	MinBackoff time.Duration
	MaxBackoff time.Duration
}

func (c Config) minBackoff() time.Duration {
	if c.MinBackoff <= 0 {
		return time.Second
	}
	return c.MinBackoff
}

func (c Config) maxBackoff() time.Duration {
	if c.MaxBackoff <= 0 {
		return 30 * time.Second
	}
	return c.MaxBackoff
}

// Client owns the relay connection lifecycle: dial, register, pump inbound RPC
// frames into the hosted JSONRPCServer, and reconnect with backoff on drop.
type Client struct {
	cfg    Config
	module productplatform.Module
	server *productplatform.JSONRPCServer
	dialer func(ctx context.Context, cfg Config) (Conn, error)
}

// passthroughPolicy never blocks. The cloud TenantPolicy is the single
// authority on permissions, danger floors, and the image.apply fresh-approval
// requirement; it evaluates BEFORE an invoke is dispatched over the relay (and
// the cloud streamModule then calls the desktop module directly). Re-running
// DefaultPolicy on the desktop would double-gate with a context that lacks the
// cloud's permission grants and approval state, denying legitimate, already
// authorized invocations. The desktop is a pure executor.
type passthroughPolicy struct{}

func (passthroughPolicy) Evaluate(productplatform.Capability, productplatform.InvocationContext) (productplatform.ActionResult, bool) {
	return productplatform.ActionResult{}, false
}

// NewClient builds a relay client that hosts the given DeckhandModule. It stands
// up a private productplatform.Runtime + Registry + JSONRPCServer so inbound
// frames are answered by the SAME dispatch the cloud uses, with no new server
// code (the wire-protocol contract). The hosted runtime uses a pass-through
// policy: the cloud is the sole policy authority (see passthroughPolicy).
func NewClient(cfg Config, module productplatform.Module) (*Client, error) {
	registry := productplatform.NewRegistry()
	if err := registry.Register(context.Background(), module); err != nil {
		return nil, fmt.Errorf("register deckhand module: %w", err)
	}
	runtime := productplatform.NewRuntime(registry, passthroughPolicy{})
	return &Client{
		cfg:    cfg,
		module: module,
		server: productplatform.NewJSONRPCServer(runtime),
		dialer: dialWebsocket,
	}, nil
}

// Run dials, registers, and pumps until ctx is cancelled, reconnecting with
// exponential backoff on any connection-level failure. It only returns when ctx
// is done; a handshake nack is logged-and-retried like any other drop, because
// a transient gateway error should not permanently disable the desktop relay.
func (c *Client) Run(ctx context.Context) error {
	backoff := c.cfg.minBackoff()
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		err := c.runOnce(ctx)
		if err == nil || errors.Is(err, context.Canceled) {
			if ctx.Err() != nil {
				return ctx.Err()
			}
		}
		// Reset backoff after a connection that survived past the handshake;
		// runOnce returns errHandshake distinctly so we keep backing off on a
		// nack loop but reset on a healthy session that simply ended.
		if errors.Is(err, errSessionEstablished) {
			backoff = c.cfg.minBackoff()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}
		backoff *= 2
		if backoff > c.cfg.maxBackoff() {
			backoff = c.cfg.maxBackoff()
		}
	}
}

// errSessionEstablished sentinels that a connection got past the register
// handshake before dropping, so Run can reset the backoff.
var errSessionEstablished = errors.New("relay: session established then closed")

// runOnce performs one connect -> register -> pump cycle. It returns when the
// connection drops or ctx is cancelled.
func (c *Client) runOnce(ctx context.Context) error {
	conn, err := c.dialer(ctx, c.cfg)
	if err != nil {
		return fmt.Errorf("dial relay: %w", err)
	}
	defer conn.Close()

	if err := c.register(conn); err != nil {
		return err
	}
	if err := c.pump(ctx, conn); err != nil {
		return fmt.Errorf("%w: %v", errSessionEstablished, err)
	}
	return errSessionEstablished
}

// register sends the body-wrapped register frame and reads the ack/nack.
func (c *Client) register(conn Conn) error {
	body, err := json.Marshal(registerBody{
		ProtocolVersion: protocolVersion,
		RuntimeID:       c.cfg.RuntimeID,
		Modules: []moduleAdvert{{
			ModuleID:      ModuleID,
			CapabilityIDs: CapabilityIDs(),
		}},
	})
	if err != nil {
		return fmt.Errorf("encode register body: %w", err)
	}
	if err := conn.WriteJSON(Frame{Kind: kindRegister, Body: body}); err != nil {
		return fmt.Errorf("write register frame: %w", err)
	}
	var frame Frame
	if err := conn.ReadJSON(&frame); err != nil {
		return fmt.Errorf("read register response: %w", err)
	}
	switch frame.Kind {
	case kindRegisterAck:
		return nil
	case kindRegisterNack:
		var nack registerNackBody
		_ = json.Unmarshal(frame.Body, &nack)
		return fmt.Errorf("relay registration rejected: %s", nack.Reason)
	default:
		return fmt.Errorf("unexpected handshake frame kind %q", frame.Kind)
	}
}

// pump reads inbound frames and answers rpc frames by feeding the body to the
// hosted JSONRPCServer. It is single-reader; every write goes back through the
// one Conn, and pump is the only writer of rpc responses, so the conn's writes
// are serialized (single-writer discipline).
func (c *Client) pump(ctx context.Context, conn Conn) error {
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		var frame Frame
		if err := conn.ReadJSON(&frame); err != nil {
			return err
		}
		switch frame.Kind {
		case kindRPC:
			resp := c.answer(ctx, frame.Body)
			if resp == nil {
				continue
			}
			if err := conn.WriteJSON(Frame{Kind: kindRPC, Body: resp}); err != nil {
				return err
			}
		case kindEvent:
			// The desktop does not consume events; the cloud is the caller.
		default:
			// Unknown / late frames are ignored.
		}
	}
}

// answer feeds a single JSON-RPC request body to the hosted JSONRPCServer via
// its HandleHTTP entry point and returns the JSON-RPC response body. Reusing
// HandleHTTP means the relay responder shares the cloud's exact method dispatch
// (action.invoke -> Runtime.Invoke -> DeckhandModule), with the id echoed
// verbatim by the server. A nil return means the request produced no response
// (e.g. a notification), and nothing is written back.
func (c *Client) answer(ctx context.Context, body json.RawMessage) json.RawMessage {
	req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/module/rpc", strings.NewReader(string(body)))
	rec := httptest.NewRecorder()
	c.server.HandleHTTP(rec, req)
	out := rec.Body.Bytes()
	if len(out) == 0 {
		return nil
	}
	return json.RawMessage(append([]byte(nil), out...))
}

// dialWebsocket is the production dialer: a TLS WS dial with the bearer token in
// the Authorization header so the gateway can validate identity before
// upgrading. The wire register frame is sent afterward but never trusted for
// auth.
func dialWebsocket(ctx context.Context, cfg Config) (Conn, error) {
	header := http.Header{}
	if cfg.Token != "" {
		header.Set("Authorization", "Bearer "+cfg.Token)
	}
	conn, resp, err := websocket.DefaultDialer.DialContext(ctx, cfg.Endpoint, header)
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("dial %s: %w (status %d)", cfg.Endpoint, err, resp.StatusCode)
		}
		return nil, fmt.Errorf("dial %s: %w", cfg.Endpoint, err)
	}
	return &gorillaConn{conn: conn}, nil
}

// gorillaConn adapts *websocket.Conn to Conn. ReadJSON/WriteJSON use text
// frames carrying one JSON object each, matching the cloud's framing.
type gorillaConn struct {
	conn *websocket.Conn
}

func (g *gorillaConn) ReadJSON(v any) error  { return g.conn.ReadJSON(v) }
func (g *gorillaConn) WriteJSON(v any) error { return g.conn.WriteJSON(v) }
func (g *gorillaConn) Close() error          { return g.conn.Close() }
