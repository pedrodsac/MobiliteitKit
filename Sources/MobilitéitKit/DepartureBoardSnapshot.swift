import Foundation

/// A board and its original acquisition evidence. Cache reuse never renews it.
public struct HafasDepartureBoardSnapshot: Sendable {
    public let board: HafasDepartureBoard
    public let fetchedAt: Date
    public let requestedInterval: DateInterval?
    public let isComplete: Bool
    private let observations: [String: Date]

    init(_ response: CachedBoardResponse) {
        board = response.board; fetchedAt = response.fetchedAt
        requestedInterval = response.scope?.interval; isComplete = response.isComplete
        observations = response.observations
    }

    public func observedAt(for departure: HafasDeparture) -> Date {
        observations[departure.cacheIdentity] ?? fetchedAt
    }
}

struct BoardCacheScope: Sendable {
    let namespace: String
    let interval: DateInterval
    let maximumJourneys: Int?
    var unlimited: Bool { maximumJourneys == -1 }
    func complete(_ board: HafasDepartureBoard) -> Bool {
        unlimited || maximumJourneys.map { $0 > 0 && board.departures.values.count < $0 } == true
    }
    func contains(_ other: BoardCacheScope) -> Bool {
        namespace == other.namespace && interval.start <= other.interval.start
            && interval.end >= other.interval.end
    }
}

extension HafasDeparture {
    var cacheIdentity: String {
        [journeyReference?.reference, stopExternalID, product?.lineID, product?.line,
         direction, plannedDate, plannedTime].map { $0 ?? "" }.joined(separator: "|")
    }
}

/// Filtering is by either scheduled or predicted departure: a delayed service
/// can be inside a board's effective window despite an earlier scheduled time.
struct BoardIntervalFilter {
    private let seconds = HafasRealtimeRoutingProvider.makeFormatter("yyyy-MM-dd HH:mm:ss")
    private let minutes = HafasRealtimeRoutingProvider.makeFormatter("yyyy-MM-dd HH:mm")
    func contains(_ departure: HafasDeparture, in interval: DateInterval) -> Bool {
        func date(_ day: String?, _ time: String?) -> Date? {
            guard let day, let time else { return nil }
            return seconds.date(from: "\(day) \(time)") ?? minutes.date(from: "\(day) \(time)")
        }
        let values = [date(departure.plannedDate, departure.plannedTime),
                      date(departure.realtimeDate ?? departure.plannedDate, departure.realtimeTime)].compactMap { $0 }
        // Keep undated rows for the mapper to handle conservatively.
        return values.isEmpty || values.contains { $0 >= interval.start && $0 <= interval.end }
    }
}
