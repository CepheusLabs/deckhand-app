package localagent

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
)

const ProtocolVersion = "deckhand-local-agent/v1"

type Config struct {
	Token        string
	AllowOrigins []string
	Version      string
}

func NewHandler(server *rpc.Server, cfg Config) http.Handler {
	s := &service{
		server: server,
		cfg:    cfg,
		ops:    newOperationRegistry(),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ping", s.handlePing)
	mux.HandleFunc("/v1/rpc", s.handleRPC)
	mux.HandleFunc("/v1/operations", s.handleOperations)
	mux.HandleFunc("/v1/operations/", s.handleOperation)
	return s.withCORS(mux)
}

func Serve(ctx context.Context, addr string, server *rpc.Server, cfg Config) error {
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           NewHandler(server, cfg),
		ReadHeaderTimeout: 5 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() {
		errCh <- httpServer.ListenAndServe()
	}()
	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
		err := <-errCh
		if errors.Is(err, http.ErrServerClosed) {
			return ctx.Err()
		}
		return err
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

type service struct {
	server *rpc.Server
	cfg    Config
	ops    *operationRegistry
}

type rpcRequest struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

func (s *service) handlePing(w http.ResponseWriter, r *http.Request) {
	if !s.authorize(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       true,
		"protocol": ProtocolVersion,
		"version":  s.cfg.Version,
	})
}

func (s *service) handleRPC(w http.ResponseWriter, r *http.Request) {
	if !s.authorize(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	req, ok := readRPCRequest(w, r)
	if !ok {
		return
	}
	operationID := newOperationID()
	result, err := s.server.Invoke(
		r.Context(),
		operationID,
		req.Method,
		normalizedParams(req.Params),
		operationNotifier{op: nil},
	)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":     operationID,
		"result": result,
	})
}

func (s *service) handleOperations(w http.ResponseWriter, r *http.Request) {
	if !s.authorize(w, r) {
		return
	}
	if r.URL.Path != "/v1/operations" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	req, ok := readRPCRequest(w, r)
	if !ok {
		return
	}
	id := newOperationID()
	ctx, cancel := context.WithCancel(context.Background())
	op := newOperation(id, cancel)
	s.ops.add(op)
	go func() {
		defer cancel()
		result, err := s.server.Invoke(
			ctx,
			id,
			req.Method,
			normalizedParams(req.Params),
			operationNotifier{op: op},
		)
		if err != nil {
			op.finish(agentEvent{
				name:     "failed",
				terminal: true,
				data: map[string]any{
					"phase":   "failed",
					"message": err.Error(),
				},
			})
			return
		}
		op.finish(agentEvent{
			name:     "done",
			terminal: true,
			data: map[string]any{
				"phase":  "done",
				"result": result,
			},
		})
	}()
	writeJSON(w, http.StatusAccepted, map[string]any{
		"id": id,
	})
}

func (s *service) handleOperation(w http.ResponseWriter, r *http.Request) {
	if !s.authorize(w, r) {
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/v1/operations/")
	id, suffix, _ := strings.Cut(rest, "/")
	if id == "" {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	op := s.ops.get(id)
	if op == nil {
		writeError(w, http.StatusNotFound, "operation not found")
		return
	}
	if suffix == "events" && r.Method == http.MethodGet {
		s.streamEvents(w, r, op)
		return
	}
	if suffix == "" && r.Method == http.MethodDelete {
		op.cancel()
		_ = s.server.CancelJob(id)
		op.finish(agentEvent{
			name:     "cancelled",
			terminal: true,
			data: map[string]any{
				"phase":   "failed",
				"message": "operation cancelled",
			},
		})
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	writeError(w, http.StatusNotFound, "not found")
}

func (s *service) streamEvents(w http.ResponseWriter, r *http.Request, op *operation) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	existing, ch, unsubscribe := op.subscribe()
	defer unsubscribe()
	for _, ev := range existing {
		writeSSE(w, flusher, ev)
		if ev.terminal {
			return
		}
	}
	for {
		select {
		case ev := <-ch:
			writeSSE(w, flusher, ev)
			if ev.terminal {
				return
			}
		case <-r.Context().Done():
			return
		}
	}
}

func (s *service) authorize(w http.ResponseWriter, r *http.Request) bool {
	token := strings.TrimSpace(s.cfg.Token)
	if token == "" {
		return true
	}
	got := strings.TrimSpace(r.Header.Get("Authorization"))
	if strings.HasPrefix(strings.ToLower(got), "bearer ") {
		got = strings.TrimSpace(got[len("bearer "):])
	}
	if got == "" {
		got = strings.TrimSpace(r.URL.Query().Get("token"))
	}
	if got == token {
		return true
	}
	writeError(w, http.StatusUnauthorized, "unauthorized")
	return false
}

func (s *service) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && s.originAllowed(origin) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Credentials", "false")
			w.Header().Set("Access-Control-Allow-Headers", "authorization, content-type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *service) originAllowed(origin string) bool {
	if origin == "" {
		return true
	}
	allowed := s.cfg.AllowOrigins
	if len(allowed) == 0 {
		return strings.HasPrefix(origin, "https://") ||
			strings.HasPrefix(origin, "http://localhost") ||
			strings.HasPrefix(origin, "http://127.0.0.1")
	}
	for _, pattern := range allowed {
		pattern = strings.TrimSpace(pattern)
		if pattern == "*" || pattern == origin {
			return true
		}
		if strings.HasSuffix(pattern, "/*") &&
			strings.HasPrefix(origin, strings.TrimSuffix(pattern, "*")) {
			return true
		}
	}
	return false
}

type operationNotifier struct {
	op *operation
}

func (n operationNotifier) Notify(method string, params any) {
	if n.op == nil {
		return
	}
	data := mapFromAny(params)
	data["event"] = method
	n.op.publish(agentEvent{name: method, data: data})
}

type operationRegistry struct {
	mu  sync.RWMutex
	ops map[string]*operation
}

func newOperationRegistry() *operationRegistry {
	return &operationRegistry{ops: map[string]*operation{}}
}

func (r *operationRegistry) add(op *operation) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ops[op.id] = op
}

func (r *operationRegistry) get(id string) *operation {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.ops[id]
}

type operation struct {
	id          string
	cancel      context.CancelFunc
	mu          sync.Mutex
	events      []agentEvent
	subscribers map[chan agentEvent]struct{}
	done        bool
}

func newOperation(id string, cancel context.CancelFunc) *operation {
	return &operation{
		id:          id,
		cancel:      cancel,
		subscribers: map[chan agentEvent]struct{}{},
	}
}

func (o *operation) publish(ev agentEvent) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.done {
		return
	}
	o.events = append(o.events, ev)
	for ch := range o.subscribers {
		select {
		case ch <- ev:
		default:
		}
	}
}

func (o *operation) finish(ev agentEvent) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.done {
		return
	}
	o.done = true
	o.events = append(o.events, ev)
	for ch := range o.subscribers {
		select {
		case ch <- ev:
		default:
		}
		close(ch)
	}
	o.subscribers = map[chan agentEvent]struct{}{}
}

func (o *operation) subscribe() ([]agentEvent, <-chan agentEvent, func()) {
	o.mu.Lock()
	defer o.mu.Unlock()
	ch := make(chan agentEvent, 16)
	existing := append([]agentEvent(nil), o.events...)
	if !o.done {
		o.subscribers[ch] = struct{}{}
	}
	return existing, ch, func() {
		o.mu.Lock()
		defer o.mu.Unlock()
		if _, ok := o.subscribers[ch]; ok {
			delete(o.subscribers, ch)
			close(ch)
		}
	}
}

type agentEvent struct {
	name     string
	data     map[string]any
	terminal bool
}

func readRPCRequest(w http.ResponseWriter, r *http.Request) (rpcRequest, bool) {
	defer r.Body.Close()
	var req rpcRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return req, false
	}
	req.Method = strings.TrimSpace(req.Method)
	if req.Method == "" {
		writeError(w, http.StatusBadRequest, "method is required")
		return req, false
	}
	return req, true
}

func normalizedParams(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || strings.TrimSpace(string(raw)) == "" {
		return json.RawMessage(`{}`)
	}
	return raw
}

func mapFromAny(v any) map[string]any {
	if v == nil {
		return map[string]any{}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return map[string]any{"message": fmt.Sprint(v)}
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		return map[string]any{"message": fmt.Sprint(v)}
	}
	return out
}

func writeSSE(w http.ResponseWriter, flusher http.Flusher, ev agentEvent) {
	data := ev.data
	if data == nil {
		data = map[string]any{}
	}
	data["operation_event"] = ev.name
	b, err := json.Marshal(data)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(w, "event: %s\n", ev.name)
	_, _ = fmt.Fprintf(w, "data: %s\n\n", b)
	flusher.Flush()
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]any{
			"message": message,
		},
	})
}

func newOperationID() string {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return fmt.Sprintf("op-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf[:])
}
