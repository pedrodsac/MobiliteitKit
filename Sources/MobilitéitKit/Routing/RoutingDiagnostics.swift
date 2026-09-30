import Foundation

/// Per-operation wall-clock measurements; cumulative work counters remain in RoutingMetrics.
public struct RoutingDiagnostics: Hashable, Sendable {
    public enum Stage: String, Hashable, Sendable, Codable {
        case snapshotPreparation, endpoints, realtime, boardFetch, schedulePreparation
        case boardMatching, raptor, walkingTransfers, candidateBuilding, directWalkingWait
        case geometry, resultAssembly, timetableReadiness, graphPreparation, adapterMapping
        case publication, firstRender
    }
    public let requestID: UUID
    public var milliseconds: [Stage: Double] = [:]
    public var totalMilliseconds: Double = 0
    public init(requestID: UUID = UUID()) { self.requestID = requestID }
    public mutating func record(_ stage: Stage, since start: ContinuousClock.Instant) {
        milliseconds[stage, default: 0] += Self.elapsed(since: start)
    }
    public static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
