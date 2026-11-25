# Native APNs receiver setup

TrioPC can receive notifications directly on a Mac. No extra server is needed for this receiver. It currently accepts Trio v1.0.2's legacy response schema for inspection only. There is no command sender, persistent correlation, pump reconciliation or verified completion status.

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

References: [Apple APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [notification handling](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate), [Trio response source](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/Services/RemoteControl/RemoteNotificationResponseManager.swift).
