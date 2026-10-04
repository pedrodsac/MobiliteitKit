import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct JourneyQualityEnvelopeTests {
    @Test(arguments: [JourneyPreference.fastest, .lessWalking, .fewerTransfers, .preferDirect])
    func indexedEnvelopeMatchesExhaustiveReplacementPolicies(preference: JourneyPreference) async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "second,08:15:00,08:15:00,b,1\nsecond,08:25:00,08:25:00,d,2\n"
                + "third,08:30:00,08:30:00,d,1\nthird,08:45:00,08:45:00,c,2\n",
            trips: "route,service,first,Destination\nroute,service,second,Destination\nroute,service,third,Destination\n",
            additionalStops: "d,Second transfer,49.68,6.18\n")
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let base = try #require(try await router.makeSession(for: .init(origin: .stop(id: "a"),
            destination: .stop(id: "c"), departureTime: RealtimeTestFixture.date("07:55:00")))
            .initial().journeys.first)
        var random: UInt64 = 42
        func next(_ bound: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Int((random >> 32) % UInt64(bound))
        }
        let choices: [AccessibilityAssessment] = [.verified, .unknown, .inaccessible]
        let journeys = (0..<192).map { index -> Journey in
            let removed = index % 3
            var legs = Array(base.legs.dropFirst(removed))
            if index % 13 == 0, case let .transit(ride) = legs[0] {
                legs[0] = .transit(.init(tripID: ride.tripID, route: ride.route, headsign: ride.headsign,
                    board: ride.board, alight: ride.alight, intermediateStops: ride.intermediateStops,
                    scheduledDeparture: ride.scheduledDeparture, scheduledArrival: ride.scheduledArrival,
                    effectiveDeparture: ride.effectiveDeparture, effectiveArrival: ride.effectiveArrival,
                    status: .cancelled, requiredTransferSecondsAfterWalking: ride.requiredTransferSecondsAfterWalking,
                    instance: ride.instance, boardSequence: ride.boardSequence, alightSequence: ride.alightSequence))
            }
            let departure = base.effectiveDeparture.addingTimeInterval(Double(next(8) * 60))
            let arrival = base.effectiveArrival.addingTimeInterval(Double(next(8) * 60))
            return Journey(id: .init("variant-\(index)"), origin: base.origin, destination: base.destination,
                scheduledDeparture: departure, scheduledArrival: arrival, effectiveDeparture: departure,
                effectiveArrival: arrival, transferCount: 2 - removed, walkingDuration: Double(next(10) * 60),
                walkingDistance: Double(next(10) * 100), waitingDuration: 300, inVehicleDuration: 1_200,
                legs: legs, feedGeneration: base.feedGeneration, accessibility: choices[next(3)],
                matchesPreferredMode: next(2) == 0)
        }
        let preferences = RoutingPreferences(routePreference: preference)
        let reference = Set(journeys.filter { candidate in
            !journeys.contains { other in
                other.id != candidate.id && (JourneyQualityPolicy.dominates(other, candidate)
                    || JourneyQualityPolicy.redundantAccessFeeder(candidate, replacedBy: other, preferences: preferences)
                    || JourneyQualityPolicy.redundantIntermediateTransfer(candidate, replacedBy: other, preferences: preferences))
            }
        }.map(\.id))
        #expect(JourneyQualityPolicy.envelopeIDs(journeys, preferences: preferences) == reference)
        #expect(JourneyQualityPolicy.envelopeIDs(journeys.reversed(), preferences: preferences) == reference)
    }
}
