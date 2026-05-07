# Deckhand sidecar IPC methods

Auto-generated from `internal/rpc` MethodSpec registrations. Do not edit by hand - regenerate with `go run ./cmd/deckhand-ipc-docs`.

| Method | Description | Params | Returns |
|---|---|---|---|
| `disks.hash` | SHA-256 of a file at a Deckhand-managed path (downloads or device nodes). | `path` (required string) | {sha256, path} |
| `disks.list` | Enumerate writable disks attached to the host. | _none_ | {disks: DiskInfo[]} |
| `disks.read_image` | Read a raw device to a local file with progress notifications. | `device_id` (optional string)<br>`path` (optional string)<br>`output` (required string) | {sha256, output} |
| `disks.safety_check` | Assess whether a target disk is safe to write. Returns a verdict. | `disk` (required object) | SafetyVerdict |
| `disks.write_image` | Write a local image to a disk. Requires a confirmation_token issued by the UI. | `image_path` (required string)<br>`disk_id` (required string)<br>`confirmation_token` (required string)<br>`disk` (optional object) | {ok} or rpc.Error with reason elevation_required / unsafe_target |
| `doctor.run` | Run the sidecar self-diagnostic and return structured results. | _none_ | {passed: bool, results: [{name, status, detail}], report: string} |
| `host.info` | Return host platform info plus Deckhand's data/cache/settings paths. | _none_ | host.Info |
| `jobs.cancel` | Cancel an in-flight handler by its originating JSON-RPC id. | `id` (required string) | {ok, cancelled} |
| `os.download` | Download an OS image to a managed cache path, verifying the expected SHA-256. | `url` (required string)<br>`dest` (required string)<br>`sha256` (required string) | {sha256, path} |
| `ping` | Liveness + version probe. Returns sidecar version and host os/arch. | _none_ | {sidecar_version, os, arch} |
| `profiles.fetch` | Shallow-clone a Klipper config profile repo; optionally verify a signed tag. | `repo_url` (required string)<br>`ref` (optional string)<br>`dest` (required string)<br>`force` (optional bool)<br>`trusted_keys` (optional string)<br>`require_signed_tag` (optional bool) | profiles.FetchResult |
| `shutdown` | Ask the sidecar to drain in-flight handlers and exit. | _none_ | {ok} |
| `version.compat` | Report whether the UI's version is compatible with this sidecar. | `ui_version` (optional string) | {compatible, sidecar_version, ui_version} |
