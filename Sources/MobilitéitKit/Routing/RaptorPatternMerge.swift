import Foundation

extension Raptor {
    /// Merge finished chunks in their original order. Releasing each chunk as
    /// soon as its predecessors finish avoids retaining the entire scan's
    /// temporary profiles and overlaps deterministic merging with later work.
    struct PatternScanMerge {
        var nextID: Int
        private var referenceID: Int
        private var mergedCompact: [Int: CompactProfile] = [:]
        private var referenceNext: [Int: LabelProfile] = [:]
        private var labels: [Int: LabelProfile] = [:]
        var patterns = 0, tripInstances = 0, boardingChecks = 0, feasibleBoardings = 0
        var alightingChecks = 0, labelAttempts = 0, retainedLabels = 0, rejectedBeforeAllocation = 0
        var slowestChunkMilliseconds = 0, summedChunkMilliseconds = 0
        var elapsedMilliseconds = 0.0

        init(nextID: Int) { self.nextID = nextID; self.referenceID = nextID }

        mutating func append(_ result: PatternScanResult) {
            let started = ContinuousClock.now
            patterns += result.scannedPatterns
            tripInstances += result.scannedTripInstances
            boardingChecks += result.boardingChecks
            feasibleBoardings += result.feasibleBoardings
            alightingChecks += result.alightingChecks
            labelAttempts += result.labelAttempts
            retainedLabels += result.retainedLabels
            rejectedBeforeAllocation += result.rejectedBeforeAllocation
            if let compact = result.compactLabels {
                for stop in compact.keys.sorted() {
                    let profile = compact[stop]!
                    var target = mergedCompact.removeValue(forKey: stop) ?? CompactProfile()
                    for slot in profile.ordered {
                        var key = profile.keys[slot]!
                        key.id = nextID; nextID += 1
                        let peers = target.byIncomingTrip[key.incomingTrip, default: 0]
                        if !target.isDominated(key, peers: peers),
                           !target.cannotEnter(key, peers: peers) {
                            _ = target.insert(key, path: profile.paths[slot]!)
                        }
                    }
                    mergedCompact[stop] = target
                }
                if Raptor.verifyKernel {
                    for stop in result.labels.keys.sorted() {
                        for label in result.labels[stop]!.ordered {
                            _ = Raptor.insert(label.replacingID(with: referenceID), at: stop, into: &referenceNext)
                            referenceID += 1
                        }
                    }
                }
            } else {
                for stop in result.labels.keys.sorted() {
                    for candidate in result.labels[stop]?.ordered ?? [] {
                        let candidate = candidate.replacingID(with: nextID)
                        nextID += 1
                        _ = Raptor.insert(candidate, at: stop, into: &labels)
                    }
                }
            }
            slowestChunkMilliseconds = max(slowestChunkMilliseconds, result.elapsedMilliseconds)
            summedChunkMilliseconds += result.elapsedMilliseconds
            elapsedMilliseconds += RoutingDiagnostics.elapsed(since: started)
        }

        mutating func materialized(boardings: BoardingIndex) -> [Int: LabelProfile] {
            if !mergedCompact.isEmpty {
                labels = Raptor.materialize(mergedCompact, boardings: boardings)
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
