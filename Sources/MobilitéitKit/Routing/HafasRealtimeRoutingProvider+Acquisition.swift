import Foundation

extension HafasRealtimeRoutingProvider {
    private enum FetchEvent: Sendable {
        case result(BoardResult)
        case deadline
    }

    func boards(for stopIDs: [String], request: RealtimeRoutingRequest,
                deadline: ContinuousClock.Instant) async -> [String: BoardResult] {
        guard ContinuousClock.now < deadline else { return [:] }
        // Stable UTC boundaries are independent of the rider's moving clock,
        // including the repeated autumn hour. Cache only proven complete coverage.
        let width: TimeInterval = 30 * 60
        let first = Date(timeIntervalSince1970: floor(request.from.timeIntervalSince1970 / width) * width)
        var intervals: [(Date, Date)] = []
        var cursor = first
        repeat {
            intervals.append((cursor, cursor.addingTimeInterval(width)))
            cursor = cursor.addingTimeInterval(width)
        } while cursor < request.through && intervals.count < 8
        var seeds: [String: [CompletedSlice]] = [:]
        var missing: [String: [(Date, Date)]] = [:]
        for stopID in stopIDs {
            let cached = request.refreshPolicy == .useCache ? boardsBySlice.values.filter {
                $0.result.stopID == stopID && now().timeIntervalSince($0.fetchedAt) < cacheLifetime
            }.sorted { $0.from < $1.from } : []
            for (from, through) in intervals {
                var position = from
                for slice in cached where slice.through > from && slice.from < through {
                    if slice.from > position { missing[stopID, default: []].append((position, min(slice.from, through))) }
                    guard let board = slice.result.board else { continue }
                    seeds[stopID, default: []].append(.init(from: slice.from, through: slice.through,
                                                          board: board, fetchedAt: slice.fetchedAt))
                    position = max(position, slice.through)
                    if position >= through { break }
                }
                if position < through { missing[stopID, default: []].append((position, through)) }
            }
        }
        let missingSnapshot = missing
        let seedSnapshot = seeds
        let omittedCoverage = cursor < request.through
        let fetched = await Self.fetchResults(
            stopIDs: stopIDs,
            maximumConcurrentRequests: min(maximumConcurrentBoardRequests, request.maximumConcurrentRequests),
            timeout: max(.zero, ContinuousClock.now.duration(to: deadline))
        ) { [client, now] stopID in
            await Self.acquireStop(client: client, stopID: stopID, request: request, now: now,
                                   intervals: missingSnapshot[stopID] ?? [],
                                   cached: seedSnapshot[stopID] ?? [],
                                   omittedCoverage: omittedCoverage)
        }
        for value in fetched.values {
            for slice in value.completedSlices {
                let key = BoardSliceKey(stopID: value.stopID, start: slice.from)
                if slice.fetchedAt >= (boardsBySlice[key]?.fetchedAt ?? .distantPast) {
                    boardsBySlice[key] = .init(fetchedAt: slice.fetchedAt, from: slice.from, through: slice.through,
                        result: .init(stopID: value.stopID, board: slice.board, fetchedAt: slice.fetchedAt,
                                      incomplete: false, requests: 0, hits: 0, bytes: 0))
                }
            }
        }
        if boardsBySlice.count > 512 {
            boardsBySlice = Dictionary(uniqueKeysWithValues: boardsBySlice.sorted {
                $0.value.fetchedAt > $1.value.fetchedAt
            }.prefix(512).map { ($0.key, $0.value) })
        }
        return fetched
    }

    /// Small intervals avoid filling a bounded board with historical departures.
    /// A full interval is split rather than being mistaken for complete coverage.
    private nonisolated static func acquireStop(
        client: MobiliteitAPIClient, stopID: String, request: RealtimeRoutingRequest,
        now: @escaping @Sendable () -> Date,
        intervals initialIntervals: [(Date, Date)], cached: [CompletedSlice], omittedCoverage: Bool
    ) async -> BoardResult {
        let maximumJourneys = 50
        let maximumSlices = 8
        var intervals = initialIntervals
        var incomplete = omittedCoverage
        var completedSlices: [CompletedSlice] = []
        var departures: [String: HafasDeparture] = [:]
        var requests = 0; var hits = 0; var bytes = 0; var slices = 0
        var httpMilliseconds = 0; var decodeMilliseconds = 0
        var successful = !cached.isEmpty
        var fetchedAt = cached.map(\.fetchedAt).min() ?? now()
        for slice in cached {
            hits += 1
            for departure in slice.board.departures.values {
                departures[departureKey(departure)] = departure
            }
        }
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
                httpMilliseconds += response.httpMilliseconds; decodeMilliseconds += response.decodeMilliseconds
                requests += response.networkRequests; hits += response.cacheHits
                if response.networkRequests > 0 { bytes += response.board.responseBytes }
                fetchedAt = min(fetchedAt, now())
                for departure in response.board.departures.values {
                    let key = departureKey(departure)
                    departures[key] = departure
                }
                if response.board.departures.values.count >= maximumJourneys {
                    if through.timeIntervalSince(from) > 60 {
                        let midpoint = from.addingTimeInterval(floor(through.timeIntervalSince(from) / 120) * 60)
                        intervals.insert(contentsOf: [(from, midpoint), (midpoint, through)], at: 0)
                    } else { incomplete = true }
                } else {
                    completedSlices.append(.init(from: from, through: through, board: response.board, fetchedAt: now()))
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
                     requests: requests, hits: hits, bytes: bytes, httpMilliseconds: httpMilliseconds, decodeMilliseconds: decodeMilliseconds, completedSlices: completedSlices)
    }

    private nonisolated static func departureKey(_ departure: HafasDeparture) -> String {
        [departure.journeyReference?.reference, departure.stopExternalID,
         departure.plannedDate, departure.plannedTime].compactMap { $0 }.joined(separator: "|")
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
