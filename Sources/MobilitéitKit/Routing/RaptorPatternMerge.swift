import Foundation
import os

extension Raptor {
    /// Counts for the merge of one round and the label IDs it assigns. `Raptor.mergeInOrder`
    /// feeds it finished chunks in index order. It splits each chunk by stop across the shards,
    /// which hold the merged profiles, so stops of different shards merge at the same time.
    struct PatternScanMerge: Sendable {
        var nextID: Int
        let shardCount: Int
        private var referenceID: Int
        private var mergedCompact: [Int: CompactProfile] = [:]
        private var referenceNext: [Int: LabelProfile] = [:]
        private var labels: [Int: LabelProfile] = [:]
        private(set) var materializedLabels: [Int: LabelProfile]?
        var patterns = 0, tripInstances = 0, boardingChecks = 0, feasibleBoardings = 0
        var alightingChecks = 0, labelAttempts = 0, retainedLabels = 0, rejectedBeforeAllocation = 0
        var slowestChunkMilliseconds = 0, summedChunkMilliseconds = 0
        var mergedProfiles: [Int: CompactProfile] { mergedCompact }

        init(nextID: Int, shardCount: Int = 1) {
            self.nextID = nextID; self.shardCount = max(1, shardCount); self.referenceID = nextID
        }

        /// Count the chunk and give its labels their IDs. A stop's labels go to shard
        /// `stop % shardCount`. Returns what each shard has to merge into its profiles, or nil
        /// for a chunk without compact profiles, which is merged here.
        ///
        /// The serial merge gave every label of the chunk the next ID, stops in ascending order,
        /// whether or not it survives. A stop's first ID is therefore the IDs before this chunk
        /// plus the labels of this chunk at lower stops; the shard adds the slot.
        mutating func append(_ result: PatternScanResult) -> ChunkSplit? {
            patterns += result.scannedPatterns
            tripInstances += result.scannedTripInstances
            boardingChecks += result.boardingChecks
            feasibleBoardings += result.feasibleBoardings
            alightingChecks += result.alightingChecks
            labelAttempts += result.labelAttempts
            retainedLabels += result.retainedLabels
            rejectedBeforeAllocation += result.rejectedBeforeAllocation
            slowestChunkMilliseconds = max(slowestChunkMilliseconds, result.elapsedMilliseconds)
            summedChunkMilliseconds += result.elapsedMilliseconds
            guard let compact = result.compactLabels else {
                for stop in result.labels.keys.sorted() {
                    for candidate in result.labels[stop]?.ordered ?? [] {
                        let candidate = candidate.replacingID(with: nextID)
                        nextID += 1
                        _ = Raptor.insert(candidate, at: stop, into: &labels)
                    }
                }
                return nil
            }
            var stopsByShard = [[(stop: Int, firstID: Int)]](repeating: [], count: shardCount)
            for (stop, profile) in compact.sorted(by: { $0.key < $1.key }) {
                stopsByShard[stop % shardCount].append((stop, nextID))
                nextID += profile.ordered.count
            }
            if Raptor.verifyKernel {
                for stop in result.labels.keys.sorted() {
                    for label in result.labels[stop]!.ordered {
                        _ = Raptor.insert(label.replacingID(with: referenceID), at: stop, into: &referenceNext)
                        referenceID += 1
                    }
                }
            }
            return .init(profiles: compact, stopsByShard: stopsByShard)
        }

        /// Take over the shards' profiles once every chunk has been merged into them. The shards
        /// may already have turned their profiles into labels; stops are never shared, so those
        /// labels are the ones `materialize` would build from all the profiles.
        mutating func finish(_ shards: [MergeShard], materialized: [Int: LabelProfile]? = nil) {
            for shard in shards { mergedCompact.merge(shard.profiles) { _, shardProfile in shardProfile } }
            materializedLabels = materialized
        }

        mutating func materialized(boardings: BoardingIndex) -> [Int: LabelProfile] {
            if !mergedCompact.isEmpty {
                labels = materializedLabels ?? Raptor.materialize(mergedCompact, boardings: boardings)
                if Raptor.verifyKernel {
                    precondition(labels.keys.sorted() == referenceNext.keys.sorted(), "Merged stops mismatch")
                    for stop in labels.keys {
                        let profile = labels[stop]!, reference = referenceNext[stop]!
                        precondition(profile.byWalk.map(\.id) == reference.byWalk.map(\.id)
                            && profile.byArrival.map(\.id) == reference.byArrival.map(\.id)
                            && profile.lastUnprotectedArrival?.id == reference.lastUnprotectedArrival?.id
                            && profile.lastPreferredArrival?.id == reference.lastPreferredArrival?.id,
                            "Materialized profile index mismatch")
                        let peers = profile.byIncomingTrip.filter { !$0.value.isEmpty }.mapValues { $0.map(\.id).sorted() }
                        let expectedPeers = reference.byIncomingTrip.filter { !$0.value.isEmpty }.mapValues { $0.map(\.id).sorted() }
                        precondition(peers == expectedPeers, "Materialized incoming-trip index mismatch")
                        let actual = labels[stop]!.ordered, expected = referenceNext[stop]!.ordered
                        precondition(actual.count == expected.count, "Merged profile count mismatch")
                        for (a, b) in zip(actual, expected) {
                            precondition(a.id == b.id && a.time == b.time && a.firstDeparture == b.firstDeparture
                                && a.minimumSlack == b.minimumSlack && a.totalSlack == b.totalSlack
                                && a.tripKey == b.tripKey && a.walkingSeconds == b.walkingSeconds
                                && String(reflecting: a.legs) == String(reflecting: b.legs), "Merged label mismatch")
                        }
                    }
                }
            }

            return labels
        }
    }
}

extension Raptor {
    /// A chunk's profiles, with the stops each shard has to merge and the ID of the first label at each.
    struct ChunkSplit: Sendable {
        let profiles: [Int: CompactProfile]
        let stopsByShard: [[(stop: Int, firstID: Int)]]

        var busyShards: [Int] { stopsByShard.indices.filter { !stopsByShard[$0].isEmpty } }

        func work(shard: Int, ticket: ChunkTicket?) -> ShardWork {
            .init(profiles: profiles, stops: stopsByShard[shard], ticket: ticket)
        }
    }

    /// One chunk's share of a shard: the stops of the chunk that belong to it, with the ID of
    /// the first label at each.
    struct ShardWork: Sendable {
        let profiles: [Int: CompactProfile]
        let stops: [(stop: Int, firstID: Int)]
        let ticket: ChunkTicket?
    }

    /// The merged profiles of a set of stops. A shard must receive the chunks in index order.
    struct MergeShard: Sendable {
        private(set) var profiles: [Int: CompactProfile] = [:]

        mutating func merge(_ work: ShardWork) {
            for (stop, firstID) in work.stops {
                let profile = work.profiles[stop]!
                var target = profiles.removeValue(forKey: stop) ?? CompactProfile()
                var id = firstID
                for slot in profile.ordered {
                    var key = profile.keys[slot]!
                    key.id = id; id += 1
                    let peers = target.byIncomingTrip[key.incomingTrip, default: 0]
                    if !target.isDominated(key, peers: peers),
                       !target.cannotEnter(key, peers: peers) {
                        _ = target.insert(key, path: profile.paths[slot]!)
                    }
                }
                profiles[stop] = target
            }
        }
    }

    /// Counts the shards that still have to read a chunk. The last one reports the chunk as merged,
    /// and the chunk's profiles are freed once the shards have dropped their work.
    final class ChunkTicket: Sendable {
        private let remaining: OSAllocatedUnfairLock<Int>
        private let merged: @Sendable () -> Void

        init(shards: Int, merged: @escaping @Sendable () -> Void) {
            remaining = .init(initialState: shards)
            self.merged = merged
        }

        func consumed() {
            if remaining.withLock({ $0 -= 1; return $0 == 0 }) { merged() }
        }
    }
}
