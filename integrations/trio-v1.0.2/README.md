# Separate Trio response-history patch

Baseline: upstream `nightscout/Trio` commit `0b29cd53415e7f0e668677749cad8daf81c68c2f` (the v1.0.2 baseline investigated by TrioPC).

`response-history.patch` is a reviewable patch, not an installed phone update. It adds an off-by-default history toggle and a synthetic connection test, saves encrypted response records, and drains them through the existing Nightscout upload pipeline. It does not modify bolus handlers, pump drivers, APNs command dispatch, or treatment uploads. The response manager journals advisory responses even when APNs return information is absent.

Keep your main Trio checkout untouched. Prepare and review a separate upstream checkout at the pinned commit, then run `git apply --check` and `git apply` with this patch **inside that separate checkout**. Use your own signing configuration there. Do not apply it over a different Trio version without adapting and reviewing the changes.

The `publisher/TrioPCResponseOutbox.swift` source is appended to the existing response-manager file by the patch, so no Xcode source membership change is needed. It is also a SwiftPM test target here, allowing the independently implemented Mac reader to verify interoperability. `scripts/prepare-trio-history-patch.py /path/to/pinned/upstream` regenerates the patch by reading that source directory; it does not modify the supplied directory.

The patch has syntax and isolated-publisher checks, not a full Trio iOS build or on-device validation. Review and complete those checks in the separate checkout before phone deployment. No patched Trio app is installed automatically and your main repository is never written by these scripts.

After a separately validated phone build is installed, use Remote Control → TrioPC response history, enable Save encrypted responses to Nightscout, and ensure the existing Nightscout upload connection uses HTTPS. Pair the same shared secret in TrioPC's Response history panel. Use Send history connection test to validate transport without executing a therapy command.

See [the protocol and coverage limits](../../docs/response-history.md). The upstream MIT notice is included in `UPSTREAM-LICENSE.txt`.
