import SwiftUI

@main
struct TrioPCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            Dashboard().environmentObject(model)
                .frame(minWidth: 820, minHeight: 620)
                .task {
                    await model.resumeSavedConnection()
                    while !Task.isCancelled {
                        await model.refresh()
                        do { try await Task.sleep(for: .seconds(60)) }
                        catch { break }
                    }
                }
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.hiddenTitleBar)
        Settings { ConnectionView().environmentObject(model).padding(24).frame(width: 470) }
        MenuBarExtra {
            Text(model.demo ? "Sample data" : "Nightscout")
            if let latest = model.latest { Text(latest.timestamp, style: .relative) }
            Button("Refresh") { Task { await model.refresh() } }.disabled(model.demo)
            Divider()
            Button("Quit TrioPC") { NSApplication.shared.terminate(nil) }
        } label: {
            Label(model.latest.map { "\(model.demo ? "Demo " : "")\(model.formatted($0.sgv)) \($0.arrow)" } ?? "TrioPC", systemImage: "drop.circle")
        }
    }
}
