# TrioPC

A native SwiftUI Mac companion for Trio and Nightscout. macOS 14 or later; no Electron, third-party Swift dependencies, or extra server.

**Contributors welcome.** This is an early prototype with working monitoring code and a command simulator. Help is wanted with SwiftUI accessibility, Nightscout compatibility, synthetic test fixtures and the reliable-control protocol. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [the control design](docs/control-design.md).

## First build: 0.1.0

- Nightscout glucose history, trend, reading age and recent treatments.
- mmol/L and mg/dL, selectable chart windows, menu-bar glucose, and automatic refresh every minute while open.
- Native light/dark appearance, a compact workspace switcher, and aligned treatment history.
- HTTPS only, redirect refusal, ephemeral network sessions, and API secret stored in macOS Keychain.
- Clearly labelled sample data and an in-memory command simulator for lost replies, partial delivery and completion.

**Live bolus commands, remote cancellation and APNs are not implemented.** The simulator cannot send insulin commands. It is not a validated dosing system. Nightscout treatment history is not command confirmation.

## Run

Install Xcode 16 or newer (Swift 6). Open `Package.swift` in Xcode, select the TrioPC executable and run, or:

```sh
swift test
bash scripts/build-app.sh
open dist/TrioPC.app
```

The script produces a locally ad-hoc signed app and `dist/TrioPC-macOS.zip`. Keychain may request permission; rebuilding can change the app's signing identity. This is not a notarized distribution build. GitHub Actions also builds and tests the app and uploads the zipped app artifact.

## Connect your server

Open **Connection settings**. Enter the final HTTPS Nightscout address and its API secret (not an access-token URL). A blank secret works only where your server allows public reads. Use the API secret locally; do not commit credentials or send them in chat. Click Connect. The app reads `/api/v1/entries/sgv.json` and `/api/v1/treatments.json` using GET requests. It makes no Nightscout writes. Servers behind a separate login proxy or with private/self-signed TLS certificates need compatible network configuration; certificate checks are not bypassed.

The app starts with sample data every launch until you connect. It saves your server address and unit preference in UserDefaults and the API secret in Keychain. Sample mode disconnects the active client. Last-fetched data remains visible on refresh failure and reading age indicates staleness.

## Development boundaries

Keep development in this repository. This project is independent of the upstream Trio application; it does not modify any existing Trio installation. Proposed iPhone changes belong in separately reviewed patches or a dedicated development fork.

See [the control design](docs/control-design.md) for the remaining work. The first app deliberately implements monitoring and simulation before adding a delivery transport.

## Privacy

Connection settings stay on the Mac. This app has no analytics or telemetry. It sends read requests only to the Nightscout server configured locally. Repository examples and simulated readings are synthetic. Never attach personal health records, real server addresses, API secrets, access tokens or APNs credentials to an issue or pull request.

## License

Original TrioPC code is available under the [MIT license](LICENSE). Trio and other referenced projects retain their own licenses. No upstream Trio source is bundled here.
