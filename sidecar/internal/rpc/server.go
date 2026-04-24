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
	"sync"
)

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

// Server is a JSON-RPC 2.0 server that reads requests one-per-line from
// stdin and writes responses one-per-line to stdout.
type Server struct {
	mu       sync.RWMutex
	handlers map[string]Handler
}

// NewServer returns a Server with no handlers registered.
func NewServer() *Server {
	return &Server{handlers: make(map[string]Handler)}
}

// Register adds a handler for [method]. Replaces any existing handler.
func (s *Server) Register(method string, h Handler) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handlers[method] = h
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
		h, ok := s.handlers[req.Method]
		s.mu.RUnlock()
		if !ok {
			w.writeResponse(errorResponse(req.ID, codeMethodNotFound, fmt.Sprintf("unknown method %q", req.Method), nil))
			continue
		}

		// Dispatch in a goroutine so long-running handlers don't block
		// the read loop. Each request gets its own notifier that scopes
		// notifications to its operation id.
		inflight.Add(1)
		go func(req request, h Handler) {
			defer inflight.Done()
			opID := unquoteID(req.ID)
			note := &methodNotifier{writer: w, operationID: opID}
			defer func() {
				if r := recover(); r != nil {
					w.writeResponse(errorResponse(req.ID, codeInternalError, fmt.Sprintf("handler panic: %v", r), nil))
				}
			}()
			result, err := h(ctx, req.Params, note)
			if err != nil {
				code, data := mapError(err)
				w.writeResponse(errorResponse(req.ID, code, err.Error(), data))
				return
			}
			w.writeResponse(successResponse(req.ID, result))
		}(req, h)
	}
	// Drain in-flight handlers before returning so the caller's output
	// stream does not close with pending writes still queued.
	inflight.Wait()
	if err := ctx.Err(); err != nil {
		return err
	}
	return scanner.Err()
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
