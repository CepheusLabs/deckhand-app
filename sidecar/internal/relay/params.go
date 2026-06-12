package relay

import "encoding/json"

// This file maps the cortex capability input shapes (from the manifest
// input_schema) onto the sidecar handler param shapes. The manifest is the
// authoritative description of each capability's input; the sidecar handlers
// predate the agentic layer and use slightly different field names, so the
// translation lives here in one place.

// profilesFetchParams maps deckhand.profile.fetch input
// {profile_ref, version} onto profiles.fetch handler params.
//
// profile_ref is the repo URL (the only fetchable profile reference today);
// version, when present, is the git ref. dest is intentionally left empty so
// the handler resolves its own Deckhand-managed profile cache path — the
// agentic caller must never get to pick an arbitrary filesystem destination.
func profilesFetchParams(input map[string]any) map[string]any {
	out := map[string]any{}
	if ref, ok := input["profile_ref"].(string); ok {
		out["repo_url"] = ref
	}
	if version, ok := input["version"].(string); ok && version != "" {
		out["ref"] = version
	}
	return out
}

// archiveSnapshotParams maps deckhand.archive.snapshot input onto the
// disks.read_image handler params (a raw-device backup to a managed .img).
//
// The snapshot's device id rides in profile_ref-adjacent fields; the handler
// constrains the output path to the Deckhand emmc-backups root regardless, so
// no caller-chosen output path is forwarded. An empty output lets the handler's
// own policy reject the call cleanly when no managed backup root is configured.
func archiveSnapshotParams(input map[string]any) map[string]any {
	out := map[string]any{}
	if ref, ok := input["device_id"].(string); ok && ref != "" {
		out["device_id"] = ref
	}
	if ref, ok := input["profile_ref"].(string); ok && ref != "" {
		out["profile_ref"] = ref
	}
	return out
}

// imageApplyParams maps deckhand.image.apply input
// {image_ref, device_id, safety_check_ref} onto disks.write_image handler
// params {image_path, disk_id, confirmation_token, ...}.
//
// safety_check_ref is the cloud-side handle proving a fresh preflight + approval
// floor was satisfied; it is forwarded as the confirmation_token the handler
// requires. The handler still re-probes the disk live and re-runs the safety
// check before telling the caller to elevate, so this token is an authorization
// marker, not a bypass.
func imageApplyParams(input map[string]any) map[string]any {
	out := map[string]any{}
	if ref, ok := input["image_ref"].(string); ok {
		out["image_path"] = ref
	}
	if ref, ok := input["device_id"].(string); ok {
		out["disk_id"] = ref
	}
	if ref, ok := input["safety_check_ref"].(string); ok {
		out["confirmation_token"] = ref
	}
	return out
}

// safetyVerdict mirrors the fields the sidecar's disks.safety_check handler
// returns (disks.SafetyCheckResult), decoded here without importing the disks
// package so the relay layer stays decoupled from the handler internals.
type safetyVerdict struct {
	Allowed         bool     `json:"allowed"`
	BlockingReasons []string `json:"blocking_reasons"`
	Warnings        []string `json:"warnings"`
}

// decodeSafetyVerdict re-encodes the handler's any-typed result and decodes it
// into the verdict shape. Returns ok=false only when the value cannot be
// re-marshaled at all.
func decodeSafetyVerdict(raw any) (safetyVerdict, bool) {
	encoded, err := json.Marshal(raw)
	if err != nil {
		return safetyVerdict{}, false
	}
	var verdict safetyVerdict
	if err := json.Unmarshal(encoded, &verdict); err != nil {
		return safetyVerdict{}, false
	}
	return verdict, true
}
