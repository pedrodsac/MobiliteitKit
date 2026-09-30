import Foundation

/// Derived journey metrics, including transfer semantics across in-seat continuations.
public struct JourneySummary: Codable, Hashable, Sendable {
    public let departure: Date
    public let arrival: Date
    public let firstBoarding: Date?
    public let transferCount: Int
    public let transferGaps: [TimeInterval]
    public let walkingDuration: TimeInterval
    public let walkingDistance: Double
    public let crossesBorder: Bool
}

extension Journey {
    public var summary: JourneySummary {
        let rides = legs.enumerated().compactMap { index, leg -> (Int, TransitLeg)? in
            if case let .transit(t) = leg { (index, t) } else { nil }
        }
        let gaps = zip(rides, rides.dropFirst()).compactMap { incoming, outgoing -> TimeInterval? in
            let between = legs[(incoming.0 + 1)..<outgoing.0]
            guard !between.contains(where: { if case .inSeatContinuation = $0 { true } else { false } }) else { return nil }
            return outgoing.1.effectiveDeparture.timeIntervalSince(incoming.1.effectiveArrival)
        }
        func outside(_ coordinate: Coordinate) -> Bool {
            !(49.44...50.19).contains(coordinate.latitude) || !(5.73...6.54).contains(coordinate.longitude)
        }
        let crossBorder = legs.contains { leg in
            switch leg {
            case let .walk(w): outside(w.from.coordinate) || outside(w.to.coordinate)
            case let .transit(t): outside(t.board.stop.coordinate) || outside(t.alight.stop.coordinate)
            case .inSeatContinuation: false
            }
        }
        return .init(departure: effectiveDeparture, arrival: effectiveArrival,
            firstBoarding: rides.first?.1.effectiveDeparture, transferCount: transferCount,
            transferGaps: gaps, walkingDuration: walkingDuration, walkingDistance: walkingDistance,
            crossesBorder: crossBorder)
    }
}
