import Foundation

/// A legacy Trio notification is advisory. It lacks command identity and delivery evidence.
/// Never use it to mutate command execution state or infer zero/full insulin delivery.
public struct LegacyReply: Decodable, Sendable, Equatable {
    public let commandStatus: String
    public let commandType: String
    public let timestamp: TimeInterval
    public let aps: APS
    public struct APS: Decodable, Sendable, Equatable {
        public let alert: Alert
    }
    public struct Alert: Decodable, Sendable, Equatable {
        public let title: String
        public let body: String
    }
    enum CodingKeys: String, CodingKey {
        case commandStatus = "command_status", commandType = "command_type", timestamp, aps
    }
    public enum ParseError: Error { case invalid }

    public static func parse(_ data: Data) throws -> LegacyReply {
        guard data.count <= 4096 else { throw ParseError.invalid }
        let reply = try JSONDecoder().decode(Self.self, from: data)
        guard ["success", "failed"].contains(reply.commandStatus),
              ["bolus", "meal", "temp_target", "cancel_temp_target", "start_override", "cancel_override"].contains(reply.commandType),
              reply.timestamp.isFinite, reply.timestamp > 0, reply.timestamp <= 253402300799,
              reply.aps.alert.title.count <= 256, reply.aps.alert.body.count <= 2048 else { throw ParseError.invalid }
        return reply
    }

    public var interpretation: String {
        commandStatus == "success"
            ? "Trio reported command processing. Delivered insulin is not verified."
            : "Trio reported a command error. Zero delivery is not verified."
    }
}
