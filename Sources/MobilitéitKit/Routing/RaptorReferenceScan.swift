import Foundation

extension Raptor {
    static let verifyKernel = ProcessInfo.processInfo.environment["ROUTING_VERIFY_KERNEL"] == "1"
    static let referenceKernel = ProcessInfo.processInfo.environment["ROUTING_REFERENCE_KERNEL"] == "1"

    static func scanPatterns(chunkIndex: Int, patternIDs: [Int], snapshot: RoutingSnapshot,
        query: RouteQuery, previousLabels: [Int: LabelProfile], boardings: BoardingIndex,
        patternStartPositions: [Int], activeInstancesByPattern: [Int: [ActiveTripInstance]],
        reachableStops: [Bool]?, round: Int, maxRounds: Int, finalRoundAlightStops: Set<Int>) throws -> PatternScanResult {
        if referenceKernel || !boardings.uniformDepth {
            return try scanPatternsReference(chunkIndex: chunkIndex, patternIDs: patternIDs, snapshot: snapshot,
                query: query, previousLabels: previousLabels, patternStartPositions: patternStartPositions,
                activeInstancesByPattern: activeInstancesByPattern, reachableStops: reachableStops,
                round: round, maxRounds: maxRounds, finalRoundAlightStops: finalRoundAlightStops)
        }
        var result = try scanPatternsCompact(chunkIndex: chunkIndex, patternIDs: patternIDs, snapshot: snapshot,
            query: query, boardings: boardings, patternStartPositions: patternStartPositions,
            activeInstancesByPattern: activeInstancesByPattern, reachableStops: reachableStops,
            round: round, maxRounds: maxRounds, finalRoundAlightStops: finalRoundAlightStops)
        if verifyKernel {
            result = .init(chunkIndex: result.chunkIndex, labels: materialize(result.compactLabels!, boardings: boardings),
                scannedPatterns: result.scannedPatterns, scannedTripInstances: result.scannedTripInstances,
                boardingChecks: result.boardingChecks, feasibleBoardings: result.feasibleBoardings, alightingChecks: result.alightingChecks,
                labelAttempts: result.labelAttempts, retainedLabels: result.retainedLabels, rejectedBeforeAllocation: result.rejectedBeforeAllocation,
                elapsedMilliseconds: result.elapsedMilliseconds, compactLabels: result.compactLabels)
            let expected = try scanPatternsReference(chunkIndex: chunkIndex, patternIDs: patternIDs, snapshot: snapshot,
                query: query, previousLabels: previousLabels, patternStartPositions: patternStartPositions,
                activeInstancesByPattern: activeInstancesByPattern, reachableStops: reachableStops,
                round: round, maxRounds: maxRounds, finalRoundAlightStops: finalRoundAlightStops)
            precondition(result.labels.keys.sorted() == expected.labels.keys.sorted(), "Kernel stop mismatch")
            for stop in result.labels.keys {
                let actual = result.labels[stop]!.ordered, original = expected.labels[stop]!.ordered
                precondition(actual.count == original.count, "Kernel profile count mismatch")
                for (a, b) in zip(actual, original) {
                    precondition(a.id == b.id && a.time == b.time && a.firstDeparture == b.firstDeparture
                        && a.minimumSlack == b.minimumSlack && a.totalSlack == b.totalSlack
                        && a.tripKey == b.tripKey && a.walkingSeconds == b.walkingSeconds
                        && String(reflecting: a.legs) == String(reflecting: b.legs), "Kernel label mismatch")
                }
            }
        }
        return result
    }

    static func scanPatternsReference(
        chunkIndex: Int,
        patternIDs: [Int],
        snapshot: RoutingSnapshot,
        query: RouteQuery,
        previousLabels: [Int: LabelProfile],
        patternStartPositions: [Int],
        activeInstancesByPattern: [Int: [ActiveTripInstance]],
        reachableStops: [Bool]?,
        round: Int,
        maxRounds: Int,
        finalRoundAlightStops: Set<Int>
    ) throws -> PatternScanResult {
        let scanStarted = ContinuousClock.now
        var next = [LabelProfile?](repeating: nil, count: snapshot.stops.count)
        var nextLabelID = (chunkIndex + 1) * 1_000_000_000
        var scannedTripInstances = 0
        var boardingChecks = 0
        var feasibleBoardings = 0
        var alightingChecks = 0
        var labelAttempts = 0
        var retainedLabels = 0
        var rejectedBeforeAllocation = 0
        var transferDecisions: [TransferDecisionKey: CachedTransferDecision] = [:]

        for patternID in patternIDs {
            try Task.checkCancellation()
            let startPosition = patternStartPositions[patternID]
            guard startPosition != Int.max else { continue }
            let instances = activeInstancesByPattern[patternID] ?? []
            scannedTripInstances += instances.count
            for instance in instances {
                try Task.checkCancellation()
                let tripIndex = instance.tripIndex
                let trip = snapshot.trips[tripIndex]
                let serviceDay = instance.serviceDay
                let day = serviceDay.date
                let tripMatchesPreferredMode = query.preferences.preferredMode?.contains(
                    routeType: snapshot.routes[trip.route].type
                ) ?? false
                let scheduledDepartures = instance.scheduledDepartures
                let scheduledArrivals = instance.scheduledArrivals
                let effectiveDepartures = instance.effectiveDepartures
                let effectiveArrivals = instance.effectiveArrivals
                let eligibleAlights = trip.times.indices.filter { position in
                    let stopTime = trip.times[position]
                    return stopTime.dropoff == 0
                        && instance.alightingAllowed[position]
                        && scheduledArrivals[position] != nil
                        && effectiveArrivals[position] != nil
                        && reachableStops?[stopTime.stop] != false
                        && (round + 1 < maxRounds || finalRoundAlightStops.contains(stopTime.stop))
                }

                for boardPos in startPosition..<trip.times.count {
                        try Task.checkCancellation()
                        let boardTime = trip.times[boardPos]
                        guard let scheduled = scheduledDepartures[boardPos],
                              let effective = effectiveDepartures[boardPos],
                              boardTime.pickup == 0,
                              instance.boardingAllowed[boardPos],
                              let sources = previousLabels[boardTime.stop]?.ordered
                        else { continue }
                        let latestPossibleArrival = effective.addingTimeInterval(
                            TimeInterval(max(0, query.preferences.sameStopTransferShortfallSeconds))
                        )

                        for source in sources {
                            boardingChecks += 1
                            guard source.time <= latestPossibleArrival else { continue }
                            guard !source.tripKey.contains(.init(trip: tripIndex, day: day)) else { continue }
                            guard let transfer = cachedTransferDecision(
                                snapshot: snapshot,
                                incoming: source.lastTransit,
                                at: boardTime.stop,
                                outgoing: tripIndex,
                                preferences: query.preferences,
                                cache: &transferDecisions
                            ) else { continue }
                            let additionalTransferSeconds = source.lastTransit == nil
                                ? 0
                                : max(0, transfer.requiredSeconds - source.transferWalkSeconds)
                            let allowedShortfall = source.transferWalkSeconds == 0
                                ? transfer.allowedShortfallSeconds : 0
                            guard effective >= source.time.addingTimeInterval(
                                TimeInterval(additionalTransferSeconds - allowedShortfall)
                            ) else { continue }
                            feasibleBoardings += 1
                            let slack = Int(effective.timeIntervalSince(source.time))
                                - additionalTransferSeconds
                            let minimumSlack = source.lastTransit == nil
                                ? source.minimumSlack
                                : min(source.minimumSlack, slack)
                            let totalSlack = source.lastTransit == nil
                                ? source.totalSlack
                                : source.totalSlack + slack

                            for alightPos in eligibleAlights where alightPos > boardPos {
                                alightingChecks += 1
                                let alightTime = trip.times[alightPos]
                                let scheduledArrival = scheduledArrivals[alightPos]!
                                let effectiveArrival = effectiveArrivals[alightPos]!
                                if transitCandidateIsDominated(
                                    by: next[alightTime.stop],
                                    source: source,
                                    tripIndex: tripIndex,
                                    day: day,
                                    alightStop: alightTime.stop,
                                    departure: effective,
                                    arrival: effectiveArrival,
                                    minimumSlack: minimumSlack,
                                    totalSlack: totalSlack,
                                    containsPreferredMode: source.containsPreferredMode || tripMatchesPreferredMode
                                ) { continue }
                                let candidateID = nextLabelID
                                nextLabelID += 1
                                labelAttempts += 1
                                if cannotEnterFullProfile(
                                    next[alightTime.stop], source: source,
                                    tripIndex: tripIndex, day: day, candidateID: candidateID,
                                    alightStop: alightTime.stop,
                                    departure: effective, arrival: effectiveArrival,
                                    minimumSlack: minimumSlack, totalSlack: totalSlack,
                                    containsPreferredMode: source.containsPreferredMode || tripMatchesPreferredMode
                                ) {
                                    rejectedBeforeAllocation += 1
                                    continue
                                }
                                let leg = TransitLeg(
                                    trip: tripIndex,
                                    board: boardTime.stop,
                                    alight: alightTime.stop,
                                    boardPos: boardPos,
                                    alightPos: alightPos,
                                    day: day,
                                    scheduledBoard: scheduled,
                                    scheduledAlight: scheduledArrival,
                                    boardTime: effective,
                                    alightTime: effectiveArrival,
                                    requiredTransferSecondsAfterWalking: additionalTransferSeconds
                                )
                                let label = Label(
                                    id: candidateID,
                                    time: effectiveArrival,
                                    prior: source, appendedLeg: .transit(leg),
                                    firstStop: source.firstStop,
                                    firstDeparture: source.firstDeparture ?? effective,
                                    lastTransit: leg,
                                    minimumSlack: minimumSlack,
                                    totalSlack: totalSlack,
                                    accessSeconds: source.accessSeconds,
                                    accessDistance: source.accessDistance,
                                    pathwaySeconds: source.pathwaySeconds,
                                    pathwayDistance: source.pathwayDistance,
                                    transferWalkSeconds: 0,
                                    containsPreferredMode: source.containsPreferredMode || tripMatchesPreferredMode,
                                    walkingStopsVisited: .one(alightTime.stop),
                                    tripKey: source.tripKey.appending(.init(trip: tripIndex, day: day))
                                )
                                if next[alightTime.stop] == nil {
                                    next[alightTime.stop] = LabelProfile()
                                }
                                if insert(label, into: &next[alightTime.stop]!) {
                                    retainedLabels += 1
                                }
                            }
                        }
                }
            }
        }
        var labelsByStop: [Int: LabelProfile] = [:]
        for (stop, profile) in next.enumerated() {
            if let profile { labelsByStop[stop] = profile }
        }
        return .init(
            chunkIndex: chunkIndex,
            labels: labelsByStop,
            scannedPatterns: patternIDs.count,
            scannedTripInstances: scannedTripInstances,
            boardingChecks: boardingChecks,
            feasibleBoardings: feasibleBoardings,
            alightingChecks: alightingChecks,
            labelAttempts: labelAttempts,
            retainedLabels: retainedLabels,
            rejectedBeforeAllocation: rejectedBeforeAllocation,
            elapsedMilliseconds: Int(RoutingDiagnostics.elapsed(since: scanStarted))
        )
    }
}
