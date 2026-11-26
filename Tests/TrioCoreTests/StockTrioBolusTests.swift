import XCTest
import CryptoKit
@testable import TrioCore

private actor BolusRequestCapture {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
    func all() -> [URLRequest] { requests }
}

final class StockTrioBolusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1700000000)
    private let secret = "synthetic-stock-trio-secret"
    private func profile(team: String = "TEAM000001", production: Bool = false) throws -> StockTrioProfile {
        let data = try JSONSerialization.data(withJSONObject: [["bundleIdentifier": "com.example.trio", "deviceToken": "ab12",
            "teamID": team, "isAPNSProduction": production, "mills": 1700000000000] as [String: Any]])
        return try StockTrioProfile.parse(data, now: now)
    }
    private func draft(profile: StockTrioProfile? = nil, time: Date? = nil) throws -> StockBolusDraft {
        try StockBolusDraft(amount: "1.25", limits: StockBolusLimits(maximum: "2", increment: "0.05"), profile: profile ?? self.profile(), now: time ?? now)
    }
    private func credentials() throws -> (APNsCredentials, StockTrioReturnInfo) {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        return (try APNsCredentials(teamID: "TEAM000001", keyID: "KEY0000001", privateKeyPEM: pem),
            try StockTrioReturnInfo(token: "cd34", bundleID: "com.example.mac", environment: .development,
                teamID: "TEAM000001", keyID: "KEY0000001", pem: pem))
    }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    func testManualAmountRequiresExactIncrementWithoutRounding() throws {
        let limits = try StockBolusLimits(maximum: "2", increment: "0.05")
        XCTAssertEqual(try limits.amount("1.25"), Decimal(string: "1.25"))
        for invalid in ["0", "-1", "1.23", "2.05", "1,25", "1e1", "1.2.5", " 1", "NaN", "0.0001"] {
            XCTAssertThrowsError(try limits.amount(invalid))
        }
        XCTAssertThrowsError(try StockBolusLimits(maximum: "0", increment: "0.05"))
        XCTAssertThrowsError(try StockBolusLimits(maximum: "2", increment: "0"))
    }

    func testPayloadMatchesStockTrioAndContainsNoClearDoseOrReturnKey() throws {
        let (_, reply) = try credentials()
        let draft = try draft()
        let data = try draft.body(sharedSecret: secret, reply: reply)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["aps", "encrypted_data"])
        let aps = try XCTUnwrap(root["aps"] as? [String: Any])
        XCTAssertEqual(aps["content-available"] as? Int, 1)
        let combined = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(root["encrypted_data"] as? String)))
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [String: Any])
        XCTAssertEqual(payload["command_type"] as? String, "bolus")
        XCTAssertEqual(payload["bolus_amount"] as? Double, 1.25)
        XCTAssertEqual(payload["timestamp"] as? Double, now.timeIntervalSince1970)
        XCTAssertNil(payload["command_id"])
        XCTAssertNil(payload["scheduled_time"])
        let callback = try XCTUnwrap(payload["return_notification"] as? [String: Any])
        XCTAssertEqual(Set(callback.keys), ["production_environment", "device_token", "bundle_id", "team_id", "key_id", "apns_key"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE KEY"))
    }

    func testSubmissionIsJournaledBeforeNetworkAndNeverMeansCompleted() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.enc")
        let journal = try StockBolusJournal(url: url, keyData: Data(repeating: 7, count: 32))
        let draft = try draft(); let profile = try profile(); let (credentials, reply) = try credentials()
        let sender = StockTrioBolusSender(transport: { request in
            let recorded = try await journal.attempts()
            XCTAssertEqual(recorded.first?.id, draft.id)
            XCTAssertEqual(recorded.first?.submission, .attempting)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), "0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), profile.bundleID)
            XCTAssertNil(request.value(forHTTPHeaderField: "apns-collapse-id"))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        try await sender.send(draft, profile: profile, sharedSecret: secret, reply: reply, credentials: credentials, journal: journal, now: now)
        let records = try await journal.attempts()
        XCTAssertEqual(records.first?.submission, .acceptedByApple)
        XCTAssertEqual(records.first?.phoneReviewCompleted, false)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(profile.bundleID))
    }

    func testNetworkTimeoutSendsOnceAndBlocksDuplicateAndNewAttempt() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try StockBolusJournal(url: directory.appendingPathComponent("journal.enc"), keyData: Data(repeating: 8, count: 32))
        let capture = BolusRequestCapture(); let (credentials, reply) = try credentials(); let profile = try profile(); let draft = try draft()
        let sender = StockTrioBolusSender(transport: { request in await capture.add(request); throw URLError(.timedOut) })
        for candidate in [draft, draft, try self.draft()] {
            do { try await sender.send(candidate, profile: profile, sharedSecret: secret, reply: reply, credentials: credentials, journal: journal, now: now); XCTFail("Expected block or unknown outcome") } catch { }
        }
        let requests = await capture.all(); XCTAssertEqual(requests.count, 1)
        let records = try await journal.attempts(); XCTAssertEqual(records.first?.submission, .unknown)
        XCTAssertEqual(records.first?.phoneReviewCompleted, false)
    }

    func testExpiredReviewAndWrongTargetAreRejectedBeforeNetworking() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try StockBolusJournal(url: directory.appendingPathComponent("journal.enc"), keyData: Data(repeating: 8, count: 32))
        let capture = BolusRequestCapture(); let (credentials, reply) = try credentials(); let profile = try profile()
        let sender = StockTrioBolusSender(transport: { request in await capture.add(request); throw URLError(.badURL) })
        do { try await sender.send(draft(time: now.addingTimeInterval(-61)), profile: profile, sharedSecret: secret, reply: reply, credentials: credentials, journal: journal, now: now); XCTFail() } catch { }
        do { try await sender.send(draft(), profile: self.profile(team: "OTHER00001"), sharedSecret: secret, reply: reply, credentials: credentials, journal: journal, now: now); XCTFail() } catch { }
        let requests = await capture.all(); XCTAssertTrue(requests.isEmpty)
        let records = try await journal.attempts(); XCTAssertTrue(records.isEmpty)
    }

    func testPersistedInterruptedAttemptRestoresBlockedAndPhoneReviewIsNotDeliveryEvidence() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.enc"), recovered = directory.appendingPathComponent("recovered.enc")
        let key = Data(repeating: 8, count: 32), original = try draft()
        let journal = try StockBolusJournal(url: first, keyData: key)
        try await journal.reserve(original)
        try FileManager.default.copyItem(at: first, to: recovered)
        let reopened = try StockBolusJournal(url: recovered, keyData: key)
        do { try await reopened.reserve(draft()); XCTFail("Restart cannot unblock an interrupted attempt") } catch { }
        try await reopened.finishPhoneReview(original.id)
        let records = try await reopened.attempts()
        XCTAssertEqual(records.first?.submission, .attempting)
        XCTAssertEqual(records.first?.phoneReviewCompleted, true)
        do { try await reopened.reserve(original); XCTFail("Same attempt ID cannot be reused after review") } catch { }
        try await reopened.reserve(draft())
    }

    func testCorruptionWrongKeyAndAnotherProcessLockFailClosed() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.enc"), key = Data(repeating: 8, count: 32)
        let journal = try StockBolusJournal(url: url, keyData: key)
        XCTAssertThrowsError(try StockBolusJournal(url: url, keyData: key))
        try await journal.reserve(draft())
        let wrongURL = directory.appendingPathComponent("wrong-key.enc")
        try FileManager.default.copyItem(at: url, to: wrongURL)
        let wrongKey = try StockBolusJournal(url: wrongURL, keyData: Data(repeating: 9, count: 32))
        do { _ = try await wrongKey.attempts(); XCTFail("A missing or wrong encryption key cannot reset the journal") } catch { }
        try Data("corrupt-encrypted-journal".utf8).write(to: url)
        do { _ = try await journal.attempts(); XCTFail("Corrupt journal must block") } catch { }
        do { try await journal.reserve(draft()); XCTFail("Corrupt journal cannot be overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), Data("corrupt-encrypted-journal".utf8))
    }

    func testAppleRejectionStillRequiresExplicitPhoneReview() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try StockBolusJournal(url: directory.appendingPathComponent("journal.enc"), keyData: Data(repeating: 8, count: 32))
        let (credentials, reply) = try credentials(); let profile = try profile(); let draft = try draft()
        let capture = BolusRequestCapture()
        let sender = StockTrioBolusSender(transport: { request in
            await capture.add(request)
            return (Data(#"{"reason":"BadEnvironmentKeyIdInToken"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        do { try await sender.send(draft, profile: profile, sharedSecret: secret, reply: reply, credentials: credentials, journal: journal, now: now); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("BadEnvironmentKeyIdInToken")) }
        let records = try await journal.attempts()
        XCTAssertEqual(records.first?.submission, .rejectedByApple); XCTAssertEqual(records.first?.phoneReviewCompleted, false)
        XCTAssertEqual(records.first?.appleRejection, .badEnvironmentKeyIdInToken)
        let calls = await capture.all(); XCTAssertEqual(calls.count, 1)
        do { try await sender.send(try self.draft(), profile: profile, sharedSecret: secret, reply: reply, credentials: credentials, journal: journal, now: now); XCTFail() } catch { }
        let stillOneCall = await capture.all(); XCTAssertEqual(stillOneCall.count, 1)
    }

    func testAppleReasonsAreAllowlistedAndOldRecordsRemainReadable() throws {
        XCTAssertEqual(APNsBolusRejection.parse(Data(#"{"reason":"InvalidProviderToken"}"#.utf8)), .invalidProviderToken)
        for text in [#"{"reason":"private-server-content"}"#, "not JSON", String(repeating: "x", count: 4097)] {
            XCTAssertNil(APNsBolusRejection.parse(Data(text.utf8)))
        }
        let record = StockBolusAttempt(try draft())
        let encoded = try JSONEncoder().encode(record)
        let old = try JSONDecoder().decode(StockBolusAttempt.self, from: encoded)
        XCTAssertNil(old.appleRejection)
        XCTAssertFalse(old.phoneReviewCompleted)
    }

    func testProfileReadOnlyFetchAndStrictMetadata() async throws {
        let valid = #"[{"bundleIdentifier":"com.example.trio","deviceToken":"ab12","teamID":"TEAM000001","isAPNSProduction":false,"mills":1700000000000}]"#
        XCTAssertThrowsError(try StockTrioProfile.parse(Data(valid.replacingOccurrences(of: "false", with: "1").utf8), now: now))
        XCTAssertThrowsError(try StockTrioProfile.parse(Data("[]".utf8), now: now))
        let client = try NightscoutClient(address: "https://example.com/ns", secret: "synthetic-api-secret", transport: { request in
            XCTAssertEqual(request.httpMethod ?? "GET", "GET")
            XCTAssertEqual(request.url?.path, "/ns/api/v1/profile.json")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "1")
            return (Data(valid.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let fetched = try await client.fetchStockTrioProfile()
        XCTAssertEqual(fetched.bundleID, "com.example.trio")
    }
}
