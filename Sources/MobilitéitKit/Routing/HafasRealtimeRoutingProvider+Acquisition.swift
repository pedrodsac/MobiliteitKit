import Foundation

extension HafasRealtimeRoutingProvider {
    private enum FetchEvent: Sendable {
        case result(BoardResult)
        case deadline
    }

    func boards(for stopIDs: [String], request: RealtimeRoutingRequest) async -> [String: BoardResult] {
        var result: [String: BoardResult] = [:]
        var pending: [String] = []
        for stopID in stopIDs {
            if request.refreshPolicy == .useCache, let cached = boardsByStopID[stopID],
               now().timeIntervalSince(cached.fetchedAt) < cacheLifetime,
               cached.from <= request.from, cached.through >= request.through,
               !cached.result.incomplete {
                result[stopID] = .init(stopID: stopID, board: cached.result.board,
                                       fetchedAt: cached.fetchedAt, incomplete: false,
                                       requests: 0, hits: 1, bytes: 0)
            } else { pending.append(stopID) }
        }
        let fetched = await Self.fetchResults(
            stopIDs: pending,
            maximumConcurrentRequests: min(maximumConcurrentBoardRequests, request.maximumConcurrentRequests),
            timeout: min(requestTimeout, request.timeout)
        ) { [client, now] stopID in
            await Self.acquireStop(client: client, stopID: stopID, request: request, now: now)
        }
        for (stopID, value) in fetched {
            result[stopID] = value
            // An older request may finish after an explicit refresh. Preserve
            // the newer interval rather than allowing that completion to win.
            if value.fetchedAt >= (boardsByStopID[stopID]?.fetchedAt ?? .distantPast) {
                if value.board != nil, !value.incomplete {
                    boardsByStopID[stopID] = .init(fetchedAt: value.fetchedAt, from: request.from,
                                                  through: request.through, result: value)
                } else { boardsByStopID[stopID] = nil }
            }
        }
        if boardsByStopID.count > 128 {
            boardsByStopID = Dictionary(uniqueKeysWithValues: boardsByStopID.sorted {
                $0.value.fetchedAt > $1.value.fetchedAt
            }.prefix(128).map { ($0.key, $0.value) })
        }
        return result
    }

    /// Small intervals avoid filling a bounded board with historical departures.
    /// A full interval is split rather than being mistaken for complete coverage.
    private nonisolated static func acquireStop(
        client: MobiliteitAPIClient, stopID: String, request: RealtimeRoutingRequest,
        now: @escaping @Sendable () -> Date
    ) async -> BoardResult {
        let maximumJourneys = 50
        let maximumSlices = 8
        var intervals: [(Date, Date)] = []
        var start = request.from
        repeat {
            let end = min(request.through, start.addingTimeInterval(30 * 60))
            intervals.append((start, end)); start = end
        } while start < request.through && intervals.count < maximumSlices
        var incomplete = start < request.through
        var departures: [String: HafasDeparture] = [:]
        var requests = 0; var hits = 0; var bytes = 0; var slices = 0
        var successful = false
        var fetchedAt = now()
        while !intervals.isEmpty, !Task.isCancelled, slices < maximumSlices {
            let (from, through) = intervals.removeFirst()
            let (date, time) = requestDateAndTime(from)
            slices += 1
            do {
                let response = try await client.departureBoardResponse(.init(
                    stationID: stopID, language: "en", date: date, time: time,
                    durationMinutes: max(1, Int(ceil(through.timeIntervalSince(from) / 60))),
                    maximumJourneys: maximumJourneys, realtimeMode: .serverDefault,
                    includePasslist: true
                ), refreshPolicy: request.refreshPolicy)
                successful = true
                requests += response.networkRequests; hits += response.cacheHits
                if response.networkRequests > 0 { bytes += response.board.responseBytes }
                fetchedAt = min(fetchedAt, now())
                for departure in response.board.departures.values {
                    let key = [departure.journeyReference?.reference, departure.stopExternalID,
                               departure.plannedDate, departure.plannedTime].compactMap { $0 }.joined(separator: "|")
                    departures[key] = departure
                }
                if response.board.departures.values.count >= maximumJourneys {
                    if through.timeIntervalSince(from) > 60 {
                        let midpoint = from.addingTimeInterval(floor(through.timeIntervalSince(from) / 120) * 60)
                        intervals.insert(contentsOf: [(from, midpoint), (midpoint, through)], at: 0)
                    } else { incomplete = true }
                }
            } catch {
                requests += 1
                incomplete = true
                if Task.isCancelled { break }
            }
        }
        incomplete = incomplete || !intervals.isEmpty || Task.isCancelled
        return .init(stopID: stopID,
                     board: successful ? .init(departures: Array(departures.values)) : nil,
                     fetchedAt: fetchedAt, incomplete: incomplete,
                     requests: requests, hits: hits, bytes: bytes)
    }

    private nonisolated static func fetchResults(
        stopIDs: [String], maximumConcurrentRequests: Int, timeout: Duration,
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
                    if completed == stopIDs.count { group.cancelAll(); return result }
                    if next < stopIDs.count, !Task.isCancelled { add() }
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
