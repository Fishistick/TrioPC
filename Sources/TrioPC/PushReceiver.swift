import AppKit
import UserNotifications
import Security
import TrioCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PushReceiver: ObservableObject {
    static let shared = PushReceiver()
    @Published private(set) var state = "Not registered"
    @Published private(set) var deviceToken: String?
    @Published private(set) var reply: LegacyReply?
    @Published private(set) var receivedAt: Date?
    @Published private(set) var testReceipt: LoopbackReceipt?

    var signedTeamID: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.team-identifier" as CFString, nil) as? String
    }

    var environment: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) as? String
    }

    func register() async {
        deviceToken = nil
        guard environment != nil else {
            state = "This build has no APNs entitlement. Use the signed Xcode target."
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard granted else { state = "Notifications are not allowed. Enable them in macOS Settings."; return }
            state = "Registering with Apple…"
            NSApplication.shared.registerForRemoteNotifications()
        } catch { state = "Notification permission could not be requested. Check macOS Settings." }
    }

    func registered(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        state = "Registered with Apple"
    }

    func failed() { deviceToken = nil; state = "APNs registration failed. Check signing, provisioning and network access." }

    func receive(_ value: LegacyReply) {
        // The same notification can arrive through both AppKit and UserNotifications.
        guard reply != value else { return }
        reply = value; receivedAt = Date()
    }

    func clearReply() { reply = nil; receivedAt = nil }

    func receiveTest(_ value: LoopbackReceipt) { testReceipt = value }

    func deliveredTest(id: UUID) async -> LoopbackReceipt? {
        // Alert pushes can reach Notification Center while the app is in the background,
        // without a foreground delegate callback. Inspect only this app's notifications.
        let receipt: LoopbackReceipt? = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                // Parse in the callback: UNNotification is not Sendable in older SDKs.
                let match = notifications.compactMap { Self.parseTest($0.request.content.userInfo) }
                    .first { $0.id == id }
                continuation.resume(returning: match)
            }
        }
        if let receipt { receiveTest(receipt) }
        return receipt
    }

    nonisolated static func parseTest(_ payload: [AnyHashable: Any]) -> LoopbackReceipt? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? LoopbackReceipt.parse(data)
    }

    nonisolated static func parse(_ payload: [AnyHashable: Any]) -> LegacyReply? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? LegacyReply.parse(data)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftPM command-line launches do not have a notification-capable app bundle.
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        PushReceiver.shared.registered(token)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushReceiver.shared.failed()
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if let test = PushReceiver.parseTest(userInfo) { PushReceiver.shared.receiveTest(test) }
        if let reply = PushReceiver.parse(userInfo) { PushReceiver.shared.receive(reply) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let value = PushReceiver.parseTest(notification.request.content.userInfo) {
            Task { @MainActor in PushReceiver.shared.receiveTest(value) }
        }
        if let value = PushReceiver.parse(notification.request.content.userInfo) {
            Task { @MainActor in PushReceiver.shared.receive(value) }
        }
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = PushReceiver.parseTest(response.notification.request.content.userInfo) {
            Task { @MainActor in PushReceiver.shared.receiveTest(value) }
        }
        if let value = PushReceiver.parse(response.notification.request.content.userInfo) {
            Task { @MainActor in PushReceiver.shared.receive(value) }
        }
        completionHandler()
    }
}

struct PushDiagnostics: View {
    @ObservedObject private var push = PushReceiver.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("APNs receiver").font(DeskTheme.section)
            Text(push.state).font(DeskTheme.body)
            Text("Environment: \(push.environment ?? "Not provisioned")").font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
            HStack {
                Button("Register this Mac") { Task { await push.register() } }
                if let token = push.deviceToken {
                    Button("Copy device token") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                }
            }
            Text("Tokens stay in memory. Register again after launch. Never post tokens or push credentials publicly.")
                .font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            if let reply = push.reply {
                Divider()
                Text("Uncorrelated legacy reply").font(DeskTheme.section)
                Text(reply.aps.alert.body).textSelection(.enabled)
                Text(reply.interpretation).font(DeskTheme.label).foregroundStyle(DeskTheme.warning)
                Text("Reply timestamp: \(Date(timeIntervalSince1970: reply.timestamp).formatted())")
                    .font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                Button("Clear reply") { push.clearReply() }
            }
            Text("This receiver sends no commands and cannot confirm completed delivery.")
                .font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
            Divider()
            APNsSenderPanel()
        }
    }
}

@MainActor
final class APNsSenderModel: ObservableObject {
    static let shared = APNsSenderModel()
    @Published var teamID = "" {
        didSet { if teamID != oldValue { saved = false; message = "Credential fields changed. Save credentials before sending." } }
    }
    @Published var keyID = "" {
        didSet { if keyID != oldValue { saved = false; message = "Credential fields changed. Save credentials before sending." } }
    }
    @Published private(set) var hasKey = false
    @Published private(set) var saved = false
    @Published private(set) var busy = false
    @Published private(set) var message = "Import an APNs signing key to send a synthetic notification to this Mac."
    @Published private(set) var test: LoopbackTest?
    @Published private(set) var deliveryLogID: String?
    private var pem = ""
    private let sender = APNsTestSender()
    private var timeout: Task<Void, Never>?
    private static let service = "com.fishistick.TrioPC.apns-test"
    private struct Stored: Codable { let teamID: String; let keyID: String; let pem: String }

    func importKey() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 16385) <= 16384 else { throw APNsTestError.invalidPrivateKey }
            let value = try String(contentsOf: url, encoding: .utf8)
            _ = try APNsCredentials(teamID: "AAAAAAAAAA", keyID: "AAAAAAAAAA", privateKeyPEM: value)
            pem = value; hasKey = true; saved = false
            message = "Key imported in memory. Save credentials to store it in Keychain."
        } catch { message = "Could not import a valid APNs .p8 key. No key contents were logged." }
    }

    func save() {
        do {
            teamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try APNsCredentials(teamID: teamID, keyID: keyID, privateKeyPEM: pem)
            let value = Stored(teamID: teamID, keyID: keyID, pem: pem)
            let data = try JSONEncoder().encode(value)
            try Keychain.save(String(decoding: data, as: UTF8.self), service: Self.service, account: "provider")
            saved = true; message = "Credentials saved in this Mac’s Keychain."
        } catch { message = (error as? APNsTestError)?.localizedDescription ?? "Keychain could not save the credentials." }
    }

    func load() {
        do {
            let text = try Keychain.read(service: Self.service, account: "provider")
            guard !text.isEmpty else { message = "No saved APNs credentials."; return }
            let value = try JSONDecoder().decode(Stored.self, from: Data(text.utf8))
            _ = try APNsCredentials(teamID: value.teamID, keyID: value.keyID, privateKeyPEM: value.pem)
            teamID = value.teamID; keyID = value.keyID; pem = value.pem; hasKey = true; saved = true
            message = "Saved credentials loaded from Keychain."
        } catch { message = "Could not load valid APNs credentials from Keychain." }
    }

    func forget() {
        do {
            try Keychain.save("", service: Self.service, account: "provider")
            pem = ""; hasKey = false; teamID = ""; keyID = ""; saved = false
            message = "Saved APNs credentials removed. The original .p8 file was not deleted."
        } catch { message = "Keychain could not remove the credentials." }
    }

    func receive(_ receipt: LoopbackReceipt?) {
        guard let receipt, var current = test, receipt.id == current.id else { return }
        current.receive(id: receipt.id); test = current; timeout?.cancel()
        message = "Round trip confirmed: this app received its matching synthetic test notification."
    }

    func checkDelivery() async {
        guard let test else { return }
        if let receipt = await PushReceiver.shared.deliveredTest(id: test.id) { receive(receipt) }
        else { message = "No matching test is in this app’s delivered notifications yet. It may be delayed or already dismissed." }
    }

    func sendToThisMac() async {
        let push = PushReceiver.shared
        guard saved, !busy, test?.waiting != true,
              let token = push.deviceToken, let topic = Bundle.main.bundleIdentifier,
              let rawEnvironment = push.environment, let environment = APNsEnvironment(rawValue: rawEnvironment),
              let signedTeam = push.signedTeamID else {
            message = "Save credentials and register this signed Mac app before sending."; return
        }
        guard signedTeam == teamID else { message = "The Team ID must match the team that signed this Mac app."; return }
        busy = true
        defer { busy = false }
        do {
            let credentials = try APNsCredentials(teamID: teamID, keyID: keyID, privateKeyPEM: pem)
            let recipient = try MacTestRecipient(token: token, topic: topic, environment: environment)
            let pending = LoopbackTest()
            deliveryLogID = nil
            test = pending; message = "Sending synthetic notification to this Mac…"
            timeout?.cancel()
            timeout = Task { [weak self] in
                for _ in 0..<15 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, let current = self.test, current.id == pending.id,
                          current.state != .received, current.state != .rejected else { return }
                    if let receipt = await PushReceiver.shared.deliveredTest(id: pending.id) {
                        self.receive(receipt); return
                    }
                }
                guard let self, var current = self.test, current.id == pending.id, current.waiting else { return }
                current.unknown(); self.test = current
                self.message = "No matching return within 30 seconds. No automatic retry was sent. A late return can still confirm this test."
            }
            let submission = try await sender.send(pending, to: recipient, credentials: credentials)
            deliveryLogID = submission.deliveryLogID
            if var current = test, current.id == pending.id {
                current.accepted(); test = current
                if current.state == .awaitingReturn { message = "Apple accepted the test. Waiting for this Mac to receive it…" }
            }
            receive(push.testReceipt)
        } catch {
            if var current = test, current.state != .received {
                if case APNsTestError.rejected = error { current.rejected(); timeout?.cancel() }
                else { current.unknown() }
                test = current
                message = (error as? APNsTestError)?.localizedDescription ?? "The test could not be prepared. No automatic retry was sent."
            }
        }
    }
}

struct APNsSenderPanel: View {
    @StateObject private var model = APNsSenderModel.shared
    @ObservedObject private var push = PushReceiver.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send a test to this Mac").font(DeskTheme.section)
            Text("Uses this app’s registered token and signed bundle ID. No Trio command is sent.")
                .font(DeskTheme.label).foregroundStyle(DeskTheme.muted)
            HStack {
                VStack(alignment: .leading) {
                    Text("Team ID").font(DeskTheme.label)
                    TextField("10 characters", text: $model.teamID).textFieldStyle(.roundedBorder).accessibilityLabel("Apple Developer Team ID")
                }
                VStack(alignment: .leading) {
                    Text("APNs Key ID").font(DeskTheme.label)
                    TextField("10 characters", text: $model.keyID).textFieldStyle(.roundedBorder).accessibilityLabel("APNs signing Key ID")
                }
            }.disabled(model.busy || model.test?.waiting == true)
            ViewThatFits {
                HStack { credentialActions }
                VStack(alignment: .leading) { credentialActions }
            }.disabled(model.busy || model.test?.waiting == true)
            Text(model.hasKey ? "Private key loaded. Its contents are hidden." : "No private key loaded.")
                .font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            Button(model.busy ? "Sending…" : "Send test to this Mac") { Task { await model.sendToThisMac() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.saved || push.deviceToken == nil || model.busy || model.test?.waiting == true)
            Text(model.message).font(DeskTheme.label).textSelection(.enabled)
            if let test = model.test {
                Text("Test ID: \(test.id.uuidString)").font(DeskTheme.code).foregroundStyle(DeskTheme.muted)
                if let logID = model.deliveryLogID {
                    Text("Apple delivery log ID: \(logID)").font(DeskTheme.code).textSelection(.enabled)
                    Button("Copy Apple delivery log ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logID, forType: .string)
                    }
                }
                Button("Check received test") { Task { await model.checkDelivery() } }.disabled(model.busy)
            }
        }.onReceive(push.$testReceipt) { model.receive($0) }
    }
    @ViewBuilder private var credentialActions: some View {
        Button("Import .p8 key") { Task { await model.importKey() } }
        Button("Save credentials") { model.save() }.disabled(!model.hasKey)
        Button("Load saved") { model.load() }
        Button("Forget saved") { model.forget() }
    }
}
