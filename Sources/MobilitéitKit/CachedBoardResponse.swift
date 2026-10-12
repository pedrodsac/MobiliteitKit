import Foundation

struct CachedBoardResponse: Sendable {
    var board: HafasDepartureBoard
    let networkRequests: Int
    let cacheHits: Int
    var fetchedAt: Date = .now
    var httpMilliseconds: Int = 0
    var decodeMilliseconds: Int = 0
    var transport: [HTTPTransportMeasurement] = []
    var scope: BoardCacheScope? = nil
    var isComplete: Bool = false
    var observations: [String: Date] = [:]

    func restricted(to requested: BoardCacheScope?) -> Self {
        guard let requested, let scope, scope.contains(requested) else { return self }
        var result = self
        let filter = BoardIntervalFilter()
        result.board = .init(departures: board.departures.values.filter {
            filter.contains($0, in: requested.interval)
        }, responseBytes: board.responseBytes)
        result.scope = requested
        return result
    }
}

