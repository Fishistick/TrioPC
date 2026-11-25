import SwiftUI
import TrioCore

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
    private var generation = 0
    private var activeClient: NightscoutClient?

    init() { loadDemo() }

    var latest: Glucose? { readings.last }
    func formatted(_ value: Double) -> String {
        mmol ? String(format: "%.1f", value / 18) : String(format: "%.0f", value)
    }
    var unit: String { mmol ? "mmol/L" : "mg/dL" }

    func loadDemo() {
        generation += 1; activeClient = nil; refreshing = false
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
            generation += 1
            activeClient = client
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

// URL is validated before the client is constructed.
enum ConnectionError: LocalizedError {
    case invalidURL
    var errorDescription: String? { "Enter an HTTPS Nightscout address without credentials, query parameters or a fragment." }
}
