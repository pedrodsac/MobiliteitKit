import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RaptorCompactProfileTests {
    @Test(arguments: [false, true])
    func compactQuotaAndDominanceMatchReferenceAfterEveryInsertion(mixedDepth: Bool) throws {
        var state: UInt64 = 0x8e327b61
        func random(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 32) % bound
        }
        let day = try GTFSDate(year: 2026, month: 9, day: 30)
        let prefixes = (0..<8).map { index in
            var key = Raptor.TripKey().appending(.init(trip: index / 2, day: day))
            if mixedDepth, index.isMultiple(of: 2) { key = key.appending(.init(trip: 14, day: day)) }
            return key
        }
        let sorted = prefixes.indices.sorted { Raptor.precedes(prefixes[$0], prefixes[$1]) }
        var ranks = [Int](repeating: 0, count: prefixes.count)
        var rank = 0
        for index in sorted.indices {
            if index > 0, prefixes[sorted[index]] != prefixes[sorted[index - 1]] { rank += 1 }
            ranks[sorted[index]] = rank
        }
        func source(_ index: Int) -> Raptor.Label {
            .init(id: index, time: .distantPast, firstStop: 0, firstDeparture: nil, lastTransit: nil,
                minimumSlack: .max, totalSlack: 0, accessSeconds: 0, accessDistance: 0,
                pathwaySeconds: 0, pathwayDistance: 0, transferWalkSeconds: 0, containsPreferredMode: false,
                walkingStopsVisited: .one(0), tripKey: prefixes[index])
        }
        let sources = prefixes.indices.map(source)
        var compact: Raptor.CompactProfile? = nil
        var original: [Raptor.Label] = []
        var nextID = 0, attempts = 0, rejected = 0
        var currentTrip: Int?
        var peers: UInt64 = 0
        for _ in 0..<4_000 {
            let departure = Double(random(120)) + Double(random(4)) / 4
            let arrival = departure + Double(random(120))
            let walking = random(5), prefix = random(8), trip = random(16) + 10
            let preferred = random(3) == 0, slack = random(10), total = random(30)
            let key = Raptor.ScanKey(id: nextID, arrival: arrival, departure: departure,
                doorDeparture: departure - Double(walking), walkingSeconds: walking,
                minimumSlack: slack, totalSlack: total, preferred: preferred,
                prefixRank: ranks[prefix], incomingTrip: trip, serviceDate: day,
                mixedDepthSource: mixedDepth ? sources[prefix] : nil)
            let board = Date(timeIntervalSinceReferenceDate: departure)
            let alight = Date(timeIntervalSinceReferenceDate: arrival)
            let leg = Raptor.TransitLeg(trip: trip, board: 0, alight: 1, boardPos: 0, alightPos: 1,
                day: day, scheduledBoard: board, scheduledAlight: alight, boardTime: board,
                alightTime: alight, requiredTransferSecondsAfterWalking: 0)
            let label = Raptor.Label(id: nextID, time: alight, firstStop: 0, firstDeparture: board,
                lastTransit: leg, minimumSlack: slack, totalSlack: total, accessSeconds: walking,
                accessDistance: 0, pathwaySeconds: 0, pathwayDistance: 0, transferWalkSeconds: 0,
                containsPreferredMode: preferred, walkingStopsVisited: .one(1),
                tripKey: prefixes[prefix].appending(.init(trip: trip, day: day)))
            original = Raptor.referenceInsert(label, into: original)
            if currentTrip != trip {
                peers = compact?.byIncomingTrip[trip, default: 0] ?? 0
                currentTrip = trip
            }
            _ = Raptor.consider(key, profile: &compact, peers: &peers, nextID: &nextID, attempts: &attempts, rejected: &rejected) {
                .init(sourceIndex: prefix, trip: trip, board: 0, alight: 1, boardPos: 0, alightPos: 1,
                    day: day, scheduledBoard: board, scheduledAlight: alight, boardTime: board,
                    alightTime: alight, requiredTransferSeconds: 0)
            }
            #expect(compact!.ordered.map { compact!.keys[$0]!.id } == original.map(\.id))
        }
        #expect(rejected > 0)
    }
}
