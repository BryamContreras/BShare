# BShare LAN Protocol

BShare transfers files only inside the local LAN/WiFi network. It does not use cloud services, relays, accounts, or external APIs.

## Discovery

Devices announce themselves on multicast address `224.0.0.251:53318` using UTF-8 JSON packets. The service identifier is `_bshare._tcp.local`, mirroring the mDNS/Zeroconf service name used by BShare-compatible clients.

Announcement payload:

```json
{
  "service": "_bshare._tcp.local",
  "id": "device-uuid",
  "name": "Laptop",
  "platform": "Windows",
  "ip": "192.168.1.20",
  "port": 53317,
  "lastSeen": "2026-06-20T12:00:00.000"
}
```

Clients discard their own ID and treat devices not seen for roughly 20 seconds as stale.

## HTTP API

Each receiving device starts a local HTTP server on the preferred port, default `53317`.

### Health check

`GET /api/ping`

Response:

```json
{"ok": true}
```

### File transfer

`POST /api/transfers`

Headers:

- `content-length`: file size in bytes when known.
- `content-type`: `application/octet-stream`.
- `x-bshare-file-name`: URI-encoded file name.
- `x-bshare-file-size`: file size in bytes.
- `x-bshare-sender-id`: sender device UUID.
- `x-bshare-sender-name`: URI-encoded sender display name.

Body:

Raw file bytes streamed directly from disk. Senders must not buffer complete files in memory. Receivers must stream directly to the configured download directory.

Responses:

- `200` or `201`: accepted and saved.
- `403`: rejected by receiver.
- `404`: unknown endpoint.
- `500`: interrupted or failed while writing.

## Errors

Clients should surface no-network, blocked-port/firewall, disconnected-device, rejected-file, interrupted-transfer, and permission-denied errors. Completed and failed transfers are stored in local history.
