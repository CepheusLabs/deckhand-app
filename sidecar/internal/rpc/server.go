// Package rpc implements JSON-RPC 2.0 framing over line-delimited JSON
// on stdin/stdout. It's the single IPC surface between the Flutter app
// and the Go sidecar.
//
// Handlers can emit progress notifications through the Notifier passed
// in their context; the UI receives them as JSON-RPC notifications
// (messages without an id).
package rpc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
)

var sensitiveURLPattern = regexp.MustCompile(`https?://[^\s"']+`)

// Error is a typed handler error that carries a JSON-RPC error code.
// Handlers return `&rpc.Error{Code: CodeDisk+1, Message: "..."}` and the
// server maps it to a proper response without flattening everything to
// codeInternalError.
type Error struct {
	Code    int
	Message string
	Data    any
}

func (e *Error) Error() string { return e.Message }

// NewError is sugar for constructing typed errors at the call site.
func NewError(code int, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// Notifier is how handlers push progress notifications back to the UI.
// Implementations serialize writes to avoid interleaving with responses.
type Notifier interface {
	Notify(method string, params any)
}

// Handler handles a single JSON-RPC method call.
type Handler func(ctx context.Context, params json.RawMessage, note Notifier) (any, error)

// MethodSpec describes a registered method for both runtime dispatch and
// the IPC-docs generator. Description/Returns/Params are purely
// informational; Handler is the dispatched function.
//
// An empty MethodSpec passed alongside a Name (via Register) still works
// - Description/Returns default to empty and the method is dispatched
// normally.
type MethodSpec struct {
	Name        string
	Description string
	Params      []ParamSpec
	Returns     string
	Handler     Handler
}

// Server is a JSON-RPC 2.0 server that reads requests one-per-line from
// stdin and writes responses one-per-line to stdout.
type Server struct {
	mu      sync.RWMutex
	methods map[string]MethodSpec

	// logger, if set via SetLogger, is called with every dispatched
	// request (INFO) and every handler error (WARN). Handlers that
	// need their own logger read it via Server.Logger().
	loggerMu sync.RWMutex
	logger   *slog.Logger

	// Job registry: one cancellable context per in-flight request.
	jobs *jobRegistry

	limitMu        sync.Mutex
	globalLimit    int
	globalInFlight int
	methodLimits   map[string]int
	methodInFlight map[string]int
}

// NewServer returns a Server with no handlers registered.
func NewServer() *Server {
	return &Server{
		methods: make(map[string]MethodSpec),
		jobs:    newJobRegistry(),

		globalLimit: 32,
		methodLimits: map[string]int{
			"disks.write_image": 1,
			"disks.read_image":  1,
			"disks.hash":        1,
		},
		methodInFlight: map[string]int{},
	}
}

// SetConcurrencyLimits configures best-effort request admission limits.
// A zero global limit disables the global cap; method limits apply by
// method name and reject excess concurrent calls before the handler starts.
func (s *Server) SetConcurrencyLimits(global int, methods map[string]int) {
	s.limitMu.Lock()
	defer s.limitMu.Unlock()
	s.globalLimit = global
	s.methodLimits = make(map[string]int, len(methods))
	for method, limit := range methods {
		if limit > 0 {
			s.methodLimits[method] = limit
		}
	}
}

// Register adds a handler for [method]. Kept for backward compat - new
// callers should use RegisterMethod with a full MethodSpec. Replaces any
// existing handler.
func (s *Server) Register(method string, h Handler) {
	s.RegisterMethod(MethodSpec{Name: method, Handler: h})
}

// RegisterMethod adds a handler plus its documentation. Replaces any
// existing registration for the same Name.
func (s *Server) RegisterMethod(spec MethodSpec) {
	if spec.Name == "" || spec.Handler == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.methods[spec.Name] = spec
}

// SetLogger installs a slog.Logger the server uses for dispatch/error
// logging and that handlers can fetch via Logger(). Safe to call
// concurrently with Serve but typically wired once at startup.
func (s *Server) SetLogger(l *slog.Logger) {
	s.loggerMu.Lock()
	defer s.loggerMu.Unlock()
	s.logger = l
}

// Logger returns the configured slog.Logger, or slog.Default() if none
// was set. Never returns nil so callers don't have to nil-check.
func (s *Server) Logger() *slog.Logger {
	s.loggerMu.RLock()
	defer s.loggerMu.RUnlock()
	if s.logger != nil {
		return s.logger
	}
	return slog.Default()
}

// CancelJob cancels the in-flight job with the given operation id.
// Returns true if an entry was found and cancelled.
func (s *Server) CancelJob(id string) bool {
	return s.jobs.cancel(id)
}

// Serve runs the read/dispatch/respond loop until [ctx] is cancelled or
// the input stream closes. In-flight handler goroutines are waited on
// before Serve returns so the output stream never closes with pending
// responses still buffered.
func (s *Server) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 1<<16), 1<<24)

	w := &outputWriter{w: bufio.NewWriter(out)}

	var inflight sync.WaitGroup

	for scanner.Scan() {
		if ctx.Err() != nil {
			break
		}

		line := append([]byte(nil), scanner.Bytes()...)

		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			w.writeResponse(errorResponse(nil, codeParseError, "parse error", nil))
			continue
		}

		if req.JSONRPC != "2.0" {
			w.writeResponse(errorResponse(req.ID, codeInvalidRequest, "missing or bad jsonrpc version", nil))
			continue
		}

		s.mu.RLock()
		spec, ok := s.methods[req.Method]
		s.mu.RUnlock()
		if !ok {
			w.writeResponse(errorResponse(req.ID, codeMethodNotFound, fmt.Sprintf("unknown method %q", req.Method), nil))
			continue
		}
		releaseLimit, ok := s.acquireLimit(req.Method)
		if !ok {
			w.writeResponse(errorResponse(req.ID, CodeGeneric, fmt.Sprintf("concurrency limit exceeded for %s", req.Method), nil))
			continue
		}

		// Dispatch in a goroutine so long-running handlers don't block
		// the read loop. Each request gets its own notifier that scopes
		// notifications to its operation id plus a cancellable context
		// registered in the job table keyed by the same id.
		inflight.Add(1)
		go func(req request, spec MethodSpec) {
			defer inflight.Done()
			defer releaseLimit()
			opID := unquoteID(req.ID)
			note := &methodNotifier{writer: w, operationID: opID}

			// Only register the context in the job table if the request
			// has a non-null id (JSON-RPC notifications have none, and
			// there is no way to target them for cancellation anyway).
			handlerCtx := ctx
			var releaseJob func()
			if opID != "" && opID != "null" {
				var cancel context.CancelFunc
				handlerCtx, cancel = context.WithCancel(ctx)
				releaseJob = s.jobs.register(opID, cancel)
				defer releaseJob()
			}

			s.logDispatch(req.Method, opID, req.Params)

			defer func() {
				if r := recover(); r != nil {
					s.logHandlerError(req.Method, opID, fmt.Errorf("panic: %v", r))
					w.writeResponse(errorResponse(req.ID, codeInternalError, "handler panic", nil))
				}
			}()
			result, err := spec.Handler(handlerCtx, req.Params, note)
			if err != nil {
				s.logHandlerError(req.Method, opID, err)
				code, data := mapError(err)
				w.writeResponse(errorResponse(req.ID, code, sanitizeErrorMessage(err.Error()), data))
				return
			}
			w.writeResponse(successResponse(req.ID, result))
		}(req, spec)
	}
	// Drain in-flight handlers before returning so the caller's output
	// stream does not close with pending writes still queued.
	inflight.Wait()
	if err := ctx.Err(); err != nil {
		return err
	}
	return scanner.Err()
}

func (s *Server) acquireLimit(method string) (func(), bool) {
	s.limitMu.Lock()
	defer s.limitMu.Unlock()
	if s.globalLimit > 0 && s.globalInFlight >= s.globalLimit {
		return nil, false
	}
	if limit := s.methodLimits[method]; limit > 0 && s.methodInFlight[method] >= limit {
		return nil, false
	}
	s.globalInFlight++
	s.methodInFlight[method]++
	return func() {
		s.limitMu.Lock()
		defer s.limitMu.Unlock()
		s.globalInFlight--
		s.methodInFlight[method]--
	}, true
}

// RenderMethodsMarkdown returns a markdown table describing every
// registered method, sorted by name. Used by cmd/deckhand-ipc-docs to
// keep docs/IPC-METHODS.md current.
func (s *Server) RenderMethodsMarkdown() string {
	s.mu.RLock()
	specs := make([]MethodSpec, 0, len(s.methods))
	for _, spec := range s.methods {
		specs = append(specs, spec)
	}
	s.mu.RUnlock()

	sort.Slice(specs, func(i, j int) bool { return specs[i].Name < specs[j].Name })

	var b strings.Builder
	b.WriteString("# Deckhand sidecar IPC methods\n\n")
	b.WriteString("Auto-generated from `internal/rpc` MethodSpec registrations. ")
	b.WriteString("Do not edit by hand - regenerate with `go run ./cmd/deckhand-ipc-docs`.\n\n")
	b.WriteString("| Method | Description | Params | Returns |\n")
	b.WriteString("|---|---|---|---|\n")
	for _, spec := range specs {
		b.WriteString("| `")
		b.WriteString(spec.Name)
		b.WriteString("` | ")
		b.WriteString(escapeTableCell(spec.Description))
		b.WriteString(" | ")
		b.WriteString(renderParams(spec.Params))
		b.WriteString(" | ")
		b.WriteString(escapeTableCell(spec.Returns))
		b.WriteString(" |\n")
	}
	return b.String()
}

func renderParams(ps []ParamSpec) string {
	if len(ps) == 0 {
		return "_none_"
	}
	parts := make([]string, 0, len(ps))
	for _, p := range ps {
		tag := "optional"
		if p.Required {
			tag = "required"
		}
		kind := string(p.Kind)
		if kind == "" {
			kind = "any"
		}
		parts = append(parts, fmt.Sprintf("`%s` (%s %s)", p.Name, tag, kind))
	}
	return strings.Join(parts, "<br>")
}

// escapeTableCell replaces pipe and newline characters that would break
// a markdown table row.
func escapeTableCell(s string) string {
	if s == "" {
		return ""
	}
	s = strings.ReplaceAll(s, "|", `\|`)
	s = strings.ReplaceAll(s, "\r\n", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	return s
}

// -------------------------------------------------------------------
// Logging helpers

// redactedKeys names JSON fields whose values are always dropped from
// the logged params. The substring regex below catches general cases
// like "api_password" or "auth_token"; redactedKeys catches the
// specific fields we know about.
var redactedKeys = map[string]struct{}{
	"confirmation_token": {},
	"repo_url":           {},
	"trusted_keys":       {},
}

// redactParams returns a copy of raw with secret-ish fields elided.
// Non-object params are passed through unchanged because everything we
// want to redact lives at the top level of an object.
func redactParams(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" {
		return raw
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return raw
	}
	changed := false
	for k := range m {
		if shouldRedactKey(k) {
			m[k] = json.RawMessage(`"[redacted]"`)
			changed = true
			continue
		}
		var value string
		if err := json.Unmarshal(m[k], &value); err == nil {
			sanitized := sanitizeErrorMessage(value)
			if sanitized != value {
				b, _ := json.Marshal(sanitized)
				m[k] = b
				changed = true
			}
		}
	}
	if !changed {
		return raw
	}
	out, err := json.Marshal(m)
	if err != nil {
		return raw
	}
	return out
}

func shouldRedactKey(k string) bool {
	if _, ok := redactedKeys[k]; ok {
		return true
	}
	lk := strings.ToLower(k)
	return strings.Contains(lk, "password") ||
		strings.Contains(lk, "secret") ||
		strings.Contains(lk, "token")
}

func sanitizeErrorMessage(msg string) string {
	return sensitiveURLPattern.ReplaceAllStringFunc(msg, func(raw string) string {
		u, err := url.Parse(raw)
		if err != nil || u.Host == "" {
			return "[redacted-url]"
		}
		if u.User != nil {
			u.User = url.User("redacted")
		}
		if u.RawQuery != "" {
			u.RawQuery = "[redacted]"
		}
		u.Fragment = ""
		return u.String()
	})
}

func (s *Server) logDispatch(method, opID string, raw json.RawMessage) {
	l := s.Logger()
	l.Info("rpc.dispatch",
		"method", method,
		"operation_id", opID,
		"params", string(redactParams(raw)),
	)
}

func (s *Server) logHandlerError(method, opID string, err error) {
	l := s.Logger()
	l.Warn("rpc.handler_error",
		"method", method,
		"operation_id", opID,
		"error", sanitizeErrorMessage(err.Error()),
	)
}

// -------------------------------------------------------------------
// Notifier plumbing

type methodNotifier struct {
	writer      *outputWriter
	operationID string
}

func (n *methodNotifier) Notify(method string, params any) {
	p, err := json.Marshal(params)
	if err != nil {
		return
	}
	// Inject the operation id so the UI can correlate notifications to
	// the originating request.
	var merged map[string]any
	if err := json.Unmarshal(p, &merged); err == nil {
		merged["operation_id"] = n.operationID
		p, _ = json.Marshal(merged)
	}
	n.writer.writeRaw(notification{
		JSONRPC: "2.0",
		Method:  method,
		Params:  p,
	})
}

type outputWriter struct {
	mu sync.Mutex
	w  *bufio.Writer
}

func (o *outputWriter) writeResponse(r response) {
	o.writeRaw(r)
}

func (o *outputWriter) writeRaw(v any) {
	o.mu.Lock()
	defer o.mu.Unlock()
	enc := json.NewEncoder(o.w)
	if err := enc.Encode(v); err != nil {
		return
	}
	_ = o.w.Flush()
}

// -------------------------------------------------------------------
// Message types + error codes

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *responseError  `json:"error,omitempty"`
}

type notification struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type responseError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// Error codes, grouped by domain per docs/ARCHITECTURE.md.
const (
	codeParseError     = -32700
	codeInvalidRequest = -32600
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
	codeInternalError  = -32603

	CodeGeneric = -32000
	CodeSSH     = -33000
	CodeDisk    = -34000
	CodeProfile = -35000
	CodeNetwork = -36000
)

func successResponse(id json.RawMessage, result any) response {
	return response{JSONRPC: "2.0", ID: id, Result: result}
}

// unquoteID strips JSON quotes off a raw-encoded id so it can be used as
// a plain string in notifications. Numeric ids are returned as-is.
func unquoteID(id json.RawMessage) string {
	if len(id) >= 2 && id[0] == '"' && id[len(id)-1] == '"' {
		var s string
		if err := json.Unmarshal(id, &s); err == nil {
			return s
		}
	}
	return string(id)
}

func errorResponse(id json.RawMessage, code int, msg string, data any) response {
	return response{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &responseError{Code: code, Message: msg, Data: data},
	}
}

// mapError turns a handler error into a JSON-RPC code + optional data.
// Typed *rpc.Error carries its own code (handler's explicit choice);
// everything else falls back to codeInternalError. Domain packages
// wrap their sentinel errors in *rpc.Error at the handler boundary
// so the server here never needs to import domain packages.
func mapError(err error) (int, any) {
	var rpcErr *Error
	if errors.As(err, &rpcErr) {
		return rpcErr.Code, rpcErr.Data
	}
	return codeInternalError, nil
}
