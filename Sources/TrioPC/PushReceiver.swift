import AppKit
import UserNotifications
import Security
import TrioCore
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import LocalAuthentication
import IOKit.ps

@MainActor
final class PushReceiver: ObservableObject {
    static let shared = PushReceiver()
    @Published private(set) var state = "Not registered"
    @Published private(set) var deviceToken: String?
    @Published private(set) var reply: LegacyReply?
    @Published private(set) var receivedAt: Date?
    @Published private(set) var testReceipt: LoopbackReceipt?
    @Published private(set) var conditions = "Checking notification settings…"
    @Published private(set) var macReadiness = "Checking this Mac…"
    @Published private(set) var replyRecovery = "Existing replies on this Mac have not been checked yet."
    private var checkingReplies = false
    private var authorizationGranted = false

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

    func refreshConditions() async {
        let snapshot: (String, Bool) = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let permission = switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: "Allowed"
                case .denied: "Denied"
                case .notDetermined: "Not requested"
                @unknown default: "Unknown"
                }
                let alerts = settings.alertSetting == .enabled ? "on" : "off"
                let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                continuation.resume(returning: ("Notifications: \(permission) · Alerts: \(alerts)", granted))
            }
        }
        authorizationGranted = snapshot.1
        conditions = "\(snapshot.0) · Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")"
        var power = "Battery information unavailable"
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = details[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                let pluggedIn = details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                let charging = details[kIOPSIsChargingKey] as? Bool == true
                power = "Battery: \(Int(Double(current) / Double(maximum) * 100))% · \(charging ? "charging" : pluggedIn ? "plugged in" : "on battery")"
                break
            }
        }
        macReadiness = "\(power) · TrioPC: \(NSApplication.shared.isActive ? "active" : "in background")"
    }

    func recoverAfterWake() async {
        await refreshConditions()
        await recoverDeliveredReplies()
        // Refresh an already-authorized registration; never prompt or send another push.
        if authorizationGranted, environment != nil {
            if deviceToken == nil { state = "Registering with Apple…" }
            NSApplication.shared.registerForRemoteNotifications()
        }
        if let pending = APNsSenderModel.shared.test,
           pending.state != .received, pending.state != .rejected {
            _ = await deliveredTest(id: pending.id)
        }
    }

    func registered(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        state = "Registered with Apple"
    }

    func failed() { deviceToken = nil; state = "APNs registration failed. Check signing, provisioning and network access." }

    func receive(_ value: LegacyReply) {
        // The same notification can arrive through both AppKit and UserNotifications.
        guard reply != value else { return }
        // A Notification Center scan must not replace a newer live reply with an older one.
        if let reply, reply.timestamp > value.timestamp { return }
        reply = value; receivedAt = Date()
    }

    func recoverDeliveredReplies() async {
        guard !checkingReplies else { return }
        checkingReplies = true
        defer { checkingReplies = false }
        let replies: [LegacyReply] = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                // Inspect only this app's existing notifications. Never remove or reschedule them.
                continuation.resume(returning: notifications.compactMap { Self.parse($0.request.content.userInfo) })
            }
        }
        if let newest = LegacyReply.newest(in: replies) { receive(newest) }
        replyRecovery = replies.isEmpty
            ? "No saved reply was found on this Mac. This does not tell us whether insulin was delivered."
            : "Found a saved reply on this Mac. The latest known reply is shown below; it may relate to another request."
    }

    func clearReply() { reply = nil; receivedAt = nil }

    func receiveTest(_ value: LoopbackReceipt) {
        testReceipt = value
        // Receipt handling must work even when Command lab is not on screen.
        APNsSenderModel.shared.receive(value)
    }

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
        guard payload["triopc_test"] == nil, payload["triopc_reply_test"] == nil,
              JSONSerialization.isValidJSONObject(payload),
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(recoverPush),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recoverPush),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
        recoverPush()
    }

    func applicationDidBecomeActive(_ notification: Notification) { recoverPush() }
    func applicationDidResignActive(_ notification: Notification) {
        Task { await PushReceiver.shared.refreshConditions() }
    }

    @objc nonisolated private func recoverPush() {
        // System power notifications may be posted off the main thread.
        Task { @MainActor in
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            await PushReceiver.shared.recoverAfterWake()
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
            Text(push.conditions).font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            Text(push.macReadiness).font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            Button("Check Notification Center for Trio replies") { Task { await push.recoverDeliveredReplies() } }
            Text(push.replyRecovery).font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            Text("macOS can delay replies for power reasons, including while charging and with Low Power Mode off. Registration alone does not confirm that replies can arrive.")
                .font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            HStack {
                Button("Refresh notification status") { Task { await push.refreshConditions() } }
                Button("Register this Mac") { Task { await push.register() } }
                if let token = push.deviceToken {
                    Button("Copy device token") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                }
            }
            Text("Tokens stay in memory and refresh automatically after launch when notifications are already allowed. Never post tokens or push credentials publicly.")
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
        }.task { await push.refreshConditions() }
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
    @Published private(set) var replyTestRequested = false
    @Published private(set) var message = "Import an APNs signing key to send a synthetic notification to this Mac."
    @Published private(set) var test: LoopbackTest? { didSet { persistCheckpoint() } }
    @Published private(set) var deliveryLogID: String? { didSet { persistCheckpoint() } }
    @Published private(set) var checkpointMessage = "Only the latest synthetic test's ID, time, state and delivery-log ID are saved locally."
    private var pem = ""
    private let sender = APNsTestSender()
    private var timeout: Task<Void, Never>?
    private static let service = "com.fishistick.TrioPC.apns-test"
    private static let checkpointKey = "apnsSyntheticTestCheckpoint.v1"
    private struct Stored: Codable { let teamID: String; let keyID: String; let pem: String }

    var testStatus: String {
        switch test?.state {
        case .sending: "Sending"
        case .awaitingReturn: "Accepted by Apple; awaiting receipt"
        case .received: "Receipt confirmed"
        case .unconfirmed: "Unconfirmed"
        case .rejected: "Rejected by Apple"
        case nil: "No test"
        }
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.checkpointKey) else { return }
        do {
            let checkpoint = try LoopbackCheckpoint.parse(data)
            test = checkpoint.recoveredTest
            deliveryLogID = checkpoint.deliveryLogID
            switch test?.state {
            case .received: message = "Restored a previously confirmed synthetic test. No new notification was sent."
            case .rejected: message = "Restored a previously rejected synthetic test. No new notification was sent."
            default: message = "Restored an unconfirmed synthetic test. Checking for its receipt; no automatic resend was sent."
            }
            persistCheckpoint()
        } catch {
            checkpointMessage = "The saved synthetic test could not be restored. Clear saved test to remove it. No notification was sent."
        }
    }

    private func persistCheckpoint() {
        guard let test else { return }
        let checkpoint = LoopbackCheckpoint(test: test, deliveryLogID: deliveryLogID)
        if let data = try? JSONEncoder().encode(checkpoint) {
            UserDefaults.standard.set(data, forKey: Self.checkpointKey)
        }
    }

    func clearSavedTest() {
        guard !busy else { return }
        timeout?.cancel(); test = nil; deliveryLogID = nil
        UserDefaults.standard.removeObject(forKey: Self.checkpointKey)
        checkpointMessage = "Saved synthetic test cleared. Push credentials are unchanged."
        message = "No synthetic test is being tracked."
    }

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

    @discardableResult func load() -> Bool {
        do {
            let text = try Keychain.read(service: Self.service, account: "provider")
            guard !text.isEmpty else { message = "No saved APNs credentials."; return false }
            let value = try JSONDecoder().decode(Stored.self, from: Data(text.utf8))
            _ = try APNsCredentials(teamID: value.teamID, keyID: value.keyID, privateKeyPEM: value.pem)
            teamID = value.teamID; keyID = value.keyID; pem = value.pem; hasKey = true; saved = true
            message = "Saved credentials loaded from Keychain."
            return true
        } catch { message = "Could not load valid APNs credentials from Keychain."; return false }
    }

    func forget() {
        do {
            try Keychain.save("", service: Self.service, account: "provider")
            pem = ""; hasKey = false; teamID = ""; keyID = ""; saved = false
            message = "Saved APNs credentials removed. The original .p8 file was not deleted."
        } catch { message = "Keychain could not remove the credentials." }
    }

    func receive(_ receipt: LoopbackReceipt?) {
        guard let receipt, var current = test, receipt.id == current.id, receipt.replyFormat == current.replyFormat else { return }
        current.receive(id: receipt.id); test = current; timeout?.cancel()
        message = current.replyFormat == true
            ? "Mac reply test passed. The matching synthetic Trio-format reply arrived and was parsed. This does not test the phone’s sending step or confirm insulin delivery."
            : "Round trip confirmed: this app received its matching synthetic test notification."
    }

    func checkDelivery() async {
        guard let test else { return }
        if test.state == .received {
            message = "This synthetic test was already confirmed. No new notification was sent."
            return
        }
        if let receipt = await PushReceiver.shared.deliveredTest(id: test.id) { receive(receipt) }
        else { message = "No matching test is in this app’s delivered notifications yet. It may be delayed or already dismissed." }
    }

    func testReplyPathToThisMac() async {
        guard !busy, test?.waiting != true else { return }
        replyTestRequested = true
        // Background reception is an intended test condition, not a reason to block a test.
        // Loading and the sender's busy guard run without an intervening suspension.
        guard load() else { return }
        await sendToThisMac(replyFormat: true)
    }

    func sendToThisMac(replyFormat: Bool = false) async {
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
        await push.refreshConditions()
        do {
            let credentials = try APNsCredentials(teamID: teamID, keyID: keyID, privateKeyPEM: pem)
            let recipient = try MacTestRecipient(token: token, topic: topic, environment: environment)
            let pending = LoopbackTest(replyFormat: replyFormat)
            deliveryLogID = nil
            test = pending; message = replyFormat ? "Sending a synthetic Trio-format reply to this Mac only…" : "Sending synthetic notification to this Mac…"
            timeout?.cancel()
            timeout = Task { [weak self] in
                for attempt in 0..<150 {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, let current = self.test, current.id == pending.id,
                          current.state != .received, current.state != .rejected else { return }
                    if let receipt = await PushReceiver.shared.deliveredTest(id: pending.id) {
                        self.receive(receipt); return
                    }
                    if attempt == 14, var delayed = self.test, delayed.waiting {
                        delayed.unknown(); self.test = delayed
                        self.message = pending.replyFormat == true
                            ? "No reply test received within 30 seconds. An immediate-only notification may already have expired. Still checking this Mac for its receipt; no retry was sent."
                            : "No test received within 30 seconds. Apple may be holding it for power or connection reasons. Checking for up to 5 minutes; no retry was sent."
                    }
                }
                guard let self, let current = self.test, current.id == pending.id, current.state == .unconfirmed else { return }
                self.message = "No matching return within 5 minutes. Check Apple’s delivery log ID for power deferral, an offline device or expiry. No automatic resend was sent."
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
                Text("Test status: \(model.testStatus)").font(DeskTheme.label)
                Text("Test ID: \(test.id.uuidString)").font(DeskTheme.code).foregroundStyle(DeskTheme.muted)
                Text("Started: \(test.createdAt.formatted())").font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
                if let logID = model.deliveryLogID {
                    Text("Apple delivery log ID: \(logID)").font(DeskTheme.code).textSelection(.enabled)
                    Button("Copy Apple delivery log ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logID, forType: .string)
                    }
                }
                Button("Check received test") { Task { await model.checkDelivery() } }.disabled(model.busy)
            }
            Text(model.checkpointMessage).font(DeskTheme.small).foregroundStyle(DeskTheme.muted)
            Button("Clear saved test") { model.clearSavedTest() }.disabled(model.busy)
        }
    }
    @ViewBuilder private var credentialActions: some View {
        Button("Import .p8 key") { Task { await model.importKey() } }
        Button("Save credentials") { model.save() }.disabled(!model.hasKey)
        Button("Load saved") { model.load() }
        Button("Forget saved") { model.forget() }
    }
}

@MainActor
final class StockBolusController: ObservableObject {
    static let shared = StockBolusController()
    @Published var enabled = false { didSet { if !enabled { cancelReview() } } }
    @Published var sharedSecret = "" { didSet { if sharedSecret != oldValue { invalidateSettings() } } }
    @Published var maximum = "" { didSet { if maximum != oldValue { invalidateSettings() } } }
    @Published var increment = "" { didSet { if increment != oldValue { invalidateSettings() } } }
    @Published var keyID = "" { didSet { if keyID != oldValue { invalidateSettings() } } }
    @Published var amount = "" { didSet { if amount != oldValue { cancelReview() } } }
    @Published var targetVerified = false { didSet { if !targetVerified { cancelReview() } } }
    @Published private(set) var profile: StockTrioProfile?
    @Published private(set) var saved = false
    @Published private(set) var providerLoaded = false
    @Published private(set) var busy = false
    @Published private(set) var latestAttempt: StockBolusAttempt?
    @Published private(set) var journalAvailable = true
    @Published private(set) var message = "Read your Trio profile from Nightscout, then configure stock-Trio control."
    private var providerPEM = ""
    private var pairedFingerprint: String?
    private var account: String?
    private var pendingDraft: StockBolusDraft?
    private var authentication: LAContext?
    private var journal: StockBolusJournal?
    private let sender = StockTrioBolusSender()
    private static let service = "com.fishistick.TrioPC.stock-bolus"
    private struct Configuration: Codable { let secret: String; let maximum: String; let increment: String; let keyID: String; let pem: String; let targetFingerprint: String }
    private struct MacProvider: Codable { let teamID: String; let keyID: String; let pem: String }
    private var journalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrioPC", isDirectory: true).appendingPathComponent("stock-bolus-attempts.v1.enc")
    }
    var needsPhoneReview: Bool { latestAttempt?.phoneReviewCompleted == false }
    var providerDescription: String { providerLoaded ? "APNs private key loaded; contents hidden." : "Import a key authorised for the Trio app’s topic and team." }

    private func invalidateSettings() { saved = false; targetVerified = false; cancelReview() }
    func cancelReview() { pendingDraft = nil; authentication?.invalidate(); authentication = nil }

    func enter() async {
        if FileManager.default.fileExists(atPath: journalURL.path) { await reloadJournal() }
    }
    func discover(app: AppModel) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let (fresh, server) = try await app.stockTrioProfile()
            guard fresh.bundleID != Bundle.main.bundleIdentifier else { throw StockBolusError.invalidTarget }
            let changed = profile?.fingerprint != fresh.fingerprint || account != server
            profile = fresh
            if changed { saved = false; targetVerified = false; cancelReview() }
            if account != server { account = server; loadConfiguration() }
            message = "Trio profile loaded. Verify the app identity and copy its current bolus maximum and increment."
        } catch { message = "Could not read a valid Trio profile. Check Nightscout and upload Trio’s current profile from the phone." }
    }
    func importProvider() async {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 16385) <= 16384 else { throw StockBolusError.invalidSettings }
            let pem = try String(contentsOf: url, encoding: .utf8)
            _ = try APNsCredentials(teamID: "AAAAAAAAAA", keyID: "AAAAAAAAAA", privateKeyPEM: pem)
            providerPEM = pem; providerLoaded = true; invalidateSettings()
            message = "Key imported in memory. Save the control settings to store it in Keychain."
        } catch { message = "Could not import a valid APNs P-256 .p8 key. No key contents were logged." }
    }
    func useMacProvider() {
        do {
            guard let profile else { throw StockBolusError.invalidTarget }
            let value = try readMacProvider()
            guard value.teamID == profile.teamID else { throw StockBolusError.invalidTarget }
            providerPEM = value.pem; keyID = value.keyID; providerLoaded = true; invalidateSettings()
            message = "Mac provider key copied in memory. It must also authorise the Trio topic. Save control settings."
        } catch { message = "The saved Mac key is unavailable or belongs to a different team. Import a key for Trio’s team instead." }
    }
    private func readMacProvider() throws -> MacProvider {
        let stored = try Keychain.read(service: "com.fishistick.TrioPC.apns-test", account: "provider")
        let value = try JSONDecoder().decode(MacProvider.self, from: Data(stored.utf8))
        _ = try APNsCredentials(teamID: value.teamID, keyID: value.keyID, privateKeyPEM: value.pem)
        return value
    }
    private func returnInfo() throws -> StockTrioReturnInfo {
        let mac = PushReceiver.shared
        let value = try readMacProvider()
        guard let token = mac.deviceToken, let bundle = Bundle.main.bundleIdentifier,
              let raw = mac.environment, let environment = APNsEnvironment(rawValue: raw), value.teamID == mac.signedTeamID
        else { throw StockBolusError.invalidSettings }
        return try StockTrioReturnInfo(token: token, bundleID: bundle, environment: environment,
            teamID: value.teamID, keyID: value.keyID, pem: value.pem)
    }
    func saveConfiguration() {
        do {
            guard let profile, let account, !sharedSecret.isEmpty, sharedSecret.utf8.count <= 1024 else { throw StockBolusError.invalidSettings }
            _ = try StockBolusLimits(maximum: maximum, increment: increment)
            _ = try APNsCredentials(teamID: profile.teamID, keyID: keyID, privateKeyPEM: providerPEM)
            let value = Configuration(secret: sharedSecret, maximum: maximum, increment: increment, keyID: keyID, pem: providerPEM, targetFingerprint: profile.fingerprint)
            try Keychain.save(String(decoding: JSONEncoder().encode(value), as: UTF8.self), service: Self.service, account: account)
            pairedFingerprint = profile.fingerprint; saved = true; message = "Control settings saved in Keychain. Verify the target and enable control for this session."
        } catch { message = (error as? StockBolusError)?.localizedDescription ?? "Could not save valid control settings in Keychain." }
    }
    private func loadConfiguration() {
        sharedSecret = ""; maximum = ""; increment = ""; keyID = ""; providerPEM = ""; providerLoaded = false; saved = false; pairedFingerprint = nil
        guard let account else { return }
        do {
            let text = try Keychain.read(service: Self.service, account: account)
            guard !text.isEmpty else { return }
            let value = try JSONDecoder().decode(Configuration.self, from: Data(text.utf8))
            _ = try StockBolusLimits(maximum: value.maximum, increment: value.increment)
            guard let profile else { return }
            _ = try APNsCredentials(teamID: profile.teamID, keyID: value.keyID, privateKeyPEM: value.pem)
            sharedSecret = value.secret; maximum = value.maximum; increment = value.increment; keyID = value.keyID
            providerPEM = value.pem; providerLoaded = true; pairedFingerprint = value.targetFingerprint
            saved = value.targetFingerprint == profile.fingerprint
        } catch { message = "Saved control settings could not be loaded. Configure them again." }
    }
    func forgetConfiguration() {
        guard !busy, let account else { return }
        do { try Keychain.save("", service: Self.service, account: account); enabled = false; loadConfiguration() }
        catch { message = "Could not remove control settings from Keychain." }
    }
    private func ensureJournal() async throws -> StockBolusJournal {
        if let journal { _ = try await journal.attempts(); return journal }
        let stored = try Keychain.read(service: Self.service, account: "journal-encryption-key")
        let keyData: Data
        if stored.isEmpty {
            guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw StockBolusError.storageUnavailable }
            let candidate = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let actual = try Keychain.createIfAbsent(candidate.base64EncodedString(), service: Self.service, account: "journal-encryption-key")
            guard let data = Data(base64Encoded: actual), data.count == 32 else { throw StockBolusError.storageUnavailable }
            keyData = data
        } else {
            guard let data = Data(base64Encoded: stored), data.count == 32 else { throw StockBolusError.storageUnavailable }
            keyData = data
        }
        let journal = try StockBolusJournal(url: journalURL, keyData: keyData)
        self.journal = journal; _ = try await journal.attempts(); return journal
    }
    private func reloadJournal() async {
        do {
            let journal = try await ensureJournal(); latestAttempt = try await journal.attempts().last; journalAvailable = true
        } catch { journalAvailable = false; message = StockBolusError.storageUnavailable.localizedDescription }
    }
    func prepare(app: AppModel) async -> StockBolusDraft? {
        guard enabled, saved, targetVerified, !busy, journalAvailable, !needsPhoneReview, app.bolusReadingIsFresh else {
            message = "Enable and verify control, use a recent Nightscout reading, and finish any previous phone review first."; return nil
        }
        busy = true; defer { busy = false }
        do {
            let (fresh, server) = try await app.stockTrioProfile()
            guard server == account, fresh.fingerprint == profile?.fingerprint, fresh.fingerprint == pairedFingerprint else { throw StockBolusError.invalidTarget }
            _ = try returnInfo()
            let draft = try StockBolusDraft(amount: amount, limits: StockBolusLimits(maximum: maximum, increment: increment), profile: fresh)
            profile = fresh; pendingDraft = draft; return draft
        } catch { message = (error as? StockBolusError)?.localizedDescription ?? "Setup could not be verified. No bolus request was sent."; return nil }
    }
    func submit(_ draft: StockBolusDraft, app: AppModel) async {
        guard !busy, enabled, saved, targetVerified, pendingDraft?.id == draft.id else { return }
        busy = true
        defer { busy = false; cancelReview() }
        do {
            let context = LAContext(); authentication = context
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                message = "Mac authentication is unavailable. No bolus request was sent."; return
            }
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Send \(NSDecimalNumber(decimal: draft.units).stringValue) U to your Trio app") { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted, enabled, saved, targetVerified, pendingDraft?.id == draft.id, app.bolusReadingIsFresh else {
                message = "Review cancelled or data became stale. No bolus request was sent."; return
            }
            let (fresh, server) = try await app.stockTrioProfile()
            guard pendingDraft?.id == draft.id, enabled, saved, server == account, fresh.fingerprint == draft.targetFingerprint,
                  Date().timeIntervalSince(draft.createdAt) <= 60 else { throw StockBolusError.staleReview }
            let reply = try returnInfo()
            let credentials = try APNsCredentials(teamID: fresh.teamID, keyID: keyID, privateKeyPEM: providerPEM)
            let journal = try await ensureJournal()
            guard pendingDraft?.id == draft.id, enabled, saved, targetVerified, app.bolusReadingIsFresh else { throw StockBolusError.staleReview }
            message = "Submitting once. Apple acceptance cannot confirm insulin delivery."
            try await sender.send(draft, profile: fresh, sharedSecret: sharedSecret, reply: reply, credentials: credentials, journal: journal)
            message = "Apple accepted this request. Check Trio on your phone for its outcome. No automatic resend will occur."
        } catch {
            if (error as NSError).domain == LAError.errorDomain { message = "Mac authentication did not complete. No bolus request was sent." }
            else { message = (error as? StockBolusError)?.localizedDescription ?? "The operation ended without a verified outcome. Check Trio on your phone before another attempt." }
        }
        if journal != nil { await reloadJournal() }
        if latestAttempt?.id == draft.id { amount = "" }
    }
    func finishPhoneReview() async {
        guard !busy, let latestAttempt else { return }
        do {
            let journal = try await ensureJournal(); try await journal.finishPhoneReview(latestAttempt.id)
            await reloadJournal(); amount = ""
            message = "Phone review recorded. This does not mark the bolus completed or establish zero delivery."
        } catch { journalAvailable = false; message = StockBolusError.storageUnavailable.localizedDescription }
    }
}
