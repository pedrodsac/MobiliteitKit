import Foundation

/// Shares completed HAFAS departure boards across all API clients.
/// The key includes the endpoint and every request option, so a filtered board
/// cannot accidentally satisfy an unfiltered or wider-window request. Fetches
/// stay in their caller's task so a canceled route request can stop promptly.
actor DepartureBoardCache {
    private struct Entry {
        let board: HafasDepartureBoard
        let fetchedAt: Date
    }

    private let lifetime: TimeInterval
    private let capacity: Int
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    init(
        lifetime: TimeInterval = 60,
        capacity: Int = 256,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.lifetime = max(0, lifetime)
        self.capacity = max(1, capacity)
        self.now = now
    }

    func value(
        for key: String,
        fetch: @escaping @Sendable () async throws -> HafasDepartureBoard
    ) async throws -> HafasDepartureBoard {
        if let entry = entries[key], now().timeIntervalSince(entry.fetchedAt) < lifetime {
            return entry.board
        }
        entries[key] = nil
        let board = try await fetch()
        try Task.checkCancellation()
        entries[key] = Entry(board: board, fetchedAt: now())
        if entries.count > capacity {
            let oldest = entries.min { $0.value.fetchedAt < $1.value.fetchedAt }?.key
            if let oldest { entries[oldest] = nil }
        }
        return board
    }
}
