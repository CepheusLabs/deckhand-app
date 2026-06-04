# Deckhand Browser Transports

Deckhand web executes only profile steps that declare explicit
`transport_requirements`. The browser shell evaluates those requirements before
enabling a step.

Supported direct browser requirements:

| Requirement | Transport | Step metadata |
|-------------|-----------|---------------|
| `webusb.dfu` | `navigator.usb` | `webusb.filters`, `request`, `value`, `index`, `request_type`, `recipient`, `chunk_size` |
| `webserial.bootloader` | `navigator.serial` | `webserial.filters`, `baud_rate`, `chunk_size`, optional `enter_bootloader_bytes` |
| `webhid.report` / `webhid.keyboard` | `navigator.hid` | `webhid.filters`, `report_id`, `chunk_size` |
| `manual.uf2` / `manual-download` | Browser download | Firmware bytes or URL |

Native fallback requirements:

| Requirement | Route |
|-------------|-------|
| `raw_disk_write`, `raw-disk-write` | Desktop app or local agent |
| `ssh.lan`, `moonraker.lan` | Desktop app or local agent |
| `local-agent` | Local agent HTTP/IPC bridge |
| `desktop-app` | Installed Deckhand desktop app |

Start the browser local agent with:

```sh
DECKHAND_AGENT_TOKEN=... deckhand-sidecar agent --addr 127.0.0.1:48765
```

The web app probes `LOCAL_AGENT_URL` (default
`http://127.0.0.1:48765/v1`) and sends `LOCAL_AGENT_TOKEN` as a bearer token.
Operations use `POST /v1/operations` and stream progress over
`GET /v1/operations/{id}/events` as server-sent events. The agent reuses the
same JSON-RPC method registry as the desktop sidecar, so raw disk and LAN steps
keep the existing safety, cancellation, and elevated-helper boundaries.

The profile linter rejects tagged `flash_mcus`/`mcu_flash` steps that omit
`transport_requirements` or declare an unsupported requirement. Marketplace and
profile packages should publish compatibility facets for `browser_transport`,
`machine_family`, and `firmware_target` using these same values.
