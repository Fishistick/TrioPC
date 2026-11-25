import AppKit
import UserNotifications
import Security
import TrioCore
import SwiftUI

@MainActor
final class PushReceiver: ObservableObject {
    static let shared = PushReceiver()
    @Published private(set) var state = "Not registered"
    @Published private(set) var deviceToken: String?
    @Published private(set) var reply: LegacyReply?
    @Published private(set) var receivedAt: Date?

    var environment: String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) as? String
    }

    func register() async {
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
        if let reply = PushReceiver.parse(userInfo) { PushReceiver.shared.receive(reply) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let value = PushReceiver.parse(notification.request.content.userInfo) {
            Task { @MainActor in PushReceiver.shared.receive(value) }
        }
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
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
        }
    }
}
