# Native desktop design

The first UI is a SwiftUI app screen: a restrained workspace centred on the glucose reading and its time series. SF system typography, semantic macOS surfaces and a single blue accent are declared in `Theme.swift`. Appearance follows the Mac. Numbers use tabular figures; captions are sentence case. The two destinations use a compact top switcher rather than a permanent sidebar. The sample label stays visible and no invented treatment data is shown.

Design craft references: Hallmark's app-screen, typography, surface and data-visualization guidance. This is a native adaptation, not a web Hallmark render run; CSS linting, browser capture and web themes are not applicable. Verification is Swift compilation and native screen inspection. No claim of a Hallmark automated pass is made.

The graph has one axis, no smoothing or interpolated readings, a current-point marker, selectable 3/6/24-hour data windows and an explicit note that its axis is scaled. Removed the draft's fixed glucose reference band because it was not read from the user's Trio settings. Treatment rows keep amounts aligned and format timestamps in local time. All settings fields have visible labels and native keyboard/focus behavior. No decorative animation is used.

Data states: sample, fetching, empty, error, full and stale readings. Command-lab states remain simulated and explicitly separate from real delivery. Remaining UI verification needs a real Nightscout server, authenticated data and pump-specific status design.
