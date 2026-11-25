# Roadmap

## Outgoing APNs diagnostic

The synthetic notification sender is implemented. Validate the full round trip with a personally signed Mac build and an appropriate APNs key. Credentials stay in Keychain. The UI distinguishes Apple's acceptance from receipt in the Mac app. This diagnostic sends no Trio commands and does not infer insulin delivery.

## Trio-style chart with active carbs and insulin

Bring the chart closer to Trio's chart, including active carbohydrates (COB, grams) and active insulin (IOB, units). Show current values and their history aligned with glucose timestamps, using the corresponding Trio data uploaded to Nightscout.

Before implementation, inspect Trio's current chart and actual Nightscout device-status schema. Preserve unit labels and data age, distinguish missing values from zero, and avoid presenting data from different loop cycles as simultaneous. Keep sample fixtures synthetic. This is planned work, not a current feature.

## Reliable remote control

Follow `control-design.md`: persistent command identity, explicit expiry, duplicate protection, pump reconciliation, cancellation accounting and recovery from uncertain delivery. Develop any iPhone changes separately; do not modify an existing Trio repository or installation.
