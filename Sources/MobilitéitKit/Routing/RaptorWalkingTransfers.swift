import Foundation

extension Raptor {
    static func relaxPathways(snapshot: RoutingSnapshot, labels: inout [Int: LabelProfile], nextLabelID: inout Int) {
        var queue = labels.keys.sorted().flatMap { stop in
            (labels[stop]?.ordered ?? []).sorted { $0.id < $1.id }.map { (stop: stop, label: $0) }
        }
        var queueIndex = 0
        while queueIndex < queue.count {
            let source = queue[queueIndex]
            queueIndex += 1
            for path in snapshot.pathsByFrom[source.stop] {
                guard !source.label.walkingStopsVisited.contains(path.to) else { continue }
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
        walking: WalkingRouteCache?
    ) async throws -> Int {
        guard let walking else { return 0 }
        struct Pair: Hashable { let from: Int; let to: Int }
        var requests: [(from: Int, to: Int, source: Label, routeIndex: Int)] = []
        requests.reserveCapacity(maximumWalkingTransferRequestsPerRound * 3)
        var uniqueRequests: [WalkingRequest] = []
        var routeIndexByPair: [Pair: Int] = [:]
        var distinctPairs = 0
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
                guard eligible.contains(where: { !$0.walkingStopsVisited.contains(to) }) else { continue }
                guard distinctPairs < maximumWalkingTransferRequestsPerRound else { break }
                distinctPairs += 1
                try Task.checkCancellation()
                let fromCoordinate = snapshot.stops[from].model.coordinate
                let toCoordinate = snapshot.stops[to].model.coordinate
                // The pedestrian route is fetched once per stop pair. Apply it
                // to every retained arrival label: sampling only the first,
                // middle, and last arrival can discard the safer bus.
                for source in eligible {
                    guard !source.walkingStopsVisited.contains(to) else { continue }
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
            if distinctPairs == maximumWalkingTransferRequestsPerRound { break }
        }
        try Task.checkCancellation()
        let routes = await walking.routes(uniqueRequests, maximumConcurrency: 4)
        try Task.checkCancellation()
        for item in requests {
            // A straight-line or unverified fallback cannot prove that a
            // connection between two boarding points is physically catchable.
            guard let route = routes[item.routeIndex], route.evidence == .routedPedestrian,
                  route.durationSeconds <= 15 * 60,
                  route.distanceMeters <= 1_500 else { continue }
            let arrival = item.source.time.addingTimeInterval(TimeInterval(route.durationSeconds))
            let leg = WalkingTransferLeg(
                from: item.from,
                to: item.to,
                route: route,
                departure: item.source.time,
                arrival: arrival
            )
            let label = Label(
                id: nextLabelID,
                time: arrival,
                prior: item.source, appendedLeg: .walkingTransfer(leg),
                firstStop: item.source.firstStop,
                firstDeparture: item.source.firstDeparture,
                lastTransit: item.source.lastTransit,
                minimumSlack: item.source.minimumSlack,
                totalSlack: item.source.totalSlack,
                accessSeconds: item.source.accessSeconds,
                accessDistance: item.source.accessDistance,
                pathwaySeconds: item.source.pathwaySeconds + route.durationSeconds,
                pathwayDistance: item.source.pathwayDistance + route.distanceMeters,
                transferWalkSeconds: item.source.transferWalkSeconds + route.durationSeconds,
                containsPreferredMode: item.source.containsPreferredMode,
                walkingStopsVisited: item.source.walkingStopsVisited.adding(item.to),
                tripKey: item.source.tripKey
            )
            nextLabelID += 1
            _ = insert(label, at: item.to, into: &labels)
        }
        return uniqueRequests.count
    }
}
