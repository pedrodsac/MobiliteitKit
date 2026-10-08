import Foundation

extension HafasRealtimeRoutingProvider {
    // Boards at several transfer stops repeat vehicle passlists. Memoize pure
    // conversions within the batch, without extending observation freshness or
    // caching matching decisions that could hide timetable ambiguity.
    func clearMatchingMemoization() {
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
