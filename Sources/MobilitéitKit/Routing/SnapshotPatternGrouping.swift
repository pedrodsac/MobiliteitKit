enum SnapshotPatternGrouping {
    private struct Key: Hashable {
        let route: Int
        let stops: [Int]
    }

    static func patterns(for trips: [SnapshotTrip]) -> [SnapshotPattern] {
        var grouped: [Key: [Int]] = [:]
        for (index, trip) in trips.enumerated() {
            let key = Key(route: trip.route, stops: trip.times.map(\.stop))
            grouped[key, default: []].append(index)
        }
        // Preserve the original lexical pattern ordering while constructing its
        // decimal string only once per family, rather than once per trip.
        let ordered = grouped.map { key, family in
            (order: "\(key.route)|\(key.stops.map(String.init).joined(separator: ","))",
             pattern: SnapshotPattern(trips: family, stops: key.stops))
        }.sorted { $0.order < $1.order }
        return ordered.map(\.pattern)
    }
}
