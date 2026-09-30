import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Journey feasibility and status")
struct JourneyAssessmentTests {
    private let start = Date(timeIntervalSince1970: 100_000)
    private var context: JourneyValidationContext {
        .init(anchor: start, arriveBy: false, minimumTransferSeconds: 120)
    }
    private func leg(_ kind: JourneyTimingLeg.Kind, _ departure: Double, _ arrival: Double,
                     evidence: WalkingEvidence = .routedPedestrian,
                     from: String? = nil, to: String? = nil) -> JourneyTimingLeg {
        .init(kind: kind, departure: start.addingTimeInterval(departure),
              arrival: start.addingTimeInterval(arrival), originStopID: from,
              destinationStopID: to, walkingEvidence: evidence)
    }
    @Test func transferWalkConsumesSlack() {
        let valid = [leg(.transit, 0, 600), leg(.walk, 600, 960), leg(.transit, 1_200, 2_400)]
        #expect(JourneyItineraryValidator.assess(valid, context: context) == .feasible(minimumTransferSlack: 120))
        let tight = [leg(.transit, 0, 600), leg(.walk, 600, 960), leg(.transit, 1_000, 2_400)]
        #expect(JourneyItineraryValidator.assess(tight, context: context) == .invalid(.missedTransfer))
        let overlap = [leg(.transit, 0, 600), leg(.walk, 600, 960), leg(.transit, 900, 2_400)]
        #expect(JourneyItineraryValidator.assess(overlap, context: context) == .invalid(.overlappingLegs))
        let estimate = [leg(.transit, 0, 600), leg(.walk, 600, 900, evidence: .estimate), leg(.transit, 1_200, 2_400)]
        #expect(JourneyItineraryValidator.assess(estimate, context: context) == .invalid(.unverifiedTransferWalk))
    }
    @Test func sameStopToleranceIsExplicit() {
        let itinerary = [leg(.transit, 0, 600, to: "platform"), leg(.transit, 615, 1_200, from: "platform")]
        #expect(JourneyItineraryValidator.assess(itinerary, context: context) == .invalid(.missedTransfer))
        let tolerant = JourneyValidationContext(anchor: start, arriveBy: false,
            minimumTransferSeconds: 180, sameStopTransferShortfallSeconds: 180)
        #expect(JourneyItineraryValidator.assess(itinerary, context: tolerant) == .atRisk(minimumTransferSlack: -165))
    }
    @Test func continuationDoesNotRequireBoardingAgain() {
        let itinerary = [leg(.transit, 0, 600), JourneyTimingLeg(kind: .continuation, departure: nil, arrival: nil),
                         leg(.transit, 600, 1_200)]
        #expect(JourneyItineraryValidator.assess(itinerary, context: context) == .feasible(minimumTransferSlack: nil))
    }
    @Test func anchorsMissingTimesAndNegativeDurations() {
        #expect(JourneyItineraryValidator.assess([], context: context) == .invalid(.missingTime))
        #expect(JourneyItineraryValidator.assess([leg(.walk, -10, 60)], context: context) == .invalid(.departureBeforeAnchor))
        #expect(JourneyItineraryValidator.assess([leg(.walk, 30, 10)], context: context) == .invalid(.negativeDuration))
        let arrive = JourneyValidationContext(anchor: start.addingTimeInterval(60), arriveBy: true, minimumTransferSeconds: 120)
        #expect(JourneyItineraryValidator.assess([leg(.walk, 0, 90)], context: arrive) == .invalid(.arrivalAfterDeadline))
    }
    @Test func statusUsesExplicitClockAndCoverage() {
        let live = JourneyStatusEvidence(firstBoarding: start, cancelled: false, delayed: false,
                                         tightTransfer: false, coverage: .live)
        #expect(live.status(at: start) == .viable)
        #expect(live.status(at: start.addingTimeInterval(31)) == .missed)
        #expect(live.status(at: start, feasibility: .invalid(.missedTransfer)) == .connectionMayBeMissed)
        #expect(live.status(at: start, feasibility: .atRisk(minimumTransferSlack: -10)) == .atRisk)
        let delayed = JourneyStatusEvidence(firstBoarding: start, cancelled: false, delayed: true,
                                            tightTransfer: false, coverage: .partial)
        #expect(delayed.status(at: start) == .delayed)
        let partial = JourneyStatusEvidence(firstBoarding: start, cancelled: false, delayed: false,
                                            tightTransfer: false, coverage: .partial)
        #expect(partial.status(at: start) == .partiallyLive)
        let cancelled = JourneyStatusEvidence(firstBoarding: start, cancelled: true, delayed: false,
                                              tightTransfer: false, coverage: .live)
        #expect(cancelled.status(at: start) == .cancelled)
        #expect(!cancelled.status(at: start).isSelectable)
    }
}
