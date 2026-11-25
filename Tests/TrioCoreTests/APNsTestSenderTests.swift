import XCTest
import CryptoKit
@testable import TrioCore

private actor RequestCapture {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
    func all() -> [URLRequest] { requests }
}

final class APNsTestSenderTests: XCTestCase {
    private func credentials(_ key: P256.Signing.PrivateKey = .init()) throws -> APNsCredentials {
        try APNsCredentials(teamID: "TEAM000001", keyID: "KEY0000001", privateKeyPEM: key.pemRepresentation)
    }

    func testJWTUsesES256AndVerifiableRawSignature() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try credentials(key).jwt(at: Date(timeIntervalSince1970: 1700000000))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertFalse(jwt.contains("="))
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: String])
        XCTAssertEqual(header, ["alg": "ES256", "kid": "KEY0000001"])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
        XCTAssertEqual(claims["iss"] as? String, "TEAM000001")
        XCTAssertEqual(claims["iat"] as? Int, 1700000000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    func testRejectsInvalidCredentialsWithoutEchoingKey() throws {
        XCTAssertThrowsError(try APNsCredentials(teamID: "bad", keyID: "KEY0000001", privateKeyPEM: "not-a-key"))
        XCTAssertThrowsError(try APNsCredentials(teamID: "TEAM000001", keyID: "KEY0000001", privateKeyPEM: "not-a-key")) {
            XCTAssertEqual($0 as? APNsTestError, .invalidPrivateKey)
            XCTAssertFalse($0.localizedDescription.contains("not-a-key"))
        }
    }

    func testRequestTargetsAppleWithSyntheticPayloadOnly() async throws {
        let capture = RequestCapture()
        let sender = APNsTestSender(transport: { request in
            await capture.add(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!)
        })
        let test = LoopbackTest()
        try await sender.send(test, to: MacTestRecipient(token: "ab12", topic: "com.example.mac", environment: .development), credentials: credentials())
        let requests = await capture.all()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/ab12")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.example.mac")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "alert")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-id"), test.id.uuidString.lowercased())
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try LoopbackReceipt.parse(body).id, test.id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        for key in ["command_type", "bolus_amount", "encrypted_data", "return_notification"] { XCTAssertNil(json[key]) }
    }

    func testProviderTokenIsReusedForSameCredentials() async throws {
        let capture = RequestCapture()
        let sender = APNsTestSender(transport: { request in
            await capture.add(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let creds = try credentials()
        let recipient = try MacTestRecipient(token: "ab12", topic: "com.example.mac", environment: .production)
        let now = Date()
        try await sender.send(LoopbackTest(), to: recipient, credentials: creds, now: now)
        try await sender.send(LoopbackTest(), to: recipient, credentials: creds, now: now.addingTimeInterval(60))
        let requests = await capture.all()
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "authorization"), requests[1].value(forHTTPHeaderField: "authorization"))
        XCTAssertEqual(requests[0].url?.host, "api.push.apple.com")
    }

    func testNetworkFailureDoesNotAutomaticallyRetry() async throws {
        let capture = RequestCapture()
        let sender = APNsTestSender(transport: { request in
            await capture.add(request)
            throw URLError(.timedOut)
        })
        do {
            try await sender.send(LoopbackTest(), to: MacTestRecipient(token: "ab12", topic: "com.example.mac", environment: .development), credentials: credentials())
            XCTFail("Expected uncertain transport")
        } catch { XCTAssertEqual(error as? APNsTestError, .transportUncertain) }
        let requests = await capture.all()
        XCTAssertEqual(requests.count, 1)
    }

    func testUnexpectedServerTextIsNotExposed() async throws {
        let sender = APNsTestSender(transport: { request in
            (Data(#"{"reason":"secret-response-example"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        do {
            try await sender.send(LoopbackTest(), to: MacTestRecipient(token: "ab12", topic: "com.example.mac", environment: .development), credentials: credentials())
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? APNsTestError, .rejected(403, "UnrecognizedResponse")) }
    }

    func testRecipientRejectsHeaderAndPathInjection() {
        for token in ["", "../abc", "abc", "nothex"] {
            XCTAssertThrowsError(try MacTestRecipient(token: token, topic: "com.example.mac", environment: .development))
        }
        XCTAssertThrowsError(try MacTestRecipient(token: "ab12", topic: "com.example\nheader", environment: .development))
    }

    func testReturnBeforeHTTPResponseAndDuplicatesStayConfirmed() {
        var test = LoopbackTest()
        test.receive(id: UUID())
        XCTAssertEqual(test.state, .sending)
        test.receive(id: test.id)
        test.accepted(); test.unknown(); test.rejected(); test.receive(id: test.id)
        XCTAssertEqual(test.state, .received)
    }

    func testLateMatchingReturnCanResolveTimeout() {
        var test = LoopbackTest()
        test.accepted(); test.unknown()
        XCTAssertEqual(test.state, .unconfirmed)
        test.receive(id: test.id)
        XCTAssertEqual(test.state, .received)
    }

    func testAppleAcceptanceAloneDoesNotConfirmReceipt() {
        var test = LoopbackTest()
        test.accepted()
        XCTAssertEqual(test.state, .awaitingReturn)
        XCTAssertTrue(test.waiting)
    }

    func testProviderTokenRenewsAfterFiftyMinutes() async throws {
        let capture = RequestCapture()
        let sender = APNsTestSender(transport: { request in
            await capture.add(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let creds = try credentials()
        let recipient = try MacTestRecipient(token: "ab12", topic: "com.example.mac", environment: .development)
        let now = Date()
        try await sender.send(LoopbackTest(), to: recipient, credentials: creds, now: now)
        try await sender.send(LoopbackTest(), to: recipient, credentials: creds, now: now.addingTimeInterval(51 * 60))
        let requests = await capture.all()
        XCTAssertNotEqual(requests[0].value(forHTTPHeaderField: "authorization"), requests[1].value(forHTTPHeaderField: "authorization"))
    }

    private func decode(_ value: String) throws -> Data {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: base64))
    }
}
