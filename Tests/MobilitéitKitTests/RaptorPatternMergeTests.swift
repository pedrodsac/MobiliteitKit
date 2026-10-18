import Foundation
import os
import Testing
@testable import MobiliteitKit

/// The merge of finished scan chunks, checked on hand-made chunks against the serial loop it replaced.
@Suite struct RaptorPatternMergeTests {
    static let baseID = 7_000
    static let stopCount = 14
    static let chunkCount = 36

    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 32) % bound
        }
    }

    /// Chunks whose profiles overlap at every stop, so the merge has to apply dominance and the
    /// 48-label quota across chunks.
    static func makeChunks(seed: UInt64) throws -> [Raptor.PatternScanResult] {
        var generator = Generator(state: seed)
        let day = try GTFSDate(year: 2026, month: 10, day: 22)
        return (0..<chunkCount).map { chunkIndex in
            var profiles: [Int: Raptor.CompactProfile] = [:]
            var nextID = (chunkIndex + 1) * 1_000_000_000
            var attempts = 0, rejected = 0, retained = 0
            // A few chunks cover only some stops, and one covers none.
            let reach = chunkIndex == 5 ? 0 : (chunkIndex.isMultiple(of: 4) ? stopCount / 3 : stopCount)
            for _ in 0..<(reach == 0 ? 0 : 120) {
                let stop = generator.next(reach)
                let departure = Double(generator.next(120)) + Double(generator.next(4)) / 4
                let arrival = departure + Double(generator.next(120))
                let walking = generator.next(5), trip = generator.next(30) + 10
                let preferred = generator.next(3) == 0, slack = generator.next(10), total = generator.next(30)
                let key = Raptor.ScanKey(id: nextID, arrival: arrival, departure: departure,
                    doorDeparture: departure - Double(walking), walkingSeconds: walking,
                    minimumSlack: slack, totalSlack: total, preferred: preferred,
                    prefixRank: generator.next(3), incomingTrip: trip, serviceDate: day)
                var peers = profiles[stop]?.byIncomingTrip[trip, default: 0] ?? 0
                let board = Date(timeIntervalSinceReferenceDate: departure)
                let alight = Date(timeIntervalSinceReferenceDate: arrival)
                let source = generator.next(6)
                if Raptor.consider(key, profile: &profiles[stop], peers: &peers, nextID: &nextID,
                    attempts: &attempts, rejected: &rejected, path: {
                        .init(sourceIndex: source, trip: trip, board: 0, alight: stop, boardPos: 0, alightPos: 1,
                            day: day, scheduledBoard: board, scheduledAlight: alight, boardTime: board,
                            alightTime: alight, requiredTransferSeconds: 0)
                    }) { retained += 1 }
            }
            return .init(chunkIndex: chunkIndex, labels: [:], scannedPatterns: chunkIndex + 1,
                scannedTripInstances: 2 * chunkIndex, boardingChecks: 3, feasibleBoardings: 5,
                alightingChecks: 7, labelAttempts: attempts, retainedLabels: retained,
                rejectedBeforeAllocation: rejected, elapsedMilliseconds: chunkIndex, compactLabels: profiles)
        }
    }

    /// The serial loop that merged each chunk as it was handed out: chunks in index order, stops in
    /// ascending order, one ID per label of the chunk, whether or not it survives.
    static func serialMerge(_ chunks: [Raptor.PatternScanResult], nextLabelID: Int)
        -> (profiles: [Int: Raptor.CompactProfile], nextID: Int) {
        var nextID = nextLabelID
        var merged: [Int: Raptor.CompactProfile] = [:]
        for chunk in chunks.sorted(by: { $0.chunkIndex < $1.chunkIndex }) {
            let compact = chunk.compactLabels!
            for stop in compact.keys.sorted() {
                let profile = compact[stop]!
                var target = merged.removeValue(forKey: stop) ?? Raptor.CompactProfile()
                for slot in profile.ordered {
                    var key = profile.keys[slot]!
                    key.id = nextID; nextID += 1
                    let peers = target.byIncomingTrip[key.incomingTrip, default: 0]
                    if !target.isDominated(key, peers: peers), !target.cannotEnter(key, peers: peers) {
                        _ = target.insert(key, path: profile.paths[slot]!)
                    }
                }
                merged[stop] = target
            }
        }
        return (merged, nextID)
    }

    /// Everything a profile keeps, in its three orders.
    static func description(_ profiles: [Int: Raptor.CompactProfile]) -> [String] {
        profiles.keys.sorted().map { stop in
            let profile = profiles[stop]!
            func slots(_ values: [Int]) -> String {
                values.map { String(reflecting: profile.keys[$0]!) + String(reflecting: profile.paths[$0]!) }.joined(separator: "|")
            }
            return "\(stop) ordered \(slots(profile.ordered)) arrival \(profile.byArrival.map { profile.keys[$0]!.id }) "
                + "walk \(profile.byWalk.map { profile.keys[$0]!.id }) peers \(profile.byIncomingTrip.mapValues { $0.nonzeroBitCount }.sorted { $0.key < $1.key })"
        }
    }

    static func arrivalOrder(_ kind: Int, count: Int, seed: UInt64) -> [Int] {
        switch kind {
        case 0: return Array(0..<count)
        case 1: return Array((0..<count).reversed())
        default:
            var generator = Generator(state: seed)
            var order = Array(0..<count)
            for index in order.indices.reversed() { order.swapAt(index, generator.next(index + 1)) }
            return order
        }
    }

    /// `trickle` hands the chunks over one at a time while the merger waits, instead of all at once.
    static func merge(_ chunks: [Raptor.PatternScanResult], order: [Int], shards: Int, trickle: Bool,
        boardings: Raptor.BoardingIndex? = nil) async -> (merge: Raptor.PatternScanMerge, steps: Int) {
        let (finished, sink) = AsyncStream.makeStream(of: Raptor.PatternScanResult.self)
        if !trickle {
            for index in order { sink.yield(chunks[index]) }
            sink.finish()
        }
        let producer = Task {
            guard trickle else { return }
            for index in order {
                sink.yield(chunks[index])
                await Task.yield()
            }
            sink.finish()
        }
        let steps = OSAllocatedUnfairLock(initialState: 0)
        let merge = await Raptor.mergeInOrder(finished, chunkCount: chunks.count, nextLabelID: baseID, shardCount: shards, boardings: boardings) {
            steps.withLock { $0 += 1 }
        }
        await producer.value
        return (merge, steps.withLock { $0 })
    }

    /// Shard counts 1 (merged in place), 3 (stops spread unevenly) and 10 (more shards than a chunk has
    /// stops, so some get no work).
    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2, 3].flatMap { kind in
        [1, 3, 10].flatMap { shards in [false, true].map { (kind, shards, $0) } }
    })
    func chunksMergeInIndexOrderWhateverTheArrivalOrder(kind: Int, shards: Int, trickle: Bool) async throws {
        let seed: UInt64 = 0x51ced + UInt64(kind)
        let chunks = try Self.makeChunks(seed: seed)
        let expected = Self.serialMerge(chunks, nextLabelID: Self.baseID)
        // The generator has to produce a merge with evictions, or the comparison proves little.
        #expect(expected.profiles.values.contains { $0.ordered.count == Raptor.profileWidth })
        let order = Self.arrivalOrder(kind, count: chunks.count, seed: seed)
        let (merge, steps) = await Self.merge(chunks, order: order, shards: shards, trickle: trickle)
        #expect(steps == chunks.count)
        #expect(merge.nextID == expected.nextID)
        #expect(Self.description(merge.mergedProfiles) == Self.description(expected.profiles))
        #expect(merge.patterns == chunks.map(\.scannedPatterns).reduce(0, +))
        #expect(merge.tripInstances == chunks.map(\.scannedTripInstances).reduce(0, +))
        #expect(merge.labelAttempts == chunks.map(\.labelAttempts).reduce(0, +))
        #expect(merge.retainedLabels == chunks.map(\.retainedLabels).reduce(0, +))
        #expect(merge.slowestChunkMilliseconds == chunks.count - 1)
    }

    /// A label gets the ID the serial loop would give it: the IDs before its chunk, plus the labels of
    /// the chunk at lower stops, plus its slot. IDs never repeat and have no gap.
    @Test(arguments: [1, 3, 10])
    func labelIDsAreTheSerialLoopsIDs(shards: Int) async throws {
        let chunks = try Self.makeChunks(seed: 99)
        let expected = Self.serialMerge(chunks, nextLabelID: Self.baseID)
        let issued = chunks.reduce(0) { total, chunk in
            total + chunk.compactLabels!.values.reduce(0) { $0 + $1.ordered.count }
        }
        #expect(expected.nextID == Self.baseID + issued)
        let (merge, _) = await Self.merge(chunks, order: Self.arrivalOrder(2, count: chunks.count, seed: 5), shards: shards, trickle: true)
        #expect(merge.nextID == Self.baseID + issued)
        let ids = merge.mergedProfiles.values.flatMap { profile in profile.ordered.map { profile.keys[$0]!.id } }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0 >= Self.baseID && $0 < Self.baseID + issued })
    }

    /// Six boarding labels, the sources the generated paths point at.
    static func makeBoardings() throws -> Raptor.BoardingIndex {
        let day = try GTFSDate(year: 2026, month: 10, day: 22)
        var profiles: [Int: Raptor.LabelProfile] = [:]
        for index in 0..<6 {
            let label = Raptor.Label(id: index, time: Date(timeIntervalSinceReferenceDate: Double(index)), firstStop: 0,
                firstDeparture: nil, lastTransit: nil, minimumSlack: .max, totalSlack: 0, accessSeconds: 0,
                accessDistance: 0, pathwaySeconds: 0, pathwayDistance: 0, transferWalkSeconds: 0,
                containsPreferredMode: false, walkingStopsVisited: .one(0),
                tripKey: Raptor.TripKey().appending(.init(trip: index, day: day)))
            _ = Raptor.insert(label, at: 0, into: &profiles)
        }
        let boardings = Raptor.BoardingIndex(profiles, stopCount: stopCount)
        #expect(boardings.sources.count == 6)
        return boardings
    }

    /// Each shard builds the labels of its own stops; together they are what one `materialize` of all
    /// merged profiles builds.
    @Test(arguments: [3, 10])
    func shardsMaterializeTheLabelsOfOneMaterialize(shards: Int) async throws {
        let chunks = try Self.makeChunks(seed: 7)
        let boardings = try Self.makeBoardings()
        let (merge, _) = await Self.merge(chunks, order: Self.arrivalOrder(2, count: chunks.count, seed: 3),
                                          shards: shards, trickle: false, boardings: boardings)
        let actual = try #require(merge.materializedLabels)
        let expected = Raptor.materialize(Self.serialMerge(chunks, nextLabelID: Self.baseID).profiles, boardings: boardings)
        #expect(actual.keys.sorted() == expected.keys.sorted())
        #expect(actual.count > 1)
        func describe(_ profile: Raptor.LabelProfile) -> [String] {
            profile.ordered.map { "\($0.id) \($0.time) \($0.firstDeparture as Any) \($0.minimumSlack) \($0.totalSlack) \(String(reflecting: $0.legs))" }
                + ["walk", profile.byWalk.map { String($0.id) }.joined(separator: ","),
                   "arrival", profile.byArrival.map { String($0.id) }.joined(separator: ","),
                   "last", "\(profile.lastUnprotectedArrival?.id as Any) \(profile.lastPreferredArrival?.id as Any)"]
        }
        for stop in expected.keys.sorted() { #expect(describe(actual[stop]!) == describe(expected[stop]!), "stop \(stop)") }
    }
}
