# Nightscout response history

TrioPC reads encrypted advisory responses from the existing Nightscout v1 device-status API. No additional server, database migration or Nightscout plugin is needed by this protocol. **Unmodified Trio v1.0.2 does not publish this history.** The separate opt-in publisher patch is in `integrations/trio-v1.0.2`; it has not been installed on a phone by this project.

## Data flow

1. The patched Trio response manager constructs its existing advisory reply. This is after command handling, not a durable command-intent record.
2. With history enabled, it encrypts the reply and writes a bounded local outbox atomically before requesting an upload. The queue contains ciphertext, event IDs and a destination binding, never APNs credentials or the shared secret.
3. The existing serialized Nightscout device-status pipeline drains this queue independently of the normal determination upload guard. HTTPS is required; redirects are refused. One response is stored in each device-status document. A successful HTTP response must contain the matching event ID and ciphertext before the phone removes its local copy.
4. Failed or ambiguous uploads remain queued. Startup, network changes, normal device-status upload triggers and the opt-in toggle request another drain. An upload retry may create another Nightscout document, but preserves the same event UUID and ciphertext. It never replays a command.
5. TrioPC fetches up to 500 newest matching documents on connection, every minute, activation and wake. It authenticates/decrypts them, deduplicates by event UUID, rejects conflicting or invalid records, and retains up to 1,000 encrypted records locally. Cached records remain available after a restart or failed refresh. The newest 20 are displayed with original response times and an explicit last-successful-check time.

## Pairing

Connect the existing HTTPS Nightscout URL and API secret in TrioPC's Connection settings. The Mac uses that connection for **GET requests only**. In Command lab → Response history, enter the exact Trio remote-control shared secret and select Save history secret. It must be at least 32 UTF-8 bytes. This is a separate Keychain entry per server; its input is cleared after saving. APNs `.p8` credentials are unrelated to history pairing.

A saved Nightscout connection resumes after launch. Selecting Use sample data disables that automatic reconnect until Connect is selected again. The history key and encrypted cache are scoped to the actual connected server and key identity, so editing an unsubmitted address cannot redirect or mix history. Forget history secret and cache removes the active pairing/cache; it does not erase records on Nightscout or change Trio's secret.

Changing Trio's shared secret makes records encrypted with the old secret unreadable with the new one. Keep the old pairing available if historical decryption is needed; automatic key rotation/migration is not implemented.

## Wire format, version 1

Nightscout document:

```json
{
  "device": "TrioPC-response-v1",
  "created_at": "2026-01-01T00:00:00Z",
  "triopc_response": {
    "schema": 1,
    "event_id": "00000000-0000-4000-8000-000000000001",
    "box": "BASE64_AES_GCM_COMBINED_DATA"
  }
}
```

`created_at` is the upload time, allowing an old queued response uploaded later to appear in a current query. Its authenticated inner `recorded_at` remains the original response time. Device-status documents are separate from treatments and glucose entries. Other followers should select their intended device when reading device status.

The encryption key is HKDF-SHA256 of the exact shared-secret UTF-8 bytes, with salt `TrioPC`, info `response-history/v1`, output length 32. AES-256-GCM uses a fresh nonce. The combined value is `nonce || ciphertext || tag`, base64 encoded. Associated data is UTF-8 `TrioPC.response-history.v1|` followed by the lowercase canonical event UUID. This is a separate cryptographic domain from Trio's legacy command encryption.

Decrypted object:

```json
{
  "schema": 1,
  "kind": "legacy_response",
  "event_id": "00000000-0000-4000-8000-000000000001",
  "recorded_at": 1700000000,
  "reply": {
    "command_status": "success",
    "command_type": "bolus",
    "timestamp": 1700000000,
    "aps": {"alert": {"title": "Command Successful", "body": "Bolus started"}}
  }
}
```

`kind: synthetic` identifies the phone's explicit history connection test. That button only queues a diagnostic record; it never calls a therapy command handler. TrioPC displays it as a connection test. The event UUID identifies a response record, **not an original command**. Encryption verifies possession of the paired shared secret; it does not establish pump delivery evidence or prevent another holder of the same secret from producing a record.

Read request: `GET /api/v1/devicestatus.json?count=500&find[device]=TrioPC-response-v1`. The existing hashed `api-secret` header is used, never a credential in a URL. The phone requires `api:devicestatus:create` and the Mac requires `api:devicestatus:read` under the server's authorization policy.

## Coverage limits

If a query reaches 500 documents, TrioPC explicitly warns that older records may be missing. It scans the bounded window again rather than advancing a timestamp cursor that could skip late uploads. Duplicate upload rows consume that window. Server retention/deletion and the 1,000-record Mac cache limit also constrain recovery. Full archival pagination/export is not implemented.

The phone outbox holds up to 1,000 pending responses and refuses to silently overwrite a corrupt file or send a pending queue to a different configured server. Disk failure, a full queue, app removal, or termination before the response is journaled can still leave gaps. No upload can occur while iOS prevents Trio from running or before protected storage is available. This first publisher does not turn legacy callbacks into a complete, crash-reconciled pump lifecycle.

A legacy “success” may mean only that a bolus started; a failure does not establish zero delivery. Neither APNs replies nor recovered history mutates TrioPC's simulator, confirms pump completion or unlocks an unresolved stock-mode attempt. The separate manually confirmed stock-Trio bolus workflow does not require this history patch. A stronger correlated, pump-verified lifecycle still requires persisted command UUIDs, revisions, deduplication and pump-result reconciliation described in `control-design.md`.

## Validation and deployment status

Automated checks exercise independent publisher/Mac encryption interoperability, encrypted outbox restart/acknowledgement, server binding, wrong secrets, altered ciphertext/UUIDs, duplicate/reordered/conflicting replies, cache reload, query limits and failed HTTP reads. The integration patch applies to the pinned upstream source and passed a full unsigned iOS Simulator build of Trio in an isolated checkout with its pinned dependencies. The isolated publisher is also type-checked with the iOS SDK in GitHub Actions. The simulator build used `CI=true` to skip formatting and Crashlytics upload phases, with `CODE_SIGNING_ALLOWED=NO`. No signed device build, phone installation or on-device validation has been completed.

No phone installation, Nightscout configuration change, or live history upload is performed by building TrioPC. A real end-to-end test requires a separately built patched phone app, enabling its history toggle, pairing the Mac, then using the phone's **Send history connection test** button. Do not issue a bolus to test this transport. Check that the synthetic row survives a Mac restart and a refresh without duplicating it.

Source baseline: [Trio response manager](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/Services/RemoteControl/RemoteNotificationResponseManager.swift), [Trio Nightscout pipeline](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/Services/Network/Nightscout/NightscoutManager.swift), [Nightscout v1 routes](https://github.com/nightscout/cgm-remote-monitor/blob/master/lib/api/devicestatus/index.js), [device-status storage](https://github.com/nightscout/cgm-remote-monitor/blob/master/lib/server/devicestatus.js). Actual compatibility and retention must be verified against the deployed home-server version.
