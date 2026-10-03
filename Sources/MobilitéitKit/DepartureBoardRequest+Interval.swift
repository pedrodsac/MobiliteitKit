import Foundation

extension HafasDepartureBoardRequest {
    func interval(at now: Date = .now) -> DateInterval? {
        guard let durationMinutes, durationMinutes > 0 else { return nil }
        let start: Date
        if let date, let time {
            start = HafasRealtimeRoutingProvider.serviceDate(date, time: time)
        } else if date == nil, time == nil {
            // Explicit minute anchors make a rolling board reusable without
            // pretending that an implicit server "now" is a fixed interval.
            start = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        } else {
            // TODO: interval reuse for partially specified ATP date/time needs
            // a verified server-default contract. Exact requests still work.
            return nil
        }
        return .init(start: start, duration: Double(durationMinutes) * 60)
    }

    func covering(_ interval: DateInterval) -> Self {
        let (date, time) = HafasRealtimeRoutingProvider.requestDateAndTime(interval.start)
        return .init(stationID: stationID, externalStationID: externalStationID,
                     requestID: requestID, language: language, directionStationID: directionStationID,
                     date: date, time: time,
                     durationMinutes: max(1, Int(ceil(interval.duration / 60))),
                     maximumJourneys: maximumJourneys, products: products, operators: operators,
                     lines: lines, filterEquivalentStops: filterEquivalentStops,
                     attributes: attributes, platforms: platforms,
                     realtimeMode: realtimeMode, includePasslist: includePasslist)
    }
}
