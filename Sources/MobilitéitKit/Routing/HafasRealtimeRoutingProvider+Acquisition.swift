import Foundation

extension HafasRealtimeRoutingProvider {
    private enum FetchEvent: Sendable {
        case result(BoardResult)
        case deadline
    }

    func boards(for stopIDs: [String], request: RealtimeRoutingRequest,
                deadline: ContinuousClock.Instant) async -> [String: BoardResult] {
        guard ContinuousClock.now < deadline else { return [:] }
        var ordered = stopIDs
        if request.refreshPolicy == .useCache {
            var coverage: [String: Double] = [:]
            for stopID in stopIDs {
                if Task.isCancelled || ContinuousClock.now >= deadline { break }
                let targets = request.targets.filter { $0.stopID == stopID }
                let lines = Self.selectedLines(in: targets)
                let windows = targets.isEmpty ? [RealtimeBoardTarget(stopID: stopID, from: request.from, through: request.through)] : targets
                for window in windows where window.through >= window.from {
                    let (date, time) = Self.requestDateAndTime(window.from)
                    var value = await client.cachedDepartureBoardCoverage(.init(
                        stationID: stopID, language: client.language ?? "en", date: date, time: time,
                        durationMinutes: max(1, Int(ceil(window.through.timeIntervalSince(window.from) / 60))),
                        maximumJourneys: -1, realtimeMode: .serverDefault, includePasslist: true
                    ), maximumCacheAge: cacheLifetime)
                    if !lines.isEmpty, value < 1 {
                        let filtered = await client.cachedDepartureBoardCoverage(.init(
                            stationID: stopID, language: client.language ?? "en", date: date, time: time,
                            durationMinutes: max(1, Int(ceil(window.through.timeIntervalSince(window.from) / 60))),
                            maximumJourneys: -1, lines: lines, realtimeMode: .serverDefault, includePasslist: true
                        ), maximumCacheAge: cacheLifetime)
                        value = max(value, filtered)
                    }
                    coverage[stopID, default: 0] += value / Double(windows.count)
                }
            }
            // Preserve destination/boarding priority among equal cache coverage.
            ordered = stopIDs.enumerated().sorted {
                let a = coverage[$0.element, default: 0]; let b = coverage[$1.element, default: 0]
                return a != b ? a > b : $0.offset < $1.offset
            }.map(\.element)
        }
        guard !Task.isCancelled, ContinuousClock.now < deadline else { return [:] }
        return await Self.fetchResults(
            stopIDs: ordered,
            maximumConcurrentRequests: min(maximumConcurrentBoardRequests, request.maximumConcurrentRequests),
            timeout: max(.zero, ContinuousClock.now.duration(to: deadline)),
            prepared: { [weak self] value in
                await self?.prepareBoard(value.board,
                    from: request.from.addingTimeInterval(-Double(request.scheduledLookbackSeconds)),
                    through: request.through, deadline: deadline)
            }
        ) { [client, now, cacheLifetime] stopID in
            await Self.acquireStop(client: client, stopID: stopID, request: request, now: now, cacheLifetime: cacheLifetime)
        }
    }

    private nonisolated static func selectedLines(in targets: [RealtimeBoardTarget]) -> [String] {
        targets.isEmpty || targets.contains(where: { $0.lines.isEmpty }) ? []
            : Array(Set(targets.flatMap(\.lines))).sorted()
    }

    /// One unlimited-journey request covers each merged window and relevant lines. The shared client
    /// cache supplies complete overlapping boards and fetches only their gaps.
    private nonisolated static func acquireStop(
        client: MobiliteitAPIClient, stopID: String, request: RealtimeRoutingRequest,
        now: @escaping @Sendable () -> Date, cacheLifetime: TimeInterval
    ) async -> BoardResult {
        let targets = request.targets.filter { $0.stopID == stopID && $0.through >= $0.from }
        let selectedLines = selectedLines(in: targets)
        let windows = targets.isEmpty ? [DateInterval(start: request.from, end: request.through)]
            : targets.map { DateInterval(start: $0.from, end: $0.through) }
        let width: TimeInterval = 30 * 60
        var intervals: [DateInterval] = []
        for window in windows.sorted(by: { $0.start < $1.start }) {
            let from = Date(timeIntervalSince1970: floor(window.start.timeIntervalSince1970 / width) * width)
            let through = Date(timeIntervalSince1970: ceil(window.end.timeIntervalSince1970 / width) * width)
            let end = max(from.addingTimeInterval(60), through)
            if let previous = intervals.last, from <= previous.end {
                intervals[intervals.count - 1] = .init(start: previous.start, end: max(previous.end, end))
            } else { intervals.append(.init(start: from, end: end)) }
        }
        // ATP allows at most 1,439 minutes in one request.
        var bounded: [DateInterval] = []
        for interval in intervals {
            var start = interval.start
            while start < interval.end {
                let end = min(interval.end, start.addingTimeInterval(1_439 * 60))
                bounded.append(.init(start: start, end: end)); start = end
            }
        }
        var incomplete = bounded.count > 8
        var departures: [String: HafasDeparture] = [:]
        var observations: [String: Date] = [:]
        var requests = 0; var hits = 0; var bytes = 0
        var httpMilliseconds = 0; var decodeMilliseconds = 0
        var transport: [HTTPTransportMeasurement] = []
        var successful = false
        var fetchedAt = now()
        for interval in bounded.prefix(8) {
            guard !Task.isCancelled else { incomplete = true; break }
            let (date, time) = requestDateAndTime(interval.start)
            do {
                var lines = selectedLines
                // A complete unrestricted board can satisfy a narrower request;
                // a filtered board must never claim unrestricted coverage.
                if !lines.isEmpty, request.refreshPolicy == .useCache {
                    let coverage = await client.cachedDepartureBoardCoverage(.init(
                        stationID: stopID, language: client.language ?? "en", date: date, time: time,
                        durationMinutes: max(1, Int(ceil(interval.duration / 60))),
                        maximumJourneys: -1, realtimeMode: .serverDefault, includePasslist: true
                    ), maximumCacheAge: cacheLifetime)
                    if coverage >= 1 { lines = [] }
                }
                let response = try await client.departureBoardResponse(.init(
                    stationID: stopID, language: client.language ?? "en", date: date, time: time,
                    durationMinutes: max(1, Int(ceil(interval.duration / 60))),
                    maximumJourneys: -1, lines: lines, realtimeMode: .serverDefault, includePasslist: true
                ), refreshPolicy: request.refreshPolicy, preservePartialOnFailure: true, maximumCacheAge: cacheLifetime)
                successful = true
                incomplete = incomplete || !response.isComplete
                httpMilliseconds += response.httpMilliseconds; decodeMilliseconds += response.decodeMilliseconds
                transport += response.transport
                requests += response.networkRequests; hits += response.cacheHits
                if response.networkRequests > 0 { bytes += response.board.responseBytes }
                fetchedAt = min(fetchedAt, response.fetchedAt)
                for departure in response.board.departures.values {
                    let key = departure.cacheIdentity
                    let observed = response.observations[key] ?? response.fetchedAt
                    if observed >= (observations[key] ?? .distantPast) {
                        departures[key] = departure; observations[key] = observed
                    }
                }
            } catch {
                requests += 1; incomplete = true
                if Task.isCancelled { break }
            }
        }
        return .init(stopID: stopID,
                     board: successful ? .init(departures: Array(departures.values)) : nil,
                     fetchedAt: fetchedAt, incomplete: incomplete || Task.isCancelled,
                     requests: requests, hits: hits, bytes: bytes,
                     httpMilliseconds: httpMilliseconds, decodeMilliseconds: decodeMilliseconds, transport: transport,
                     observations: observations)
    }

    private nonisolated static func fetchResults(
        stopIDs: [String], maximumConcurrentRequests: Int, timeout: Duration,
        prepared: @escaping @Sendable (BoardResult) async -> Void = { _ in },
        fetch: @escaping @Sendable (String) async -> BoardResult
    ) async -> [String: BoardResult] {
        guard !stopIDs.isEmpty else { return [:] }
        return await withTaskGroup(of: FetchEvent.self) { group in
            var next = 0; var completed = 0
            func add() {
                let stopID = stopIDs[next]; next += 1
                group.addTask { .result(await fetch(stopID)) }
            }
            for _ in 0..<min(max(1, maximumConcurrentRequests), stopIDs.count) { add() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .deadline
            }
            var result: [String: BoardResult] = [:]
            while let event = await group.next() {
                switch event {
                case .deadline:
                    group.cancelAll()
                    // Drain cancelled children: they retain completed slices and
                    // mark coverage incomplete instead of discarding useful data.
                    while let remaining = await group.next() {
                        if case let .result(value) = remaining { result[value.stopID] = value }
                    }
                    return result
                case let .result(value):
                    result[value.stopID] = value; completed += 1
                    if next < stopIDs.count, !Task.isCancelled { add() }
                    await prepared(value)
                    if completed == stopIDs.count { group.cancelAll(); return result }
                }
            }
            return result
        }
    }

    /// Kept as a small injectable concurrency primitive for deterministic tests.
    nonisolated static func fetchBoardsWithLimitedConcurrency(
        stopIDs: [String], maximumConcurrentRequests: Int, timeout: Duration,
        fetch: @escaping @Sendable (String) async -> HafasDepartureBoard?
    ) async -> [String: HafasDepartureBoard] {
        let results = await fetchResults(stopIDs: stopIDs, maximumConcurrentRequests: maximumConcurrentRequests,
                                         timeout: timeout) { stopID in
            let board = await fetch(stopID)
            return .init(stopID: stopID, board: Task.isCancelled ? nil : board,
                         fetchedAt: .now, incomplete: Task.isCancelled, requests: 0, hits: 0, bytes: 0)
        }
        return results.compactMapValues(\.board)
    }
}
