import XCTest
import CryptoKit
@testable import TrioCore
@testable import TrioHistoryPublisher

final class ResponseHistoryTests: XCTestCase {
    private let secret = "synthetic-history-secret-for-tests-only-0001"
    private var replyData: Data {
        Data(#"{"command_status":"success","command_type":"bolus","timestamp":1700000000,"aps":{"alert":{"title":"Command Successful","body":"Bolus started"}}}"#.utf8)
    }
    private func event(id: UUID = UUID(), time: Double = 1700000000) throws -> ResponseHistoryEvent {
        try ResponseHistoryEvent(id: id, recordedAt: time, reply: LegacyReply.parse(replyData))
    }

    func testIndependentPhonePublisherInteroperatesWithMacAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("outbox.json")
        let outbox = TrioPCResponseOutbox(storageURL: url)
        let id = UUID()
        try await outbox.enqueue(replyData: replyData, sharedSecret: secret, destination: "https://example.com", id: id, recordedAt: 1700000000)
        let disk = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("Bolus started"))
        XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains(secret))
        let reopened = TrioPCResponseOutbox(storageURL: url)
        let pending = try await reopened.pending(destination: "https://example.com")
        XCTAssertEqual(pending.count, 1)
        let document = TrioPCResponseDocument(envelope: pending[0])
        let page = try ResponseHistoryPage.parse(JSONEncoder().encode([document]))
        let key = try ResponseHistoryKey(sharedSecret: secret)
        let received = try key.open(XCTUnwrap(page.envelopes.first))
        XCTAssertEqual(received.id, id)
        XCTAssertEqual(received.reply.aps.alert.body, "Bolus started")
        XCTAssertTrue(received.reply.interpretation.contains("not verified"))
        try await reopened.acknowledge(id)
        let afterAck = try await TrioPCResponseOutbox(storageURL: url).pending(destination: "https://example.com")
        XCTAssertTrue(afterAck.isEmpty)
    }

    func testWrongSecretTamperingAndEventIDSubstitutionAreRejected() throws {
        let key = try ResponseHistoryKey(sharedSecret: secret)
        let envelope = try key.seal(event())
        XCTAssertThrowsError(try ResponseHistoryKey(sharedSecret: "different-synthetic-secret-for-tests").open(envelope))
        XCTAssertThrowsError(try key.open(ResponseHistoryEnvelope(eventID: UUID(), box: envelope.box)))
        var bytes = try XCTUnwrap(Data(base64Encoded: envelope.box)); bytes[15] ^= 1
        XCTAssertThrowsError(try key.open(ResponseHistoryEnvelope(eventID: envelope.eventID, box: bytes.base64EncodedString())))
        XCTAssertThrowsError(try key.open(ResponseHistoryEnvelope(schema: 2, eventID: envelope.eventID, box: envelope.box)))
    }

    func testDuplicateOutOfOrderRecoveryAndConflictsPreservePriorEvidence() throws {
        let key = try ResponseHistoryKey(sharedSecret: secret)
        let older = try event(time: 1700000000), newer = try event(time: 1700000001)
        var ledger = ResponseHistoryLedger()
        let one = try key.seal(older), two = try key.seal(newer)
        _ = ledger.merge([two, one, two, one], key: key)
        XCTAssertEqual(ledger.events.map(\.id), [newer.id, older.id])
        let conflict = try key.seal(event(id: newer.id, time: 1700000002))
        let result = ledger.merge([conflict], key: key)
        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(ledger.events.first?.recordedAt, newer.recordedAt)
        let cached = try JSONEncoder().encode(ledger.envelopes)
        var reopened = ResponseHistoryLedger()
        _ = reopened.merge(try JSONDecoder().decode([ResponseHistoryEnvelope].self, from: cached), key: key)
        XCTAssertEqual(reopened.events, ledger.events)
    }

    func testDeviceStatusReaderIsReadOnlyFilteredAndAuthenticatedWithoutURLSecret() async throws {
        let client = try NightscoutClient(address: "https://example.com/nightscout", secret: "synthetic-api-secret", transport: { request in
            XCTAssertEqual(request.httpMethod ?? "GET", "GET")
            XCTAssertEqual(request.url?.path, "/nightscout/api/v1/devicestatus.json")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "find[device]" }?.value, "TrioPC-response-v1")
            XCTAssertEqual(query.first { $0.name == "count" }?.value, "500")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "api-secret"))
            XCTAssertFalse(request.url!.absoluteString.contains("synthetic-api-secret"))
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let page = try await client.fetchResponseHistory()
        XCTAssertTrue(page.envelopes.isEmpty)
    }

    func testMalformedEntriesAreCountedAndQueryLimitIsExplicit() throws {
        let data = try JSONSerialization.data(withJSONObject: Array(repeating: ["device": "unrelated"], count: 500))
        let page = try ResponseHistoryPage.parse(data)
        XCTAssertTrue(page.atLimit); XCTAssertEqual(page.ignored, 500); XCTAssertTrue(page.envelopes.isEmpty)
        XCTAssertThrowsError(try ResponseHistoryPage.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try ResponseHistoryPage.parse(Data(repeating: 32, count: 2_097_153)))
    }

    func testServerErrorsDoNotBecomeAnEmptySuccessfulHistory() async throws {
        for status in [401, 403, 302, 500] {
            let client = try NightscoutClient(address: "https://example.com", secret: "", transport: { request in
                (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do { _ = try await client.fetchResponseHistory(); XCTFail("Expected failed read") } catch { }
        }
    }

    func testCorruptPhoneOutboxIsPreservedAndCannotBeOverwritten() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("corrupt-test-outbox".utf8); try original.write(to: url)
        let outbox = TrioPCResponseOutbox(storageURL: url)
        do { try await outbox.enqueue(replyData: replyData, sharedSecret: secret, destination: "https://example.com"); XCTFail("Expected storage failure") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUnauthenticatedRecordsCannotReplaceVerifiedCache() throws {
        let key = try ResponseHistoryKey(sharedSecret: secret)
        var ledger = ResponseHistoryLedger()
        let envelope = try key.seal(event()); _ = ledger.merge([envelope], key: key)
        let result = ledger.merge([ResponseHistoryEnvelope(eventID: envelope.eventID, box: "bad")], key: key)
        XCTAssertEqual(result.invalid, 1); XCTAssertEqual(ledger.events.count, 1)
        XCTAssertThrowsError(try ResponseHistoryKey(sharedSecret: "too short"))
    }

    func testPublisherRequiresMatchingJSONAcknowledgementAndServerBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TrioPCResponseOutbox(storageURL: directory.appendingPathComponent("outbox.json"))
        try await outbox.enqueue(replyData: replyData, sharedSecret: secret, destination: "https://example.com")
        let pending = try await outbox.pending(destination: "https://example.com")
        let envelope = try XCTUnwrap(pending.first)
        XCTAssertTrue(TrioPCResponseDocument.acknowledged(try JSONEncoder().encode([TrioPCResponseDocument(envelope: envelope)]), envelope: envelope))
        XCTAssertFalse(TrioPCResponseDocument.acknowledged(Data("[]".utf8), envelope: envelope))
        XCTAssertFalse(TrioPCResponseDocument.acknowledged(Data("<html>login</html>".utf8), envelope: envelope))
        let mismatched = TrioPCResponseEnvelope(schema: 1, event_id: UUID(), box: envelope.box)
        XCTAssertFalse(TrioPCResponseDocument.acknowledged(try JSONEncoder().encode([TrioPCResponseDocument(envelope: mismatched)]), envelope: envelope))
        do { _ = try await outbox.pending(destination: "https://different.example.com"); XCTFail("Must not forward another server's queue") } catch { }
        let retained = try await outbox.pending(destination: "https://example.com")
        XCTAssertEqual(retained.first?.box, envelope.box)
        XCTAssertThrowsError(try TrioPCResponseOutbox.destinationID(URL(string: "http://example.com")!))
        XCTAssertThrowsError(try TrioPCResponseOutbox.destinationID(URL(string: "https://example.com?token=synthetic")!))
    }

    func testVerifiedButInvalidLegacyPayloadOrTimestampIsRejected() throws {
        let key = try ResponseHistoryKey(sharedSecret: secret)
        XCTAssertThrowsError(try key.open(key.seal(event(time: 0))))
        let invalidReply = try JSONDecoder().decode(LegacyReply.self, from: Data(String(decoding: replyData, as: UTF8.self).replacingOccurrences(of: "success", with: "completed").utf8))
        let invalid = ResponseHistoryEvent(recordedAt: 1700000000, reply: invalidReply)
        XCTAssertThrowsError(try key.open(key.seal(invalid)))
    }

    func testPhoneConnectionTestIsExplicitlyMarkedSynthetic() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = TrioPCResponseOutbox(storageURL: directory.appendingPathComponent("outbox.json"))
        try await outbox.enqueue(replyData: replyData, sharedSecret: secret, destination: "https://example.com", isSynthetic: true)
        let pending = try await outbox.pending(destination: "https://example.com")
        let page = try ResponseHistoryPage.parse(JSONEncoder().encode(pending.map { TrioPCResponseDocument(envelope: $0) }))
        let key = try ResponseHistoryKey(sharedSecret: secret)
        XCTAssertEqual(try key.open(XCTUnwrap(page.envelopes.first)).kind, .synthetic)
    }
}
