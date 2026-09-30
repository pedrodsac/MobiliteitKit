import Foundation

extension Raptor {
    static func search(snapshot: RoutingSnapshot, query: RouteQuery, access: [JourneyPlanningSession.Edge], egress: [JourneyPlanningSession.Edge], patches: [RealtimeTripPatch], walking: WalkingRouteCache?, profileHorizon: TimeInterval) async throws -> SearchResult {
        guard !access.isEmpty, !egress.isEmpty else { return .init(candidates: [], scannedPatterns: 0, scannedTripInstances: 0, cpuMilliseconds: 0, walkingTransferMilliseconds: 0, walkingTransferPairs: 0, maximumWorkerCount: 1, roundMetrics: []) }
        let maxRounds = (query.preferences.maxTransfers ?? max(1, snapshot.trips.count)) + 1
        let searchStart = query.direction == .arriveBy
            ? query.departureTime.addingTimeInterval(-profileHorizon) : query.departureTime
        let profileUpperBound = query.direction == .arriveBy
            ? query.departureTime : query.departureTime.addingTimeInterval(profileHorizon)
        let scheduledLowerBound: Date = switch query.realtimePolicy {
        case .disabled:
            searchStart
        case let .bestEffort(configuration, _):
            searchStart.addingTimeInterval(-TimeInterval(configuration.scheduledLookbackSeconds))
        }
        let relevantServiceDays = snapshot.serviceDays.filter { serviceDay in
            guard serviceDay.start <= profileUpperBound,
                  serviceDay.start.addingTimeInterval(TimeInterval(snapshot.info.maximumServiceTime.rawValue)) >= scheduledLowerBound
            else { return false }
            return true
        }
        let patchesByInstance = Dictionary(
            patches.compactMap { patch -> (PatchKey, PatchOverlay)? in
                guard let trip = snapshot.tripByID[patch.tripID] else { return nil }
                let times = snapshot.trips[trip].times
                let events = times.indices.compactMap { position -> (Int, RealtimeStopEventPatch)? in
                    let time = times[position]
                    guard let event = patch.event(stopID: snapshot.stops[time.stop].id, sequence: time.sequence)
                    else { return nil }
                    return (position, event)
                }
                return (
                    PatchKey(trip: trip, serviceDate: patch.serviceDate),
                    PatchOverlay(
                        status: patch.status,
                        eventsByPosition: Dictionary(events, uniquingKeysWith: { _, latest in latest })
                    )
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        var activeInstancesByPattern: [Int: [ActiveTripInstance]] = [:]
        var labels: [Int: LabelProfile] = [:]
        var nextLabelID = 0
        for a in access {
            _ = insert(.init(id: nextLabelID, time: searchStart.addingTimeInterval(TimeInterval(a.seconds)), firstStop: a.stop, firstDeparture: nil, lastTransit: nil, minimumSlack: .max, totalSlack: 0, accessSeconds: a.seconds, accessDistance: a.distance, pathwaySeconds: 0, pathwayDistance: 0, transferWalkSeconds: 0, containsPreferredMode: query.preferences.preferredMode == nil, walkingStopsVisited: .one(a.stop), tripKey: .init()), at: a.stop, into: &labels)
            nextLabelID += 1
        }
        var destination: [Candidate] = []
        var scannedPatterns = 0
        var scannedTripInstances = 0
        var cpuSeconds: TimeInterval = 0
        var walkingTransferSeconds: TimeInterval = 0
        var walkingTransferPairs = 0
        var maximumWorkerCount = 1
        var roundMetrics: [RoutingRoundMetrics] = []
        let egressStops = Set(egress.map(\.stop))
        let destinationReachability = maxRounds <= 8
            ? DestinationReachability(snapshot: snapshot, egressStops: egressStops, maxRides: maxRounds)
            : nil
        var finalRoundAlightStops = egressStops
        for from in snapshot.nearbyTransferStopsByStop.indices
        where snapshot.nearbyTransferStopsByStop[from].contains(where: { egressStops.contains($0) }) {
            finalRoundAlightStops.insert(from)
        }
        var predecessorQueue = Array(finalRoundAlightStops)
        var predecessorIndex = 0
        while predecessorIndex < predecessorQueue.count {
            let stop = predecessorQueue[predecessorIndex]
            predecessorIndex += 1
            for path in snapshot.pathsByTo[stop] {
                if finalRoundAlightStops.insert(path.from).inserted {
                    predecessorQueue.append(path.from)
                }
            }
        }
        for round in 0..<maxRounds { var next: [Int: LabelProfile] = [:]
            try Task.checkCancellation()
            let cpuStarted = ContinuousClock.now
            let remainingRides = maxRounds - round - 1
            // Patterns are constructed from route + ordered stop occurrences;
            // scanning only families touched by a label avoids walking the full
            // feed on every round.
            var markedFlags = Array(repeating: false, count: snapshot.patterns.count)
            var patternStartPositions = Array(repeating: Int.max, count: snapshot.patterns.count)
            var markedPatternIDs: [Int] = []
            for stop in labels.keys.sorted() {
                for occurrence in snapshot.patternOccurrencesByStop[stop] {
                    patternStartPositions[occurrence.pattern] = min(
                        patternStartPositions[occurrence.pattern],
                        occurrence.position
                    )
                    if !markedFlags[occurrence.pattern] {
                        markedFlags[occurrence.pattern] = true
                        markedPatternIDs.append(occurrence.pattern)
                    }
                }
            }
            if let destinationReachability {
                let lastAlight = destinationReachability.lastAlightPositionByRemainingRides[remainingRides]
                markedPatternIDs.removeAll {
                    lastAlight[$0] <= patternStartPositions[$0]
                }
            }
            markedPatternIDs.sort()
            let preparationStarted = ContinuousClock.now
            for patternID in markedPatternIDs where activeInstancesByPattern[patternID] == nil {
                activeInstancesByPattern[patternID] = activeTripInstances(
                    patternID: patternID,
                    snapshot: snapshot,
                    query: query,
                    relevantServiceDays: relevantServiceDays,
                    patchesByInstance: patchesByInstance,
                    scheduledLowerBound: scheduledLowerBound,
                    searchStart: searchStart,
                    profileUpperBound: profileUpperBound
                )
            }
            let preparationMilliseconds = Int(RoutingDiagnostics.elapsed(since: preparationStarted))
            let availableWorkers = min(maximumPatternWorkers, ProcessInfo.processInfo.activeProcessorCount)
            let workerCount = markedPatternIDs.count >= minimumPatternsForParallelScan
                ? min(availableWorkers, markedPatternIDs.count)
                : 1
            maximumWorkerCount = max(maximumWorkerCount, workerCount)
            let previousLabels = labels
            let boardings = BoardingIndex(labels, stopCount: snapshot.stops.count)
            let chunkSize = max(1, (markedPatternIDs.count + workerCount * 12 - 1) / (workerCount * 12))
            let chunks = stride(from: 0, to: markedPatternIDs.count, by: chunkSize).enumerated().map { chunkIndex, start in
                (index: chunkIndex, patterns: Array(markedPatternIDs[start..<min(start + chunkSize, markedPatternIDs.count)]))
            }
            let currentRound = round
            let finalRoundAlightStopSnapshot = finalRoundAlightStops
            let activeInstanceSnapshot = activeInstancesByPattern
            let patternStartPositionSnapshot = patternStartPositions
            let reachableStops = destinationReachability?.stopsByRemainingRides[remainingRides]
            let scanStarted = ContinuousClock.now
            let scanResults = try await withThrowingTaskGroup(of: PatternScanResult.self) { group in
                // Schedule costly chunks first, but merge in the original index order.
                let scheduled = chunks.sorted { a, b in
                    func cost(_ patterns: [Int]) -> Int {
                        patterns.reduce(0) { total, pattern in
                            total + (activeInstanceSnapshot[pattern]?.count ?? 0)
                                * snapshot.patterns[pattern].stops.count
                        }
                    }
                    let left = cost(a.patterns), right = cost(b.patterns)
                    return left == right ? a.index < b.index : left > right
                }
                var cursor = 0
                func enqueue() {
                    let chunk = scheduled[cursor]
                    cursor += 1
                    group.addTask(priority: .userInitiated) {
                        try scanPatterns(
                            chunkIndex: chunk.index,
                            patternIDs: chunk.patterns,
                            snapshot: snapshot,
                            query: query,
                            previousLabels: previousLabels,
                            boardings: boardings,
                            patternStartPositions: patternStartPositionSnapshot,
                            activeInstancesByPattern: activeInstanceSnapshot,
                            reachableStops: reachableStops,
                            round: currentRound,
                            maxRounds: maxRounds,
                            finalRoundAlightStops: finalRoundAlightStopSnapshot
                        )
                    }
                }
                for _ in 0..<min(workerCount, scheduled.count) { enqueue() }
                var values: [PatternScanResult] = []
                while let value = try await group.next() {
                    values.append(value)
                    if cursor < scheduled.count { enqueue() }
                }
                return values.sorted { $0.chunkIndex < $1.chunkIndex }
            }
            let scanMilliseconds = Int(RoutingDiagnostics.elapsed(since: scanStarted))
            let mergeStarted = ContinuousClock.now
            var roundBoardingChecks = 0
            var roundFeasibleBoardings = 0
            var roundAlightingChecks = 0
            var roundLabelAttempts = 0
            var roundRetainedLabels = 0
            var roundRejectedBeforeAllocation = 0
            var mergedCompact: [Int: CompactProfile] = [:]
            var referenceNext: [Int: LabelProfile] = [:]
            var referenceID = nextLabelID
            for result in scanResults {
                scannedPatterns += result.scannedPatterns
                scannedTripInstances += result.scannedTripInstances
                roundBoardingChecks += result.boardingChecks
                roundFeasibleBoardings += result.feasibleBoardings
                roundAlightingChecks += result.alightingChecks
                roundLabelAttempts += result.labelAttempts
                roundRetainedLabels += result.retainedLabels
                roundRejectedBeforeAllocation += result.rejectedBeforeAllocation
                if let compact = result.compactLabels {
                    for stop in compact.keys.sorted() {
                        let profile = compact[stop]!
                        for slot in profile.ordered {
                            var key = profile.keys[slot]!
                            key.id = nextLabelID; nextLabelID += 1
                            if mergedCompact[stop] == nil { mergedCompact[stop] = CompactProfile() }
                            if !mergedCompact[stop]!.isDominated(key), !mergedCompact[stop]!.cannotEnter(key) {
                                _ = mergedCompact[stop]!.insert(key, path: profile.paths[slot]!)
                            }
                        }
                    }
                    if verifyKernel {
                        for stop in result.labels.keys.sorted() {
                            for label in result.labels[stop]!.ordered {
                                _ = insert(label.replacingID(with: referenceID), at: stop, into: &referenceNext)
                                referenceID += 1
                            }
                        }
                    }
                } else {
                    for stop in result.labels.keys.sorted() {
                        for candidate in result.labels[stop]?.ordered ?? [] {
                            let candidate = candidate.replacingID(with: nextLabelID)
                            nextLabelID += 1
                            _ = insert(candidate, at: stop, into: &next)
                        }
                    }
                }
            }
            if !mergedCompact.isEmpty {
                next = materialize(mergedCompact, boardings: boardings)
                if verifyKernel {
                    precondition(next.keys.sorted() == referenceNext.keys.sorted(), "Merged stops mismatch")
                    for stop in next.keys {
                        let profile = next[stop]!, reference = referenceNext[stop]!
                        precondition(profile.byWalk.map(\.id) == reference.byWalk.map(\.id)
                            && profile.byArrival.map(\.id) == reference.byArrival.map(\.id)
                            && profile.lastUnprotectedArrival?.id == reference.lastUnprotectedArrival?.id
                            && profile.lastPreferredArrival?.id == reference.lastPreferredArrival?.id,
                            "Materialized profile index mismatch")
                        let peers = profile.byIncomingTrip.filter { !$0.value.isEmpty }.mapValues { $0.map(\.id).sorted() }
                        let expectedPeers = reference.byIncomingTrip.filter { !$0.value.isEmpty }.mapValues { $0.map(\.id).sorted() }
                        precondition(peers == expectedPeers, "Materialized incoming-trip index mismatch")
                        let actual = next[stop]!.ordered, expected = referenceNext[stop]!.ordered
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

            let mergeMilliseconds = Int(RoutingDiagnostics.elapsed(since: mergeStarted))
            roundMetrics.append(.init(
                tripPreparationMilliseconds: preparationMilliseconds,
                patternScanMilliseconds: scanMilliseconds,
                labelMergeMilliseconds: mergeMilliseconds,
                patterns: markedPatternIDs.count,
                tripInstances: scanResults.reduce(0) { $0 + $1.scannedTripInstances },
                boardingChecks: roundBoardingChecks,
                feasibleBoardings: roundFeasibleBoardings,
                alightingChecks: roundAlightingChecks,
                labelAttempts: roundLabelAttempts,
                retainedLabels: roundRetainedLabels,
                rejectedBeforeAllocation: roundRejectedBeforeAllocation,
                slowestChunkMilliseconds: scanResults.map(\.elapsedMilliseconds).max() ?? 0,
                summedChunkMilliseconds: scanResults.reduce(0) { $0 + $1.elapsedMilliseconds }
            ))
            if verifyKernel {
                var reference = next, referenceID = nextLabelID
                relaxPathways(snapshot: snapshot, labels: &reference, nextLabelID: &referenceID, skipEmptySources: false)
                relaxPathways(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID)
                precondition(referenceID == nextLabelID && reference.keys.sorted() == next.keys.sorted(), "Pathway pruning mismatch")
                for stop in next.keys {
                    precondition(next[stop]!.ordered.map { String(reflecting: $0.legs) } == reference[stop]!.ordered.map { String(reflecting: $0.legs) }, "Pathway result mismatch")
                    precondition(next[stop]!.ordered.map(\.id) == reference[stop]!.ordered.map(\.id), "Pathway ID mismatch")
                }
            } else {
                relaxPathways(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID)
            }
            cpuSeconds += RoutingDiagnostics.elapsed(since: cpuStarted) / 1_000
            let walkingStarted = ContinuousClock.now
            walkingTransferPairs += try await relaxWalkingTransfers(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID, walking: walking)
            walkingTransferSeconds += RoutingDiagnostics.elapsed(since: walkingStarted) / 1_000
            for e in egress { for label in next[e.stop]?.ordered ?? [] where label.firstDeparture != nil { destination.append(.init(legs: label.legs, firstStop: label.firstStop, lastStop: e.stop, firstDeparture: label.firstDeparture!, lastArrival: label.time, minimumTransferSlack: label.minimumSlack, totalTransferSlack: label.totalSlack, pathwaySeconds: label.pathwaySeconds, pathwayDistance: label.pathwayDistance)) } }
            labels = next; if labels.isEmpty { break }
        }
        return .init(candidates: destination, scannedPatterns: scannedPatterns, scannedTripInstances: scannedTripInstances, cpuMilliseconds: Int(cpuSeconds * 1_000), walkingTransferMilliseconds: Int(walkingTransferSeconds * 1_000), walkingTransferPairs: walkingTransferPairs, maximumWorkerCount: maximumWorkerCount, roundMetrics: roundMetrics)
    }
}
