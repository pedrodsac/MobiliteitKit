import Foundation

public struct Journey: Hashable, Sendable, Identifiable {
    public let id: JourneySignature
    public let origin: JourneyEndpoint
    public let destination: JourneyEndpoint
    public let scheduledDeparture: Date
    public let scheduledArrival: Date
    public let effectiveDeparture: Date
    public let effectiveArrival: Date
    public let transferCount: Int
    public let walkingDuration: TimeInterval
    public let walkingDistance: Double
    public let waitingDuration: TimeInterval
    public let inVehicleDuration: TimeInterval
    public let legs: [JourneyLeg]
    public let feedGeneration: Int
    public let accessibility: AccessibilityAssessment
    public let matchesPreferredMode: Bool
    /// Derived solely from immutable legs. Freshness is still checked at publication.
    public let statusEvidence: JourneyStatusEvidence
    public var duration: TimeInterval { effectiveArrival.timeIntervalSince(effectiveDeparture) }

    init(id: JourneySignature, origin: JourneyEndpoint, destination: JourneyEndpoint,
         scheduledDeparture: Date, scheduledArrival: Date, effectiveDeparture: Date, effectiveArrival: Date,
         transferCount: Int, walkingDuration: TimeInterval, walkingDistance: Double,
         waitingDuration: TimeInterval, inVehicleDuration: TimeInterval, legs: [JourneyLeg],
         feedGeneration: Int, accessibility: AccessibilityAssessment, matchesPreferredMode: Bool) {
        self.id = id; self.origin = origin; self.destination = destination
        self.scheduledDeparture = scheduledDeparture; self.scheduledArrival = scheduledArrival
        self.effectiveDeparture = effectiveDeparture; self.effectiveArrival = effectiveArrival
        self.transferCount = transferCount; self.walkingDuration = walkingDuration; self.walkingDistance = walkingDistance
        self.waitingDuration = waitingDuration; self.inVehicleDuration = inVehicleDuration; self.legs = legs
        self.feedGeneration = feedGeneration; self.accessibility = accessibility; self.matchesPreferredMode = matchesPreferredMode
        statusEvidence = Self.evidence(for: legs)
    }
}
