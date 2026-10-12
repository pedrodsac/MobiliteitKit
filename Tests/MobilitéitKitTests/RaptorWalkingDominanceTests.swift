import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RaptorWalkingDominanceTests {
    @Test(arguments: [false, true])
    func projectedWalkingInsertMatchesFullLabelInsertAfterEveryAttempt(mixedVisits: Bool) throws {
        var randomState: UInt64 = 0x189a3e6f
        func random(_ bound: Int) -> Int {
            randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
            return Int(randomState >> 32) % bound
        }
        let day = try GTFSDate(year: 2026, month: 10, day: 12)
        let target = 20
        let route = WalkingRoute(durationSeconds: 30, distanceMeters: 25,
            polyline: [.init(latitude: 49.6, longitude: 6.1), .init(latitude: 49.601, longitude: 6.1)])
        var full = Raptor.LabelProfile()
        var projected = Raptor.LabelProfile()
        var skipped = 0
        var skippedFullProfiles = 0
        var fullNextID = 0
        var projectedNextID = 0
        for attempt in 0..<4_000 {
            let trip = random(16)
            let departure = Date(timeIntervalSinceReferenceDate: Double(random(120)))
            let sourceArrival = departure.addingTimeInterval(Double(random(120)))
            let transit = Raptor.TransitLeg(trip: trip, board: 0, alight: 1, boardPos: 0, alightPos: 1,
                day: day, scheduledBoard: departure, scheduledAlight: sourceArrival,
                boardTime: departure, alightTime: sourceArrival, requiredTransferSecondsAfterWalking: 0)
            let visits: Raptor.WalkingVisits
            if mixedVisits {
                switch random(4) {
                case 0: visits = .one(1)
                case 1: visits = .multiple([1, 2])
                case 2: visits = .multiple([1])
                default: visits = .multiple([1, target])
                }
            } else { visits = .one(1) }
            let source = Raptor.Label(id: -attempt - 1, time: sourceArrival, appendedLeg: .transit(transit),
                firstStop: 0, firstDeparture: random(8) == 0 ? nil : departure,
                lastTransit: transit, minimumSlack: random(8), totalSlack: random(24),
                accessSeconds: random(6), accessDistance: 10, pathwaySeconds: random(3),
                pathwayDistance: 5, transferWalkSeconds: 0, containsPreferredMode: random(3) == 0,
                walkingStopsVisited: visits, tripKey: Raptor.TripKey().appending(.init(trip: trip, day: day)))
            let duration = random(4) * 30
            let arrival = sourceArrival.addingTimeInterval(Double(duration))
            let label = Raptor.Label(id: fullNextID, time: arrival, prior: source,
                appendedLeg: .walkingTransfer(.init(from: 1, to: target, route: route,
                    departure: sourceArrival, arrival: arrival)),
                firstStop: source.firstStop, firstDeparture: source.firstDeparture,
                lastTransit: source.lastTransit, minimumSlack: source.minimumSlack, totalSlack: source.totalSlack,
                accessSeconds: source.accessSeconds, accessDistance: source.accessDistance,
                pathwaySeconds: source.pathwaySeconds + duration, pathwayDistance: source.pathwayDistance + 25,
                transferWalkSeconds: source.transferWalkSeconds + duration,
                containsPreferredMode: source.containsPreferredMode,
                walkingStopsVisited: source.walkingStopsVisited.adding(target), tripKey: source.tripKey)
            let reject = Raptor.walkingCandidateCannotEnterProfile(projected, source: source, to: target,
                durationSeconds: duration, arrival: arrival, candidateID: projectedNextID)
            if reject {
                skipped += 1
                if projected.ordered.count == Raptor.profileWidth { skippedFullProfiles += 1 }
            } else { _ = Raptor.insert(label, into: &projected) }
            _ = Raptor.insert(label, into: &full)
            fullNextID += 1
            projectedNextID += 1
            #expect(projected.ordered.map(\.id) == full.ordered.map(\.id))
            #expect(projected.byWalk.map(\.id) == full.byWalk.map(\.id))
            #expect(projected.byArrival.map(\.id) == full.byArrival.map(\.id))
            #expect(projected.lastUnprotectedArrival?.id == full.lastUnprotectedArrival?.id)
            #expect(projected.lastPreferredArrival?.id == full.lastPreferredArrival?.id)
            #expect(projectedNextID == fullNextID)
        }
        #expect(skipped > 0)
        #expect(skippedFullProfiles > 0)
        // Retained prefixes preserve their complete transit and walking legs.
        #expect(projected.ordered.map { String(reflecting: $0.legs) }
            == full.ordered.map { String(reflecting: $0.legs) })
    }
}
