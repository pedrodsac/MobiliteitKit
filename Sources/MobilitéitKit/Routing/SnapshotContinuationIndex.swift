import Foundation

/// Immutable continuation lookups shared by searches, publication and trip details.
struct SnapshotContinuationIndex: Sendable {
    let blockTripsByID: [String: [Int]]
    let explicitTargetsByTrip: [[Int]]
    /// Conservative reverse edges: a vehicle at a terminal may continue to these
    /// downstream stops without consuming another boarding round. Calendar and
    /// restriction checks remain the responsibility of the actual search.
    let sourcesByStop: [[Int]]
    let hasLinks: Bool

    init(trips: [SnapshotTrip], routes: [TransitRoute], rules: [SnapshotRule], stopCount: Int) {
        blockTripsByID = Dictionary(grouping: trips.indices.filter {
            trips[$0].blockID?.isEmpty == false && !trips[$0].isFrequencyTemplate
        }, by: { trips[$0].blockID! })
        var explicit = Array(repeating: Set<Int>(), count: trips.count)
        for rule in rules where rule.type == 4 {
            if let from = rule.fromTrip, let to = rule.toTrip { explicit[from].insert(to) }
        }
        explicitTargetsByTrip = explicit.map { $0.sorted() }
        var sources = Array(repeating: Set<Int>(), count: stopCount)
        func add(from: Int, to: Int) {
            guard let terminal = trips[from].times.last?.stop,
                  trips[to].times.first?.stop == terminal else { return }
            for time in trips[to].times.dropFirst() { sources[time.stop].insert(terminal) }
        }
        for from in explicit.indices {
            for to in explicit[from] { add(from: from, to: to) }
        }
        // Include every topologically possible block link, even if its services
        // never overlap. Over-approximation may retain extra work, never prune a
        // valid calendar-specific continuation or a chain of continuations.
        for members in blockTripsByID.values {
            for from in members {
                for to in members where from != to
                    && trips[to].firstServiceTime >= trips[from].lastServiceTime
                    && routes[trips[to].route].type == routes[trips[from].route].type {
                    add(from: from, to: to)
                }
            }
        }
        sourcesByStop = sources.map { $0.sorted() }
        hasLinks = sources.contains { !$0.isEmpty }
    }
}
