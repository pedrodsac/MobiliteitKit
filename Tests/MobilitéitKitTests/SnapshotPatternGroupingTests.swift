import Testing
@testable import MobiliteitKit

@Suite struct SnapshotPatternGroupingTests {
    @Test(arguments: [false, true])
    func groupingPreservesLegacyLexicalOrderAndInputTripOrder(reverseInput: Bool) {
        let specifications: [(route: Int, stops: [Int])] = [
            (2, [2, 10, 2]), (10, [2, 10, 2]), (2, [2, 10]),
            (2, [2, 10, 2]), (2, [10, 2]), (10, [2, 10, 2]),
            (2, [2, 2, 10]), (10, [2, 10, 2]),
        ]
        let forward = specifications.enumerated().map { index, value in
            SnapshotTrip(id: "trip-\(index)", route: value.route, service: index % 3,
                times: value.stops.enumerated().map { position, stop in
                    .init(stop: stop, sequence: position, arrival: Int32(index * 60 + position),
                        departure: Int32(index * 60 + position), pickup: 0, dropoff: 0)
                }, headsign: nil, wheelchairAccessible: 0)
        }
        let trips = reverseInput ? Array(forward.reversed()) : forward
        let actual = SnapshotPatternGrouping.patterns(for: trips)
        let expected = legacyPatterns(trips)
        #expect(actual.map(\.trips) == expected.map(\.trips))
        #expect(actual.map(\.stops) == expected.map(\.stops))
        if !reverseInput {
            // Decimal route and stop indices sort lexically, including 10 before 2.
            #expect(actual.map(\.trips) == [[1, 5, 7], [4], [2], [0, 3], [6]])
            #expect(actual.first?.stops == [2, 10, 2])
        }
    }

    @Test func emptyInputHasNoPatterns() {
        #expect(SnapshotPatternGrouping.patterns(for: []).isEmpty)
    }

    private func legacyPatterns(_ trips: [SnapshotTrip]) -> [SnapshotPattern] {
        var grouped: [String: [Int]] = [:]
        for (index, trip) in trips.enumerated() {
            let key = "\(trip.route)|\(trip.times.map(\.stop).map(String.init).joined(separator: ","))"
            grouped[key, default: []].append(index)
        }
        return grouped.keys.sorted().map { key in
            let family = grouped[key] ?? []
            return SnapshotPattern(trips: family, stops: family.first.map { trips[$0].times.map(\.stop) } ?? [])
        }
    }
}
