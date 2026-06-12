// Package relay hosts the Deckhand desktop runtime's side of the cortex
// edge relay. The cloud (pd-cortex) is the WebSocket server and JSON-RPC
// caller; this package dials out, advertises the deckhand module, and
// answers action.invoke / task.* / health.check frames by routing them
// onto the existing sidecar JSON-RPC handlers.
//
// The two halves are:
//
//   - DeckhandModule (module.go) — a productplatform.Module whose
//     InvokeAction maps each deckhand.* capability to a sidecar handler.
//   - Client (client.go) — the WS dialer + register handshake + the
//     inbound-frame pump that feeds a hosted productplatform.JSONRPCServer.
package relay

import (
	productplatform "github.com/cepheuslabs/printdeck_product_platform"
)

// ModuleID is the stable identifier the desktop runtime advertises and the
// cloud manifest owns for every deckhand.* capability.
const ModuleID = "deckhand"

// Capability ids the desktop runtime exposes over the relay. These MUST
// match the manifest ids in printdeck_product_platform/agentic_capabilities.json
// (owner == "deckhand", transport.kind == "edge_relay"). The cloud sources the
// authoritative capability structs from that manifest; the desktop only needs
// the id set to advertise in the register frame and to map to a handler.
const (
	CapHostDiagnose    = "deckhand.host.diagnose"
	CapDisksInspect    = "deckhand.disks.inspect"
	CapDisksPreflight  = "deckhand.disks.preflight"
	CapArchiveSnapshot = "deckhand.archive.snapshot"
	CapProfileFetch    = "deckhand.profile.fetch"
	CapImageApply      = "deckhand.image.apply"
)

// CapabilityIDs is the ordered set the register frame advertises.
func CapabilityIDs() []string {
	return []string{
		CapHostDiagnose,
		CapDisksInspect,
		CapDisksPreflight,
		CapArchiveSnapshot,
		CapProfileFetch,
		CapImageApply,
	}
}

// inlineCapabilities is the fallback descriptor set used when the embedded
// manifest cannot be loaded (e.g. a stripped build). The danger_level /
// approval / task_behavior here mirror the manifest exactly so the desktop's
// self-reported Describe() never understates the risk of a capability. The
// authoritative gating still lives in the cloud, which re-sources every struct
// from its own embedded manifest; this is purely so a relay-only build can
// still answer module.describe coherently.
func inlineCapabilities() []productplatform.Capability {
	edge := productplatform.Transport{Kind: productplatform.TransportEdgeRelay, Target: ModuleID}
	return []productplatform.Capability{
		{
			ID: CapHostDiagnose, Owner: ModuleID, Object: "diagnostic", Verb: "diagnose",
			Title: "Run host doctor", DangerLevel: productplatform.DangerSafe,
			Approval: productplatform.ApprovalNone, TaskBehavior: productplatform.TaskLongRunning,
			Permissions: []string{"setup.host.read", "diagnostics.read"},
			AuditEvent:  "agent.tool.invoke", Transport: edge,
		},
		{
			ID: CapDisksInspect, Owner: ModuleID, Object: "disk", Verb: "inspect",
			Title: "Inspect removable disks", DangerLevel: productplatform.DangerSafe,
			Approval: productplatform.ApprovalNone, TaskBehavior: productplatform.TaskImmediate,
			Permissions: []string{"setup.host.read", "diagnostics.read"},
			AuditEvent:  "agent.tool.invoke", Transport: edge,
		},
		{
			ID: CapDisksPreflight, Owner: ModuleID, Object: "disk", Verb: "preflight",
			Title: "Preflight removable disk", DangerLevel: productplatform.DangerSafe,
			Approval: productplatform.ApprovalNone, TaskBehavior: productplatform.TaskImmediate,
			Permissions: []string{"setup.host.read", "diagnostics.read"},
			AuditEvent:  "agent.tool.invoke", Transport: edge,
		},
		{
			ID: CapArchiveSnapshot, Owner: ModuleID, Object: "archive", Verb: "snapshot",
			Title: "Create Deckhand archive snapshot", DangerLevel: productplatform.DangerModerate,
			Approval: productplatform.ApprovalPolicy, TaskBehavior: productplatform.TaskLongRunning,
			Permissions: []string{"exports.create", "setup.host.read"},
			AuditEvent:  "agent.tool.invoke", Transport: edge,
		},
		{
			ID: CapProfileFetch, Owner: ModuleID, Object: "profile", Verb: "fetch",
			Title: "Fetch Deckhand profile", DangerLevel: productplatform.DangerSafe,
			Approval: productplatform.ApprovalNone, TaskBehavior: productplatform.TaskImmediate,
			Permissions: []string{"setup.host.read"},
			AuditEvent:  "agent.tool.invoke", Transport: edge,
		},
		{
			ID: CapImageApply, Owner: ModuleID, Object: "image", Verb: "apply",
			Title: "Write setup image", DangerLevel: productplatform.DangerCritical,
			Approval: productplatform.ApprovalFreshRequired, TaskBehavior: productplatform.TaskLongRunning,
			Permissions: []string{"setup.image.write"},
			AuditEvent:  "agent.approval.resolve", Transport: edge,
		},
	}
}

// ManifestCapabilities returns the deckhand capability structs sourced from the
// embedded platform manifest when it is loadable, else the inline fallback. The
// returned slice is what DeckhandModule.Describe advertises; the relay register
// frame only sends the ids (CapabilityIDs).
func ManifestCapabilities() []productplatform.Capability {
	registry, err := productplatform.LoadEmbeddedAgenticRegistry()
	if err != nil {
		return inlineCapabilities()
	}
	out := make([]productplatform.Capability, 0, len(CapabilityIDs()))
	want := map[string]struct{}{}
	for _, id := range CapabilityIDs() {
		want[id] = struct{}{}
	}
	for _, capability := range registry.Capabilities {
		if capability.Owner != ModuleID {
			continue
		}
		if _, ok := want[capability.ID]; !ok {
			continue
		}
		out = append(out, capability)
	}
	if len(out) == 0 {
		return inlineCapabilities()
	}
	return out
}
