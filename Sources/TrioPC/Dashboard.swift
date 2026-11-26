import SwiftUI
import Charts
import TrioCore
import AppKit

struct Dashboard: View {
    @EnvironmentObject var model: AppModel
    @State private var showConnection = false
    @State private var workspace = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("TrioPC", systemImage: "circle.hexagongrid.fill").font(DeskTheme.identity)
                Spacer()
                Picker("Workspace", selection: $workspace) {
                    Text("Glucose").tag(0); Text("Bolus").tag(1); Text("Command lab").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                Button { showConnection = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Connection settings").accessibilityLabel("Connection settings").buttonStyle(.borderless)
            }.padding(.horizontal, 28).frame(height: 64)
            Divider().overlay(DeskTheme.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: DeskTheme.gap) {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(DeskTheme.warning)
                    }
                    if workspace == 2 { CommandLab() }
                    else if workspace == 1 { StockBolusPanel() }
                    else { overview }
                }.frame(maxWidth: 1000, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
        }.font(DeskTheme.body).foregroundStyle(DeskTheme.ink).background(DeskTheme.canvas).tint(DeskTheme.accent)
            .sheet(isPresented: $showConnection) { ConnectionView().padding(28).frame(width: 480) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refresh() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { await model.refresh() }
            }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: DeskTheme.gap) {
            HStack(spacing: 12) {
                Label(model.demo ? "Sample data" : "Nightscout", systemImage: model.demo ? "testtube.2" : "network")
                    .foregroundStyle(model.demo ? DeskTheme.warning : DeskTheme.muted)
                Text(model.demo ? "Connect your server to see your readings." : "Monitoring only").foregroundStyle(DeskTheme.muted)
                Spacer()
                if model.demo {
                    Button("Connect Nightscout") { showConnection = true }.buttonStyle(.bordered)
                } else {
                    Button(model.refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.refreshing)
                }
            }.font(DeskTheme.label)

            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Current glucose").font(DeskTheme.section)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(model.latest.map { model.formatted($0.sgv) } ?? "—").font(DeskTheme.number)
                            Text(model.latest?.arrow ?? "").font(DeskTheme.trend).foregroundStyle(DeskTheme.accent)
                            Text(model.unit).foregroundStyle(DeskTheme.muted)
                        }
                        readingAge
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.demo ? "Demo workspace" : "Your Nightscout").font(DeskTheme.label)
                        Text(model.demo ? "No device connected" : "Updates every minute").font(DeskTheme.small)
                    }.foregroundStyle(DeskTheme.muted).padding(.top, 4)
                }
                GlucoseChart()
            }.padding(24).deskSurface()
            treatments
        }
    }

    private var readingAge: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if model.demo {
                Text("Illustrative values, not your glucose").foregroundStyle(DeskTheme.muted)
            } else if let reading = model.latest {
                let age = context.date.timeIntervalSince(reading.timestamp)
                Label(age < -60 ? "Reading timestamp is in the future" : "Reading \(max(0, Int(age / 60))) min ago\(age > 600 ? ", data is stale" : "")",
                      systemImage: age > 600 || age < -60 ? "exclamationmark.clock" : "clock")
                    .foregroundStyle(age > 600 || age < -60 ? DeskTheme.warning : DeskTheme.muted)
            } else { Text("Waiting for a reading").foregroundStyle(DeskTheme.muted) }
        }.font(DeskTheme.label)
    }

    private var treatments: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent treatments").font(DeskTheme.section)
                Spacer()
                Text("From Nightscout").font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
            }
            if model.treatments.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle").font(DeskTheme.trend).foregroundStyle(DeskTheme.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.demo ? "Your history belongs here" : "No recent treatments")
                        Text(model.demo ? "Connect your server to see meals and insulin entries." : "Nightscout did not return treatment entries.")
                            .font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
                    }
                    Spacer()
                }.padding(.vertical, 18)
            } else {
                ForEach(model.treatments.prefix(8)) { treatment in
                    HStack(spacing: 14) {
                        Image(systemName: treatment.insulin != nil ? "drop" : "fork.knife").foregroundStyle(DeskTheme.muted).frame(width: 20)
                        Text(treatment.eventType ?? "Treatment").frame(maxWidth: .infinity, alignment: .leading)
                        Text(treatment.insulin.map { String(format: "%.2f U", $0) } ?? "—").monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(treatment.carbs.map { String(format: "%.0f g", $0) } ?? "—").monospacedDigit().frame(width: 55, alignment: .trailing)
                        Text(treatment.timeLabel).font(DeskTheme.label).foregroundStyle(DeskTheme.muted).frame(width: 115, alignment: .trailing)
                    }.padding(.vertical, 8)
                    Divider().overlay(DeskTheme.rule)
                }
            }
            Text("History can be delayed. It does not confirm a pending command.").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GlucoseChart: View {
    @EnvironmentObject var model: AppModel
    @State private var hours = 6
    private var readings: [Glucose] {
        let end = model.latest?.timestamp ?? Date()
        return model.readings.filter { $0.timestamp >= end.addingTimeInterval(-Double(hours) * 3600) }
    }
    private var yDomain: ClosedRange<Double> {
        let values = readings.map { model.mmol ? $0.sgv / 18 : $0.sgv }
        let padding = model.mmol ? 1.0 : 18.0
        return max(0, (values.min() ?? 0) - padding)...max(padding, (values.max() ?? padding) + padding)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("History").font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
                Spacer()
                Picker("History window", selection: $hours) {
                    Text("3h").tag(3); Text("6h").tag(6); Text("24h").tag(24)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            if readings.isEmpty {
                ContentUnavailableView("No glucose readings", systemImage: "waveform.path.ecg", description: Text("Check your connection to Nightscout."))
                    .frame(height: 190)
            } else {
                Chart {
                    ForEach(readings) { reading in
                        LineMark(x: .value("Time", reading.timestamp), y: .value(model.unit, model.mmol ? reading.sgv / 18 : reading.sgv))
                            .lineStyle(StrokeStyle(lineWidth: 2.5)).foregroundStyle(DeskTheme.accent)
                    }
                    if let last = readings.last {
                        PointMark(x: .value("Time", last.timestamp), y: .value(model.unit, model.mmol ? last.sgv / 18 : last.sgv))
                            .symbolSize(35).foregroundStyle(DeskTheme.accent)
                    }
                }.chartYScale(domain: yDomain)
                    .chartXScale(range: .plotDimension(padding: 20))
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(DeskTheme.rule)
                        AxisValueLabel().font(DeskTheme.small)
                    } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute()).font(DeskTheme.small)
                    } }
                    .frame(height: 190)
                    .accessibilityLabel("Glucose history chart. Latest reading \(model.latest.map { model.formatted($0.sgv) } ?? "unavailable") \(model.unit).")
            }
            Text("Glucose axis scales to the readings shown.").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
        }
    }
}

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Your Nightscout", systemImage: "network").font(DeskTheme.title)
            Text("Connect directly to your home server.").foregroundStyle(DeskTheme.muted)
            VStack(alignment: .leading, spacing: 8) {
                Text("Server address").font(DeskTheme.label)
                TextField("https://nightscout.example.com", text: $model.address).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Nightscout HTTPS address")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("API secret").font(DeskTheme.label)
                SecureField("Optional for public sites", text: $model.secret).textFieldStyle(.roundedBorder)
                Label("Stored in this Mac’s Keychain", systemImage: "lock").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            }
            Picker("Glucose units", selection: $model.mmol) {
                Text("mmol/L").tag(true); Text("mg/dL").tag(false)
            }.pickerStyle(.segmented)
            if let error = model.error { Text(error).font(DeskTheme.label).foregroundStyle(DeskTheme.warning) }
            Divider()
            HStack {
                Button("Use sample data") { model.loadDemo(); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.refreshing ? "Connecting…" : "Connect") {
                    Task { await model.connect(); if model.error == nil { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(model.refreshing).keyboardShortcut(.defaultAction)
            }
        }.font(DeskTheme.body).tint(DeskTheme.accent).onAppear { model.readSavedSecret() }
    }
}

struct CommandLab: View {
    @EnvironmentObject var model: AppModel
    @State private var amount = "1.00"
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Practice the unexpected.").font(DeskTheme.title)
                Text("Simulated commands only. No insulin is sent.").foregroundStyle(DeskTheme.muted)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Simulated bolus").font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
                    HStack {
                        TextField("Units", text: $amount).textFieldStyle(.roundedBorder).frame(width: 100).accessibilityLabel("Simulated bolus units")
                        Text("U").foregroundStyle(DeskTheme.muted)
                    }
                }
                Spacer()
                Button("Create simulation") { model.simulate(units: amount) }
                    .buttonStyle(.borderedProminent).disabled(model.command != nil && model.command?.state.terminal == false)
            }
            if let command = model.command {
                Divider()
                Text(command.state.label).font(DeskTheme.section)
                HStack {
                    Text("Requested: \(NSDecimalNumber(decimal: command.requestedUnits).stringValue) U").monospacedDigit()
                    if let delivered = command.deliveredUnits { Text("Simulated delivered: \(NSDecimalNumber(decimal: delivered).stringValue) U").monospacedDigit() }
                }
                if !command.state.terminal {
                    ViewThatFits {
                        HStack { simulationButtons(command) }
                        VStack(alignment: .leading) { simulationButtons(command) }
                    }
                }
                Text(command.id.uuidString).font(DeskTheme.code).textSelection(.enabled).foregroundStyle(DeskTheme.muted)
                Button("Reset simulation") { model.command = nil; model.commandError = nil }
            }
            if let error = model.commandError { Text(error).foregroundStyle(DeskTheme.warning) }
            Divider()
            Label("Command lab is a simulation workspace. Stock-Trio controls are in Bolus.", systemImage: "lock.shield").font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
            Divider()
            PushDiagnostics()
            Divider()
            ResponseHistoryPanel()
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).deskSurface()
    }
    @ViewBuilder private func simulationButtons(_ command: SimulatedCommand) -> some View {
        if command.state == .submitted { Button("Reject") { model.advance(.rejected) } }
        if command.state != .started { Button("Started") { model.advance(.started) } }
        Button("Lose response") { model.advance(.uncertain) }
        Button("Stop at 50%") { model.advance(.partial) }
        Button("Complete") { model.advance(.completed) }
    }
}

private struct StockBolusPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var control = StockBolusController.shared
    @ObservedObject private var push = PushReceiver.shared
    @State private var review: StockBolusDraft?
    @State private var checkedPhone = false
    @State private var showSetup = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Bolus · stock Trio").font(DeskTheme.title)
            Text("Uses Trio’s existing remote-control protocol. No phone patch or response-history pairing is required.")
                .font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
            Text("Manual amounts only. Apple acceptance and legacy replies cannot verify completed insulin delivery. Stock Trio cannot remotely cancel a bolus through this protocol.")
                .font(DeskTheme.label).foregroundStyle(DeskTheme.warning)
            DisclosureGroup("Connection and control settings", isExpanded: $showSetup) {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Read Trio profile from Nightscout") { Task { await control.discover(app: app) } }.disabled(app.demo || control.busy)
                    if let profile = control.profile {
                        Text("Trio app: \(profile.bundleID)").font(DeskTheme.code).textSelection(.enabled)
                        Text("Team: \(profile.teamID) · APNs: \(profile.environment.rawValue)").font(DeskTheme.small)
                        Text("Device fingerprint: \(profile.fingerprint.suffix(12))").font(DeskTheme.code).foregroundStyle(DeskTheme.muted)
                        Text("Profile published: \(profile.publishedAt.formatted())").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                    }
                    SecureField("Existing Trio remote-control shared secret", text: $control.sharedSecret).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Stock Trio shared secret")
                    HStack {
                        TextField("Trio’s maximum bolus (U)", text: $control.maximum).textFieldStyle(.roundedBorder)
                        TextField("Trio’s bolus increment (U)", text: $control.increment).textFieldStyle(.roundedBorder)
                    }
                    Text("Copy both limits from your current Trio pump settings. Use decimal points; amounts are never rounded automatically.")
                        .font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                    TextField("APNs Key ID for the Trio app’s team", text: $control.keyID).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Import Trio APNs .p8 key") { Task { await control.importProvider() } }
                        Button("Use saved Mac key for Trio") { control.useMacProvider() }.disabled(control.profile == nil)
                    }
                    Text(control.providerDescription).font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                    Text("Replies require the Mac APNs key saved in Command lab. Stock Trio receives that return key only inside the encrypted command. A separate Trio signing key is supported when the teams differ.")
                        .font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                    HStack {
                        Button("Save control settings") { control.saveConfiguration() }.disabled(control.profile == nil)
                        Button("Forget control settings") { control.forgetConfiguration() }
                    }
                }.padding(.top, 12).disabled(control.busy)
            }
            Toggle("I verified this is my Trio app and these limits match its current pump settings", isOn: $control.targetVerified)
                .disabled(control.profile == nil || control.busy)
            Toggle("Enable stock-Trio bolus control for this session", isOn: $control.enabled).disabled(control.busy)
            if app.demo { Text("Connect Nightscout in Connection settings first.").foregroundStyle(DeskTheme.warning) }
            else if !app.bolusReadingIsFresh {
                Text("A Nightscout glucose reading within 10 minutes is required by this prototype. Refresh before reviewing a bolus.")
                    .font(DeskTheme.label).foregroundStyle(DeskTheme.warning)
            }
            HStack {
                TextField("Manually entered bolus (U)", text: $control.amount).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 230).accessibilityLabel("Stock Trio bolus units")
                Button(control.busy ? "Working…" : "Review bolus…") { Task { review = await control.prepare(app: app) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(control.busy || !control.enabled || !control.saved || !control.targetVerified || control.needsPhoneReview || !control.journalAvailable)
            }.disabled(control.busy)
            Text(control.message).font(DeskTheme.label).textSelection(.enabled)
            if let attempt = control.latestAttempt {
                Divider()
                Text("Last local attempt: \(NSDecimalNumber(decimal: attempt.units).stringValue) U · \(attempt.createdAt.formatted())").font(DeskTheme.label)
                Text(submissionLabel(attempt.submission)).font(DeskTheme.label).foregroundStyle(DeskTheme.warning)
                if !attempt.phoneReviewCompleted {
                    Text("This attempt cannot be resent. Check Trio on your phone for delivery and any active bolus before preparing a separate new request.")
                        .font(DeskTheme.label)
                    Toggle("I checked the outcome in Trio on my phone", isOn: $checkedPhone)
                    Button("Record phone review") {
                        Task { await control.finishPhoneReview(); checkedPhone = false }
                    }.disabled(!checkedPhone || control.busy)
                } else { Text("Phone review recorded; delivery is not independently verified by TrioPC.").font(DeskTheme.small).foregroundStyle(DeskTheme.muted) }
            }
            if let reply = push.reply {
                Divider()
                Text("Uncorrelated Trio reply").font(DeskTheme.section)
                Text(reply.aps.alert.body).textSelection(.enabled)
                Text(reply.interpretation).font(DeskTheme.small).foregroundStyle(DeskTheme.warning)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).deskSurface()
            .task { await control.enter() }
            .onChange(of: control.latestAttempt?.id) { _, _ in checkedPhone = false }
            .sheet(item: $review, onDismiss: { control.cancelReview() }) { draft in
                VStack(alignment: .leading, spacing: 18) {
                    Text("Review bolus").font(DeskTheme.title)
                    Text("\(NSDecimalNumber(decimal: draft.units).stringValue) U").font(DeskTheme.number)
                    Text("Target: \(draft.bundleID)").font(DeskTheme.code)
                    Text("Device fingerprint: \(draft.targetFingerprint.suffix(12))").font(DeskTheme.code)
                    Text("This can deliver insulin. The next step requires your Mac password or Touch ID. The request is sent once; no automatic resend or remote cancellation is available.")
                    Text("The encrypted request also contains the Mac’s saved APNs return key so stock Trio can send replies.").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                    HStack {
                        Button("Cancel") { control.cancelReview(); review = nil }.keyboardShortcut(.cancelAction).disabled(control.busy)
                        Spacer()
                        Button("Authenticate and send \(NSDecimalNumber(decimal: draft.units).stringValue) U", role: .destructive) {
                            Task { await control.submit(draft, app: app); review = nil }
                        }.disabled(control.busy)
                    }
                }.padding(28).frame(width: 520)
            }
    }
    private func submissionLabel(_ state: StockBolusAttempt.Submission) -> String {
        switch state {
        case .attempting: "Submission was interrupted; delivery is unknown."
        case .acceptedByApple: "Accepted by Apple; insulin delivery is unverified."
        case .rejectedByApple: "Not accepted by Apple; phone review is required before another request."
        case .unknown: "Connection outcome unknown; insulin delivery is unverified."
        }
    }
}

private struct ResponseHistoryPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Response history").font(DeskTheme.section)
                Spacer()
                Button(model.historyRefreshing ? "Checking…" : "Check history") { Task { await model.refreshResponseHistory() } }
                    .disabled(model.demo || model.historyRefreshing)
            }
            Text("Recover saved Trio responses from your existing Nightscout server. Requires the separate, opt-in Trio history patch.")
                .font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
            if model.demo {
                Text("Connect Nightscout in Connection settings first.").font(DeskTheme.label)
            } else {
                SecureField("Trio remote-control shared secret", text: $model.historySharedSecret).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Trio history shared secret")
                Text("Used to decrypt and verify history. Saved separately in this Mac’s Keychain.").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                HStack {
                    Button("Save history secret") { Task { await model.saveHistorySecret() } }
                        .disabled(model.historySharedSecret.isEmpty || model.historyRefreshing)
                    if model.historyPaired { Button("Forget history secret and cache") { model.forgetHistorySecret() }.disabled(model.historyRefreshing) }
                }
            }
            Text(model.historyMessage).font(DeskTheme.label)
            if let synced = model.historyLastSync {
                Text("Last checked: \(synced.formatted())").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            }
            ForEach(model.historyEvents.prefix(20)) { event in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(event.kind == .synthetic ? "History connection test" : event.reply.commandType.replacingOccurrences(of: "_", with: " ").capitalized).font(DeskTheme.label)
                        Spacer()
                        Text(Date(timeIntervalSince1970: event.recordedAt).formatted()).font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                    }
                    Text(event.reply.aps.alert.body).textSelection(.enabled)
                    Text(event.kind == .synthetic ? "Synthetic history test; no command was executed." : event.reply.interpretation)
                        .font(DeskTheme.small).foregroundStyle(event.kind == .synthetic ? DeskTheme.muted : DeskTheme.warning)
                }.padding(.vertical, 8)
                Divider()
            }
            Text(model.historyPaired
                 ? "Records are verified with the paired secret. Legacy replies do not identify an original command or verify completed insulin delivery. The 20 newest cached responses are shown."
                 : "Pair history to verify saved responses. These advisory replies cannot verify completed insulin delivery.")
                .font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
        }
    }
}

private extension View {
    func deskSurface() -> some View {
        self.background(DeskTheme.surface, in: RoundedRectangle(cornerRadius: DeskTheme.corner))
    }
}

private extension Treatment {
    var timeLabel: String {
        guard let raw = created_at else { return "Time unavailable" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return "Time unavailable" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
