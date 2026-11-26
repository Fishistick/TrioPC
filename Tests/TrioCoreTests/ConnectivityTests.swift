import XCTest
@testable import TrioCore

final class ConnectivityTests: XCTestCase {
    func testFetchSortsReadingsAndParsesTreatments() async throws {
        let client = try NightscoutClient(address: "https://example.com", secret: "", transport: { request in
            let json = request.url!.path.contains("entries")
                ? #"[{"sgv":120,"date":2000,"direction":"Flat"},{"sgv":110,"date":1000}]"#
                : #"[{"_id":"synthetic","eventType":"Meal Bolus","insulin":1,"carbs":10}]"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let snapshot = try await client.fetch()
        XCTAssertEqual(snapshot.glucose.map(\.sgv), [110, 120])
        XCTAssertEqual(snapshot.treatments.first?.carbs, 10)
    }

    func testUnauthorizedDoesNotProduceSnapshot() async throws {
        let client = try client(status: 401, body: "{}")
        do { _ = try await client.fetch(); XCTFail("Expected authentication failure") }
        catch TrioCore.ConnectionError.unauthorized { }
    }

    func testRedirectResponseIsRejected() async throws {
        let client = try client(status: 302, body: "")
        do { _ = try await client.fetch(); XCTFail("Expected redirect rejection") }
        catch TrioCore.ConnectionError.redirect { }
    }

    func testMalformedDataDoesNotProduceSnapshot() async throws {
        let client = try client(status: 200, body: "<html>Login</html>")
        do { _ = try await client.fetch(); XCTFail("Expected decoding failure") }
        catch TrioCore.ConnectionError.malformedData { }
    }

    private func client(status: Int, body: String) throws -> NightscoutClient {
        try NightscoutClient(address: "https://example.com", secret: "", transport: { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    func testLegacySuccessIsNotDeliveryConfirmation() throws {
        let data = Data(#"{"command_status":"success","command_type":"bolus","timestamp":1700000000,"aps":{"alert":{"title":"Command Successful","body":"Bolus started"}}}"#.utf8)
        let reply = try LegacyReply.parse(data)
        XCTAssertTrue(reply.interpretation.contains("not verified"))
        XCTAssertEqual(reply.aps.alert.body, "Bolus started")
    }

    func testLegacyFailureDoesNotClaimZeroDelivery() throws {
        let data = Data(#"{"command_status":"failed","command_type":"bolus","timestamp":1700000000,"aps":{"alert":{"title":"Command Failed","body":"Communication error"}}}"#.utf8)
        XCTAssertTrue(try LegacyReply.parse(data).interpretation.contains("Zero delivery is not verified"))
    }

    func testRecoveredRepliesSelectNewestWithoutTreatingSuccessAsCompletion() throws {
        let fixture = #"{"command_status":"success","command_type":"bolus","timestamp":1700000000,"aps":{"alert":{"title":"Command Successful","body":"Bolus started"}}}"#
        let older = try LegacyReply.parse(Data(fixture.utf8))
        let newer = try LegacyReply.parse(Data(fixture.replacingOccurrences(of: "1700000000", with: "1700000010").replacingOccurrences(of: "success", with: "failed").utf8))
        XCTAssertNil(LegacyReply.newest(in: []))
        XCTAssertEqual(LegacyReply.newest(in: [newer, older, newer]), newer)
        XCTAssertEqual(LegacyReply.newest(in: [older, newer]), newer)
        XCTAssertTrue(older.interpretation.contains("not verified"))
        XCTAssertTrue(newer.interpretation.contains("Zero delivery is not verified"))
    }

    func testLegacyReplyRejectsMalformedAndOversizedPayloads() {
        for data in [Data("{}".utf8), Data(repeating: 32, count: 4097),
                     Data(#"{"command_status":"complete","command_type":"bolus","timestamp":1,"aps":{"alert":{"title":"x","body":"x"}}}"#.utf8)] {
            XCTAssertThrowsError(try LegacyReply.parse(data))
        }
    }

    func testUnrepresentableReplyTimestampIsRejected() {
        let data = Data(#"{"command_status":"success","command_type":"bolus","timestamp":1e100,"aps":{"alert":{"title":"x","body":"x"}}}"#.utf8)
        XCTAssertThrowsError(try LegacyReply.parse(data))
    }
}
