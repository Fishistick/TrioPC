# Native APNs receiver setup

TrioPC can receive notifications directly on a Mac and send a fixed synthetic test notification back to that same Mac. No extra server is needed. It also accepts Trio v1.0.2's legacy response schema for inspection only. There is no Trio command sender, persistent dosing-command correlation, pump reconciliation or verified insulin-completion status.

## Build with push capability

1. Open `TrioPC.xcodeproj` in Xcode 16 or newer. Choose the TrioPC app scheme and My Mac.
2. In Signing & Capabilities, choose your own developer team and a unique bundle identifier. Enable Push Notifications for this macOS App ID in the Apple developer account and use a matching provisioning profile. Do not reuse Trio's iPhone bundle identifier.
3. Build and run. Debug requests the development APNs environment; Release requests production. The signed profile, entitlements and push endpoint must agree. Inspect the actual environment shown in Command lab.
4. In Command lab, select Register this Mac and grant notification permission. The app requests a fresh token. Registration failure is shown without logging token contents or credential-bearing errors.

No team ID or signing credentials are included in this repository. Keep your signing changes local. The ad-hoc app ZIP has no push entitlement; its receiver screen explains that a signed Xcode build is needed. The generated project can be recreated with `python3 scripts/generate-xcode-project.py` after adding app source files; this resets project-level local signing edits.

## Non-dosing test

Use Apple's Push Notifications Console for **the Mac app's own App ID and device token**, not the iPhone's Trio token. Choose the same APNs environment and send a synthetic alert payload:

```json
{
  "aps": { "alert": { "title": "Receiver test", "body": "Synthetic receiver test only" } },
  "command_status": "success",
  "command_type": "temp_target",
  "timestamp": 1700000000
}
```

This is a notification to the Mac; it does not issue a command to Trio. The inspector must show it as an uncorrelated legacy reply and must not change the simulator's state. The timestamp above is intentionally synthetic; the UI shows the supplied timestamp and does not treat it as fresh evidence. Foreground notifications and notification clicks are handled; do not assume an app that is quit or a sleeping Mac will process every push immediately.

Tokens and the last reply are memory-only. Register again after launching, and use Clear reply to dismiss the retained message. Do not include real tokens, screenshots of real reply bodies, APNs private keys or provisioning profiles in a bug report.

## Why a reply does not confirm delivery

The current legacy payload has no command UUID and its status fields are not an authenticated, correlated delivery receipt. A success may only mean a bolus started; a failure does not establish zero delivery. TrioPC deliberately leaves all command state unchanged when receiving these messages. Reliable control still needs the separate protocol work documented in `control-design.md`.

## Send a test from TrioPC itself

After receiver registration works:

1. Obtain an APNs authentication signing key (`.p8`) from your Apple developer account. It must belong to the team signing the Mac app and be authorized for its bundle ID and APNs environment. A production-only or iPhone-topic-only key will not work for a development Mac test. An existing compatible key can be reused; do not revoke a key used by another app.
2. In Command lab, under Send a test to this Mac, enter that key's Team ID and Key ID. Import the `.p8` file and select Save credentials. Never paste the key into chat, source files or GitHub.
3. Select Send test to this Mac. The recipient, topic and environment come from this running app; no iPhone token or Trio shared secret is used.
4. Keep the app open. The UI first distinguishes submission to Apple from receipt of the notification with the same random test UUID. Only that matching return displays Round trip confirmed. A legacy Trio response cannot confirm a self-test.

The private key is validated as P-256 and stored with its IDs in a separate macOS Keychain item. Its contents are never displayed or logged. Load saved restores it in a later app session; Forget saved removes that Keychain item but does not delete the original `.p8` file. The sender caches its ES256 provider token for up to 50 minutes to avoid frequent token updates. It uses only Apple's development/production HTTPS endpoints, refuses redirects and sends `apns-expiration: 0`.

A network timeout does not prove that Apple rejected the notification. There is no automatic retry. After 30 seconds without a matching return, the test is unconfirmed; a late matching notification can still resolve it. This UUID matching is a synthetic notification diagnostic, not dosing-command authentication or pump verification.

References: [Apple APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [notification handling](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate), [Trio response source](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/Services/RemoteControl/RemoteNotificationResponseManager.swift).
