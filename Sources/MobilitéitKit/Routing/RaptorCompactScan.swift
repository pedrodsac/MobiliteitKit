import Foundation

extension Raptor {
    struct BoardingIndex: Sendable {
        struct Profile: Sendable {
            let range: Range<Int>
            let byArrival: [Int]
        }
        let prefixRanks: [Int]
        let uniformDepth: Bool
        let sources: [Label]
        let profiles: [Profile?]

        init(_ labels: [Int: LabelProfile], stopCount: Int) {
            var sources: [Label] = []
            var profiles = [Profile?](repeating: nil, count: stopCount)
            for stop in labels.keys.sorted() {
                let start = sources.count
                sources.append(contentsOf: labels[stop]!.ordered)
                let range = start..<sources.count
                profiles[stop] = .init(range: range, byArrival: range.sorted {
                    sources[$0].timeSeconds == sources[$1].timeSeconds
                        ? sources[$0].id < sources[$1].id
                        : sources[$0].timeSeconds < sources[$1].timeSeconds
                })
            }
            // Every round adds exactly one ride. Rank its equal-length prefixes
            // once, instead of retaining and comparing entire trip keys in every
            // alighting candidate. A mixed-depth profile uses the reference scan.
            self.uniformDepth = Set(sources.map { $0.tripKey.count }).count <= 1
            let sorted = sources.indices.sorted { Raptor.precedes(sources[$0].tripKey, sources[$1].tripKey) }
            var ranks = [Int](repeating: 0, count: sources.count)
            var rank = 0
            for position in sorted.indices {
                if position > 0, sources[sorted[position]].tripKey != sources[sorted[position - 1]].tripKey { rank += 1 }
                ranks[sorted[position]] = rank
            }
            self.prefixRanks = ranks
            self.sources = sources; self.profiles = profiles
        }

        /// Iterate the original departure order, so temporary IDs and quota tie
        /// breaking do not change when impossible arrivals are excluded.
        @inline(__always) func eligibleSources(at stop: Int, through time: Double) -> (start: Int, mask: UInt64) {
            guard let profile = profiles[stop] else { return (0, 0) }
            var mask: UInt64 = 0
            for source in profile.byArrival {
                if sources[source].timeSeconds > time { break }
                mask |= 1 << (source - profile.range.lowerBound)
            }
            return (profile.range.lowerBound, mask)
        }
    }

    static func scanPatternsCompact(chunkIndex: Int, patternIDs: [Int], snapshot: RoutingSnapshot,
        query: RouteQuery, boardings: BoardingIndex, patternStartPositions: [Int],
        activeInstancesByPattern: [Int: [ActiveTripInstance]], reachableStops: [Bool]?,
        round: Int, maxRounds: Int, finalRoundAlightStops: Set<Int>) throws -> PatternScanResult {
        let started = ContinuousClock.now
        var next = [CompactProfile?](repeating: nil, count: snapshot.stops.count)
        var nextID = (chunkIndex + 1) * 1_000_000_000
        var scannedInstances = 0, boardingChecks = 0, feasibleBoardings = 0
        var alightingChecks = 0, attempts = 0, retained = 0, rejected = 0
        var decisions: [TransferDecisionKey: CachedTransferDecision] = [:]
        for patternID in patternIDs {
            try Task.checkCancellation()
            let startPosition = patternStartPositions[patternID]
            guard startPosition != Int.max else { continue }
            let instances = activeInstancesByPattern[patternID] ?? []
            scannedInstances += instances.count
            for instance in instances {
                try Task.checkCancellation()
                let tripIndex = instance.tripIndex
                let trip = snapshot.trips[tripIndex]
                let day = instance.serviceDay.date
                let preferred = query.preferences.preferredMode?.contains(
                    routeType: snapshot.routes[trip.route].type) ?? false
                // This eligibility is invariant for every boarding on the instance.
                let alights = trip.times.indices.filter {
                    let time = trip.times[$0]
                    return time.dropoff == 0 && instance.alightingAllowed[$0]
                        && instance.scheduledArrivals[$0] != nil && instance.effectiveArrivals[$0] != nil
                        && reachableStops?[time.stop] != false
                        && (round + 1 < maxRounds || finalRoundAlightStops.contains(time.stop))
                }
                var firstAlight = 0
                for boardPos in startPosition..<trip.times.count {
                    try Task.checkCancellation()
                    while firstAlight < alights.count && alights[firstAlight] <= boardPos { firstAlight += 1 }
                    let board = trip.times[boardPos]
                    guard let scheduled = instance.scheduledDepartures[boardPos],
                          let effective = instance.effectiveDepartures[boardPos],
                          board.pickup == 0, instance.boardingAllowed[boardPos]
                    else { continue }
                    let departure = effective.timeIntervalSinceReferenceDate
                    let eligible = boardings.eligibleSources(at: board.stop,
                        through: departure + Double(max(0, query.preferences.sameStopTransferShortfallSeconds)))
                    // Counts include the excluded arrivals for compatibility with
                    // the reference's logical work counters.
                    boardingChecks += boardings.profiles[board.stop]?.range.count ?? 0
                    var mask = eligible.mask
                    while mask != 0 {
                        let sourceIndex = eligible.start + mask.trailingZeroBitCount
                        mask &= mask - 1
                        let source = boardings.sources[sourceIndex]
                        guard !source.tripKey.contains(.init(trip: tripIndex, day: day)),
                              let transfer = cachedTransferDecision(snapshot: snapshot, incoming: source.lastTransit,
                                at: board.stop, outgoing: tripIndex, preferences: query.preferences, cache: &decisions)
                        else { continue }
                        let additional = source.lastTransit == nil ? 0
                            : max(0, transfer.requiredSeconds - source.transferWalkSeconds)
                        let shortfall = source.transferWalkSeconds == 0 ? transfer.allowedShortfallSeconds : 0
                        guard departure >= source.timeSeconds + Double(additional - shortfall) else { continue }
                        feasibleBoardings += 1
                        let slack = Int(departure - source.timeSeconds) - additional
                        let minimumSlack = source.lastTransit == nil ? source.minimumSlack : min(source.minimumSlack, slack)
                        let totalSlack = source.lastTransit == nil ? source.totalSlack : source.totalSlack + slack
                        let firstDeparture = source.firstDepartureSeconds ?? departure
                        var key = ScanKey(id: 0, arrival: 0, departure: firstDeparture,
                            doorDeparture: firstDeparture - Double(source.accessSeconds),
                            walkingSeconds: source.walkingSeconds, minimumSlack: minimumSlack,
                            totalSlack: totalSlack, preferred: source.containsPreferredMode || preferred,
                            prefixRank: boardings.prefixRanks[sourceIndex], incomingTrip: tripIndex, serviceDate: day)
                        for position in firstAlight..<alights.count {
                            let alightPos = alights[position]
                            let stop = trip.times[alightPos].stop
                            alightingChecks += 1
                            key.arrival = instance.effectiveArrivals[alightPos]!.timeIntervalSinceReferenceDate
                            key.id = nextID
                            if consider(key, profile: &next[stop], nextID: &nextID, attempts: &attempts,
                                rejected: &rejected, path: {
                                    .init(sourceIndex: sourceIndex, trip: tripIndex, board: board.stop, alight: stop,
                                        boardPos: boardPos, alightPos: alightPos, day: day, scheduledBoard: scheduled,
                                        scheduledAlight: instance.scheduledArrivals[alightPos]!, boardTime: effective,
                                        alightTime: instance.effectiveArrivals[alightPos]!, requiredTransferSeconds: additional)
                                }) { retained += 1 }
                        }
                    }
                }
            }
        }
        let compactLabels = Dictionary(uniqueKeysWithValues: next.indices.compactMap { stop in
            next[stop].map { (stop, $0) }
        })
        return .init(chunkIndex: chunkIndex, labels: [:], scannedPatterns: patternIDs.count,
            scannedTripInstances: scannedInstances, boardingChecks: boardingChecks, feasibleBoardings: feasibleBoardings,
            alightingChecks: alightingChecks, labelAttempts: attempts, retainedLabels: retained,
            rejectedBeforeAllocation: rejected, elapsedMilliseconds: Int(RoutingDiagnostics.elapsed(since: started)), compactLabels: compactLabels)
    }

    static func materialize(_ compactLabels: [Int: CompactProfile], boardings: BoardingIndex) -> [Int: LabelProfile] {
        var labels: [Int: LabelProfile] = [:]
        for stop in compactLabels.keys.sorted() {
            let compact = compactLabels[stop]!
            var profile = LabelProfile()
            for slot in compact.ordered {
                let key = compact.keys[slot]!, path = compact.paths[slot]!
                let source = boardings.sources[path.sourceIndex]
                let leg = TransitLeg(trip: path.trip, board: path.board, alight: path.alight,
                    boardPos: path.boardPos, alightPos: path.alightPos, day: path.day,
                    scheduledBoard: path.scheduledBoard, scheduledAlight: path.scheduledAlight,
                    boardTime: path.boardTime, alightTime: path.alightTime,
                    requiredTransferSecondsAfterWalking: path.requiredTransferSeconds)
                let label = Label(id: key.id, time: path.alightTime, prior: source, appendedLeg: .transit(leg),
                    firstStop: source.firstStop, firstDeparture: source.firstDeparture ?? path.boardTime,
                    lastTransit: leg, minimumSlack: key.minimumSlack, totalSlack: key.totalSlack,
                    accessSeconds: source.accessSeconds, accessDistance: source.accessDistance,
                    pathwaySeconds: source.pathwaySeconds, pathwayDistance: source.pathwayDistance,
                    transferWalkSeconds: 0, containsPreferredMode: key.preferred,
                    walkingStopsVisited: .one(stop), tripKey: source.tripKey.appending(.init(trip: path.trip, day: path.day)))
                _ = insert(label, into: &profile)
            }
            labels[stop] = profile
        }
        return labels
    }

    @inline(__always) static func consider(_ key: ScanKey, profile: inout CompactProfile?,
        nextID: inout Int, attempts: inout Int, rejected: inout Int, path: () -> ScanPath) -> Bool {
        if profile == nil { profile = CompactProfile() }
        if profile!.isDominated(key) { return false }
        nextID += 1; attempts += 1
        if profile!.cannotEnter(key) { rejected += 1; return false }
        return profile!.insert(key, path: path())
    }
}
