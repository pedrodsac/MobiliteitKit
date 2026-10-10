import Foundation

enum Raptor {
    // Retain enough non-dominated prefixes to fill a five-result page while
    // keeping regional, full-feed searches bounded.
    static let profileWidth = 48
    // Walking providers can be backed by a detailed local graph or a network
    // fallback. Bound automatic interchange probes so a broad regional search
    // never turns into one directions request for every alighting stop.
    static let maximumWalkingTransferRequestsPerRound = 96
    static let minimumPatternsForParallelScan = 32
    static let maximumPatternWorkers = 10
    #if DEBUG
    static let verifyProfile = ProcessInfo.processInfo.environment["ROUTING_VERIFY_PROFILE"] == "1"
    #endif
    static let fullProfileHorizon: TimeInterval = 86_400
    struct TripInstance: Hashable, Sendable { let trip: Int; let day: GTFSDate }
    struct TransitLeg: Sendable { let trip: Int; let board: Int; let alight: Int; let boardPos: Int; let alightPos: Int; let day: GTFSDate; let scheduledBoard: Date; let scheduledAlight: Date; let boardTime: Date; let alightTime: Date; let requiredTransferSecondsAfterWalking: Int; var continuesFromPrevious = false; var boardingDeadline: Date? = nil }
    struct PathwayLeg: Sendable { let from: Int; let to: Int; let seconds: Int; let distance: Double; let mode: Int; let stairCount: Int?; let maxSlope: Double?; let minWidth: Double?; let departure: Date; let arrival: Date }
    struct WalkingTransferLeg: Sendable { let from: Int; let to: Int; let route: WalkingRoute; let departure: Date; let arrival: Date }
    enum Leg: Sendable { case transit(TransitLeg); case pathway(PathwayLeg); case walkingTransfer(WalkingTransferLeg) }
    struct Candidate: Sendable {
        let legs: [Leg]; let firstStop: Int; let lastStop: Int; let firstDeparture: Date; let lastArrival: Date
        let minimumTransferSlack: Int; let totalTransferSlack: Int; let pathwaySeconds: Int; let pathwayDistance: Double
        let transitLegs: [TransitLeg]
        init(legs: [Leg], firstStop: Int, lastStop: Int, firstDeparture: Date, lastArrival: Date,
             minimumTransferSlack: Int, totalTransferSlack: Int, pathwaySeconds: Int, pathwayDistance: Double) {
            self.legs = legs; self.firstStop = firstStop; self.lastStop = lastStop
            self.firstDeparture = firstDeparture; self.lastArrival = lastArrival
            self.minimumTransferSlack = minimumTransferSlack; self.totalTransferSlack = totalTransferSlack
            self.pathwaySeconds = pathwaySeconds; self.pathwayDistance = pathwayDistance
            transitLegs = legs.compactMap { if case let .transit(leg) = $0 { leg } else { nil } }
        }
        var firstTransit: TransitLeg? { transitLegs.first }
        var lastTransit: TransitLeg? { transitLegs.last }
        func tripInstanceKey(snapshot: RoutingSnapshot) -> String {
            let rides = transitLegs.map {
                "\(snapshot.trips[$0.trip].id)@\($0.day.compactString):\($0.boardPos)-\($0.alightPos)"
            }.joined(separator: "|")
            return "\(firstStop)>\(lastStop):\(rides)"
        }
        func equivalentTransferKey(snapshot: RoutingSnapshot) -> String {
            let rides = transitLegs
            let vehicles = rides.map { "\(snapshot.trips[$0.trip].id)@\($0.day.compactString)" }
                .joined(separator: "|")
            return "\(firstStop)>\(lastStop):\(rides.first?.boardPos ?? -1)-\(rides.last?.alightPos ?? -1):\(vehicles)"
        }
    }
    struct SearchResult: Sendable {
        let candidates: [Candidate]
        let scannedPatterns: Int
        let scannedTripInstances: Int
        let cpuMilliseconds: Int
        let walkingTransferMilliseconds: Int
        let walkingTransferPairs: Int
        let maximumWorkerCount: Int
        let roundMetrics: [RoutingRoundMetrics]
        var preparation = PreparationCache()
    }
    struct PatchKey: Hashable, Sendable { let trip: Int; let serviceDate: GTFSDate }
    struct PatchOverlay: Equatable, Sendable {
        let status: RealtimeTripStatus
        let eventsByPosition: [Int: RealtimeStopEventPatch]
    }
    enum WalkingVisits: Hashable, Sendable {
        case one(Int)
        case multiple(Set<Int>)

        var count: Int {
            switch self {
            case .one: 1
            case let .multiple(stops): stops.count
            }
        }

        func contains(_ stop: Int) -> Bool {
            switch self {
            case let .one(only): only == stop
            case let .multiple(stops): stops.contains(stop)
            }
        }

        func adding(_ stop: Int) -> Self {
            switch self {
            case let .one(only): return only == stop ? self : .multiple([only, stop])
            case var .multiple(stops):
                stops.insert(stop)
                return .multiple(stops)
            }
        }
    }
    struct TripKey: Equatable, Sendable {
        var first: TripInstance?
        var second: TripInstance?
        var third: TripInstance?
        var fourth: TripInstance?
        var overflow: [TripInstance]? = nil
        private(set) var count = 0

        var last: TripInstance? { count == 0 ? nil : self[count - 1] }

        subscript(_ index: Int) -> TripInstance {
            switch index {
            case 0: first!
            case 1: second!
            case 2: third!
            case 3: fourth!
            default: overflow![index - 4]
            }
        }

        func contains(_ value: TripInstance) -> Bool {
            for index in 0..<count where self[index] == value { return true }
            return false
        }

        func appending(_ value: TripInstance) -> Self {
            var result = self
            switch count {
            case 0: result.first = value
            case 1: result.second = value
            case 2: result.third = value
            case 3: result.fourth = value
            default: result.overflow = (result.overflow ?? []) + [value]
            }
            result.count += 1
            return result
        }

        func hasPrefix(_ other: Self) -> Bool {
            guard count >= other.count else { return false }
            for index in 0..<other.count where self[index] != other[index] { return false }
            return true
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.count == rhs.count && lhs.hasPrefix(rhs)
        }
    }
    final class Label: Sendable {
        let timeSeconds: Double; let firstDepartureSeconds: Double?
        let id: Int; let time: Date; let prior: Label?; let appendedLeg: Leg?; let legCount: Int
        let firstStop: Int; let firstDeparture: Date?
        let doorDeparture: Date?; let walkingSeconds: Int
        let lastTransit: TransitLeg?; let minimumSlack: Int; let totalSlack: Int; let accessSeconds: Int; let accessDistance: Double; let pathwaySeconds: Int; let pathwayDistance: Double; let transferWalkSeconds: Int
        let containsPreferredMode: Bool
        let walkingStopsVisited: WalkingVisits
        let tripKey: TripKey

        var legs: [Leg] {
            var result: [Leg] = []
            result.reserveCapacity(legCount)
            var cursor: Label? = self
            while let label = cursor {
                if let leg = label.appendedLeg { result.append(leg) }
                cursor = label.prior
            }
            return result.reversed()
        }

        init(id: Int, time: Date, prior: Label? = nil, appendedLeg: Leg? = nil,
             firstStop: Int, firstDeparture: Date?,
             lastTransit: TransitLeg?, minimumSlack: Int, totalSlack: Int,
             accessSeconds: Int, accessDistance: Double, pathwaySeconds: Int,
             pathwayDistance: Double, transferWalkSeconds: Int, containsPreferredMode: Bool,
             walkingStopsVisited: WalkingVisits, tripKey: TripKey) {
            self.timeSeconds = time.timeIntervalSinceReferenceDate
            self.firstDepartureSeconds = firstDeparture?.timeIntervalSinceReferenceDate
            self.id = id; self.time = time; self.prior = prior; self.appendedLeg = appendedLeg
            self.legCount = (prior?.legCount ?? 0) + (appendedLeg == nil ? 0 : 1)
            self.firstStop = firstStop
            self.firstDeparture = firstDeparture; self.lastTransit = lastTransit
            self.doorDeparture = firstDeparture?.addingTimeInterval(-TimeInterval(accessSeconds))
            self.walkingSeconds = accessSeconds + pathwaySeconds
            self.minimumSlack = minimumSlack; self.totalSlack = totalSlack
            self.accessSeconds = accessSeconds; self.accessDistance = accessDistance
            self.pathwaySeconds = pathwaySeconds; self.pathwayDistance = pathwayDistance
            self.transferWalkSeconds = transferWalkSeconds
            self.containsPreferredMode = containsPreferredMode
            self.walkingStopsVisited = walkingStopsVisited; self.tripKey = tripKey
        }
    }
    struct LabelProfile: Sendable {
        var ordered: [Label] = []
        var byWalk: [Label] = []
        var byArrival: [Label] = []
        var byIncomingTrip: [Int: [Label]] = [:]
        // Boundaries for rejecting a candidate that cannot enter any quota.
        // Recomputed whenever the retained profile changes.
        var lastUnprotectedArrival: Label?
        var lastPreferredArrival: Label?
    }
    struct PatternScanResult: Sendable {
        let chunkIndex: Int
        let labels: [Int: LabelProfile]
        let scannedPatterns: Int
        let scannedTripInstances: Int
        let boardingChecks: Int
        let feasibleBoardings: Int
        let alightingChecks: Int
        let labelAttempts: Int
        let retainedLabels: Int
        let rejectedBeforeAllocation: Int
        let elapsedMilliseconds: Int
        var compactLabels: [Int: CompactProfile]? = nil
    }
    struct ActiveTripInstance: Sendable {
        let tripIndex: Int
        let serviceDay: SnapshotServiceDay
        let scheduledDepartures: [Date?]
        let scheduledArrivals: [Date?]
        let effectiveDepartures: [Date?]
        let effectiveArrivals: [Date?]
        let conservativeDepartures: [Date?]
        let boardingAllowed: [Bool]
        let alightingAllowed: [Bool]
    }

    /// A conservative topology bound. A true bit means that a stop may still
    /// reach an egress stop with the given number of further vehicle rides.
    /// Pedestrian links are included even when the walking provider may later
    /// reject them, so this bound can only remove impossible journeys.
    struct DestinationReachability: Sendable {
        let stopsByRemainingRides: [[Bool]]
        let lastAlightPositionByRemainingRides: [[Int]]

        init(snapshot: RoutingSnapshot, egressStops: Set<Int>, maxRides: Int) {
            let stopCount = snapshot.stops.count
            let walkingSources = snapshot.nearbyTransferSourcesByStop
            func walkingClosure(_ seeds: [Bool]) -> [Bool] {
                var result = seeds
                var queue = result.indices.filter { result[$0] }
                var cursor = 0
                while cursor < queue.count {
                    let to = queue[cursor]
                    cursor += 1
                    for from in snapshot.pathsByTo[to].map(\.from) + walkingSources[to] where !result[from] {
                        result[from] = true
                        queue.append(from)
                    }
                }
                return result
            }

            var base = Array(repeating: false, count: stopCount)
            for stop in egressStops { base[stop] = true }
            var reachability = [walkingClosure(base)]
            if maxRides > 1 {
                for rides in 1..<maxRides {
                    var seeds = reachability[rides - 1]
                    for pattern in snapshot.patterns {
                        guard pattern.stops.count > 1 else { continue }
                        var laterIsReachable = false
                        for position in pattern.stops.indices.reversed() {
                            let stop = pattern.stops[position]
                            if laterIsReachable { seeds[stop] = true }
                            if reachability[rides - 1][stop] { laterIsReachable = true }
                        }
                    }
                    reachability.append(walkingClosure(seeds))
                }
            }
            stopsByRemainingRides = reachability
            lastAlightPositionByRemainingRides = reachability.map { reachable in
                snapshot.patterns.map { pattern in
                    pattern.stops.indices.reversed().first { reachable[pattern.stops[$0]] } ?? -1
                }
            }
        }
    }
    struct TransferDecisionKey: Hashable, Sendable {
        let incomingTrip: Int
        let incomingStop: Int
        let stop: Int
        let outgoingTrip: Int
    }
    struct TransferAllowance: Sendable {
        let requiredSeconds: Int
        let allowedShortfallSeconds: Int
    }
    enum CachedTransferDecision: Sendable {
        case allowed(TransferAllowance)
        case forbidden

        var allowance: TransferAllowance? {
            switch self {
            case let .allowed(value): value
            case .forbidden: nil
            }
        }
    }

}

extension Raptor.Label {
    func replacingID(with id: Int) -> Self {
        .init(
            id: id,
            time: time,
            prior: prior,
            appendedLeg: appendedLeg,
            firstStop: firstStop,
            firstDeparture: firstDeparture,
            lastTransit: lastTransit,
            minimumSlack: minimumSlack,
            totalSlack: totalSlack,
            accessSeconds: accessSeconds,
            accessDistance: accessDistance,
            pathwaySeconds: pathwaySeconds,
            pathwayDistance: pathwayDistance,
            transferWalkSeconds: transferWalkSeconds,
            containsPreferredMode: containsPreferredMode,
            walkingStopsVisited: walkingStopsVisited,
            tripKey: tripKey
        )
    }
}
