import Foundation
import CryptoKit
import Darwin

public enum StockBolusError: Error, LocalizedError {
    case invalidSettings, invalidUnits, invalidTarget, staleReview, pendingReview, storageUnavailable, uncertainTransport
    case appleRejected(Int, APNsBolusRejection? = nil)
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: "Check the shared secret, APNs credentials, maximum and increment copied from Trio."
        case .invalidUnits: "Enter a positive amount within your configured maximum and exactly matching its increment. Use a decimal point."
        case .invalidTarget: "Refresh and verify the intended Trio installation and its APNs team."
        case .staleReview: "The review expired or the target changed. Review the amount again."
        case .pendingReview: "Check the previous attempt in Trio on your phone before preparing another bolus."
        case .storageUnavailable: "The local bolus record is unavailable or locked by another app instance. Sending is blocked."
        case .uncertainTransport: "No reliable Apple response. Delivery is unknown. Check Trio on your phone; do not resend this attempt."
        case .appleRejected(let status, let reason): "Apple did not accept this request (HTTP \(status)). " + (reason.map { "\($0.rawValue): \($0.guidance) " } ?? "Apple’s specific reason was unavailable. ") + "Check Trio on your phone before another attempt."
        }
    }
}

/// Only documented error codes are retained. Arbitrary response bodies never reach logs or UI.
public enum APNsBolusRejection: String, Codable, Sendable {
    case invalidProviderToken = "InvalidProviderToken"
    case expiredProviderToken = "ExpiredProviderToken"
    case missingProviderToken = "MissingProviderToken"
    case forbidden = "Forbidden"
    case topicDisallowed = "TopicDisallowed"
    case topicMismatch = "TopicMismatch"
    case badEnvironmentKeyIdInToken = "BadEnvironmentKeyIdInToken"
    case unrelatedKeyIdInToken = "UnrelatedKeyIdInToken"
    case badDeviceToken = "BadDeviceToken"
    case deviceTokenNotForTopic = "DeviceTokenNotForTopic"
    case unregistered = "Unregistered"
    case tooManyProviderTokenUpdates = "TooManyProviderTokenUpdates"

    public var guidance: String {
        switch self {
        case .invalidProviderToken, .missingProviderToken:
            "Check that the Key ID and .p8 file belong together under Trio’s Apple developer team, and that the key has not been revoked. Check the Mac’s date and time too."
        case .expiredProviderToken:
            "Apple rejected an expired authentication token. Check the Mac’s date and time. The cached token was discarded; this bolus was not retried."
        case .forbidden, .topicDisallowed, .topicMismatch:
            "Check that this Apple key permits notifications to the phone’s Trio app. A key limited to the Mac app cannot be reused for Trio."
        case .badEnvironmentKeyIdInToken:
            "Check that this Apple key permits the APNs environment shown for Trio. Mac development and phone production permissions may differ."
        case .unrelatedKeyIdInToken:
            "Apple rejected the connection’s key association. This bolus was not retried."
        case .badDeviceToken, .deviceTokenNotForTopic, .unregistered:
            "Refresh Trio’s Nightscout profile and verify the phone app and APNs environment."
        case .tooManyProviderTokenUpdates:
            "Apple is limiting authentication token changes. Do not send repeated bolus requests to test the connection."
        }
    }
    static func parse(_ data: Data) -> Self? {
        struct Response: Decodable { let reason: String }
        guard data.count <= 4096, let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return Self(rawValue: response.reason)
    }
}

public struct StockTrioProfile: Sendable {
    public let bundleID: String
    public let teamID: String
    public let environment: APNsEnvironment
    public let publishedAt: Date
    let deviceToken: String
    public var fingerprint: String {
        SHA256.hash(data: Data((bundleID + "|" + teamID + "|" + environment.rawValue + "|" + deviceToken).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    public static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        struct Metadata: Decodable {
            let bundleIdentifier: String; let deviceToken: String; let teamID: String
            let isAPNSProduction: Bool; let mills: Double; let expirationDate: String?
        }
        guard data.count <= 262144, let profiles = try? JSONDecoder().decode([Metadata].self, from: data),
              profiles.count == 1, let profile = profiles.first else { throw StockBolusError.invalidTarget }
        let bundle = profile.bundleIdentifier, token = profile.deviceToken, team = profile.teamID
        let production = profile.isAPNSProduction, millis = profile.mills
        guard team.count == 10,
              team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              millis.isFinite, millis > 0,
              millis / 1000 <= now.timeIntervalSince1970 + 300 else { throw StockBolusError.invalidTarget }
        if let text = profile.expirationDate {
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text), date > now else { throw StockBolusError.invalidTarget }
        }
        let environment: APNsEnvironment = production ? .production : .development
        _ = try MacTestRecipient(token: token, topic: bundle, environment: environment)
        return Self(bundleID: bundle, teamID: team, environment: environment,
                    publishedAt: Date(timeIntervalSince1970: millis / 1000), deviceToken: token)
    }
}

public struct StockBolusLimits: Codable, Sendable, Equatable {
    public let maximum: Decimal
    public let increment: Decimal
    public init(maximum: String, increment: String) throws {
        self.maximum = try Self.decimal(maximum); self.increment = try Self.decimal(increment)
        guard self.maximum > 0, self.maximum <= 100, self.increment > 0, self.increment <= self.maximum else { throw StockBolusError.invalidSettings }
    }
    public func amount(_ text: String) throws -> Decimal {
        let value = try Self.decimal(text)
        guard maximum > 0, maximum <= 100, increment > 0, increment <= maximum, value > 0, value <= maximum else { throw StockBolusError.invalidUnits }
        var ratio = value / increment; var integral = Decimal()
        NSDecimalRound(&integral, &ratio, 0, .down)
        guard integral == ratio else { throw StockBolusError.invalidUnits }
        return value
    }
    private static func decimal(_ text: String) throws -> Decimal {
        guard text.count <= 12, text.range(of: "^[0-9]+(?:\\.[0-9]{1,3})?$", options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { throw StockBolusError.invalidUnits }
        return value
    }
}

public struct StockTrioReturnInfo: Encodable, Sendable {
    let productionEnvironment: Bool
    let deviceToken: String
    let bundleId: String
    let teamId: String
    let keyId: String
    let apnsKey: String
    enum CodingKeys: String, CodingKey {
        case productionEnvironment = "production_environment", deviceToken = "device_token", bundleId = "bundle_id"
        case teamId = "team_id", keyId = "key_id", apnsKey = "apns_key"
    }
    public init(token: String, bundleID: String, environment: APNsEnvironment, teamID: String, keyID: String, pem: String) throws {
        _ = try MacTestRecipient(token: token, topic: bundleID, environment: environment)
        _ = try APNsCredentials(teamID: teamID, keyID: keyID, privateKeyPEM: pem)
        productionEnvironment = environment == .production; deviceToken = token; bundleId = bundleID
        teamId = teamID; keyId = keyID; apnsKey = pem
    }
}

public struct StockBolusDraft: Identifiable, Sendable {
    public let id: UUID
    public let units: Decimal
    public let createdAt: Date
    public let targetFingerprint: String
    public let bundleID: String
    public init(amount: String, limits: StockBolusLimits, profile: StockTrioProfile, now: Date = Date()) throws {
        id = UUID(); units = try limits.amount(amount); createdAt = now
        targetFingerprint = profile.fingerprint; bundleID = profile.bundleID
    }
    func body(sharedSecret: String, reply: StockTrioReturnInfo) throws -> Data {
        guard !sharedSecret.isEmpty, sharedSecret.utf8.count <= 1024 else { throw StockBolusError.invalidSettings }
        struct Command: Encodable {
            let user = "TrioPC"; let command_type = "bolus"; let timestamp: Double
            let bolus_amount: Decimal; let return_notification: StockTrioReturnInfo
        }
        let clear = try JSONEncoder().encode(Command(timestamp: createdAt.timeIntervalSince1970, bolus_amount: units, return_notification: reply))
        let key = SymmetricKey(data: SHA256.hash(data: Data(sharedSecret.utf8)))
        guard let combined = try AES.GCM.seal(clear, using: key).combined else { throw StockBolusError.invalidSettings }
        struct APS: Encodable {
            let alert = "Remote Command: Bolus"; let contentAvailable = 1; let interruptionLevel = "time-sensitive"
            enum CodingKeys: String, CodingKey { case alert, contentAvailable = "content-available", interruptionLevel = "interruption-level" }
        }
        struct Push: Encodable { let aps = APS(); let encrypted_data: String }
        let data = try JSONEncoder().encode(Push(encrypted_data: combined.base64EncodedString()))
        guard data.count <= 4096 else { throw StockBolusError.invalidSettings }
        return data
    }
}

public struct StockBolusAttempt: Codable, Identifiable, Sendable {
    public enum Submission: String, Codable, Sendable { case attempting, acceptedByApple, rejectedByApple, unknown }
    public let id: UUID
    public let units: Decimal
    public let createdAt: Date
    public let bundleID: String
    public let targetFingerprint: String
    public fileprivate(set) var submission: Submission
    public fileprivate(set) var phoneReviewCompleted: Bool
    public fileprivate(set) var appleRejection: APNsBolusRejection?
    init(_ draft: StockBolusDraft) {
        id = draft.id; units = draft.units; createdAt = draft.createdAt; bundleID = draft.bundleID
        targetFingerprint = draft.targetFingerprint; submission = .attempting; phoneReviewCompleted = false
    }
}

private final class BolusProcessLock: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        let candidate = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { throw StockBolusError.storageUnavailable }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else { close(candidate); throw StockBolusError.storageUnavailable }
        descriptor = candidate
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// An encrypted, process-locked local record. It never resends an attempt or infers pump completion.
public actor StockBolusJournal {
    private let url: URL
    private let key: SymmetricKey
    private let lock: BolusProcessLock
    private struct Archive: Codable { let schema: Int; let attempts: [StockBolusAttempt] }
    public init(url: URL, keyData: Data) throws {
        guard keyData.count == 32 else { throw StockBolusError.storageUnavailable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url; key = SymmetricKey(data: keyData)
        lock = try BolusProcessLock(url: url.appendingPathExtension("lock"))
    }
    public func attempts() throws -> [StockBolusAttempt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let encrypted = try Data(contentsOf: url)
            guard encrypted.count <= 1048576 else { throw StockBolusError.storageUnavailable }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key,
                authenticating: Data("TrioPC.stock-bolus-journal.v1".utf8))
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schema == 1, archive.attempts.count <= 1000,
                  Set(archive.attempts.map(\.id)).count == archive.attempts.count,
                  archive.attempts.allSatisfy({ $0.units > 0 && $0.units <= 100 && $0.createdAt.timeIntervalSince1970.isFinite && $0.createdAt.timeIntervalSince1970 > 0 && $0.createdAt.timeIntervalSince1970 <= 253402300799 })
            else { throw StockBolusError.storageUnavailable }
            return archive.attempts
        } catch { throw StockBolusError.storageUnavailable }
    }
    func reserve(_ draft: StockBolusDraft) throws {
        let existing = try attempts()
        guard !existing.contains(where: { !$0.phoneReviewCompleted }), !existing.contains(where: { $0.id == draft.id }) else { throw StockBolusError.pendingReview }
        try persist(Array((existing + [StockBolusAttempt(draft)]).suffix(1000)))
    }
    func record(_ id: UUID, submission: StockBolusAttempt.Submission, rejection: APNsBolusRejection? = nil) throws {
        var entries = try attempts()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw StockBolusError.storageUnavailable }
        entries[index].submission = submission; entries[index].appleRejection = rejection; try persist(entries)
    }
    public func finishPhoneReview(_ id: UUID) throws {
        var entries = try attempts()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw StockBolusError.storageUnavailable }
        entries[index].phoneReviewCompleted = true; try persist(entries)
    }
    private func persist(_ attempts: [StockBolusAttempt]) throws {
        let data = try JSONEncoder().encode(Archive(schema: 1, attempts: attempts))
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data("TrioPC.stock-bolus-journal.v1".utf8)).combined else { throw StockBolusError.storageUnavailable }
        try combined.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }
}

private final class StockBolusNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor StockTrioBolusSender {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport?
    public init(transport: Transport? = nil) { self.transport = transport }
    public func send(_ draft: StockBolusDraft, profile: StockTrioProfile, sharedSecret: String, reply: StockTrioReturnInfo,
                     credentials: APNsCredentials, journal: StockBolusJournal, now: Date = Date()) async throws {
        let monotonicStart = ContinuousClock.now
        guard profile.fingerprint == draft.targetFingerprint, profile.teamID == credentials.teamID,
              profile.bundleID != reply.bundleId else { throw StockBolusError.invalidTarget }
        guard draft.createdAt.timeIntervalSince1970.isFinite, draft.createdAt.timeIntervalSince1970 > 0,
              draft.createdAt.timeIntervalSince1970 <= 253402300799,
              now.timeIntervalSince(draft.createdAt) >= 0, now.timeIntervalSince(draft.createdAt) <= 60 else { throw StockBolusError.staleReview }
        let body = try draft.body(sharedSecret: sharedSecret, reply: reply)
        let jwt = try await APNsProviderTokens.shared.token(credentials: credentials, now: now)
        var request = URLRequest(url: URL(string: "https://\(profile.environment.host)/3/device/\(profile.deviceToken)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("bearer " + jwt, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(profile.bundleID, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("0", forHTTPHeaderField: "apns-expiration")
        request.setValue(draft.id.uuidString.lowercased(), forHTTPHeaderField: "apns-id")
        request.httpBody = body
        // Commit before any networking. A crash after this point requires a phone review.
        try await journal.reserve(draft)
        let elapsed = monotonicStart.duration(to: ContinuousClock.now).components
        let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard now.timeIntervalSince(draft.createdAt) + elapsedSeconds <= 60 else { throw StockBolusError.staleReview }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false; configuration.timeoutIntervalForResource = 20
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: configuration, delegate: StockBolusNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let send: Transport = transport ?? { try await session.data(for: $0) }
        let response: URLResponse
        let responseData: Data
        do { (responseData, response) = try await send(request) }
        catch { try? await journal.record(draft.id, submission: .unknown); throw StockBolusError.uncertainTransport }
        guard let http = response as? HTTPURLResponse else {
            try? await journal.record(draft.id, submission: .unknown); throw StockBolusError.uncertainTransport
        }
        if http.statusCode == 200 { try await journal.record(draft.id, submission: .acceptedByApple) }
        else {
            if http.statusCode == 403 { await APNsProviderTokens.shared.invalidate(credentials.identity) }
            let reason = APNsBolusRejection.parse(responseData)
            try await journal.record(draft.id, submission: .rejectedByApple, rejection: reason)
            throw StockBolusError.appleRejected(http.statusCode, reason)
        }
    }
}
