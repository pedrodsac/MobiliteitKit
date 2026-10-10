import Foundation

/// A UI-independent timing projection, also usable for persisted itineraries.
public struct JourneyTimingLeg: Sendable {
    public enum Kind: Sendable { case walk, transit, continuation }
    public let kind: Kind
    public let departure: Date?
    public let arrival: Date?
    public let originStopID: String?
    public let destinationStopID: String?
    public let requiredTransferSeconds: Int?
    public let walkingEvidence: WalkingEvidence
    public init(kind: Kind, departure: Date?, arrival: Date?, originStopID: String? = nil,
                destinationStopID: String? = nil, requiredTransferSeconds: Int? = nil,
                walkingEvidence: WalkingEvidence = .routedPedestrian) {
        self.kind = kind; self.departure = departure; self.arrival = arrival
        self.originStopID = originStopID; self.destinationStopID = destinationStopID
        self.requiredTransferSeconds = requiredTransferSeconds; self.walkingEvidence = walkingEvidence
    }
}

public enum JourneyItineraryValidator {
    public static let tightTransferThresholdSeconds: TimeInterval = 180

    public static func assess(_ journey: Journey, context: JourneyValidationContext) -> JourneyFeasibility {
        assess(journey.legs.map { leg in
            switch leg {
            case let .walk(w): .init(kind: .walk, departure: w.departure, arrival: w.arrival,
                                    walkingEvidence: w.evidence)
            case let .transit(t): .init(kind: .transit, departure: t.effectiveDeparture,
                arrival: t.effectiveArrival, originStopID: t.board.stop.id,
                destinationStopID: t.alight.stop.id,
                requiredTransferSeconds: t.requiredTransferSecondsAfterWalking)
            case .inSeatContinuation: .init(kind: .continuation, departure: nil, arrival: nil)
            }
        }, context: context)
    }

    public static func transferRisks(_ journey: Journey,
                                     context: JourneyValidationContext) -> [Int: JourneyTransferRisk] {
        transferRisks(in: journey.legs)
    }

    static func transferRisks(in legs: [JourneyLeg]) -> [Int: JourneyTransferRisk] {
        let rides = legs.enumerated().compactMap { index, leg -> (Int, TransitLeg)? in
            if case let .transit(t) = leg { (index, t) } else { nil }
        }
        var risks: [Int: JourneyTransferRisk] = [:]
        for (incoming, outgoing) in zip(rides, rides.dropFirst()) {
            let between = legs[(incoming.0 + 1)..<outgoing.0]
            if between.contains(where: { if case .inSeatContinuation = $0 { true } else { false } }) { continue }
            let movement = between.reduce(0.0) { sum, leg in
                if case let .walk(w) = leg { sum + w.duration } else { sum }
            }
            let gap = outgoing.1.effectiveDeparture.timeIntervalSince(incoming.1.effectiveArrival)
            let slack = gap - movement - Double(outgoing.1.requiredTransferSecondsAfterWalking)
            if slack < 0 {
                risks[outgoing.0] = .missed
            } else if gap < tightTransferThresholdSeconds {
                risks[outgoing.0] = .tight
            }
        }
        return risks
    }

    public static func assess(_ itinerary: [JourneyTimingLeg],
                              context: JourneyValidationContext) -> JourneyFeasibility {
        let legs = itinerary.filter { $0.kind != .continuation }
        guard let departure = legs.first?.departure, let arrival = legs.last?.arrival else {
            return .invalid(.missingTime)
        }
        if !context.arriveBy && departure < context.anchor { return .invalid(.departureBeforeAnchor) }
        if context.arriveBy && arrival > context.anchor { return .invalid(.arrivalAfterDeadline) }
        for (index, leg) in legs.enumerated() {
            guard let start = leg.departure, let end = leg.arrival else { return .invalid(.missingTime) }
            if end < start { return .invalid(.negativeDuration) }
            if index > 0, let previous = legs[index - 1].arrival, start < previous {
                return .invalid(.overlappingLegs)
            }
        }
        let rides = itinerary.enumerated().filter { $0.element.kind == .transit }
        var minimum: TimeInterval?
        for (incoming, outgoing) in zip(rides, rides.dropFirst()) {
            let between = itinerary[(incoming.offset + 1)..<outgoing.offset]
            if between.contains(where: { $0.kind == .continuation }) { continue }
            guard let arrival = incoming.element.arrival, let departure = outgoing.element.departure else {
                return .invalid(.missingTime)
            }
            let walks = between.filter { $0.kind == .walk }
            if walks.contains(where: { $0.walkingEvidence == .estimate }) {
                return .invalid(.unverifiedTransferWalk)
            }
            let movement = walks.reduce(0.0) {
                $0 + max(0, ($1.arrival ?? .distantPast).timeIntervalSince($1.departure ?? .distantPast))
            }
            let required = outgoing.element.requiredTransferSeconds ?? context.minimumTransferSeconds
            let slack = departure.timeIntervalSince(arrival) - movement - Double(required)
            if slack < 0 { return .invalid(.missedTransfer) }
            minimum = min(minimum ?? slack, slack)
        }
        return .feasible(minimumTransferSlack: minimum)
    }
}

/// Stored evidence; time-dependent status is always evaluated with an explicit clock.
public struct JourneyStatusEvidence: Codable, Hashable, Sendable {
    public let firstBoarding: Date?
    public let cancelled: Bool
    public let delayed: Bool
    public let tightTransfer: Bool
    public let connectionMiss: Bool
    public let coverage: JourneyRealtimeCoverage
    public init(firstBoarding: Date?, cancelled: Bool, delayed: Bool,
                tightTransfer: Bool, connectionMiss: Bool = false,
                coverage: JourneyRealtimeCoverage) {
        self.firstBoarding = firstBoarding; self.cancelled = cancelled; self.delayed = delayed
        self.tightTransfer = tightTransfer; self.connectionMiss = connectionMiss; self.coverage = coverage
    }
    public func status(at now: Date, feasibility: JourneyFeasibility? = nil) -> JourneyStatus {
        if feasibility?.isInvalid == true { return .connectionMayBeMissed }
        if cancelled { return .cancelled }
        if let firstBoarding, firstBoarding < now { return .missed }
        if connectionMiss { return .connectionMayBeMissed }
        if case .atRisk = feasibility { return .atRisk }
        if tightTransfer { return .atRisk }
        if delayed { return .delayed }
        switch coverage {
        case .live: return .viable
        case .partial: return .partiallyLive
        case .scheduleOnly: return .scheduledOnly
        }
    }
}

extension Journey {
    static func evidence(for legs: [JourneyLeg]) -> JourneyStatusEvidence {
        let rides = legs.compactMap { if case let .transit(t) = $0 { t } else { nil } }
        let live = rides.filter { $0.board.timingSource != .scheduled || $0.alight.timingSource != .scheduled }
        let coverage: JourneyRealtimeCoverage = live.isEmpty ? .scheduleOnly :
            (live.count == rides.count ? .live : .partial)
        let tight = JourneyItineraryValidator.transferRisks(in: legs).values.contains(.tight)
        return .init(firstBoarding: rides.first?.boardingDeadline ?? rides.first?.effectiveDeparture,
                     cancelled: rides.contains { $0.status == .cancelled },
                     delayed: live.contains { $0.effectiveDeparture > $0.scheduledDeparture },
                     tightTransfer: tight, coverage: coverage)
    }
    public var transitFingerprint: String {
        legs.map {
            switch $0 {
            case let .transit(t): "\(t.instance?.stableKey ?? t.tripID)|\(t.boardSequence ?? -1)|\(t.alightSequence ?? -1)|\(t.board.stop.id)|\(t.alight.stop.id)|\(t.effectiveDeparture.timeIntervalSince1970)|\(t.effectiveArrival.timeIntervalSince1970)"
            case let .inSeatContinuation(c): "continuation|\(c.fromTripID)|\(c.toTripID)"
            case .walk: ""
            }
        }.filter { !$0.isEmpty }.joined(separator: ";")
    }
    func replacing(legs: [JourneyLeg]) -> Journey {
        let walks = legs.compactMap { if case let .walk(w) = $0 { w } else { nil } }
        let times = legs.compactMap { leg -> (Date, Date)? in
            switch leg {
            case let .walk(w): (w.departure, w.arrival)
            case let .transit(t): (t.effectiveDeparture, t.effectiveArrival)
            case .inSeatContinuation: nil
            }
        }
        let departure = times.first?.0 ?? effectiveDeparture
        let arrival = times.last?.1 ?? effectiveArrival
        let walking = walks.reduce(0) { $0 + $1.pedestrianDuration }
        let vehicle = legs.reduce(0.0) { total, leg in
            switch leg {
            case let .transit(ride): total + ride.effectiveArrival.timeIntervalSince(ride.effectiveDeparture)
            case let .walk(walk): total + walk.connectionDuration
            case .inSeatContinuation: total
            }
        }
        return Journey(id: id, origin: origin, destination: destination,
            scheduledDeparture: scheduledDeparture, scheduledArrival: scheduledArrival,
            effectiveDeparture: departure, effectiveArrival: arrival, transferCount: transferCount,
            walkingDuration: walking, walkingDistance: walks.reduce(0) { $0 + $1.pedestrianDistance },
            waitingDuration: max(0, arrival.timeIntervalSince(departure) - vehicle - walking),
            inVehicleDuration: vehicle, legs: legs, feedGeneration: feedGeneration,
            accessibility: accessibility, matchesPreferredMode: matchesPreferredMode)
    }
}

/// Selection fallback for clients whose manually selected route becomes unusable.
public enum JourneySelectionPolicy {
    public static func select(preferred: JourneySignature?, recommended: JourneySignature?,
                              candidates: [(id: JourneySignature, status: JourneyStatus)]) -> JourneySignature? {
        for id in [preferred, recommended].compactMap({ $0 }) {
            if candidates.contains(where: { $0.id == id && $0.status.isSelectable }) { return id }
        }
        return candidates.first(where: { $0.status.isSelectable })?.id ?? candidates.first?.id
    }
}
