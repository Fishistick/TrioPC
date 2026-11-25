import SwiftUI
import Charts
import TrioCore

struct Dashboard: View {
    @EnvironmentObject var model: AppModel
    @State private var showConnection = false
    @State private var lab = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("TrioPC", systemImage: "circle.hexagongrid.fill").font(DeskTheme.identity)
                Spacer()
                Picker("Workspace", selection: $lab) {
                    Text("Glucose").tag(false); Text("Command lab").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
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
                    if lab { CommandLab() } else { overview }
                }.frame(maxWidth: 1000, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
        }.font(DeskTheme.body).foregroundStyle(DeskTheme.ink).background(DeskTheme.canvas).tint(DeskTheme.accent)
            .sheet(isPresented: $showConnection) { ConnectionView().padding(28).frame(width: 480) }
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
            Label("Live control is not available in this build.", systemImage: "lock.shield").font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
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
