import Foundation

/// Converts Mobiliteit HAFAS departure boards into immutable GTFS trip-instance
/// patches that can be applied while RAPTOR is scanning the timetable.
public actor HafasRealtimeRoutingProvider: RealtimeRoutingProvider {
    private struct CachedBoard: Sendable {
        let fetchedAt: Date
        let from: Date
        let through: Date
        let board: HafasDepartureBoard
    }

    private struct BoardResult: Sendable {
        let stopID: String
        let board: HafasDepartureBoard?
    }

    private enum BoardFetchEvent: Sendable {
        case result(BoardResult)
        case deadlineReached
    }

    private struct Candidate {
        let departure: ScheduledDeparture
        let serviceDate: GTFSDate
        let scheduledDate: Date
        let score: Int
    }

    private let store: GTFSStore
    private let client: MobiliteitAPIClient
    private let maximumConcurrentBoardRequests: Int
    private let cacheLifetime: TimeInterval
    private let requestTimeout: Duration
    private let now: @Sendable () -> Date
    private var boardsByStopID: [String: CachedBoard] = [:]

    public init(
        databaseURL: URL,
        client: MobiliteitAPIClient,
        maximumConcurrentBoardRequests: Int = 4,
        cacheLifetime: TimeInterval = 60,
        requestTimeout: Duration = .seconds(4)
    ) throws {
        self.store = try GTFSStore(databaseAt: databaseURL)
        self.client = client
        self.maximumConcurrentBoardRequests = max(1, maximumConcurrentBoardRequests)
        self.cacheLifetime = max(0, cacheLifetime)
        self.requestTimeout = requestTimeout
        self.now = { .now }
    }

    init(
        store: GTFSStore,
        client: MobiliteitAPIClient,
        maximumConcurrentBoardRequests: Int = 4,
        cacheLifetime: TimeInterval = 60,
        requestTimeout: Duration = .seconds(4),
        now: @escaping @Sendable () -> Date
    ) {
        self.store = store
        self.client = client
        self.maximumConcurrentBoardRequests = max(1, maximumConcurrentBoardRequests)
        self.cacheLifetime = max(0, cacheLifetime)
        self.requestTimeout = requestTimeout
        self.now = now
    }

    public func patches(
        for stopIDs: [String],
        from: Date,
        through: Date,
        refreshPolicy _: RealtimeRefreshPolicy
    ) async throws -> RealtimePatchBatch {
        var seenStopIDs: Set<String> = []
        let orderedStopIDs = stopIDs.filter { !$0.isEmpty && seenStopIDs.insert($0).inserted }
        let requested = Set(orderedStopIDs)
        guard !requested.isEmpty, through >= from else {
            return RealtimePatchBatch(
                patches: [],
                requestedStopIDs: requested,
                coveredStopIDs: []
            )
        }

        let fetched = await boards(
            for: orderedStopIDs,
            from: from,
            through: through
        )
        guard !fetched.isEmpty else { throw HafasRealtimeRoutingError.unavailable }

        var patchesByInstance: [String: RealtimeTripPatch] = [:]
        var seenJourneys: Set<String> = []
        for stopID in orderedStopIDs where fetched[stopID] != nil {
            guard let board = fetched[stopID] else { continue }
            let scheduled = (try? await store.nextScheduledDepartures(
                fromStopID: stopID,
                at: from,
                horizon: through.timeIntervalSince(from),
                limit: 500
            )) ?? []

            for departure in board.departures.values {
                guard Self.hasRealtimeSignal(departure),
                      let planned = Self.date(date: departure.plannedDate, time: departure.plannedTime),
                      planned >= from.addingTimeInterval(-90),
                      planned <= through.addingTimeInterval(90)
                else { continue }

                let journeyKey = departure.journeyReference?.reference
                    ?? Self.syntheticJourneyKey(departure, stopID: stopID)
                guard !seenJourneys.contains(journeyKey) else { continue }
                guard let candidate = await uniqueCandidate(
                    for: departure,
                    planned: planned,
                    scheduled: scheduled
                ) else { continue }

                let key = "\(candidate.departure.tripID)@\(candidate.serviceDate.compactString)"
                guard let patch = await patch(
                    for: departure,
                    candidate: candidate,
                    boardingStopID: stopID
                ) else { continue }
                seenJourneys.insert(journeyKey)
                patchesByInstance[key] = Self.merging(patchesByInstance[key], patch)
            }
        }

        return RealtimePatchBatch(
            patches: patchesByInstance.values.sorted {
                ($0.serviceDate, $0.tripID) < ($1.serviceDate, $1.tripID)
            },
            requestedStopIDs: requested,
            coveredStopIDs: Set(fetched.keys)
        )
    }

    private func boards(
        for stopIDs: [String],
        from: Date,
        through: Date
    ) async -> [String: HafasDepartureBoard] {
        var result: [String: HafasDepartureBoard] = [:]
        var pending: [String] = []
        let currentDate = now()

        for stopID in stopIDs {
            if let cached = boardsByStopID[stopID],
               currentDate.timeIntervalSince(cached.fetchedAt) <= cacheLifetime,
               abs(cached.from.timeIntervalSince(from)) <= cacheLifetime,
               abs(cached.through.timeIntervalSince(through)) <= cacheLifetime {
                result[stopID] = cached.board
            } else {
                pending.append(stopID)
            }
        }

        let fetched = await Self.fetchBoards(
            client: client,
            stopIDs: pending,
            from: from,
            through: through,
            maximumConcurrentRequests: maximumConcurrentBoardRequests,
            timeout: requestTimeout
        )
        for (stopID, board) in fetched {
            result[stopID] = board
            boardsByStopID[stopID] = CachedBoard(
                fetchedAt: currentDate,
                from: from,
                through: through,
                board: board
            )
        }
        return result
    }

    private nonisolated static func fetchBoards(
        client: MobiliteitAPIClient,
        stopIDs: [String],
        from: Date,
        through: Date,
        maximumConcurrentRequests: Int,
        timeout: Duration
    ) async -> [String: HafasDepartureBoard] {
        await fetchBoardsWithLimitedConcurrency(
            stopIDs: stopIDs,
            maximumConcurrentRequests: maximumConcurrentRequests,
            timeout: timeout
        ) { stopID in
            await boardResult(client: client, stopID: stopID, from: from, through: through).board
        }
    }

    nonisolated static func fetchBoardsWithLimitedConcurrency(
        stopIDs: [String],
        maximumConcurrentRequests: Int,
        timeout: Duration,
        fetch: @escaping @Sendable (String) async -> HafasDepartureBoard?
    ) async -> [String: HafasDepartureBoard] {
        guard !stopIDs.isEmpty else { return [:] }
        return await withTaskGroup(of: BoardFetchEvent.self) { group in
            var nextIndex = 0
            var completedCount = 0
            let initialCount = min(max(1, maximumConcurrentRequests), stopIDs.count)
            for _ in 0..<initialCount {
                let stopID = stopIDs[nextIndex]
                nextIndex += 1
                group.addTask {
                    .result(BoardResult(stopID: stopID, board: await fetch(stopID)))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .deadlineReached
            }

            var result: [String: HafasDepartureBoard] = [:]
            while let event = await group.next() {
                switch event {
                case .deadlineReached:
                    group.cancelAll()
                    return result
                case let .result(value):
                    completedCount += 1
                    if let board = value.board { result[value.stopID] = board }
                    if completedCount == stopIDs.count {
                        group.cancelAll()
                        return result
                    }
                    guard !Task.isCancelled, nextIndex < stopIDs.count else { continue }
                    let stopID = stopIDs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        .result(BoardResult(stopID: stopID, board: await fetch(stopID)))
                    }
                }
            }
            return result
        }
    }

    private nonisolated static func boardResult(
        client: MobiliteitAPIClient,
        stopID: String,
        from: Date,
        through: Date
    ) async -> BoardResult {
        let (date, time) = requestDateAndTime(from)
        let duration = max(1, min(1_439, Int(ceil(through.timeIntervalSince(from) / 60))))
        do {
            let board = try await client.departureBoard(HafasDepartureBoardRequest(
                stationID: stopID,
                language: "en",
                date: date,
                time: time,
                durationMinutes: duration,
                maximumJourneys: 100,
                filterEquivalentStops: false,
                realtimeMode: .full,
                includePasslist: true
            ))
            return BoardResult(stopID: stopID, board: board)
        } catch {
            return BoardResult(stopID: stopID, board: nil)
        }
    }

    private func uniqueCandidate(
        for live: HafasDeparture,
        planned: Date,
        scheduled: [ScheduledDeparture]
    ) async -> Candidate? {
        var candidates: [Candidate] = []
        for value in scheduled {
            guard let serviceDate = await store.date(for: value.serviceDay),
                  let departureTime = value.departure
            else { continue }
            let scheduledDate = Self.serviceDate(serviceDate, time: departureTime)
            guard abs(scheduledDate.timeIntervalSince(planned)) <= 90,
                  let lineScore = Self.lineScore(live.product, route: value.route)
            else { continue }

            var score = lineScore
            if let direction = live.direction,
               let headsign = value.headsign,
               Self.normalized(direction) == Self.normalized(headsign) {
                score += 2
            }
            if !live.passlist.values.isEmpty {
                let stopTimes = (try? await store.stopTimes(forTripID: value.tripID)) ?? []
                score += min(4, Self.alignmentCount(live.passlist.values, stopTimes: stopTimes))
            }
            candidates.append(.init(
                departure: value,
                serviceDate: serviceDate,
                scheduledDate: scheduledDate,
                score: score
            ))
        }

        let ordered = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = abs($0.scheduledDate.timeIntervalSince(planned))
            let rhs = abs($1.scheduledDate.timeIntervalSince(planned))
            if lhs != rhs { return lhs < rhs }
            return $0.departure.tripID < $1.departure.tripID
        }
        guard let best = ordered.first else { return nil }
        if ordered.count > 1 {
            let firstDistance = abs(best.scheduledDate.timeIntervalSince(planned))
            let secondDistance = abs(ordered[1].scheduledDate.timeIntervalSince(planned))
            guard best.score != ordered[1].score || firstDistance != secondDistance else { return nil }
        }
        return best
    }

    private func patch(
        for live: HafasDeparture,
        candidate: Candidate,
        boardingStopID: String
    ) async -> RealtimeTripPatch? {
        let realtime = Self.date(
            date: live.realtimeDate ?? live.plannedDate,
            time: live.realtimeTime
        )
        let delay = realtime?.timeIntervalSince(candidate.scheduledDate) ?? 0
        let status: RealtimeTripStatus = if live.cancelled == true {
            .cancelled
        } else if live.reachable == false {
            .unreachable
        } else {
            .active
        }
        let stopTimes = (try? await store.stopTimes(forTripID: candidate.departure.tripID)) ?? []
        guard !stopTimes.isEmpty else { return nil }
        let passlistPlatforms = Self.platforms(
            live.passlist.values,
            alignedTo: stopTimes
        )

        let events = stopTimes.map { value -> RealtimeStopEventPatch in
            let scheduledDeparture = value.departure.map {
                Self.serviceDate(candidate.serviceDate, time: $0)
            }
            let scheduledArrival = value.arrival.map {
                Self.serviceDate(candidate.serviceDate, time: $0)
            }
            let source: RealtimeTimingSource = value.stop.id == boardingStopID ? .reported : .estimated
            return RealtimeStopEventPatch(
                stopID: value.stop.id,
                scheduledDeparture: scheduledDeparture,
                effectiveDeparture: scheduledDeparture?.addingTimeInterval(delay),
                departureSource: scheduledDeparture == nil ? .scheduled : source,
                scheduledArrival: scheduledArrival,
                effectiveArrival: scheduledArrival?.addingTimeInterval(delay),
                arrivalSource: scheduledArrival == nil ? .scheduled : source,
                platform: passlistPlatforms[value.stop.id]
                    ?? (value.stop.id == boardingStopID
                        ? live.realtimePlatform?.text ?? live.platform?.text
                        : value.stop.platformCode)
            )
        }
        return RealtimeTripPatch(
            tripID: candidate.departure.tripID,
            serviceDate: candidate.serviceDate,
            status: status,
            events: events
        )
    }

    private nonisolated static func merging(
        _ existing: RealtimeTripPatch?,
        _ incoming: RealtimeTripPatch
    ) -> RealtimeTripPatch {
        guard let existing else { return incoming }
        let status: RealtimeTripStatus = if existing.status == .cancelled || incoming.status == .cancelled {
            .cancelled
        } else if existing.status == .unreachable || incoming.status == .unreachable {
            .unreachable
        } else {
            .active
        }
        let events = Dictionary(
            (existing.events + incoming.events).map { ($0.stopID, $0) },
            uniquingKeysWith: { current, replacement in
                current.departureSource == .reported || current.arrivalSource == .reported
                    ? current : replacement
            }
        )
        return RealtimeTripPatch(
            tripID: existing.tripID,
            serviceDate: existing.serviceDate,
            status: status,
            events: events.values.sorted { $0.stopID < $1.stopID }
        )
    }

    private nonisolated static func hasRealtimeSignal(_ value: HafasDeparture) -> Bool {
        value.realtimeTime != nil
            || value.cancelled == true
            || value.reachable == false
            || value.prognosisType != nil
    }

    private nonisolated static func lineScore(
        _ product: HafasProduct?,
        route: TransitRoute
    ) -> Int? {
        guard let product else { return nil }
        if let lineID = product.lineID,
           normalized(lineID) == normalized(route.id) {
            return 6
        }
        let liveNames = [product.line, product.name, product.categoryShort]
            .compactMap { $0.map(normalized) }
        let routeNames = [route.shortName, route.longName]
            .compactMap { $0.map(normalized) }
        return liveNames.contains(where: routeNames.contains) ? 4 : nil
    }

    private nonisolated static func alignmentCount(
        _ live: [HafasPasslistStop],
        stopTimes: [TripStopTime]
    ) -> Int {
        var searchStart = 0
        var matches = 0
        for stop in live {
            guard searchStart < stopTimes.count else { break }
            if let index = stopTimes[searchStart...].firstIndex(where: { scheduled in
                passlistStop(stop, matches: scheduled)
            }) {
                matches += 1
                searchStart = index + 1
            }
        }
        return matches
    }

    private nonisolated static func platforms(
        _ live: [HafasPasslistStop],
        alignedTo stopTimes: [TripStopTime]
    ) -> [String: String] {
        var result: [String: String] = [:]
        var searchStart = 0
        for stop in live {
            guard searchStart < stopTimes.count,
                  let index = stopTimes[searchStart...].firstIndex(where: { passlistStop(stop, matches: $0) })
            else { continue }
            let platform = stop.realtimeDepartureTrack
                ?? stop.realtimeArrivalTrack
            if let platform, !platform.isEmpty {
                result[stopTimes[index].stop.id] = platform
            }
            searchStart = index + 1
        }
        return result
    }

    private nonisolated static func passlistStop(
        _ live: HafasPasslistStop,
        matches scheduled: TripStopTime
    ) -> Bool {
        if [live.externalID, live.id].compactMap({ $0 }).contains(scheduled.stop.id) {
            return true
        }
        guard let name = live.name,
              normalized(name) == normalized(scheduled.stop.name)
        else { return false }
        guard let liveTime = date(
            date: live.departureDate ?? live.arrivalDate,
            time: live.departureTime ?? live.arrivalTime
        ) else { return true }
        let serviceDate = try? GTFSDate(
            year: Calendar.luxembourg.component(.year, from: liveTime),
            month: Calendar.luxembourg.component(.month, from: liveTime),
            day: Calendar.luxembourg.component(.day, from: liveTime)
        )
        guard let serviceDate else { return true }
        let scheduledDate = (scheduled.departure ?? scheduled.arrival).map {
            self.serviceDate(serviceDate, time: $0)
        }
        return scheduledDate.map { abs($0.timeIntervalSince(liveTime)) <= 90 } ?? true
    }

    private nonisolated static func syntheticJourneyKey(
        _ value: HafasDeparture,
        stopID: String
    ) -> String {
        [stopID, value.product?.lineID, value.product?.line, value.direction,
         value.plannedDate, value.plannedTime]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    private nonisolated static func requestDateAndTime(_ value: Date) -> (GTFSDate, ServiceTime) {
        let components = Calendar.luxembourg.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: value
        )
        let date = try! GTFSDate(
            year: components.year!, month: components.month!, day: components.day!
        )
        let seconds = Int32(
            (components.hour ?? 0) * 3_600
                + (components.minute ?? 0) * 60
                + (components.second ?? 0)
        )
        return (date, ServiceTime(rawValue: seconds))
    }

    private nonisolated static func serviceDate(_ date: GTFSDate, time: ServiceTime) -> Date {
        ServiceInstantConverter(timeZone: Calendar.luxembourg.timeZone).date(
            serviceDate: date,
            serviceSeconds: time.rawValue
        )
    }

    private nonisolated static func date(date: String?, time: String?) -> Date? {
        guard let date, let time else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.luxembourg.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let value = formatter.date(from: "\(date) \(time)") { return value }
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(time)")
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }
}

public enum HafasRealtimeRoutingError: Error, Sendable {
    case unavailable
    case timedOut
}

private extension Calendar {
    static var luxembourg: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Luxembourg")!
        return calendar
    }
}
