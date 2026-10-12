import Foundation

extension HafasRealtimeRoutingProvider {
    /// Reuse each proven partition once, then acquire only the missing lines.
    /// Joining existing work never opens another HTTP slot or renews its age.
    nonisolated static func acquireBoardInterval(
        client: MobiliteitAPIClient, stopID: String, selectedLines: [String], interval: DateInterval,
        request: RealtimeRoutingRequest, now: @escaping @Sendable () -> Date,
        cacheLifetime: TimeInterval
    ) async -> BoardResult {
        guard !selectedLines.isEmpty else {
            return await acquireBoardSlice(client: client, stopID: stopID, selectedLines: selectedLines,
                interval: interval, request: request, now: now, cacheLifetime: cacheLifetime)
        }
        let minimumFetchedAt = request.refreshPolicy == .forceRefresh ? request.refreshStartedAt : nil
        let (date, time) = requestDateAndTime(interval.start)
        let whole = HafasDepartureBoardRequest(stationID: stopID, language: client.language ?? "en", date: date,
            time: time, durationMinutes: max(1, Int(ceil(interval.duration / 60))), maximumJourneys: -1,
            lines: selectedLines, realtimeMode: .serverDefault, includePasslist: true)
        if let minimumFetchedAt { await client.retireDepartureBoardCoverage(whole, before: minimumFetchedAt) }
        let slices = request.refreshPolicy == .useCache || minimumFetchedAt != nil
            ? await client.departureBoardLineCoverageIntervals(whole, maximumCacheAge: cacheLifetime, minimumFetchedAt: minimumFetchedAt)
            : [interval]
        var values: [BoardResult] = []
        for slice in slices {
            guard !Task.isCancelled else { break }
            values.append(await acquireBoardSlice(client: client, stopID: stopID, selectedLines: selectedLines,
                interval: slice, request: request, now: now, cacheLifetime: cacheLifetime))
        }
        return combineBoards(values, stopID: stopID, incomplete: Task.isCancelled || slices.isEmpty, now: now())
    }

    private nonisolated static func acquireBoardSlice(
        client: MobiliteitAPIClient, stopID: String, selectedLines: [String], interval: DateInterval,
        request: RealtimeRoutingRequest, now: @escaping @Sendable () -> Date,
        cacheLifetime: TimeInterval
    ) async -> BoardResult {
        let scopedRefresh = request.refreshPolicy == .forceRefresh && request.refreshStartedAt != nil
        let minimumFetchedAt = scopedRefresh ? request.refreshStartedAt : nil
        let (date, time) = requestDateAndTime(interval.start)
        func boardRequest(_ lines: [String]) -> HafasDepartureBoardRequest {
            .init(stationID: stopID, language: client.language ?? "en", date: date, time: time,
                durationMinutes: max(1, Int(ceil(interval.duration / 60))), maximumJourneys: -1,
                lines: lines, realtimeMode: .serverDefault, includePasslist: true)
        }
        var result = LineCoverageAccumulator(stopID: stopID, fetchedAt: now())
        var missing = Set(selectedLines)
        if let minimumFetchedAt {
            await client.retireDepartureBoardCoverage(boardRequest(selectedLines), before: minimumFetchedAt)
        }
        if !selectedLines.isEmpty, request.refreshPolicy == .useCache || scopedRefresh {
            let parts = await client.departureBoardLineCoverageParts(boardRequest(selectedLines),
                maximumCacheAge: cacheLifetime, minimumFetchedAt: minimumFetchedAt)
            for part in parts {
                guard !Task.isCancelled else { break }
                do {
                    guard let response = try await client.reuseDepartureBoardLineCoveragePart(part,
                        maximumCacheAge: cacheLifetime, minimumFetchedAt: minimumFetchedAt) else { continue }
                    let safe = response.isComplete && response.board.departures.values.allSatisfy { $0.product?.line?.isEmpty == false }
                    result.record(response, retaining: safe ? Set(part.requestedLines) : nil, discard: !safe)
                    if safe { missing.subtract(part.requestedLines) }
                } catch {
                    // A failed borrowed flight owns no new request here. The
                    // original filter remains missing and gets a normal retry.
                    if Task.isCancelled { break }
                }
            }
        }
        if (selectedLines.isEmpty || !missing.isEmpty), !Task.isCancelled {
            let fallback = boardRequest(selectedLines.isEmpty ? [] : missing.sorted())
            do {
                let response = try await client.departureBoardResponse(fallback, refreshPolicy: request.refreshPolicy,
                    preservePartialOnFailure: true, maximumCacheAge: cacheLifetime, refreshStartedAt: minimumFetchedAt)
                // ATP's original line filter is authoritative even when its
                // response lacks the metadata needed to filter a wider board.
                result.record(response)
                if response.isComplete { missing.removeAll() }
                else { result.incomplete = true }
            } catch {
                result.requests += 1
                result.incomplete = true
            }
        }
        return result.finish(incomplete: !missing.isEmpty || Task.isCancelled)
    }
}

private struct LineCoverageAccumulator {
    let stopID: String
    var fetchedAt: Date
    var departures: [String: HafasDeparture] = [:]
    var observations: [String: Date] = [:]
    var requests = 0, hits = 0, bytes = 0, httpMilliseconds = 0, decodeMilliseconds = 0
    var transport: [HTTPTransportMeasurement] = []
    var successful = false, incomplete = false

    mutating func record(_ response: CachedBoardResponse, retaining lines: Set<String>? = nil, discard: Bool = false) {
        requests += response.networkRequests; hits += response.cacheHits
        if response.networkRequests > 0 { bytes += response.board.responseBytes }
        httpMilliseconds += response.httpMilliseconds; decodeMilliseconds += response.decodeMilliseconds
        transport += response.transport
        guard !discard else { return }
        successful = true
        fetchedAt = min(fetchedAt, response.fetchedAt)
        for departure in response.board.departures.values {
            if let lines, !lines.contains(departure.product?.line ?? "") { continue }
            let key = departure.cacheIdentity
            let observed = response.observations[key] ?? response.fetchedAt
            if observed >= (observations[key] ?? .distantPast) {
                departures[key] = departure; observations[key] = observed
            }
        }
    }

    func finish(incomplete missing: Bool) -> HafasRealtimeRoutingProvider.BoardResult {
        .init(stopID: stopID, board: successful ? .init(departures: Array(departures.values)) : nil,
            fetchedAt: fetchedAt, incomplete: incomplete || missing, requests: requests, hits: hits, bytes: bytes,
            httpMilliseconds: httpMilliseconds, decodeMilliseconds: decodeMilliseconds,
            transport: transport, observations: observations)
    }
}
