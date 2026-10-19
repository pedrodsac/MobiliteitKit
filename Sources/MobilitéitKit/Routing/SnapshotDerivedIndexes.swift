import Foundation

/// Snapshot values that follow from other snapshot values. The database build
/// and the cached-file load both call these, so the two paths cannot diverge.
/// They are cheap; the expensive indexes are stored in the snapshot file.
enum SnapshotDerivedIndexes {
    static func stationGroups(stops: [SnapshotStop], stopByID: [String: Int]) -> [Int] {
        stops.indices.map { stop in stops[stop].parent.flatMap { stopByID[$0] } ?? stop }
    }

    static func rulesByGroup(_ rules: [SnapshotRule], stationGroupByStop: [Int]) -> [RuleGroupKey: [SnapshotRule]] {
        Dictionary(grouping: rules) { rule in
            RuleGroupKey(from: rule.from.map { stationGroupByStop[$0] }, to: rule.to.map { stationGroupByStop[$0] })
        }
    }

    /// Instants depend on the time-zone database of the running OS, so they are
    /// recomputed on every load rather than stored.
    static func serviceDays(info: FeedInfo, converter: ServiceInstantConverter, active: [Set<Int>]) -> [SnapshotServiceDay] {
        active.indices.map { offset in
            let date = info.firstServiceDate.adding(days: offset)
            return SnapshotServiceDay(offset: offset, date: date, start: converter.date(serviceDate: date, serviceSeconds: 0), activeServices: active[offset])
        }
    }

    static func lastActiveDayStart(serviceDays: [SnapshotServiceDay], serviceCount: Int) -> [Date?] {
        var lastActiveDayStartByService = Array<Date?>(repeating: nil, count: serviceCount)
        for day in serviceDays {
            for service in day.activeServices {
                lastActiveDayStartByService[service] = day.start
            }
        }
        return lastActiveDayStartByService
    }

    static func serviceDayByDate(_ serviceDays: [SnapshotServiceDay]) -> [GTFSDate: SnapshotServiceDay] {
        Dictionary(uniqueKeysWithValues: serviceDays.map { ($0.date, $0) })
    }

    static func nearbyTransferSources(_ nearbyTransferStopsByStop: [[Int]]) -> [[Int]] {
        var sources = Array(repeating: [Int](), count: nearbyTransferStopsByStop.count)
        for from in nearbyTransferStopsByStop.indices {
            for to in nearbyTransferStopsByStop[from] { sources[to].append(from) }
        }
        return sources
    }
}
