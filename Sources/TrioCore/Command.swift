import Foundation

public enum CommandState: String, Codable, CaseIterable, Sendable {
    case prepared, submitted, started, uncertain, rejected, partial, completed
    public var label: String {
        switch self {
        case .prepared: "Prepared"
        case .submitted: "Submitted · awaiting Trio"
        case .started: "Started · awaiting pump result"
        case .uncertain: "Outcome unknown · do not resend"
        case .rejected: "Rejected before delivery"
        case .partial: "Stopped · partial delivery"
        case .completed: "Completed · simulated pump result"
        }
    }
    public var terminal: Bool { [.rejected, .partial, .completed].contains(self) }
}

/// Simulator model only. It never invokes the separate stock-Trio bolus sender.
public struct SimulatedCommand: Codable, Identifiable, Sendable {
    public let id: UUID
    public let requestedUnits: Decimal
    public let createdAt: Date
    public private(set) var state: CommandState = .prepared
    public private(set) var deliveredUnits: Decimal?
    public private(set) var revision: Int = 0

    public init(units: Decimal) throws {
        guard units > 0, units <= 25 else { throw CommandError.invalidAmount }
        id = UUID(); requestedUnits = units; createdAt = Date()
    }

    public mutating func apply(_ next: CommandState, delivered: Decimal? = nil, revision incoming: Int) throws {
        guard incoming > revision else { return } // duplicate/out-of-order event
        guard !state.terminal else { throw CommandError.finalized }
        let allowed: Bool = switch state {
        case .prepared: next == .submitted
        case .submitted: [.started, .uncertain, .rejected, .partial, .completed].contains(next)
        case .started, .uncertain: [.uncertain, .partial, .completed, .started].contains(next)
        default: false
        }
        guard allowed else { throw CommandError.invalidTransition }
        if next == .partial || next == .completed {
            guard let delivered, delivered >= 0, delivered <= requestedUnits,
                  (next != .completed || delivered == requestedUnits),
                  (next != .partial || delivered < requestedUnits) else { throw CommandError.invalidAmount }
        } else if delivered != nil { throw CommandError.invalidAmount }
        state = next; deliveredUnits = delivered; revision = incoming
    }
}

public enum CommandError: Error { case invalidAmount, finalized, invalidTransition }
