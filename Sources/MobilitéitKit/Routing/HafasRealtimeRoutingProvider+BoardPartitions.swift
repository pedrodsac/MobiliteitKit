import Foundation

extension HafasRealtimeRoutingProvider {
    nonisolated static func combineBoards(_ values: [BoardResult], stopID: String,
                                         incomplete: Bool, now: Date) -> BoardResult {
        var departures: [String: HafasDeparture] = [:]
        var observations: [String: Date] = [:]
        for value in values {
            for departure in value.board?.departures.values ?? [] {
                let key = departure.cacheIdentity
                let observed = value.observations[key] ?? value.fetchedAt
                if observed >= (observations[key] ?? .distantPast) {
                    departures[key] = departure
                    observations[key] = observed
                }
            }
        }
        return .init(stopID: stopID,
            board: values.contains { $0.board != nil } ? .init(departures: Array(departures.values)) : nil,
            fetchedAt: values.map(\.fetchedAt).min() ?? now,
            incomplete: incomplete || values.contains { $0.incomplete || $0.board == nil },
            requests: values.reduce(0) { $0 + $1.requests }, hits: values.reduce(0) { $0 + $1.hits },
            bytes: values.reduce(0) { $0 + $1.bytes },
            httpMilliseconds: values.reduce(0) { $0 + $1.httpMilliseconds },
            decodeMilliseconds: values.reduce(0) { $0 + $1.decodeMilliseconds },
            transport: values.flatMap(\.transport), observations: observations)
    }
}

extension HafasRealtimeRoutingProvider.BoardResult {
    func identified(as value: String) -> Self {
        .init(stopID: value, board: board, fetchedAt: fetchedAt, incomplete: incomplete,
            requests: requests, hits: hits, bytes: bytes, httpMilliseconds: httpMilliseconds,
            decodeMilliseconds: decodeMilliseconds, transport: transport, observations: observations)
    }
}
