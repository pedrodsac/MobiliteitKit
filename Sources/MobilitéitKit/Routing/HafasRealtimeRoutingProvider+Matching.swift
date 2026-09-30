import Foundation

extension HafasRealtimeRoutingProvider {
    func uniqueCandidate(
        for live: HafasDeparture,
        planned: Date,
        scheduled: [PreparedDeparture]
    ) async -> Candidate? {
        var candidates: [Candidate] = []
        let lowerBound = planned.addingTimeInterval(-90)
        let upperBound = planned.addingTimeInterval(90)
        var lower = 0
        var upper = scheduled.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if scheduled[middle].scheduledDate < lowerBound { lower = middle + 1 }
            else { upper = middle }
        }
        for value in scheduled[lower...] {
            guard value.scheduledDate <= upperBound else { break }
            guard let lineScore = Self.lineScore(live.product, route: value.departure.route)
            else { continue }

            // A cancelled board row has no realtime position to disambiguate
            // opposite-direction trips on the same line. Never cancel a GTFS
            // trip based on line and departure time alone.
            if live.cancelled == true {
                let directionMatches = live.direction.flatMap { direction in
                    value.departure.headsign.map { Self.normalized(direction) == Self.normalized($0) }
                } == true
                let stopTimes = await cachedStopTimes(forTripID: value.departure.tripID)
                let passlistMatches = align(live.passlist.values, to: stopTimes, serviceDate: value.serviceDate).count
                guard directionMatches || passlistMatches >= 2 else { continue }
            }

            var score = lineScore
            if let direction = live.direction,
               let headsign = value.departure.headsign,
               Self.normalized(direction) == Self.normalized(headsign) {
                score += 2
            }
            if !live.passlist.values.isEmpty {
                let stopTimes = await cachedStopTimes(forTripID: value.departure.tripID)
                score += min(4, align(live.passlist.values, to: stopTimes, serviceDate: value.serviceDate).count)
            }
            candidates.append(.init(
                departure: value.departure,
                serviceDate: value.serviceDate,
                scheduledDate: value.scheduledDate,
                score: score
            ))
        }

        let ordered = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = abs($0.scheduledDate.timeIntervalSince(planned))
            let rhs = abs($1.scheduledDate.timeIntervalSince(planned))
            if lhs != rhs { return lhs < rhs }
            return $0.departure.tripID < $1.departure.tripID
        }
        guard let best = ordered.first else { return nil }
        if ordered.count > 1 {
            let firstDistance = abs(best.scheduledDate.timeIntervalSince(planned))
            let secondDistance = abs(ordered[1].scheduledDate.timeIntervalSince(planned))
            guard best.score != ordered[1].score || firstDistance != secondDistance else { return nil }
        }
        return best
    }

    func cachedStopTimes(forTripID tripID: String) async -> [TripStopTime] {
        if let cached = stopTimesByTripID[tripID] { return cached }
        guard let values = try? await store.stopTimes(forTripID: tripID) else { return [] }
        if stopTimeCacheOrder.count == maximumCachedTripStopTimes {
            let oldest = stopTimeCacheOrder.removeFirst()
            stopTimesByTripID[oldest] = nil
        }
        stopTimesByTripID[tripID] = values
        stopTimeCacheOrder.append(tripID)
        return values
    }

    nonisolated static func lineScore(
        _ product: HafasProduct?,
        route: TransitRoute
    ) -> Int? {
        guard let product else { return nil }
        if let lineID = product.lineID,
           normalized(lineID) == normalized(route.id) {
            return 6
        }
        let liveNames = [product.line, product.name, product.categoryShort]
            .compactMap { $0.map(normalized) }
        let routeNames = [route.shortName, route.longName]
            .compactMap { $0.map(normalized) }
        return liveNames.contains(where: routeNames.contains) ? 4 : nil
    }

    nonisolated static func syntheticJourneyKey(
        _ value: HafasDeparture,
        stopID: String
    ) -> String {
        [stopID, value.product?.lineID, value.product?.line, value.direction,
         value.plannedDate, value.plannedTime]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    nonisolated static func requestDateAndTime(_ value: Date) -> (GTFSDate, ServiceTime) {
        let components = Calendar.luxembourg.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: value
        )
        let date = try! GTFSDate(
            year: components.year!, month: components.month!, day: components.day!
        )
        let seconds = Int32(
            (components.hour ?? 0) * 3_600
                + (components.minute ?? 0) * 60
                + (components.second ?? 0)
        )
        return (date, ServiceTime(rawValue: seconds))
    }

    nonisolated static func serviceDate(_ date: GTFSDate, time: ServiceTime) -> Date {
        ServiceInstantConverter(timeZone: Calendar.luxembourg.timeZone).date(
            serviceDate: date,
            serviceSeconds: time.rawValue
        )
    }

    static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.luxembourg.timeZone
        formatter.dateFormat = format
        return formatter
    }

    func date(date: String?, time: String?) -> Date? {
        guard let date, let time else { return nil }
        let timestamp = "\(date) \(time)"
        return fullTimestampFormatter.date(from: timestamp)
            ?? minuteTimestampFormatter.date(from: timestamp)
    }

    nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }
}

public enum HafasRealtimeRoutingError: Error, Sendable {
    case unavailable, timedOut
}

extension Calendar {
    static var luxembourg: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Luxembourg")!
        return value
    }
}
