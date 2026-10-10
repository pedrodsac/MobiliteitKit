import Foundation

extension Raptor {
    static func search(snapshot: RoutingSnapshot, query: RouteQuery, access: [JourneyPlanningSession.Edge], egress: [JourneyPlanningSession.Edge], patches: [RealtimeTripPatch], walking: WalkingRouteCache?, profileHorizon: TimeInterval, preparation: PreparationCache = .init()) async throws -> SearchResult {
        guard !access.isEmpty, !egress.isEmpty else { return .init(candidates: [], scannedPatterns: 0, scannedTripInstances: 0, cpuMilliseconds: 0, walkingTransferMilliseconds: 0, walkingTransferPairs: 0, maximumWorkerCount: 1, roundMetrics: []) }
        var preparation = preparation
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
            ? preparation.destination(snapshot: snapshot, stops: egressStops, rides: maxRounds)
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
            for from in snapshot.pathsByTo[stop].map(\.from) + snapshot.continuations.sourcesByStop[stop] {
                if finalRoundAlightStops.insert(from).inserted {
                    predecessorQueue.append(from)
                }
            }
        }
        let finalRoundReachable = snapshot.stops.indices.map { finalRoundAlightStops.contains($0) }
        let finalRoundLastAlight = snapshot.patterns.map { pattern in
            pattern.stops.indices.reversed().first { finalRoundReachable[pattern.stops[$0]] } ?? -1
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
                let lastAlight = remainingRides == 0 ? finalRoundLastAlight
                    : destinationReachability.lastAlightPositionByRemainingRides[remainingRides]
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
                    profileUpperBound: profileUpperBound, preparation: &preparation
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
            let reachableStops = remainingRides == 0 ? finalRoundReachable
                : destinationReachability?.stopsByRemainingRides[remainingRides]
            let scanStarted = ContinuousClock.now
            var merge = PatternScanMerge(nextID: nextLabelID)
            try await withThrowingTaskGroup(of: PatternScanResult.self) { group in
                var availableScratch: [CompactScratch] = []
                // Schedule costly chunks first, but merge in the original index order.
                let schedulingWindow = max(1, workerCount * 2)
                let scheduled = stride(from: 0, to: chunks.count, by: schedulingWindow).flatMap { start in
                    chunks[start..<min(start + schedulingWindow, chunks.count)].sorted { a, b in
                        func cost(_ patterns: [Int]) -> Int {
                            patterns.reduce(0) { total, pattern in
                                total + (activeInstanceSnapshot[pattern]?.count ?? 0)
                                    * snapshot.patterns[pattern].stops.count
                            }
                        }
                        let left = cost(a.patterns), right = cost(b.patterns)
                        return left == right ? a.index < b.index : left > right
                    }
                }
                var cursor = 0
                var active = 0
                func enqueue() {
                    let chunk = scheduled[cursor]
                    cursor += 1
                    active += 1
                    let scratch = availableScratch.popLast() ?? CompactScratch()
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
                            finalRoundAlightStops: finalRoundAlightStopSnapshot, scratch: scratch
                        )
                    }
                }
                for _ in 0..<min(workerCount, scheduled.count) { enqueue() }
                var pending: [Int: PatternScanResult] = [:]
                var nextChunk = 0
                while var value = try await group.next() {
                    if let scratch = value.scratch { availableScratch.append(scratch); value.scratch = nil }
                    active -= 1
                    pending[value.chunkIndex] = value
                    while let ready = pending.removeValue(forKey: nextChunk) {
                        merge.append(ready)
                        nextChunk += 1
                    }
                    // Every earlier chunk in this window has already started
                    // before the completed buffer can fill. Bound that buffer
                    // instead of retaining all workers' full profile arrays.
                    while active < workerCount, cursor < scheduled.count, pending.count < schedulingWindow {
                        enqueue()
                    }
                }
                precondition(pending.isEmpty && nextChunk == chunks.count)
            }
            // Charge serial merge work once, even when worker scans overlap it.
            let scanMilliseconds = Int(max(0, RoutingDiagnostics.elapsed(since: scanStarted) - merge.elapsedMilliseconds))
            let mergeStarted = ContinuousClock.now
            next = merge.materialized(boardings: boardings)
            nextLabelID = merge.nextID
            scannedPatterns += merge.patterns
            scannedTripInstances += merge.tripInstances

            if snapshot.hasContinuations {
                try relaxContinuations(snapshot: snapshot, query: query, serviceDays: relevantServiceDays,
                    patches: patchesByInstance, searchStart: searchStart, scheduledLowerBound: scheduledLowerBound,
                    upperBound: profileUpperBound, reachableStops: reachableStops, preparation: &preparation,
                    labels: &next, nextLabelID: &nextLabelID)
            }

            let mergeMilliseconds = Int(merge.elapsedMilliseconds + RoutingDiagnostics.elapsed(since: mergeStarted))
            roundMetrics.append(.init(
                tripPreparationMilliseconds: preparationMilliseconds,
                patternScanMilliseconds: scanMilliseconds,
                labelMergeMilliseconds: mergeMilliseconds,
                patterns: markedPatternIDs.count,
                tripInstances: merge.tripInstances,
                boardingChecks: merge.boardingChecks,
                feasibleBoardings: merge.feasibleBoardings,
                alightingChecks: merge.alightingChecks,
                labelAttempts: merge.labelAttempts,
                retainedLabels: merge.retainedLabels,
                rejectedBeforeAllocation: merge.rejectedBeforeAllocation,
                slowestChunkMilliseconds: merge.slowestChunkMilliseconds,
                summedChunkMilliseconds: merge.summedChunkMilliseconds
            ))
            if verifyKernel {
                var reference = next, referenceID = nextLabelID
                relaxPathways(snapshot: snapshot, labels: &reference, nextLabelID: &referenceID, skipEmptySources: false, preferences: query.preferences)
                relaxPathways(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID, preferences: query.preferences)
                precondition(referenceID == nextLabelID && reference.keys.sorted() == next.keys.sorted(), "Pathway pruning mismatch")
                for stop in next.keys {
                    precondition(next[stop]!.ordered.map { String(reflecting: $0.legs) } == reference[stop]!.ordered.map { String(reflecting: $0.legs) }, "Pathway result mismatch")
                    precondition(next[stop]!.ordered.map(\.id) == reference[stop]!.ordered.map(\.id), "Pathway ID mismatch")
                }
            } else {
                relaxPathways(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID, preferences: query.preferences)
            }
            cpuSeconds += RoutingDiagnostics.elapsed(since: cpuStarted) / 1_000
            let walkingStarted = ContinuousClock.now
            if query.preferences.wheelchair != .required { walkingTransferPairs += try await relaxWalkingTransfers(snapshot: snapshot, labels: &next, nextLabelID: &nextLabelID, walking: walking, reachableStops: reachableStops) }
            walkingTransferSeconds += RoutingDiagnostics.elapsed(since: walkingStarted) / 1_000
            for e in egress { for label in next[e.stop]?.ordered ?? [] where label.firstDeparture != nil { destination.append(.init(legs: label.legs, firstStop: label.firstStop, lastStop: e.stop, firstDeparture: label.firstDeparture!, lastArrival: label.time, minimumTransferSlack: label.minimumSlack, totalTransferSlack: label.totalSlack, pathwaySeconds: label.pathwaySeconds, pathwayDistance: label.pathwayDistance)) } }
            labels = next; if labels.isEmpty { break }
        }
        return .init(candidates: destination, scannedPatterns: scannedPatterns, scannedTripInstances: scannedTripInstances, cpuMilliseconds: Int(cpuSeconds * 1_000), walkingTransferMilliseconds: Int(walkingTransferSeconds * 1_000), walkingTransferPairs: walkingTransferPairs, maximumWorkerCount: maximumWorkerCount, roundMetrics: roundMetrics, preparation: preparation)
    }
}
