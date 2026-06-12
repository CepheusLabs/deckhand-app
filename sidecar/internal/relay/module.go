package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"

	productplatform "github.com/cepheuslabs/printdeck_product_platform"
)

// Invoker is the seam DeckhandModule routes capability calls through. In
// production it is satisfied by the sidecar's *rpc.Server.Invoke, which shares
// the exact handler set, cancellation registry, and concurrency limits as the
// stdio IPC path. Tests substitute a fake to assert the cap->method mapping
// without spinning up the real handlers.
type Invoker interface {
	Invoke(ctx context.Context, operationID, method string, params json.RawMessage) (any, error)
}

// InvokerFunc adapts a plain function to Invoker.
type InvokerFunc func(ctx context.Context, operationID, method string, params json.RawMessage) (any, error)

func (f InvokerFunc) Invoke(ctx context.Context, operationID, method string, params json.RawMessage) (any, error) {
	return f(ctx, operationID, method, params)
}

// DeckhandModule adapts the sidecar's JSON-RPC handlers to the cortex
// productplatform.Module contract so the cloud relay can drive them. It is the
// in-process target of the hosted JSONRPCServer.dispatch on the desktop side:
// action.invoke -> Runtime.Invoke -> this module's InvokeAction.
//
// The cloud TenantPolicy enforces the fresh-approval floor for the critical
// deckhand.image.apply capability before the invoke ever reaches the wire, so
// this module trusts that a request which arrives is an already-confirmed
// invoke. It still re-applies the desktop's own defense-in-depth: preflight
// blocks unsafe targets, and write_image re-probes the disk live in the handler.
type DeckhandModule struct {
	invoker Invoker

	mu    sync.Mutex
	tasks map[string]*task
	idSeq uint64
}

// task tracks one long-running invocation so TaskStatus/TaskCancel can report
// progress and cancellation for deckhand.image.apply and the other
// long_running capabilities.
type task struct {
	capabilityID string
	result       *productplatform.ActionResult
	err          error
	done         bool
	cancel       context.CancelFunc
}

// NewDeckhandModule builds the module around an Invoker (the sidecar rpc.Server
// in production).
func NewDeckhandModule(invoker Invoker) *DeckhandModule {
	return &DeckhandModule{
		invoker: invoker,
		tasks:   map[string]*task{},
	}
}

func (m *DeckhandModule) Describe(context.Context) (productplatform.ModuleDescriptor, error) {
	return productplatform.ModuleDescriptor{
		ID:           ModuleID,
		DisplayName:  "Deckhand desktop",
		Version:      "edge-relay",
		RuntimeModes: []productplatform.RuntimeMode{productplatform.RuntimeLocal},
		Capabilities: ManifestCapabilities(),
	}, nil
}

// ContextSnapshot reports a minimal local snapshot. The desktop has no routed
// UI state to expose to the cloud beyond reachability, which the cloud-side
// EdgeRelayModule already annotates.
func (m *DeckhandModule) ContextSnapshot(_ context.Context, ic productplatform.InvocationContext) (productplatform.ContextSnapshot, error) {
	return productplatform.ContextSnapshot{
		ModuleID:    ModuleID,
		RuntimeMode: productplatform.RuntimeLocal,
		Values: map[string]any{
			"tenant_id": ic.TenantID,
		},
	}, nil
}

// ReadResource is not offered by the deckhand edge module; binary payloads
// travel as managed file paths, never inline over the relay.
func (m *DeckhandModule) ReadResource(context.Context, productplatform.ResourceRequest) (productplatform.Resource, error) {
	return productplatform.Resource{}, errors.New("deckhand edge module does not expose resources")
}

// InvokeAction maps a deckhand.* capability onto the underlying sidecar handler.
func (m *DeckhandModule) InvokeAction(ctx context.Context, invocation productplatform.ActionInvocation) (productplatform.ActionResult, error) {
	switch invocation.CapabilityID {
	case CapHostDiagnose:
		return m.invokeImmediate(ctx, invocation, "doctor.run", nil)
	case CapDisksInspect:
		return m.invokeImmediate(ctx, invocation, "disks.list", nil)
	case CapDisksPreflight:
		return m.invokePreflight(ctx, invocation)
	case CapProfileFetch:
		return m.invokeImmediate(ctx, invocation, "profiles.fetch", profilesFetchParams(invocation.Input))
	case CapArchiveSnapshot:
		return m.startLongRunning(ctx, invocation, "disks.read_image", archiveSnapshotParams(invocation.Input))
	case CapImageApply:
		return m.startLongRunning(ctx, invocation, "disks.write_image", imageApplyParams(invocation.Input))
	default:
		return productplatform.ActionResult{
			Status:  productplatform.StatusFailed,
			Message: fmt.Sprintf("unknown deckhand capability: %s", invocation.CapabilityID),
		}, nil
	}
}

// invokeImmediate runs a synchronous handler and wraps its raw result as an
// ActionResult output. params, when nil, sends no params.
func (m *DeckhandModule) invokeImmediate(ctx context.Context, invocation productplatform.ActionInvocation, method string, params map[string]any) (productplatform.ActionResult, error) {
	raw, err := m.dispatch(ctx, invocation.Context, method, params)
	if err != nil {
		return failed(err), nil
	}
	return productplatform.ActionResult{
		Status: productplatform.StatusSuccess,
		Output: map[string]any{"result": raw},
	}, nil
}

// invokePreflight runs disks.safety_check and BLOCKS the result before
// deckhand.image.apply is ever offered to the user/agent. A target that is
// non-removable, system/boot, read-only, or otherwise unsafe yields a denied
// result whose blocking reasons are surfaced; only an allowed verdict carries a
// "next_actions: [deckhand.image.apply]" hint.
func (m *DeckhandModule) invokePreflight(ctx context.Context, invocation productplatform.ActionInvocation) (productplatform.ActionResult, error) {
	deviceID, _ := invocation.Input["device_id"].(string)
	if deviceID == "" {
		return productplatform.ActionResult{
			Status:  productplatform.StatusFailed,
			Message: "device_id is required for preflight",
		}, nil
	}
	// safety_check re-probes the live disk by id inside the handler, so a
	// fabricated DiskInfo cannot pass. We only forward the id.
	raw, err := m.dispatch(ctx, invocation.Context, "disks.safety_check", map[string]any{
		"disk": map[string]any{"id": deviceID},
	})
	if err != nil {
		return failed(err), nil
	}
	verdict, ok := decodeSafetyVerdict(raw)
	if !ok {
		return productplatform.ActionResult{
			Status:  productplatform.StatusFailed,
			Message: "could not interpret safety verdict",
		}, nil
	}
	if !verdict.Allowed {
		return productplatform.ActionResult{
			Status:   productplatform.StatusDenied,
			Message:  fmt.Sprintf("preflight blocked %s: target is not safe to flash", deviceID),
			Warnings: append(append([]string(nil), verdict.BlockingReasons...), verdict.Warnings...),
			Output:   map[string]any{"verdict": raw},
		}, nil
	}
	return productplatform.ActionResult{
		Status:      productplatform.StatusSuccess,
		Output:      map[string]any{"verdict": raw},
		Warnings:    verdict.Warnings,
		NextActions: []string{CapImageApply},
	}, nil
}

// startLongRunning launches a handler in the background and returns a queued
// ActionResult carrying a TaskRef. The cloud Runtime namespaces the returned
// task id with the module before the agent polls task.status. image.apply is
// CRITICAL; the cloud already enforced fresh approval, so reaching here means
// the write is confirmed and we execute it.
func (m *DeckhandModule) startLongRunning(ctx context.Context, invocation productplatform.ActionInvocation, method string, params map[string]any) (productplatform.ActionResult, error) {
	taskID := m.newTaskID()
	// Detach from the inbound RPC ctx so the long write/backup survives the
	// frame that started it; TaskCancel cancels this child explicitly.
	runCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))

	t := &task{capabilityID: invocation.CapabilityID, cancel: cancel}
	m.mu.Lock()
	m.tasks[taskID] = t
	m.mu.Unlock()

	go func() {
		raw, err := m.dispatch(runCtx, invocation.Context, method, params)
		m.mu.Lock()
		defer m.mu.Unlock()
		t.done = true
		if err != nil {
			t.err = err
			res := failed(err)
			t.result = &res
			return
		}
		res := productplatform.ActionResult{
			Status: productplatform.StatusSuccess,
			Output: map[string]any{"result": raw},
		}
		t.result = &res
	}()

	return productplatform.ActionResult{
		Status:  productplatform.StatusQueued,
		Message: fmt.Sprintf("%s started", invocation.CapabilityID),
		Task: &productplatform.TaskRef{
			ID:           taskID,
			CapabilityID: invocation.CapabilityID,
			Status:       productplatform.StatusQueued,
		},
	}, nil
}

// TaskStatus reports the terminal result of a long-running task, or a queued
// placeholder while it runs.
func (m *DeckhandModule) TaskStatus(_ context.Context, taskID string, _ productplatform.InvocationContext) (productplatform.ActionResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tasks[taskID]
	if !ok {
		return productplatform.ActionResult{
			Status:  productplatform.StatusFailed,
			Message: fmt.Sprintf("unknown task: %s", taskID),
		}, nil
	}
	if !t.done {
		return productplatform.ActionResult{
			Status: productplatform.StatusQueued,
			Task:   &productplatform.TaskRef{ID: taskID, CapabilityID: t.capabilityID, Status: productplatform.StatusQueued},
		}, nil
	}
	res := *t.result
	if res.Task == nil {
		res.Task = &productplatform.TaskRef{ID: taskID, CapabilityID: t.capabilityID, Status: res.Status}
	}
	return res, nil
}

// TaskCancel cancels a running task's context. A task that already finished is
// reported as such.
func (m *DeckhandModule) TaskCancel(_ context.Context, taskID string, _ productplatform.InvocationContext) (productplatform.ActionResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tasks[taskID]
	if !ok {
		return productplatform.ActionResult{
			Status:  productplatform.StatusFailed,
			Message: fmt.Sprintf("unknown task: %s", taskID),
		}, nil
	}
	if t.done {
		return productplatform.ActionResult{
			Status:  t.result.Status,
			Message: "task already finished",
			Task:    &productplatform.TaskRef{ID: taskID, CapabilityID: t.capabilityID, Status: t.result.Status},
		}, nil
	}
	t.cancel()
	return productplatform.ActionResult{
		Status:  productplatform.StatusCancelled,
		Message: "cancellation requested",
		Task:    &productplatform.TaskRef{ID: taskID, CapabilityID: t.capabilityID, Status: productplatform.StatusCancelled},
	}, nil
}

// Events returns a closed channel: the relay carries no event stream (progress
// is polled via task.status), matching the cloud streamModule.
func (m *DeckhandModule) Events(context.Context, productplatform.InvocationContext) (<-chan productplatform.ModuleEvent, error) {
	ch := make(chan productplatform.ModuleEvent)
	close(ch)
	return ch, nil
}

// HealthCheck probes the sidecar via its ping handler so the cloud presence
// signal reflects a live, answering runtime rather than just a held socket.
func (m *DeckhandModule) HealthCheck(ctx context.Context) (productplatform.ModuleHealth, error) {
	if _, err := m.dispatch(ctx, productplatform.InvocationContext{}, "ping", nil); err != nil {
		return productplatform.ModuleHealth{
			ModuleID: ModuleID,
			Status:   productplatform.HealthUnhealthy,
			Message:  err.Error(),
		}, nil
	}
	return productplatform.ModuleHealth{
		ModuleID: ModuleID,
		Status:   productplatform.HealthHealthy,
		Message:  "sidecar reachable",
	}, nil
}

// dispatch encodes params and runs the underlying sidecar method through the
// Invoker. The operationID is derived from the invocation context so an
// in-flight job is cancellable through the same registry the stdio path uses.
func (m *DeckhandModule) dispatch(ctx context.Context, ic productplatform.InvocationContext, method string, params map[string]any) (any, error) {
	var raw json.RawMessage
	if params != nil {
		encoded, err := json.Marshal(params)
		if err != nil {
			return nil, fmt.Errorf("encode %s params: %w", method, err)
		}
		raw = encoded
	}
	return m.invoker.Invoke(ctx, operationID(ic), method, raw)
}

func (m *DeckhandModule) newTaskID() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.idSeq++
	return fmt.Sprintf("deckhand-task-%d", m.idSeq)
}

// operationID picks a stable per-invocation id for the sidecar job registry,
// preferring the idempotency key, then trace/correlation ids.
func operationID(ic productplatform.InvocationContext) string {
	for _, candidate := range []string{ic.IdempotencyKey, ic.TraceID, ic.CorrelationID} {
		if candidate != "" {
			return candidate
		}
	}
	return ""
}

func failed(err error) productplatform.ActionResult {
	return productplatform.ActionResult{
		Status:  productplatform.StatusFailed,
		Message: err.Error(),
	}
}

var _ productplatform.Module = (*DeckhandModule)(nil)
