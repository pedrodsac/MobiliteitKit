import Foundation

extension HafasRealtimeRoutingProvider {
    // Boards at several transfer stops repeat vehicle passlists. Memoize pure
    // conversions within the batch, without extending observation freshness or
    // caching matching decisions that could hide timetable ambiguity.
    func clearMatchingMemoization() {
        alignments.removeAll(keepingCapacity: true)
        timestampCache.removeAll(keepingCapacity: true)
        invalidTimestamps.removeAll(keepingCapacity: true)
        normalizedNames.removeAll(keepingCapacity: true)
        serviceDayStarts.removeAll(keepingCapacity: true)
    }

    func normalizedName(_ value: String) -> String {
        if let cached = normalizedNames[value] { return cached }
        let result = Self.normalized(value)
        if normalizedNames.count < 8_192 { normalizedNames[value] = result }
        return result
    }

    func serviceInstant(_ date: GTFSDate, time: ServiceTime) -> Date {
        let start: Date
        if let cached = serviceDayStarts[date] { start = cached }
        else {
            start = Self.serviceDate(date, time: ServiceTime(rawValue: 0))
            if serviceDayStarts.count < 32 { serviceDayStarts[date] = start }
        }
        return start.addingTimeInterval(Double(time.rawValue))
    }
}

extension HafasRealtimeRoutingProvider {
    /// Populate only pure conversions while other HTTP requests are in flight.
    /// Matching and patch merging still visit boards in their original order.
    func prepareBoard(_ board: HafasDepartureBoard?, from: Date, through: Date, deadline: ContinuousClock.Instant) {
        guard let board else { return }
        for live in board.departures.values {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return }
            guard Self.hasRealtimeSignal(live), let planned = date(date: live.plannedDate, time: live.plannedTime),
                  planned >= from.addingTimeInterval(-90), planned <= through.addingTimeInterval(90) else { continue }
            for name in [live.product?.lineID, live.product?.line, live.product?.name,
                         live.product?.categoryShort, live.direction].compactMap({ $0 }) { _ = normalizedName(name) }
            _ = date(date: live.realtimeDate ?? live.plannedDate, time: live.realtimeTime)
            for stop in live.passlist.values {
                _ = date(date: stop.arrivalDate, time: stop.arrivalTime)
                _ = date(date: stop.departureDate, time: stop.departureTime)
                _ = date(date: stop.realtimeArrivalDate ?? stop.arrivalDate, time: stop.realtimeArrivalTime)
                _ = date(date: stop.realtimeDepartureDate ?? stop.departureDate, time: stop.realtimeDepartureTime)
            }
        }
    }
}
