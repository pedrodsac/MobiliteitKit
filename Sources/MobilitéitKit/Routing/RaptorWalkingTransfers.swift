import Foundation

extension Raptor {
    static func relaxPathways(snapshot: RoutingSnapshot, labels: inout [Int: LabelProfile], nextLabelID: inout Int, skipEmptySources: Bool = true, preferences: RoutingPreferences = .init()) {
        // A stop without outgoing pathways cannot insert a label or consume an
        // ID. Excluding these no-op sources preserves queue and merge order.
        var queue = labels.keys.sorted().filter { !skipEmptySources || !snapshot.pathsByFrom[$0].isEmpty }.flatMap { stop in
            (labels[stop]?.ordered ?? []).sorted { $0.id < $1.id }.map { (stop: stop, label: $0) }
        }
        var queueIndex = 0
        while queueIndex < queue.count {
            let source = queue[queueIndex]
            queueIndex += 1
            for path in snapshot.pathsByFrom[source.stop] {
                guard pathwayAllowed(path, preferences: preferences), !source.label.walkingStopsVisited.contains(path.to) else { continue }
                let arrival = source.label.time.addingTimeInterval(TimeInterval(path.seconds))
                let leg = PathwayLeg(from: path.from, to: path.to, seconds: path.seconds, distance: path.distance, mode: path.mode, stairCount: path.stairCount, maxSlope: path.maxSlope, minWidth: path.minWidth, departure: source.label.time, arrival: arrival)
                let label = Label(id: nextLabelID, time: arrival, prior: source.label, appendedLeg: .pathway(leg), firstStop: source.label.firstStop, firstDeparture: source.label.firstDeparture, lastTransit: source.label.lastTransit, minimumSlack: source.label.minimumSlack, totalSlack: source.label.totalSlack, accessSeconds: source.label.accessSeconds, accessDistance: source.label.accessDistance, pathwaySeconds: source.label.pathwaySeconds + path.seconds, pathwayDistance: source.label.pathwayDistance + path.distance, transferWalkSeconds: source.label.transferWalkSeconds + path.seconds, containsPreferredMode: source.label.containsPreferredMode, walkingStopsVisited: source.label.walkingStopsVisited.adding(path.to), tripKey: source.label.tripKey)
                nextLabelID += 1
                if insert(label, at: path.to, into: &labels) {
                    queue.append((stop: path.to, label: label))
                }
            }
        }
    }

    static func relaxWalkingTransfers(
        snapshot: RoutingSnapshot,
        labels: inout [Int: LabelProfile],
        nextLabelID: inout Int,
        walking: WalkingRouteCache?,
        reachableStops: [Bool]? = nil,
        boardingDeadlines: [Date]? = nil,
        egressStops: Set<Int> = [],
        canBoardAgain: Bool = true
    ) async throws -> Int {
        guard let walking else { return 0 }
        struct Pair: Hashable { let from: Int; let to: Int }
        var requests: [(from: Int, to: Int, source: Label, routeIndex: Int)] = []
        requests.reserveCapacity(labels.count * 3)
        var uniqueRequests: [WalkingRequest] = []
        var routeIndexByPair: [Pair: Int] = [:]
        let sourceStops = labels.keys.sorted { lhs, rhs in
            let a = labels[lhs]?.byArrival.first?.time ?? .distantFuture
            let b = labels[rhs]?.byArrival.first?.time ?? .distantFuture
            return a == b ? lhs < rhs : a < b
        }
        for from in sourceStops {
            let targets = snapshot.nearbyTransferStopsByStop[from]
            guard !targets.isEmpty else { continue }
            let eligible = (labels[from]?.ordered ?? []).filter { $0.lastTransit != nil }
                .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
            guard !eligible.isEmpty else { continue }
            for to in targets {
                // A global pair quota silently loses later interchanges in
                // dense profiles. Keep every potentially useful transfer;
                // destination topology can safely exclude impossible targets.
                guard reachableStops?[to] != false else { continue }
                // An egress target can finish the journey without another
                // vehicle. All other targets must still offer a boarding.
                let isEgress = egressStops.contains(to)
                guard isEgress || canBoardAgain else { continue }
                let deadline = isEgress ? Date.distantFuture : boardingDeadlines?[to] ?? .distantFuture
                guard eligible.contains(where: { !$0.walkingStopsVisited.contains(to) }) else { continue }
                try Task.checkCancellation()
                let fromCoordinate = snapshot.stops[from].model.coordinate
                let toCoordinate = snapshot.stops[to].model.coordinate
                // The pedestrian route is fetched once per stop pair. Apply it
                // to every retained arrival label: sampling only the first,
                // middle, and last arrival can discard the safer bus.
                for source in eligible {
                    guard !source.walkingStopsVisited.contains(to), source.time <= deadline else { continue }
                    let pair = Pair(from: from, to: to)
                    let routeIndex: Int
                    if let existing = routeIndexByPair[pair] {
                        routeIndex = existing
                    } else {
                        routeIndex = uniqueRequests.count
                        routeIndexByPair[pair] = routeIndex
                        uniqueRequests.append(.init(
                            source: fromCoordinate,
                            destination: toCoordinate,
                            departure: source.time
                        ))
                    }
                    requests.append((from, to, source, routeIndex))
                }
            }
        }
        try Task.checkCancellation()
        let routes = await walking.routes(uniqueRequests, maximumConcurrency: 4)
        try Task.checkCancellation()
        // Assign IDs in the original request order. Each target profile then
        // receives its own requests in that order, so targets are independent:
        // sources are immutable labels captured before any insertion.
        var worksByTarget: [Int: [WalkingTransferWork]] = [:]
        for item in requests {
            // A straight-line or unverified fallback cannot prove that a
            // connection between two boarding points is physically catchable.
            guard let route = routes[item.routeIndex], route.evidence == .routedPedestrian,
                  route.durationSeconds <= 15 * 60,
                  route.distanceMeters <= 1_500 else { continue }
            let arrival = item.source.time.addingTimeInterval(TimeInterval(route.durationSeconds))
            // Once the measured duration is known, do not retain a label that
            // has missed every eligible departure. Final walks remain valid.
            guard egressStops.contains(item.to)
                || arrival <= (boardingDeadlines?[item.to] ?? .distantFuture) else { continue }
            worksByTarget[item.to, default: []].append(.init(
                from: item.from, to: item.to, source: item.source, route: route,
                arrival: arrival, labelID: nextLabelID))
            nextLabelID += 1
        }
        let reference = verifyKernel ? labels : nil
        try await applyWalkingTransfers(worksByTarget, to: &labels)
        if var reference {
            // The original single loop, in global request order.
            for work in worksByTarget.values.joined().sorted(by: { $0.labelID < $1.labelID }) {
                applyWalkingTransfer(work, to: &reference[work.to])
            }
            precondition(reference.keys.sorted() == labels.keys.sorted(), "Walking transfer stops mismatch")
            for stop in labels.keys {
                let actual = labels[stop]!, expected = reference[stop]!
                precondition(actual.ordered.map(\.id) == expected.ordered.map(\.id)
                    && actual.byWalk.map(\.id) == expected.byWalk.map(\.id)
                    && actual.byArrival.map(\.id) == expected.byArrival.map(\.id)
                    && actual.lastUnprotectedArrival?.id == expected.lastUnprotectedArrival?.id
                    && actual.lastPreferredArrival?.id == expected.lastPreferredArrival?.id,
                    "Walking transfer profile mismatch")
            }
        }
        return uniqueRequests.count
    }

    struct WalkingTransferWork: Sendable {
        let from: Int; let to: Int; let source: Label; let route: WalkingRoute
        let arrival: Date; let labelID: Int
    }

    static let minimumTargetsForParallelWalking = 64

    /// Applies each target's ordered transfers to that target's profile only.
    static func applyWalkingTransfers(_ worksByTarget: [Int: [WalkingTransferWork]],
                                      to labels: inout [Int: LabelProfile]) async throws {
        let targets = worksByTarget.keys.sorted()
        let workerCount = min(maximumPatternWorkers, ProcessInfo.processInfo.activeProcessorCount)
        guard targets.count >= minimumTargetsForParallelWalking, workerCount > 1 else {
            for target in targets {
                for work in worksByTarget[target]! { applyWalkingTransfer(work, to: &labels[target]) }
            }
            return
        }
        let owned = targets.map { (target: $0, profile: labels.removeValue(forKey: $0)) }
        let chunkSize = max(1, (owned.count + workerCount * 4 - 1) / (workerCount * 4))
        try await withThrowingTaskGroup(of: [(Int, LabelProfile?)].self) { group in
            for start in stride(from: 0, to: owned.count, by: chunkSize) {
                let chunk = owned[start..<min(start + chunkSize, owned.count)]
                group.addTask(priority: .userInitiated) {
                    try chunk.map { entry in
                        try Task.checkCancellation()
                        var profile = entry.profile
                        for work in worksByTarget[entry.target]! { applyWalkingTransfer(work, to: &profile) }
                        return (entry.target, profile)
                    }
                }
            }
            for try await results in group {
                for (target, profile) in results { labels[target] = profile }
            }
        }
    }

    @inline(__always) static func applyWalkingTransfer(_ work: WalkingTransferWork, to profile: inout LabelProfile?) {
        let source = work.source, route = work.route
        guard !walkingCandidateCannotEnterProfile(profile, source: source,
            to: work.to, durationSeconds: route.durationSeconds, arrival: work.arrival,
            candidateID: work.labelID) else { return }
        let leg = WalkingTransferLeg(
            from: work.from,
            to: work.to,
            route: route,
            departure: source.time,
            arrival: work.arrival
        )
        let label = Label(
            id: work.labelID,
            time: work.arrival,
            prior: source, appendedLeg: .walkingTransfer(leg),
            firstStop: source.firstStop,
            firstDeparture: source.firstDeparture,
            lastTransit: source.lastTransit,
            minimumSlack: source.minimumSlack,
            totalSlack: source.totalSlack,
            accessSeconds: source.accessSeconds,
            accessDistance: source.accessDistance,
            pathwaySeconds: source.pathwaySeconds + route.durationSeconds,
            pathwayDistance: source.pathwayDistance + route.distanceMeters,
            transferWalkSeconds: source.transferWalkSeconds + route.durationSeconds,
            containsPreferredMode: source.containsPreferredMode,
            walkingStopsVisited: source.walkingStopsVisited.adding(work.to),
            tripKey: source.tripKey
        )
        if profile == nil { profile = LabelProfile() }
        _ = insert(label, into: &profile!)
    }
}
