#!/usr/bin/env python3
"""Generate a reviewable patch from an untouched Trio v1.0.2 source directory.

Reads the supplied directory; never modifies it. No network or credentials are used.
"""
import difflib
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = Path(sys.argv[1])
OUT = ROOT / 'integrations/trio-v1.0.2/response-history.patch'

def replace_once(source, old, new):
    if source.count(old) != 1:
        raise SystemExit('Pinned Trio source did not match expected patch context.')
    return source.replace(old, new, 1)

paths = [
    'Trio/Sources/Services/RemoteControl/RemoteNotificationResponseManager.swift',
    'Trio/Sources/Services/Network/Nightscout/NightscoutManager.swift',
    'Trio/Sources/Services/Network/Nightscout/NightscoutAPI.swift',
    'Trio/Sources/Modules/RemoteControlConfig/View/RemoteControlConfig.swift',
]
original = {p: (BASE / p).read_text() for p in paths}
changed = dict(original)
p = paths[0]
s = original[p].replace('import Foundation', 'import Foundation\nimport CryptoKit', 1)
guard = '''        guard let returnInfo = returnInfo,
              !returnInfo.deviceToken.isEmpty
        else {
            debug(.remoteControl, "No return notification info provided, skipping response")
            return
        }

'''
s = replace_once(s, guard, '')
hook = '''        if UserDefaults.standard.bool(forKey: "trioPCResponseHistoryEnabled") {
            do {
                let data = try JSONEncoder().encode(payload)
                let secret = UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? ""
                await TrioRemoteControl.shared.nightscoutManager.storeResponseHistory(data, sharedSecret: secret, isSynthetic: false)
            } catch {
                debug(.remoteControl, "Response history encoding failed; no payload or credentials were logged")
            }
        }

'''
s = replace_once(s, '        await sendPushNotification(\n', hook + guard + '        await sendPushNotification(\n')
helper = (ROOT / 'integrations/trio-v1.0.2/publisher/TrioPCResponseOutbox.swift').read_text()
helper = helper.replace('import Foundation\nimport CryptoKit\n', '', 1)
changed[p] = s.rstrip() + '\n\n' + helper

p = paths[1]
s = replace_once(original[p], 'protocol NightscoutManager: GlucoseSource {', '''protocol NightscoutManager: GlucoseSource {
    func storeResponseHistory(_ replyData: Data, sharedSecret: String, isSynthetic: Bool) async
    func uploadResponseHistory() async''')
s = replace_once(s, '        case .deviceStatus:\n', '        case .deviceStatus:\n            await performUploadResponseHistory()\n')
methods = '''    func storeResponseHistory(_ replyData: Data, sharedSecret: String, isSynthetic: Bool) async {
        guard UserDefaults.standard.bool(forKey: "trioPCResponseHistoryEnabled"), let api = nightscoutAPI else { return }
        do {
            let destination = try TrioPCResponseOutbox.destinationID(api.url)
            try await TrioPCResponseOutbox.shared.enqueue(replyData: replyData, sharedSecret: sharedSecret, destination: destination, isSynthetic: isSynthetic)
            requestUpload(.deviceStatus)
        } catch {
            debug(.nightscout, "Response history could not be saved; inspect history storage and settings")
        }
    }

    func uploadResponseHistory() async { requestUpload(.deviceStatus) }

    private func performUploadResponseHistory() async {
        guard UserDefaults.standard.bool(forKey: "trioPCResponseHistoryEnabled"), isUploadEnabled,
              isNetworkReachable, let api = nightscoutAPI else { return }
        do {
            let destination = try TrioPCResponseOutbox.destinationID(api.url)
            let batch = try await TrioPCResponseOutbox.shared.pending(destination: destination)
            for envelope in batch {
                guard UserDefaults.standard.bool(forKey: "trioPCResponseHistoryEnabled"), isUploadEnabled else { return }
                try await api.uploadResponseHistory(envelope)
                try await TrioPCResponseOutbox.shared.acknowledge(envelope.event_id)
            }
            if batch.count == 20 { requestUpload(.deviceStatus) }
        } catch {
            // Keep the encrypted outbox. A later serialized upload retries these records, never a command.
            debug(.nightscout, "Response history upload deferred; encrypted responses remain queued")
        }
    }

'''
s = replace_once(s, '    private var lastEnactedDetermination: Determination?', methods + '    private var lastEnactedDetermination: Determination?')
s = replace_once(s, '        wireSubscribers()\n', '        wireSubscribers()\n        requestUpload(.deviceStatus)\n')
s = replace_once(s, '_ = reachabilityManager.startListening(onQueue: processQueue) { status in', '_ = reachabilityManager.startListening(onQueue: processQueue) { [weak self] status in')
s = replace_once(s, '            debug(.nightscout, "Network status: \\(status)")\n', '            debug(.nightscout, "Network status: \\(status)")\n            self?.requestUpload(.deviceStatus)\n')
changed[p] = s

p = paths[2]
method = '''    func uploadResponseHistory(_ envelope: TrioPCResponseEnvelope) async throws {
        _ = try TrioPCResponseOutbox.destinationID(url) // HTTPS only, with no URL credentials.
        let endpoint = url.appendingPathComponent("api/v1/devicestatus.json")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = secret { request.setValue(secret.sha1(), forHTTPHeaderField: "api-secret") }
        request.httpBody = try JSONEncoder().encode(TrioPCResponseDocument(envelope: envelope))
        let session = URLSession(configuration: .ephemeral, delegate: TrioPCResponseNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              TrioPCResponseDocument.acknowledged(data, envelope: envelope) else { throw URLError(.badServerResponse) }
    }

'''
s = replace_once(original[p], '    func uploadDeviceStatus(_ status: NightscoutStatus) async throws {', method + '    func uploadDeviceStatus(_ status: NightscoutStatus) async throws {')
s += '''
private final class TrioPCResponseNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
'''
changed[p] = s

p = paths[3]
s = replace_once(original[p], '        @State private var isCopied: Bool = false', '''        @State private var isCopied: Bool = false
        @AppStorage("trioPCResponseHistoryEnabled") private var historyEnabled = false
        @State private var historyStatus = ""''')
s = replace_once(s, '            List {\n', '''            List {
                Section("TrioPC response history") {
                    Toggle("Save encrypted responses to Nightscout", isOn: $historyEnabled)
                    Text("Uses your Trio shared secret (at least 32 characters) and existing Nightscout upload connection. Saves advisory command responses, not pump-completion evidence.")
                    Text(historyStatus).font(.caption)
                    Button("Send history connection test") {
                        Task {
                            do {
                                let data = try JSONSerialization.data(withJSONObject: [
                                    "command_status": "success", "command_type": "temp_target",
                                    "timestamp": Date().timeIntervalSince1970,
                                    "aps": ["alert": ["title": "History connection test", "body": "Synthetic history test. No command was executed."]]
                                ])
                                await TrioRemoteControl.shared.nightscoutManager.storeResponseHistory(data, sharedSecret: state.sharedSecret, isSynthetic: true)
                                historyStatus = await TrioPCResponseOutbox.shared.statusDescription()
                            } catch { historyStatus = "Could not prepare the synthetic history test." }
                        }
                    }.disabled(!historyEnabled)
                }
                .task { historyStatus = await TrioPCResponseOutbox.shared.statusDescription() }
                .onChange(of: historyEnabled) { enabled in
                    if enabled { Task { await TrioRemoteControl.shared.nightscoutManager.uploadResponseHistory() } }
                }
''')
changed[p] = s

diff = ''.join(''.join(difflib.unified_diff(original[p].splitlines(True), changed[p].splitlines(True),
    fromfile='a/' + p, tofile='b/' + p)) for p in paths)
OUT.write_text(diff)
print('Generated separate patch:', OUT.name)
