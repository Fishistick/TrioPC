# Mac remote-control design

Baseline investigated: Trio v1.0.2 (`0b29cd53415e7f0e668677749cad8daf81c68c2f`) with its pinned OmnipodKit (`043b91dbf1958d26c55d927a6a8d651bc91f208d`), for Omnipod 5.

## Why live control is not enabled

Trio's stable bolus path reports initiation/start, not verified full delivery. Its APNs response payload lacks a unique command ID. Its Omnipod progress reporter estimates delivery from elapsed time. The driver can report uncertain command delivery and return partial-dose information after cancellation, but the current remote interface does not expose that as a durable, correlated lifecycle.

Sources: [bolus handler](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/Services/RemoteControl/TrioRemoteControl%2BBolus.swift), [response manager](https://github.com/nightscout/Trio/blob/0b29cd53415e7f0e668677749cad8daf81c68c2f/Trio/Sources/Services/RemoteControl/RemoteNotificationResponseManager.swift), [pump manager](https://github.com/loopandlearn/OmnipodKit/blob/043b91dbf1958d26c55d927a6a8d651bc91f208d/OmnipodKit/PumpManager/OmniPumpManager.swift).

## Serverless Mac route

A signed macOS app can register with APNs and receive replies directly. It needs an App ID with push capability, provisioning, current device token and compatible APNs credentials. An ad-hoc signed SwiftPM app cannot establish this production registration. APNs is best effort, so a live receiver alone does not solve lost replies or ambiguous pump outcomes.

Required iPhone-side protocol changes, outside the existing Trio repository:

1. Persistent command UUID, explicit expiry and replay/deduplication handling. Persist intent before communicating with the pod. A crash during submission must reconcile rather than blindly retry.
2. Association with a pump dose identity and pod identity, including programmed rounded amount, independently of estimated progress.
3. Structured outcome and evidence: rejected before submission; submitted; uncertain; started; stopped partially; pump-reconciled completion. Never infer zero delivery from a communication failure.
4. Preserve cancellation dose results and distinguish pump-derived from time-estimated amounts. A cancellation must target the associated active dose and handle races with completion or pod replacement.
5. Durable result history with monotonically increasing revisions. APNs replies include command UUID and revision. A read-only status query returns saved records after lost notifications or Mac restarts. Exact recovery/query transport still needs design and testing.
6. Authenticated/encrypted result payloads. Existing plain response status fields alone must not be accepted as authoritative evidence. Keep pairing and key rotation explicit.

Before enabling delivery, test against a mock driver: duplicate/reordered pushes; send timeout after pump receipt; process termination at each state transition; partial cancel; cancel acknowledgement loss; pump fault; pod replacement; stale glucose; and Mac sleep/wake. Existing Trio safety checks remain required. The in-memory simulator is only an initial UI/state model, not persistent command tracking or a substitute for those tests.

## Next increments

- Verify read-only Nightscout compatibility against test servers; add device-status IOB/COB parsing with synthetic fixtures.
- Add an Xcode app target with push entitlements and validate a non-dosing APNs round trip.
- Design and review the persistent command protocol and separate iPhone patches.
- Implement pump-result reconciliation and recovery tests before live bolus or cancellation.
