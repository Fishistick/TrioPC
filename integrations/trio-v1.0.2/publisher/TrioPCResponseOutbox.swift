import Foundation
import CryptoKit

// Copied into the separate Trio patch. Keep protocol constants in sync with ResponseHistoryKey.
struct TrioPCResponseEnvelope: Codable, Sendable {
    let schema: Int
    let event_id: UUID
    let box: String
}

struct TrioPCResponseDocument: Encodable, Sendable {
    let device = "TrioPC-response-v1"
    let created_at: String
    let triopc_response: TrioPCResponseEnvelope
    init(envelope: TrioPCResponseEnvelope, uploadedAt: Date = Date()) {
        created_at = ISO8601DateFormatter().string(from: uploadedAt)
        triopc_response = envelope
    }
    static func acknowledged(_ data: Data, envelope: TrioPCResponseEnvelope) -> Bool {
        guard data.count <= 262144, let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        let rows = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
        return rows.contains { row in
            guard row["device"] as? String == "TrioPC-response-v1",
                  let saved = row["triopc_response"] as? [String: Any],
                  let id = saved["event_id"] as? String else { return false }
            return UUID(uuidString: id) == envelope.event_id && saved["box"] as? String == envelope.box
        }
    }
}

/// An encrypted, write-before-upload outbox. This does not queue or replay commands.
actor TrioPCResponseOutbox {
    static let shared = TrioPCResponseOutbox(storageURL: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("TrioPCResponseOutbox.v1.json"))
    enum Failure: Error { case invalid, full, storage }
    private let storageURL: URL
    private var entries: [TrioPCResponseEnvelope] = []
    private var destination: String?
    private var healthy = true
    private var lastSaveFailed = false
    private struct Archive: Codable { let schema: Int; let destination: String?; let entries: [TrioPCResponseEnvelope] }
    init(storageURL: URL) {
        self.storageURL = storageURL
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                guard data.count <= 8_388_608 else { throw Failure.storage }
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                guard archive.schema == 1, archive.entries.count <= 1000 else { throw Failure.storage }
                entries = archive.entries; destination = archive.destination
            } catch { healthy = false }
        }
    }
    func statusDescription() -> String {
        if lastSaveFailed { return "A response could not be saved. Check the shared secret, storage, queue limit and Nightscout server binding. History may be incomplete." }
        return healthy ? "\(entries.count) encrypted responses waiting for upload." : "Response history storage needs attention. Existing data was preserved."
    }
    static func destinationID(_ url: URL) throws -> String {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw Failure.invalid }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    func enqueue(replyData: Data, sharedSecret: String, destination: String, id: UUID = UUID(), recordedAt: TimeInterval = Date().timeIntervalSince1970, isSynthetic: Bool = false) throws {
        var saved = false
        defer { if !saved { lastSaveFailed = true } }
        guard healthy else { throw Failure.storage }
        guard self.destination == nil || self.destination == destination else { throw Failure.storage }
        guard entries.count < 1000 else { throw Failure.full }
        guard (32...1024).contains(sharedSecret.utf8.count), replyData.count <= 4096,
              recordedAt.isFinite, recordedAt > 0, recordedAt <= 253402300799,
              let reply = try JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        else { throw Failure.invalid }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(sharedSecret.utf8)),
            salt: Data("TrioPC".utf8), info: Data("response-history/v1".utf8), outputByteCount: 32)
        let plain = try JSONSerialization.data(withJSONObject: ["schema": 1, "kind": isSynthetic ? "synthetic" : "legacy_response", "event_id": id.uuidString,
            "recorded_at": recordedAt, "reply": reply])
        guard plain.count <= 8192 else { throw Failure.invalid }
        let aad = Data(("TrioPC.response-history.v1|" + id.uuidString.lowercased()).utf8)
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw Failure.invalid }
        let envelope = TrioPCResponseEnvelope(schema: 1, event_id: id, box: combined.base64EncodedString())
        // Retrying an upload reuses this exact event ID and ciphertext.
        try persist(entries + [envelope], destination: destination)
        saved = true
    }
    func pending(destination: String) throws -> [TrioPCResponseEnvelope] {
        guard healthy else { throw Failure.storage }
        guard self.destination == nil || self.destination == destination else { throw Failure.storage }
        return Array(entries.prefix(20))
    }
    func acknowledge(_ id: UUID) throws {
        guard healthy else { throw Failure.storage }
        try persist(entries.filter { $0.event_id != id }, destination: destination)
    }
    private func persist(_ values: [TrioPCResponseEnvelope], destination: String?) throws {
        let retainedDestination = values.isEmpty ? nil : destination
        let data = try JSONEncoder().encode(Archive(schema: 1, destination: retainedDestination, entries: values))
        guard data.count <= 8_388_608 else { throw Failure.storage }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: storageURL, options: .atomic)
        #endif
        entries = values
        self.destination = retainedDestination
    }
}
