package relay

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	productplatform "github.com/cepheuslabs/printdeck_product_platform"
)

// fakeInvoker records the (method, params) it was asked to dispatch and returns
// a programmed result/error per method.
type fakeInvoker struct {
	mu      sync.Mutex
	calls   []invokerCall
	results map[string]any
	errs    map[string]error
}

type invokerCall struct {
	method string
	params map[string]any
}

func newFakeInvoker() *fakeInvoker {
	return &fakeInvoker{results: map[string]any{}, errs: map[string]error{}}
}

func (f *fakeInvoker) Invoke(_ context.Context, _, method string, params json.RawMessage) (any, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var decoded map[string]any
	if len(params) > 0 {
		_ = json.Unmarshal(params, &decoded)
	}
	f.calls = append(f.calls, invokerCall{method: method, params: decoded})
	if err, ok := f.errs[method]; ok {
		return nil, err
	}
	if res, ok := f.results[method]; ok {
		return res, nil
	}
	return map[string]any{"ok": true}, nil
}

func (f *fakeInvoker) lastCall(method string) (invokerCall, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.calls) - 1; i >= 0; i-- {
		if f.calls[i].method == method {
			return f.calls[i], true
		}
	}
	return invokerCall{}, false
}

func invoke(t *testing.T, m *DeckhandModule, capID string, input map[string]any) productplatform.ActionResult {
	t.Helper()
	res, err := m.InvokeAction(context.Background(), productplatform.ActionInvocation{
		CapabilityID: capID,
		Input:        input,
		Context:      productplatform.InvocationContext{TenantID: "t1"},
	})
	if err != nil {
		t.Fatalf("InvokeAction(%s) returned transport error: %v", capID, err)
	}
	return res
}

func TestInvokeActionMapsCapabilitiesToHandlers(t *testing.T) {
	cases := []struct {
		cap        string
		input      map[string]any
		wantMethod string
	}{
		{CapHostDiagnose, nil, "doctor.run"},
		{CapDisksInspect, nil, "disks.list"},
		{CapProfileFetch, map[string]any{"profile_ref": "https://example.com/p.git"}, "profiles.fetch"},
	}
	for _, tc := range cases {
		t.Run(tc.cap, func(t *testing.T) {
			fake := newFakeInvoker()
			m := NewDeckhandModule(fake)
			res := invoke(t, m, tc.cap, tc.input)
			if res.Status != productplatform.StatusSuccess {
				t.Fatalf("status = %s, want success (msg=%q)", res.Status, res.Message)
			}
			if _, ok := fake.lastCall(tc.wantMethod); !ok {
				t.Fatalf("expected a call to %q, got calls %+v", tc.wantMethod, fake.calls)
			}
		})
	}
}

func TestProfileFetchForwardsRefAsRepoURL(t *testing.T) {
	fake := newFakeInvoker()
	m := NewDeckhandModule(fake)
	invoke(t, m, CapProfileFetch, map[string]any{"profile_ref": "https://example.com/p.git", "version": "v1.2.3"})
	call, ok := fake.lastCall("profiles.fetch")
	if !ok {
		t.Fatal("profiles.fetch was not called")
	}
	if call.params["repo_url"] != "https://example.com/p.git" {
		t.Fatalf("repo_url = %v, want the profile_ref", call.params["repo_url"])
	}
	if call.params["ref"] != "v1.2.3" {
		t.Fatalf("ref = %v, want version", call.params["ref"])
	}
	// The agentic caller must never get to choose a filesystem destination.
	if _, present := call.params["dest"]; present {
		t.Fatalf("dest must not be forwarded from the agent, got %v", call.params["dest"])
	}
}

func TestPreflightBlocksUnsafeTarget(t *testing.T) {
	fake := newFakeInvoker()
	// safety_check returns a disallowed verdict for a system/non-removable disk.
	fake.results["disks.safety_check"] = map[string]any{
		"disk_id":          "PhysicalDrive0",
		"allowed":          false,
		"blocking_reasons": []string{"disk is marked as a Windows boot/system disk — refusing to flash"},
	}
	m := NewDeckhandModule(fake)
	res := invoke(t, m, CapDisksPreflight, map[string]any{"device_id": "PhysicalDrive0"})
	if res.Status != productplatform.StatusDenied {
		t.Fatalf("status = %s, want denied for an unsafe target", res.Status)
	}
	if len(res.NextActions) != 0 {
		t.Fatalf("denied preflight must not offer image.apply, got next_actions=%v", res.NextActions)
	}
	if len(res.Warnings) == 0 {
		t.Fatal("denied preflight should surface the blocking reasons")
	}
}

func TestPreflightAllowsSafeTargetAndOffersApply(t *testing.T) {
	fake := newFakeInvoker()
	fake.results["disks.safety_check"] = map[string]any{
		"disk_id": "PhysicalDrive3",
		"allowed": true,
	}
	m := NewDeckhandModule(fake)
	res := invoke(t, m, CapDisksPreflight, map[string]any{"device_id": "PhysicalDrive3"})
	if res.Status != productplatform.StatusSuccess {
		t.Fatalf("status = %s, want success for a safe target (msg=%q)", res.Status, res.Message)
	}
	if len(res.NextActions) != 1 || res.NextActions[0] != CapImageApply {
		t.Fatalf("safe preflight should offer image.apply, got %v", res.NextActions)
	}
	// preflight must only forward the device id (the handler re-probes live).
	call, _ := fake.lastCall("disks.safety_check")
	disk, _ := call.params["disk"].(map[string]any)
	if disk == nil || disk["id"] != "PhysicalDrive3" {
		t.Fatalf("preflight should forward only the disk id, got %+v", call.params)
	}
}

func TestPreflightRequiresDeviceID(t *testing.T) {
	m := NewDeckhandModule(newFakeInvoker())
	res := invoke(t, m, CapDisksPreflight, map[string]any{})
	if res.Status != productplatform.StatusFailed {
		t.Fatalf("status = %s, want failed when device_id is missing", res.Status)
	}
}

func TestImageApplyIsLongRunningAndReturnsTaskRef(t *testing.T) {
	fake := newFakeInvoker()
	// Block the underlying write until released so we can observe the queued state.
	release := make(chan struct{})
	fake.results["disks.write_image"] = map[string]any{"ok": true}
	blocking := &blockingInvoker{inner: fake, gate: release, gated: "disks.write_image"}
	m := NewDeckhandModule(blocking)

	res := invoke(t, m, CapImageApply, map[string]any{
		"image_ref":        "/managed/img.img",
		"device_id":        "PhysicalDrive3",
		"safety_check_ref": "token-123",
	})
	if res.Status != productplatform.StatusQueued {
		t.Fatalf("status = %s, want queued for the long-running image.apply", res.Status)
	}
	if res.Task == nil || res.Task.ID == "" {
		t.Fatal("image.apply must return a task ref")
	}
	if res.Task.CapabilityID != CapImageApply {
		t.Fatalf("task capability = %s, want %s", res.Task.CapabilityID, CapImageApply)
	}
	taskID := res.Task.ID

	// While gated, TaskStatus reports queued.
	status, err := m.TaskStatus(context.Background(), taskID, productplatform.InvocationContext{})
	if err != nil {
		t.Fatalf("TaskStatus error: %v", err)
	}
	if status.Status != productplatform.StatusQueued {
		t.Fatalf("in-flight task status = %s, want queued", status.Status)
	}

	// Release and wait for completion.
	close(release)
	final := waitForTerminal(t, m, taskID)
	if final.Status != productplatform.StatusSuccess {
		t.Fatalf("final task status = %s, want success (msg=%q)", final.Status, final.Message)
	}

	// The safety_check_ref must be forwarded as the confirmation_token.
	call, ok := fake.lastCall("disks.write_image")
	if !ok {
		t.Fatal("disks.write_image was never called")
	}
	if call.params["confirmation_token"] != "token-123" {
		t.Fatalf("confirmation_token = %v, want the safety_check_ref", call.params["confirmation_token"])
	}
	if call.params["disk_id"] != "PhysicalDrive3" || call.params["image_path"] != "/managed/img.img" {
		t.Fatalf("image.apply mapped params wrong: %+v", call.params)
	}
}

func TestTaskStatusUnknownTask(t *testing.T) {
	m := NewDeckhandModule(newFakeInvoker())
	res, err := m.TaskStatus(context.Background(), "nope", productplatform.InvocationContext{})
	if err != nil {
		t.Fatalf("TaskStatus error: %v", err)
	}
	if res.Status != productplatform.StatusFailed {
		t.Fatalf("unknown task status = %s, want failed", res.Status)
	}
}

func TestArchiveSnapshotIsLongRunning(t *testing.T) {
	fake := newFakeInvoker()
	m := NewDeckhandModule(fake)
	res := invoke(t, m, CapArchiveSnapshot, map[string]any{"device_id": "PhysicalDrive3"})
	if res.Status != productplatform.StatusQueued || res.Task == nil {
		t.Fatalf("archive.snapshot should be long-running with a task ref, got status=%s task=%v", res.Status, res.Task)
	}
	waitForTerminal(t, m, res.Task.ID)
	if _, ok := fake.lastCall("disks.read_image"); !ok {
		t.Fatalf("archive.snapshot should map to disks.read_image, calls=%+v", fake.calls)
	}
}

func TestDescribeAdvertisesDeckhandCaps(t *testing.T) {
	m := NewDeckhandModule(newFakeInvoker())
	desc, err := m.Describe(context.Background())
	if err != nil {
		t.Fatalf("Describe error: %v", err)
	}
	if desc.ID != ModuleID {
		t.Fatalf("module id = %s, want %s", desc.ID, ModuleID)
	}
	got := map[string]productplatform.Capability{}
	for _, c := range desc.Capabilities {
		got[c.ID] = c
	}
	for _, id := range CapabilityIDs() {
		if _, ok := got[id]; !ok {
			t.Fatalf("Describe is missing capability %s", id)
		}
	}
	// image.apply must self-report as critical / fresh-approval so the desktop
	// never understates the danger even in the inline fallback.
	apply := got[CapImageApply]
	if apply.DangerLevel != productplatform.DangerCritical || apply.Approval != productplatform.ApprovalFreshRequired {
		t.Fatalf("image.apply danger=%s approval=%s, want critical/fresh_required", apply.DangerLevel, apply.Approval)
	}
}

func TestHealthCheckProbesPing(t *testing.T) {
	fake := newFakeInvoker()
	m := NewDeckhandModule(fake)
	health, err := m.HealthCheck(context.Background())
	if err != nil {
		t.Fatalf("HealthCheck error: %v", err)
	}
	if health.Status != productplatform.HealthHealthy {
		t.Fatalf("health = %s, want healthy when ping succeeds", health.Status)
	}
	if _, ok := fake.lastCall("ping"); !ok {
		t.Fatal("HealthCheck should probe the ping handler")
	}

	fake.errs["ping"] = errors.New("sidecar down")
	health, _ = m.HealthCheck(context.Background())
	if health.Status != productplatform.HealthUnhealthy {
		t.Fatalf("health = %s, want unhealthy when ping fails", health.Status)
	}
}

// blockingInvoker wraps a fakeInvoker and blocks the named method on a gate
// channel so a long-running task's queued state can be observed.
type blockingInvoker struct {
	inner *fakeInvoker
	gate  chan struct{}
	gated string
}

func (b *blockingInvoker) Invoke(ctx context.Context, op, method string, params json.RawMessage) (any, error) {
	if method == b.gated {
		select {
		case <-b.gate:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return b.inner.Invoke(ctx, op, method, params)
}

func waitForTerminal(t *testing.T, m *DeckhandModule, taskID string) productplatform.ActionResult {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		res, err := m.TaskStatus(context.Background(), taskID, productplatform.InvocationContext{})
		if err != nil {
			t.Fatalf("TaskStatus error: %v", err)
		}
		if res.Status != productplatform.StatusQueued {
			return res
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("task %s did not reach a terminal state in time", taskID)
	return productplatform.ActionResult{}
}
