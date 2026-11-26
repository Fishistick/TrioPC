import Foundation
import CryptoKit

public struct Glucose: Decodable, Identifiable, Sendable {
    public let sgv: Double
    public let date: Double
    public let direction: String?
    public var id: Double { date }
    public var timestamp: Date { Date(timeIntervalSince1970: date / 1000) }
    public var arrow: String {
        switch direction {
        case "DoubleUp": "↑↑"
        case "SingleUp": "↑"
        case "FortyFiveUp": "↗"
        case "Flat": "→"
        case "FortyFiveDown": "↘"
        case "SingleDown": "↓"
        case "DoubleDown": "↓↓"
        default: "—"
        }
    }
}

public struct Treatment: Decodable, Identifiable, Sendable {
    public let id: String
    public let eventType: String?
    public let created_at: String?
    public let insulin: Double?
    public let carbs: Double?
    enum CodingKeys: String, CodingKey { case id = "_id", eventType, created_at, insulin, carbs }
}

public struct Snapshot: Sendable {
    public let glucose: [Glucose]
    public let treatments: [Treatment]
}

public enum ConnectionError: Error, LocalizedError {
    case invalidURL, unauthorized, server(Int), malformedData, redirect
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS Nightscout URL without a token, query, or fragment."
        case .unauthorized: "Nightscout rejected the API secret. Check the connection settings."
        case .server(let code): "Nightscout returned HTTP \(code)."
        case .malformedData: "Nightscout returned data this app could not read."
        case .redirect: "Nightscout redirected the request. Enter its final HTTPS address."
        }
    }
}

// Refuse redirects so authentication is never forwarded to another endpoint.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct NightscoutClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let baseURL: URL
    let secret: String
    private let transport: Transport?
    public init(address: String, secret: String, transport: Transport? = nil) throws {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw ConnectionError.invalidURL }
        baseURL = url
        self.secret = secret
        self.transport = transport
    }

    public func request(path: String, count: Int) -> URLRequest {
        var parts = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "count", value: String(count))]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !secret.isEmpty {
            let hash = Insecure.SHA1.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
            request.setValue(hash, forHTTPHeaderField: "api-secret")
        }
        return request
    }

    public func fetch() async throws -> Snapshot {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let send: Transport = transport ?? { try await session.data(for: $0) }
        async let readings: [Glucose] = load(request(path: "api/v1/entries/sgv.json", count: 288), send: send)
        async let treatments: [Treatment] = load(request(path: "api/v1/treatments.json", count: 30), send: send)
        return try await Snapshot(glucose: readings.sorted { $0.date < $1.date }, treatments: treatments)
    }

    public func fetchResponseHistory() async throws -> ResponseHistoryPage {
        var request = request(path: "api/v1/devicestatus.json", count: ResponseHistoryPage.limit)
        var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        parts.queryItems?.append(URLQueryItem(name: "find[device]", value: "TrioPC-response-v1"))
        request.url = parts.url
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let send: Transport = transport ?? { try await session.data(for: $0) }
        return try ResponseHistoryPage.parse(await loadData(request, send: send))
    }

    public func fetchStockTrioProfile() async throws -> StockTrioProfile {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let send: Transport = transport ?? { try await session.data(for: $0) }
        var request = request(path: "api/v1/profile.json", count: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try StockTrioProfile.parse(await loadData(request, send: send))
    }

    private func load<T: Decodable & Sendable>(_ request: URLRequest, send: Transport) async throws -> T {
        let data = try await loadData(request, send: send)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ConnectionError.malformedData }
    }

    private func loadData(_ request: URLRequest, send: Transport) async throws -> Data {
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.malformedData }
        switch http.statusCode {
        case 200: break
        case 301...399: throw ConnectionError.redirect
        case 401, 403: throw ConnectionError.unauthorized
        default: throw ConnectionError.server(http.statusCode)
        }
        guard data.count <= 2_097_152 else { throw ConnectionError.malformedData }
        return data
    }
}
