import SwiftUI
import TrioCore
import CryptoKit

@MainActor
final class AppModel: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey: "nightscoutAddress") ?? ""
    @Published var secret = ""
    @Published var mmol = UserDefaults.standard.object(forKey: "mmol") as? Bool ?? true
    @Published var readings: [Glucose] = []
    @Published var treatments: [Treatment] = []
    @Published var error: String?
    @Published var refreshing = false
    @Published var demo = true
    @Published var lastSync: Date?
    @Published var command: SimulatedCommand?
    @Published var commandError: String?
    @Published var historySharedSecret = ""
    @Published private(set) var historyEvents: [ResponseHistoryEvent] = []
    @Published private(set) var historyMessage = "Pair response history with Trio’s shared secret after connecting Nightscout."
    @Published private(set) var historyRefreshing = false
    @Published private(set) var historyPaired = false
    @Published private(set) var historyLastSync: Date?
    private var historyKey: ResponseHistoryKey?
    private var historyLedger = ResponseHistoryLedger()
    private var activeServer: String?
    private var attemptedResume = false
    private static let historyService = "com.fishistick.TrioPC.response-history"
    private var generation = 0
    private var activeClient: NightscoutClient?

    init() { loadDemo(remember: false) }

    var latest: Glucose? { readings.last }
    func formatted(_ value: Double) -> String {
        mmol ? String(format: "%.1f", value / 18) : String(format: "%.0f", value)
    }
    var unit: String { mmol ? "mmol/L" : "mg/dL" }

    func loadDemo(remember: Bool = true) {
        if remember { UserDefaults.standard.set(false, forKey: "nightscoutAutoConnect") }
        generation += 1; activeClient = nil; refreshing = false
        activeServer = nil; resetHistory()
        demo = true; lastSync = nil; error = nil; treatments = []
        let now = Date()
        let values = (0..<72).map { index -> [String: Any] in
            let wave = sin(Double(index) / 9.0) * 22.0
            let ripple = cos(Double(index) / 4.0) * 7.0
            let value = 118.0 + wave + ripple
            let timestamp = now.addingTimeInterval(Double(index - 71) * 300).timeIntervalSince1970 * 1000
            return ["sgv": value, "date": timestamp, "direction": "Flat"]
        }
        readings = (try? JSONDecoder().decode([Glucose].self, from: JSONSerialization.data(withJSONObject: values))) ?? []
    }

    func resumeSavedConnection() async {
        guard !attemptedResume else { return }; attemptedResume = true
        guard !address.isEmpty, UserDefaults.standard.object(forKey: "nightscoutAutoConnect") as? Bool != false else { return }
        do { secret = try Keychain.read(); await connect() }
        catch { self.error = "Could not restore the Nightscout connection. Open Connection settings." }
    }

    func readSavedSecret() {
        do { secret = try Keychain.read() }
        catch { self.error = error.localizedDescription }
    }

    func connect() async {
        do {
            let url = try Self.validatedURL(address)
            let client = try NightscoutClient(address: url.absoluteString, secret: secret)
            try Keychain.save(secret)
            UserDefaults.standard.set(url.absoluteString, forKey: "nightscoutAddress")
            UserDefaults.standard.set(mmol, forKey: "mmol")
            UserDefaults.standard.set(true, forKey: "nightscoutAutoConnect")
            generation += 1
            refreshing = false
            activeClient = client
            activeServer = url.absoluteString
            resetHistory(); loadSavedHistorySecret()
            demo = false; readings = []; treatments = []; lastSync = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw ConnectionError.invalidURL }
        return url
    }

    func refresh() async {
        guard !refreshing, !demo, let client = activeClient else { return }
        refreshing = true
        let startedGeneration = generation
        defer { if generation == startedGeneration { refreshing = false } }
        do {
            let snapshot = try await client.fetch()
            guard generation == startedGeneration else { return }
            readings = snapshot.glucose; treatments = snapshot.treatments
            lastSync = Date(); error = nil
        } catch {
            guard generation == startedGeneration else { return }
            self.error = "Unable to refresh Nightscout. Check the server, HTTPS certificate and API secret. Previously fetched data may be old."
        }
        await refreshResponseHistory()
    }

    private func resetHistory() {
        historyKey = nil; historyLedger = ResponseHistoryLedger(); historyEvents = []
        historySharedSecret = ""; historyPaired = false; historyRefreshing = false; historyLastSync = nil
        historyMessage = "Pair response history with Trio’s shared secret after connecting Nightscout."
    }

    private var historyAccount: String? {
        activeServer.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
    private func cacheName(key: ResponseHistoryKey, account: String) -> String {
        "responseHistory.v1." + account + "." + key.cacheIdentity
    }

    func saveHistorySecret() async {
        guard let account = historyAccount else { historyMessage = "Connect Nightscout first."; return }
        do {
            let key = try ResponseHistoryKey(sharedSecret: historySharedSecret)
            try Keychain.save(historySharedSecret, service: Self.historyService, account: account)
            historySharedSecret = ""; installHistoryKey(key, account: account)
            await refreshResponseHistory()
        } catch { historyMessage = "Could not save the history secret. Use the exact Trio shared secret, at least 32 characters." }
    }

    private func loadSavedHistorySecret() {
        guard let account = historyAccount else { return }
        do {
            let secret = try Keychain.read(service: Self.historyService, account: account)
            guard !secret.isEmpty else { return }
            installHistoryKey(try ResponseHistoryKey(sharedSecret: secret), account: account)
        } catch { historyMessage = "Could not load the saved history secret. Pair history again." }
    }

    private func installHistoryKey(_ key: ResponseHistoryKey, account: String) {
        historyKey = key; historyPaired = true; historyLedger = ResponseHistoryLedger(); historyLastSync = nil
        if let data = UserDefaults.standard.data(forKey: cacheName(key: key, account: account)), data.count <= 8_388_608,
           let envelopes = try? JSONDecoder().decode([ResponseHistoryEnvelope].self, from: data), envelopes.count <= 1000 {
            _ = historyLedger.merge(envelopes, key: key)
        }
        historyEvents = historyLedger.events
        historyMessage = "History paired. Checking Nightscout; cached responses may be old."
    }

    func forgetHistorySecret() {
        guard let account = historyAccount else { return }
        do {
            try Keychain.save("", service: Self.historyService, account: account)
            if let key = historyKey { UserDefaults.standard.removeObject(forKey: cacheName(key: key, account: account)) }
            resetHistory()
        } catch { historyMessage = "Could not remove the history secret from Keychain." }
    }

    func stockTrioProfile() async throws -> (StockTrioProfile, String) {
        guard !demo, let client = activeClient, let account = historyAccount else { throw StockBolusError.invalidTarget }
        let requestedGeneration = generation
        let profile = try await client.fetchStockTrioProfile()
        guard requestedGeneration == generation else { throw StockBolusError.invalidTarget }
        return (profile, account)
    }

    var bolusReadingIsFresh: Bool {
        guard !demo, let latest else { return false }
        let age = Date().timeIntervalSince(latest.timestamp)
        return age >= -60 && age <= 600
    }

    func refreshResponseHistory() async {
        guard !historyRefreshing, let client = activeClient, let account = historyAccount else { return }
        let keyAtStart = historyKey
        historyRefreshing = true
        let startedGeneration = generation
        defer { if generation == startedGeneration { historyRefreshing = false } }
        do {
            let page = try await client.fetchResponseHistory()
            guard generation == startedGeneration, historyKey?.cacheIdentity == keyAtStart?.cacheIdentity else { return }
            guard let key = keyAtStart else {
                historyLastSync = Date()
                historyMessage = "Nightscout’s history endpoint is reachable. Pair the Trio shared secret to verify responses. \(page.envelopes.count) encrypted records found."
                if page.atLimit { historyMessage += " The query limit was reached; older responses may be missing." }
                return
            }
            let result = historyLedger.merge(page.envelopes, key: key)
            historyEvents = historyLedger.events
            let data = try JSONEncoder().encode(historyLedger.envelopes)
            guard data.count <= 8_388_608 else { throw ResponseHistoryError.malformed }
            UserDefaults.standard.set(data, forKey: cacheName(key: key, account: account))
            historyLastSync = Date()
            historyMessage = historyEvents.isEmpty
                ? "No verified responses found. The separate Trio history patch must be installed and enabled on your phone."
                : "Recovered \(historyEvents.count) unique advisory responses. Up to 1,000 are retained locally."
            if page.atLimit { historyMessage += " The server returned the 500-record limit; older responses may be missing." }
            if result.invalid + result.conflicts + page.ignored > 0 {
                historyMessage += " \(result.invalid + result.conflicts + page.ignored) records were ignored or conflicted. Check pairing and phone patch version."
            }
            if result.evicted > 0 { historyMessage += " Older local records were removed at the retention limit." }
        } catch {
            guard generation == startedGeneration else { return }
            historyMessage = "Response history could not refresh. Check Nightscout access and pairing. Cached responses may be old."
        }
    }

    func simulate(units: String) {
        do {
            guard command == nil || command?.state.terminal == true else {
                commandError = "Resolve or reset the current simulation first."; return
            }
            guard let amount = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")) else { throw CommandError.invalidAmount }
            command = try SimulatedCommand(units: amount)
            advance(.submitted)
        } catch { commandError = "Enter a simulation amount greater than 0 and at most 25 U." }
    }

    func advance(_ state: CommandState) {
        guard var updated = command else { return }
        do {
            let delivered: Decimal? = state == .completed ? updated.requestedUnits : (state == .partial ? updated.requestedUnits / 2 : nil)
            try updated.apply(state, delivered: delivered, revision: updated.revision + 1)
            command = updated; commandError = nil
        } catch { commandError = "That simulated transition is not allowed." }
    }
}

enum ConnectionError: LocalizedError {
    case invalidURL
    var errorDescription: String? { "Enter an HTTPS Nightscout address without credentials, query parameters or a fragment." }
}
