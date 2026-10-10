import Foundation

/// A continuously available station connection carried inside an access or
/// transfer path. It consumes transfer time without creating a scheduled trip.
public struct WalkingRouteSegment: Hashable, Sendable {
    public enum Mode: Hashable, Sendable { case walking, funicular }
    public let mode: Mode
    public let name: String?
    public let originLabel: String?
    public let destinationLabel: String?
    public let durationSeconds: Int
    public let distanceMeters: Double
    public let polyline: [Coordinate]

    public init(mode: Mode, name: String? = nil, originLabel: String? = nil,
                destinationLabel: String? = nil, durationSeconds: Int,
                distanceMeters: Double, polyline: [Coordinate]) {
        self.mode = mode; self.name = name
        self.originLabel = originLabel; self.destinationLabel = destinationLabel
        self.durationSeconds = durationSeconds; self.distanceMeters = distanceMeters
        self.polyline = polyline
    }
}

extension WalkingLeg {
    var connectionDuration: TimeInterval {
        Double(segments.filter { $0.mode != .walking }.reduce(0) { $0 + $1.durationSeconds })
    }
    var pedestrianDuration: TimeInterval { max(0, duration - connectionDuration) }
    var pedestrianDistance: Double {
        max(0, distanceMeters - segments.filter { $0.mode != .walking }.reduce(0) { $0 + $1.distanceMeters })
    }
    var hasValidSegments: Bool {
        guard !segments.isEmpty else { return true }
        guard segments.allSatisfy({ $0.durationSeconds >= 0 && $0.distanceMeters.isFinite
            && $0.distanceMeters >= 0 && $0.polyline.count >= 2
            && $0.polyline.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite } }),
            abs(Double(segments.reduce(0) { $0 + $1.durationSeconds }) - duration) <= 1,
            abs(segments.reduce(0) { $0 + $1.distanceMeters } - distanceMeters) <= 1,
            segments.first?.polyline.first == from.coordinate,
            segments.last?.polyline.last == to.coordinate else { return false }
        return zip(segments, segments.dropFirst()).allSatisfy { $0.polyline.last == $1.polyline.first }
    }
}
