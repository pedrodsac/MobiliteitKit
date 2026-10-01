import Foundation

public enum JourneyPlanningTime: Hashable, Sendable {
    case now, departAt(Date), arriveBy(Date)
}

public enum JourneyRefreshPolicy: Hashable, Sendable {
    case scheduleOnly, useCache, forceRefresh
}

public enum JourneyPlanningPage: Hashable, Sendable {
    case initial, earlier, later
    case before(Date, JourneySignature?, Int)
    case after(Date, JourneySignature?, Int)

    public func realtimePolicy(_ refresh: JourneyRefreshPolicy, acquisitionBudgetMilliseconds: Int = 4_000) -> RealtimePolicy {
        let later: Bool = switch self { case .later, .after: true; default: false }
        let configuration = RealtimeConfiguration(scheduledLookbackSeconds: later ? 600 : 1_200, acquisitionBudgetMilliseconds: acquisitionBudgetMilliseconds)
        return switch refresh {
        case .scheduleOnly: .disabled
        case .useCache: .bestEffort(configuration: configuration, refresh: .useCache)
        case .forceRefresh: .bestEffort(configuration: configuration, refresh: .forceRefresh)
        }
    }
}

public struct JourneyPlanningRequest: Hashable, Sendable {
    public var origin: JourneyEndpoint
    public var destination: JourneyEndpoint
    public var time: JourneyPlanningTime
    public var preferences: RoutingPreferences
    public var realtimeAcquisitionBudgetMilliseconds: Int
    public init(origin: JourneyEndpoint, destination: JourneyEndpoint,
                time: JourneyPlanningTime = .now, preferences: RoutingPreferences = .init(),
                realtimeAcquisitionBudgetMilliseconds: Int = 4_000) {
        self.origin = origin; self.destination = destination
        self.time = time; self.preferences = preferences
        self.realtimeAcquisitionBudgetMilliseconds = max(0, realtimeAcquisitionBudgetMilliseconds)
    }
}

extension RoutingPreferences {
    /// The rider-facing transfer choice; mode preference remains soft.
    public init(preferredMode: TransitModeMask?, avoidTightTransfers: Bool) {
        self.init(maxTransfers: 3, minimumTransferSeconds: avoidTightTransfers ? 180 : 120,
                  sameStopTransferShortfallSeconds: 0,
                  preferredMode: preferredMode)
    }
}

public enum JourneyInfeasibility: String, Codable, Hashable, Sendable {
    case missingTime, negativeDuration, overlappingLegs, departureBeforeAnchor
    case missedTransfer, unverifiedTransferWalk, arrivalAfterDeadline
    case invalidIdentity, invalidOccurrence, inactiveService, forbiddenAction, disconnectedLegs
    case invalidMovement, constraintViolation, repeatedTripInstance, invalidContinuation, contradictoryRealtime
}

public enum JourneyFeasibility: Codable, Hashable, Sendable {
    case feasible(minimumTransferSlack: TimeInterval?)
    case atRisk(minimumTransferSlack: TimeInterval)
    case invalid(JourneyInfeasibility)
    public var isInvalid: Bool {
        switch self { case .invalid: true; case let .atRisk(slack): slack < 0; case .feasible: false }
    }
}

public struct JourneyValidationContext: Hashable, Sendable {
    public let anchor: Date
    public let arriveBy: Bool
    public let minimumTransferSeconds: Int
    public let sameStopTransferShortfallSeconds: Int
    public init(anchor: Date, arriveBy: Bool, minimumTransferSeconds: Int,
                sameStopTransferShortfallSeconds: Int = 0) {
        self.anchor = anchor; self.arriveBy = arriveBy
        self.minimumTransferSeconds = minimumTransferSeconds
        self.sameStopTransferShortfallSeconds = sameStopTransferShortfallSeconds
    }
}

public enum JourneyTransferRisk: String, Codable, Hashable, Sendable { case tight, missed }

public enum JourneyRealtimeCoverage: String, Codable, Hashable, Sendable {
    case live, partial, scheduleOnly
}

public enum JourneyStatus: String, Codable, Hashable, Sendable {
    case viable, delayed, partiallyLive, scheduledOnly, atRisk
    case connectionMayBeMissed, missed, cancelled
    public var isSelectable: Bool {
        switch self {
        case .cancelled, .missed, .connectionMayBeMissed: false
        default: true
        }
    }
}

/// Stable within a planning generation, including across independent walk updates.
public struct JourneyRefinementToken: Codable, Hashable, Sendable {
    public let generation: UUID
    public let journeyID: JourneySignature
    public let transitFingerprint: String
    public init(generation: UUID, journeyID: JourneySignature, transitFingerprint: String) {
        self.generation = generation; self.journeyID = journeyID
        self.transitFingerprint = transitFingerprint
    }
}

/// Replaces one contiguous span of native walking legs. The caller adjusts times.
public struct JourneyWalkingRefinement: Sendable {
    public let token: JourneyRefinementToken
    public let range: Range<Int>
    public let route: WalkingRoute
    public let departure: Date
    public let arrival: Date
    public init(token: JourneyRefinementToken, range: Range<Int>, route: WalkingRoute,
                departure: Date, arrival: Date) {
        self.token = token; self.range = range; self.route = route
        self.departure = departure; self.arrival = arrival
    }
}

/// Opaque session/query generation plus an effective chronological boundary.
public struct JourneyPlanningCursor: Hashable, Sendable {
    public let generation: UUID
    public let feedGeneration: Int
    public let departure: Date
    public let journeyID: JourneySignature?
}

public struct JourneyPlanningResult: Sendable {
    public var earlierCursor: JourneyPlanningCursor? = nil
    public var laterCursor: JourneyPlanningCursor? = nil
    public let journeys: [Journey]
    public let recommendedJourneyID: JourneySignature?
    public let invalidatedIDs: Set<JourneySignature>
    public let feasibility: [JourneySignature: JourneyFeasibility]
    public let transferRisks: [JourneySignature: [Int: JourneyTransferRisk]]
    public let refinementTokens: [JourneySignature: JourneyRefinementToken]
    public let hasEarlier: Bool
    public let hasLater: Bool
    public let revision: UInt64
    public let metrics: RoutingMetrics
    public var diagnostics = RoutingDiagnostics()
    public let validationContext: JourneyValidationContext
}

public enum JourneyPlanningError: Error, Sendable {
    case noRouteFound, supersededRequest, staleRefinement, invalidRefinement, stalePage
}
