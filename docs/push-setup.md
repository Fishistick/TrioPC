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

Tokens and the last legacy reply are memory-only. A signed app automatically requests a fresh token on launch when notification permission is already granted. On a first launch, use Register this Mac to request permission. Use Clear reply to dismiss the retained legacy message. Do not include real tokens, screenshots of real reply bodies, APNs private keys or provisioning profiles in a bug report.

## Why a reply does not confirm delivery

The current legacy payload has no command UUID and its status fields are not an authenticated, correlated delivery receipt. A success may only mean a bolus started; a failure does not establish zero delivery. TrioPC deliberately leaves all command state unchanged when receiving these messages. Reliable control still needs the separate protocol work documented in `control-design.md`.

## Send a test from TrioPC itself

After receiver registration works:

1. Obtain an APNs authentication signing key (`.p8`) from your Apple developer account. It must belong to the team signing the Mac app and be authorized for its bundle ID and APNs environment. A production-only or iPhone-topic-only key will not work for a development Mac test. An existing compatible key can be reused; do not revoke a key used by another app.
2. In Command lab, under Send a test to this Mac, enter that key's Team ID and Key ID. Import the `.p8` file and select Save credentials. Never paste the key into chat, source files or GitHub.
3. Select Send test to this Mac. The recipient, topic and environment come from this running app; no iPhone token or Trio shared secret is used.
4. Keep the app open. The UI first distinguishes submission to Apple from receipt of the notification with the same random test UUID. Only that matching return displays Round trip confirmed. A legacy Trio response cannot confirm a self-test.

The private key is validated as P-256 and stored with its IDs in a separate macOS Keychain item. Its contents are never displayed or logged. Load saved restores it in a later app session; Forget saved removes that Keychain item but does not delete the original `.p8` file. The sender caches its ES256 provider token for up to 50 minutes to avoid frequent token updates. It uses only Apple's development/production HTTPS endpoints, refuses redirects and gives synthetic tests a five-minute APNs retention window.

A network timeout does not prove that Apple rejected the notification. There is no automatic send retry. While waiting, the app checks its own delivered notifications for the matching UUID, including alerts delivered while it was in the background. After 30 seconds without a matching return, the test is unconfirmed. Automatic receipt checks continue for five minutes; a matching late notification can still resolve it. Check received test can inspect Notification Center again, but a notification that was already dismissed may no longer be available. This UUID matching is a synthetic notification diagnostic, not dosing-command authentication or pump verification.

Changing either credential ID marks the form as unsaved and requires Save credentials before sending. Refreshing or loading unchanged values must not disable the test button.

References: [Apple APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [notification handling](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate), [Trio response source](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/Services/RemoteControl/RemoteNotificationResponseManager.swift).


## If Apple accepts a test but it does not return

For development pushes, TrioPC shows and can copy Apple's `apns-unique-id` response header. Paste it into the Mac App ID's Delivery Log in Apple's Push Notifications Console. This distinguishes rejection, expiry in transit and device delivery; HTTP 200 alone proves only acceptance. No private key or device token is copied by this diagnostic button.

Synthetic tests expire five minutes after creation, allowing a brief interruption in the Mac's push connection. An earlier zero-expiry test could be accepted and then discarded in transit. The app still sends once and never retries automatically. The 30-second UI deadline is an observation timeout; a matching late receipt can confirm it. This retention policy applies only to harmless synthetic tests and must not be reused for dosing commands.

If Delivery Log reports **stored for device power considerations**, the Mac asked APNs to defer delivery. A longer expiry does not override that decision. Keep the Mac awake and connected to power, check Battery settings for Low Power Mode, and try a new synthetic test once power conditions recover. A low battery can be relevant even after connecting a charger. If it persists, collect the diagnostic ID privately for Apple support; do not publish device tokens or keys. A successful registration and HTTP 200 do not establish that the OS will deliver a push promptly.


## Battery reliability and recovery

TrioPC refreshes an existing registration and checks for its pending synthetic receipt when the Mac wakes or the app becomes active. Receipt processing is independent of the visible tab. Command lab shows notification authorization, alert permission and Low Power Mode; that last value alone cannot predict Apple's power restrictions. These actions never resend a notification or change macOS power settings.

A confirmed round trip demonstrates one notification's delivery. It does not guarantee future delivery on battery, during sleep, while offline or after quitting the app. Priority 10 alert pushes are already used; there is no documented per-app APNs switch that guarantees prompt delivery despite system power restrictions. Keeping the process awake with App Nap or sleep assertions is not evidence that APNs has removed its separate power reservation. Synthetic tests do not use critical-alert or time-sensitive privileges to bypass user settings.

For reliable future command **status**, APNs should be a wake-up hint backed by a durable, authenticated event journal on the Trio side. The Mac must fetch missed events on reconnect, wake and launch and while a command is unresolved. This needs command UUIDs, monotonically increasing revisions, deduplication and pump reconciliation. The existing Nightscout server could potentially host the journal without an additional server, but Trio must explicitly write that protocol; Nightscout treatment history and current legacy replies are not substitutes. This has not been implemented, and the main Trio repository has not been changed.

References: [Apple delivery and power restrictions](https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns), [similar macOS battery deferral report and Apple support response](https://developer.apple.com/forums/thread/813492).


## Recovery after quitting TrioPC

The app saves one local synthetic-test checkpoint in its macOS preferences. It contains a schema version, random test UUID, creation time, test state and optional Apple delivery-log ID. It contains no private key, Team ID, Key ID, device token, notification body, Nightscout connection details or health data. Clear saved test removes this diagnostic checkpoint without changing credentials. The checkpoint is local diagnostic metadata, not an authenticated record of an insulin command.

On relaunch, previously observed receipt/rejection states remain visible with the original start time. An interrupted send or wait restores as **unconfirmed**. It must never imply failure, receipt or a fresh send. TrioPC checks its delivered notifications for that exact UUID during launch, activation and wake, and handles incoming matching receipts even if Command lab is hidden. Loading credentials never resends the test. Notifications that were dismissed or never delivered may be unrecoverable from Notification Center; this checkpoint is not a server-backed response journal. macOS preference persistence supports normal restarts and is not a dosing-grade crash-consistency guarantee.

Automatic registration only runs when notification permission is already granted and the running app is signed for APNs. It does not display a new permission prompt, load the signing key, send a notification, or persist the device token.
