# TrioPC

A native SwiftUI Mac companion for Trio and Nightscout. macOS 14 or later; no Electron, third-party Swift dependencies, or extra server.

**Contributors welcome.** This is an early prototype with working monitoring code and a command simulator. Help is wanted with SwiftUI accessibility, Nightscout compatibility, synthetic test fixtures and the reliable-control protocol. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [the control design](docs/control-design.md).

## Current build: 0.2.0

- Nightscout glucose history, trend, reading age and recent treatments.
- mmol/L and mg/dL, selectable chart windows, menu-bar glucose, and automatic refresh every minute while open.
- Native light/dark appearance, a compact workspace switcher, and aligned treatment history.
- HTTPS only, redirect refusal, ephemeral network sessions, and API secret stored in macOS Keychain.
- Clearly labelled sample data and an in-memory command simulator for lost replies, partial delivery and completion.

- Opt-in APNs registration and an advisory legacy-reply inspector in Command lab, using a separately provisioned Xcode app target.
- An outgoing APNs diagnostic that sends a fixed synthetic notification back to this Mac, with credentials in Keychain and a matching test ID to confirm receipt.
- An encrypted Nightscout advisory-response history reader with duplicate/conflict handling and an encrypted local cache. Requires the [separate opt-in Trio publisher patch](integrations/trio-v1.0.2/README.md); it is not active in unmodified Trio. See [setup and coverage limits](docs/response-history.md).
- An opt-in **Bolus** workspace using stock Trio v1.0.2: manually entered amounts, explicit review, macOS authentication, and an encrypted local attempt record. The history patch is optional. See [stock-Trio setup and limitations](docs/stock-trio-control.md).

**Stock-Trio bolus sending is a prototype, not a validated dosing system.** It has been tested with mocked transports, not a live bolus. There is no remote bolus cancellation or pump-completion verification. The Command lab simulator remains separate and cannot send insulin commands. Uncorrelated APNs replies and Nightscout treatment history do not confirm delivery.

## Run

Install Xcode 16 or newer (Swift 6). Open `Package.swift` in Xcode, select the TrioPC executable and run, or:

```sh
swift test
bash scripts/build-app.sh
open dist/TrioPC.app
```

The script produces a locally ad-hoc signed app and `dist/TrioPC-macOS.zip`. Keychain may request permission; rebuilding can change the app's signing identity. This is not a notarized distribution build. GitHub Actions also builds and tests the app and uploads the zipped app artifact.

For APNs registration and the outgoing self-test, open `TrioPC.xcodeproj`, configure your own signing team and App ID, and follow [the APNs setup](docs/push-setup.md). The ad-hoc ZIP can run monitoring and simulation but cannot register with APNs. If you already configured signing locally, preserve those local changes when updating the app sources.

## Connect your server

Open **Connection settings**. Enter the final HTTPS Nightscout address and its API secret (not an access-token URL). A blank secret works only where your server allows public reads. Use the API secret locally; do not commit credentials or send them in chat. Click Connect. The app reads `/api/v1/entries/sgv.json`, `/api/v1/treatments.json` and filtered `/api/v1/devicestatus.json` using GET requests. It makes no Nightscout writes. Servers behind a separate login proxy or with private/self-signed TLS certificates need compatible network configuration; certificate checks are not bypassed.

The app starts with sample data before the first connection and resumes a saved connection on later launches. It saves your server address and unit preference in UserDefaults and the API secret in Keychain. Selecting sample mode disconnects and disables automatic reconnect until Connect is selected again. Last-fetched data remains visible on refresh failure and reading age indicates staleness.

## Development boundaries

Keep development in this repository. This project is independent of the upstream Trio application; it does not modify any existing Trio installation. Proposed iPhone changes belong in separately reviewed patches or a dedicated development fork.

See [the control design](docs/control-design.md) for the remaining work. The first app deliberately implements monitoring and simulation before adding a delivery transport.

## Privacy

Connection settings stay on the Mac. This app has no analytics or telemetry. Monitoring sends read requests only to the Nightscout server configured locally. Opt-in notification registration and the self-test contact Apple; device tokens and direct legacy reply messages stay in memory and are not logged. APNs credentials are stored in Keychain. The self-test sends a signed provider token to Apple over TLS. **Stock-Trio bolus replies additionally require the Mac return APNs key inside the encrypted command sent to the phone**; this is disclosed before confirmation. The Copy device token action places the token on the system clipboard. Repository examples and simulated readings are synthetic. Never attach personal health records, real server addresses, API secrets, access tokens or APNs credentials to an issue or pull request.

The latest synthetic APNs test's ID, time, state and delivery-log ID are saved locally for restart recovery. Nightscout history uses a separate per-server Keychain pairing secret and stores only encrypted history records in its local cache. Decrypted history is held in memory for display. The separate phone patch, when enabled, uploads encrypted advisory responses to the already configured Nightscout server. It is not installed or enabled by building the Mac app.

Stock-Trio control settings are separate Keychain items. An encrypted, process-locked journal retains up to 1,000 local bolus attempts and phone-review acknowledgements; it is never a resend queue. Unresolved attempts survive restarts and block another send until a deliberate phone review.

See [the roadmap](docs/roadmap.md) for planned work, including a Trio-style chart with active carbohydrates (COB) and active insulin (IOB).

## License

Original TrioPC code is available under the [MIT license](LICENSE). Trio and other referenced projects retain their own licenses. The separate integration patch contains upstream context under [Trio's MIT notice](integrations/trio-v1.0.2/UPSTREAM-LICENSE.txt).
