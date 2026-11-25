# Contributing to TrioPC

TrioPC is an early native macOS companion. Monitoring and simulation work; APNs, live bolusing and remote cancellation are not implemented. Contributions must preserve that distinction in code, UI and documentation.

## Start here

1. Fork this repository and create a focused branch.
2. Open `Package.swift` in Xcode 16 or newer, or run `swift test`.
3. Run with sample data. Use a disposable test Nightscout instance for network changes.
4. Open a pull request explaining the behavior changed and how it was checked.

Useful first contributions:

- Accessibility and keyboard navigation, including VoiceOver checks.
- Nightscout decoding fixtures covering missing fields, timestamps and device status.
- Network tests for authentication failures, redirects, stale data and cancellation.
- Command-state recovery tests and discussion of the proposed protocol in `docs/control-design.md`.

## Scope and delivery changes

Keep changes small and discuss architectural changes in an issue first. Do not add a live dosing transport or bypass Trio's safety checks as a UI-only change. Proposals for command execution need durable correlation, replay protection, explicit uncertainty and pump reconciliation. Test with simulated drivers; do not use a person's active pump as a development test fixture.

## Protect private information

Use only synthetic data in fixtures, screenshots, logs and reports. Replace server names with `example.com`, remove usernames and local file paths, and exclude device tokens, pump identifiers and all credentials. A secret's hash may also grant access and must be removed. Do not upload Keychain exports, provisioning files or `.p8` keys.

Before publishing a branch, check its full history and staged files, not just the current diff. Review commit author metadata and use GitHub's noreply email if appropriate. Build public app downloads in GitHub Actions rather than uploading a local developer build containing machine-specific metadata.

If a credential was accidentally published, revoke it immediately; deleting its line does not remove it from history or copies. See `SECURITY.md` for reporting guidance.

## Licensing

Contributions of original code are accepted under this repository's MIT license. Identify third-party code and its license in the pull request; do not copy upstream Trio or pump-driver source without checking its license and preserving required notices.
