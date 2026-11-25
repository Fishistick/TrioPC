import XCTest
@testable import TrioCore

final class TrioCoreTests: XCTestCase {
    func testAPISecretIsHashedInHeaderAndNeverInURL() throws {
        let client = try NightscoutClient(address: "https://example.com/nightscout", secret: "hello")
        let request = client.request(path: "api/v1/entries/sgv.json", count: 288)
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
        XCTAssertEqual(request.url?.path, "/nightscout/api/v1/entries/sgv.json")
        XCTAssertFalse(request.url!.absoluteString.contains("hello"))
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testRejectsInsecureAndCredentialBearingAddresses() {
        for address in ["http://example.com", "https://u:p@example.com", "https://example.com?token=secret", "https://example.com/#secret", "not a url"] {
            XCTAssertThrowsError(try NightscoutClient(address: address, secret: ""))
        }
    }

    func testLostReplyCanReconcileWithoutAnotherSubmission() throws {
        var command = try SimulatedCommand(units: 2)
        let id = command.id
        try command.apply(.submitted, revision: 1)
        try command.apply(.uncertain, revision: 2)
        command = try JSONDecoder().decode(SimulatedCommand.self, from: JSONEncoder().encode(command))
        try command.apply(.completed, delivered: 2, revision: 3)
        XCTAssertEqual(command.id, id)
        XCTAssertEqual(command.state, .completed)
        XCTAssertEqual(command.deliveredUnits, 2)
    }

    func testDuplicateAndOutOfOrderResponsesCannotRegressState() throws {
        var command = try SimulatedCommand(units: 2)
        try command.apply(.submitted, revision: 1)
        try command.apply(.started, revision: 2)
        try command.apply(.submitted, revision: 1)
        try command.apply(.rejected, revision: 2)
        XCTAssertEqual(command.state, .started)
        XCTAssertThrowsError(try command.apply(.rejected, revision: 3))
    }

    func testPartialDeliveryAndTerminalStateArePreserved() throws {
        var command = try SimulatedCommand(units: 3)
        try command.apply(.submitted, revision: 1)
        try command.apply(.partial, delivered: 1.5, revision: 2)
        XCTAssertEqual(command.deliveredUnits, 1.5)
        XCTAssertThrowsError(try command.apply(.completed, delivered: 3, revision: 3))
    }

    func testCompletionRequiresEntireRequestedAmount() throws {
        var command = try SimulatedCommand(units: 3)
        try command.apply(.submitted, revision: 1)
        XCTAssertThrowsError(try command.apply(.completed, delivered: 2, revision: 2))
        XCTAssertThrowsError(try command.apply(.partial, delivered: 4, revision: 2))
        XCTAssertEqual(command.state, .submitted)
    }
}
