import Foundation
import CryptoKit

public enum ResponseHistoryError: Error { case invalidSecret, malformed, authentication }

public struct ResponseHistoryEnvelope: Codable, Sendable, Equatable {
    public let schema: Int
    public let eventID: UUID
    public let box: String
    enum CodingKeys: String, CodingKey { case schema, eventID = "event_id", box }
    public init(schema: Int = 1, eventID: UUID, box: String) { self.schema = schema; self.eventID = eventID; self.box = box }
}

public struct ResponseHistoryEvent: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case legacyResponse = "legacy_response", synthetic }
    public let schema: Int
    public let kind: Kind
    public let id: UUID
    public let recordedAt: TimeInterval
    public let reply: LegacyReply
    enum CodingKeys: String, CodingKey { case schema, kind, id = "event_id", recordedAt = "recorded_at", reply }
    public init(id: UUID = UUID(), recordedAt: TimeInterval, reply: LegacyReply, kind: Kind = .legacyResponse) {
        schema = 1; self.kind = kind; self.id = id; self.recordedAt = recordedAt; self.reply = reply
    }
}

/// Separate encryption domain from Trio's command channel. This codec sends no commands.
public struct ResponseHistoryKey: Sendable {
    private let key: SymmetricKey
    public let cacheIdentity: String
    public init(sharedSecret: String) throws {
        guard (32...1024).contains(sharedSecret.utf8.count) else { throw ResponseHistoryError.invalidSecret }
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(sharedSecret.utf8)),
            salt: Data("TrioPC".utf8), info: Data("response-history/v1".utf8), outputByteCount: 32)
        cacheIdentity = key.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
    }
    public func seal(_ event: ResponseHistoryEvent) throws -> ResponseHistoryEnvelope {
        let data = try JSONEncoder().encode(event)
        guard data.count <= 8192 else { throw ResponseHistoryError.malformed }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: aad(event.id))
        guard let combined = sealed.combined else { throw ResponseHistoryError.malformed }
        return ResponseHistoryEnvelope(eventID: event.id, box: combined.base64EncodedString())
    }
    public func open(_ envelope: ResponseHistoryEnvelope) throws -> ResponseHistoryEvent {
        guard envelope.schema == 1, envelope.box.utf8.count <= 16384,
              let combined = Data(base64Encoded: envelope.box), combined.count <= 12288 else { throw ResponseHistoryError.malformed }
        let data: Data
        do { data = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad(envelope.eventID)) }
        catch { throw ResponseHistoryError.authentication }
        guard data.count <= 8192 else { throw ResponseHistoryError.malformed }
        let event = try JSONDecoder().decode(ResponseHistoryEvent.self, from: data)
        guard event.schema == 1, event.id == envelope.eventID, event.recordedAt.isFinite,
              event.recordedAt > 0, event.recordedAt <= 253402300799 else { throw ResponseHistoryError.malformed }
        _ = try LegacyReply.parse(JSONEncoder().encode(event.reply))
        return event
    }
    private func aad(_ id: UUID) -> Data { Data(("TrioPC.response-history.v1|" + id.uuidString.lowercased()).utf8) }
}

public struct ResponseHistoryPage: Sendable {
    public static let limit = 500
    public let envelopes: [ResponseHistoryEnvelope]
    public let ignored: Int
    public let atLimit: Bool
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 2_097_152,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= limit
        else { throw ResponseHistoryError.malformed }
        var envelopes: [ResponseHistoryEnvelope] = []; var ignored = 0
        for row in rows {
            guard row["device"] as? String == "TrioPC-response-v1", let object = row["triopc_response"],
                  JSONSerialization.isValidJSONObject(object),
                  let encoded = try? JSONSerialization.data(withJSONObject: object), encoded.count <= 20000,
                  let envelope = try? JSONDecoder().decode(ResponseHistoryEnvelope.self, from: encoded)
            else { ignored += 1; continue }
            envelopes.append(envelope)
        }
        return Self(envelopes: envelopes, ignored: ignored, atLimit: rows.count == limit)
    }
}

public struct ResponseHistoryLedger: Sendable {
    public private(set) var envelopes: [ResponseHistoryEnvelope] = []
    public private(set) var events: [ResponseHistoryEvent] = []
    public init() {}
    /// Validate before deduplicating. Conflicting content for an ID never replaces an observed record.
    public mutating func merge(_ incoming: [ResponseHistoryEnvelope], key: ResponseHistoryKey) -> (invalid: Int, conflicts: Int, evicted: Int) {
        var byID: [UUID: (ResponseHistoryEnvelope, ResponseHistoryEvent)] = [:]
        var invalid = 0; var conflicts = 0
        for envelope in envelopes + incoming {
            guard let event = try? key.open(envelope) else { invalid += 1; continue }
            if let previous = byID[event.id] {
                if previous.1 != event { conflicts += 1 }
                continue
            }
            byID[event.id] = (envelope, event)
        }
        let sorted = byID.values.sorted {
            $0.1.recordedAt == $1.1.recordedAt ? $0.1.id.uuidString < $1.1.id.uuidString : $0.1.recordedAt > $1.1.recordedAt
        }
        let kept = sorted.prefix(1000)
        envelopes = kept.map(\.0); events = kept.map(\.1)
        return (invalid, conflicts, max(0, sorted.count - 1000))
    }
}
