import Foundation
import CryptoKit

public enum APNsEnvironment: String, Sendable {
    case development, production
    var host: String { self == .development ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
}

public enum APNsTestError: Error, LocalizedError, Equatable {
    case invalidCredentials, invalidPrivateKey, invalidRecipient, transportUncertain
    case rejected(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Team ID and Key ID must each contain 10 uppercase letters or digits."
        case .invalidPrivateKey: "The imported file is not a valid APNs P-256 private key."
        case .invalidRecipient: "Register this Mac again before sending a test."
        case .transportUncertain: "The connection ended without a reliable Apple response. No automatic retry was sent."
        case let .rejected(code, reason): "Apple rejected the test (HTTP \(code), \(reason))."
        }
    }
}

public struct APNsCredentials: Sendable {
    public let teamID: String
    public let keyID: String
    private let key: P256.Signing.PrivateKey
    var identity: String { teamID + ":" + keyID + ":" + key.publicKey.rawRepresentation.base64EncodedString() }

    public init(teamID: String, keyID: String, privateKeyPEM: String) throws {
        func valid(_ id: String) -> Bool {
            id.count == 10 && id.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
        }
        guard valid(teamID), valid(keyID) else { throw APNsTestError.invalidCredentials }
        guard privateKeyPEM.utf8.count <= 16384,
              let key = try? P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) else { throw APNsTestError.invalidPrivateKey }
        self.teamID = teamID; self.keyID = keyID; self.key = key
    }

    func jwt(at now: Date) throws -> String {
        struct Header: Encodable { let alg = "ES256"; let kid: String }
        struct Claims: Encodable { let iss: String; let iat: Int }
        let encoder = JSONEncoder()
        let header = try encoder.encode(Header(kid: keyID)).base64URL
        let claims = try encoder.encode(Claims(iss: teamID, iat: Int(now.timeIntervalSince1970))).base64URL
        let content = header + "." + claims
        let signature = try key.signature(for: Data(content.utf8)).rawRepresentation.base64URL
        return content + "." + signature
    }
}

public struct MacTestRecipient: Sendable {
    let token: String
    let topic: String
    let environment: APNsEnvironment
    public init(token: String, topic: String, environment: APNsEnvironment) throws {
        guard !token.isEmpty, token.count <= 1024, token.count.isMultiple(of: 2),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              !topic.isEmpty, topic.count <= 255,
              topic.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 })
        else { throw APNsTestError.invalidRecipient }
        self.token = token; self.topic = topic; self.environment = environment
    }
}

public struct LoopbackReceipt: Decodable, Sendable {
    public let id: UUID
    let marker: Bool
    public let timestamp: TimeInterval
    public let replyFormat: Bool?
    enum CodingKeys: String, CodingKey { case id = "triopc_test_id", marker = "triopc_test", timestamp, replyFormat = "triopc_reply_test" }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw APNsTestError.invalidRecipient }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.marker, value.timestamp.isFinite, value.timestamp > 0, value.timestamp <= 253402300799
        else { throw APNsTestError.invalidRecipient }
        if value.replyFormat == true { _ = try LegacyReply.parse(data) }
        return value
    }
}

public struct LoopbackTest: Codable, Sendable {
    public enum State: String, Codable, Sendable { case sending, awaitingReturn, received, unconfirmed, rejected }
    public let id: UUID
    public let createdAt: Date
    public let replyFormat: Bool?
    public private(set) var state: State = .sending
    public init(id: UUID = UUID(), now: Date = Date(), replyFormat: Bool = false) {
        self.id = id; createdAt = now; self.replyFormat = replyFormat ? true : nil
    }
    public mutating func accepted() { if state == .sending { state = .awaitingReturn } }
    public mutating func unknown() { if state != .received && state != .rejected { state = .unconfirmed } }
    public mutating func rejected() { if state != .received { state = .rejected } }
    public mutating func receive(id: UUID) {
        if id == self.id { state = .received }
    }
    public var waiting: Bool { state == .sending || state == .awaitingReturn }

    func payload() throws -> Data {
        if replyFormat == true {
            struct Alert: Encodable {
                let title = "TrioPC reply test — no insulin command"
                let body = "Synthetic Trio-format reply received on this Mac. No command was sent to your phone."
            }
            struct APS: Encodable { let alert = Alert(); let sound = "default" }
            struct Payload: Encodable {
                let aps = APS(); let command_status = "success"; let command_type = "bolus"
                let timestamp: TimeInterval
                let triopc_test = true; let triopc_reply_test = true; let triopc_test_id: UUID
            }
            return try JSONEncoder().encode(Payload(timestamp: createdAt.timeIntervalSince1970, triopc_test_id: id))
        }
        struct Alert: Encodable { let title = "TrioPC connection test"; let body = "Synthetic notification sent to this Mac only. No insulin command." }
        struct APS: Encodable { let alert = Alert() }
        struct Payload: Encodable {
            let aps = APS(); let triopc_test = true; let triopc_test_id: UUID; let timestamp: TimeInterval
        }
        return try JSONEncoder().encode(Payload(triopc_test_id: id, timestamp: createdAt.timeIntervalSince1970))
    }
}

/// Local synthetic-test metadata only. Never use this unauthenticated checkpoint for dosing.
public struct LoopbackCheckpoint: Codable, Sendable {
    private let schema: Int
    public let test: LoopbackTest
    public let deliveryLogID: String?

    public init(test: LoopbackTest, deliveryLogID: String?) {
        schema = 1
        self.test = test
        self.deliveryLogID = Self.validLogID(deliveryLogID)
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw APNsTestError.invalidRecipient }
        let checkpoint = try JSONDecoder().decode(Self.self, from: data)
        let timestamp = checkpoint.test.createdAt.timeIntervalSince1970
        guard checkpoint.schema == 1, timestamp.isFinite, timestamp > 0, timestamp <= 253402300799,
              checkpoint.deliveryLogID == validLogID(checkpoint.deliveryLogID)
        else { throw APNsTestError.invalidRecipient }
        return checkpoint
    }

    public var recoveredTest: LoopbackTest {
        var recovered = test
        // A process exit cannot establish whether Apple accepted an in-flight request.
        recovered.unknown()
        return recovered
    }

    private static func validLogID(_ value: String?) -> String? {
        value.flatMap { id in
            guard !id.isEmpty, id.utf8.count <= 256,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            return id
        }
    }
}

public struct APNsTestSubmission: Sendable {
    public let deliveryLogID: String?
    init(response: HTTPURLResponse) {
        // Only retain the documented opaque diagnostic ID, never arbitrary headers.
        let value = response.value(forHTTPHeaderField: "apns-unique-id")
        deliveryLogID = value.flatMap { id in
            guard !id.isEmpty, id.utf8.count <= 256,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            return id
        }
    }
}

actor APNsProviderTokens {
    static let shared = APNsProviderTokens()
    private var cache: [String: (issuedAt: Date, jwt: String)] = [:]
    func token(credentials: APNsCredentials, now: Date) throws -> String {
        if let cached = cache[credentials.identity], now.timeIntervalSince(cached.issuedAt) >= 0,
           now.timeIntervalSince(cached.issuedAt) < 50 * 60 { return cached.jwt }
        let token = try credentials.jwt(at: now)
        if cache.count >= 32 { cache.removeAll() }
        cache[credentials.identity] = (now, token)
        return token
    }
    func invalidate(_ identity: String) { cache[identity] = nil }
}

private final class APNsNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A fixed synthetic payload only. The app supplies its own registered token, signed topic and environment.
public actor APNsTestSender {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport?
    public init(transport: Transport? = nil) { self.transport = transport }

    @discardableResult
    public func send(_ test: LoopbackTest, to recipient: MacTestRecipient, credentials: APNsCredentials, now: Date = Date()) async throws -> APNsTestSubmission {
        let jwt = try await APNsProviderTokens.shared.token(credentials: credentials, now: now)
        let url = URL(string: "https://\(recipient.environment.host)/3/device/\(recipient.token)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("bearer " + jwt, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(recipient.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        // Synthetic tests may wait briefly for the Mac’s APNs connection.
        // This retention policy must not be reused for insulin commands.
        request.setValue(test.replyFormat == true ? "0" : String(Int(test.createdAt.timeIntervalSince1970) + 300), forHTTPHeaderField: "apns-expiration")
        request.setValue(test.id.uuidString.lowercased(), forHTTPHeaderField: "apns-id")
        request.httpBody = try test.payload()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: configuration, delegate: APNsNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let send: Transport = transport ?? { try await session.data(for: $0) }
        let data: Data; let response: URLResponse
        do { (data, response) = try await send(request) }
        catch { throw APNsTestError.transportUncertain }
        guard let response = response as? HTTPURLResponse else { throw APNsTestError.transportUncertain }
        guard response.statusCode != 200 else { return APNsTestSubmission(response: response) }
        // Never surface arbitrary server text, headers, URLs or credentials in errors/logs.
        struct Reason: Decodable { let reason: String }
        let allowed = ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "InvalidProviderToken", "ExpiredProviderToken", "Forbidden", "BadTopic", "TopicDisallowed", "TooManyRequests", "TooManyProviderTokenUpdates", "BadEnvironmentKeyIdInToken", "BadEnvironment", "InternalServerError", "ServiceUnavailable", "PayloadTooLarge", "MissingTopic"]
        let parsed = data.count <= 4096 ? (try? JSONDecoder().decode(Reason.self, from: data).reason) : nil
        let reason = parsed.flatMap { allowed.contains($0) ? $0 : nil } ?? "UnrecognizedResponse"
        if response.statusCode == 403 { await APNsProviderTokens.shared.invalidate(credentials.identity) }
        throw APNsTestError.rejected(response.statusCode, reason)
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
