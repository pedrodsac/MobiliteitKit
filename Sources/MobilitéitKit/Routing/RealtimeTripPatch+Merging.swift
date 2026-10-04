import Foundation

extension RealtimeTripPatch {
    struct EventKey: Hashable {
        let stopID: String
        let sequence: Int?
    }
    var isChronological: Bool {
        var previous: Date?
        for event in events {
            for time in [event.effectiveArrival, event.effectiveDeparture].compactMap({ $0 }) {
                if let previous, time < previous { return false }
                previous = time
            }
        }
        return true
    }

    /// Merge predictions independently; a later report at a boarding stop can
    /// improve a previously estimated event without erasing downstream reports.
    func merging(_ incoming: RealtimeTripPatch) -> RealtimeTripPatch {
        guard tripID == incoming.tripID, serviceDate == incoming.serviceDate else { return self }
        var merged = Dictionary(events.map { (EventKey(stopID: $0.stopID, sequence: $0.stopSequence), $0) },
                                uniquingKeysWith: { _, newest in newest })
        for update in incoming.events {
            let key = EventKey(stopID: update.stopID, sequence: update.stopSequence)
            guard let old = merged[key] else { merged[key] = update; continue }
            func prefer(_ source: RealtimeTimingSource, over prior: RealtimeTimingSource, observation: Date?, priorObservation: Date?) -> Bool {
                func rank(_ value: RealtimeTimingSource) -> Int {
                    switch value { case .scheduled: 0; case .estimated: 1; case .reported: 2 }
                }
                let age = (observation ?? .distantPast).timeIntervalSince(priorObservation ?? .distantPast)
                // Within the freshness window, direct observations outrank
                // extrapolations regardless of concurrent board completion order.
                if rank(source) != rank(prior), abs(age) <= RealtimeTimeline.maximumObservationAge {
                    return rank(source) > rank(prior)
                }
                if observation != priorObservation { return age > 0 }
                if rank(source) != rank(prior) { return rank(source) > rank(prior) }
                return (update.observedAt ?? .distantPast) >= (old.observedAt ?? .distantPast)
            }
            let departure = update.effectiveDeparture != nil && prefer(update.departureSource, over: old.departureSource, observation: update.departureObservedAt, priorObservation: old.departureObservedAt)
            let arrival = update.effectiveArrival != nil && prefer(update.arrivalSource, over: old.arrivalSource, observation: update.arrivalObservedAt, priorObservation: old.arrivalObservedAt)
            let latest = (update.observedAt ?? .distantPast) >= (old.observedAt ?? .distantPast)
            let platform: String? = latest ? (update.platform ?? old.platform) : (old.platform ?? update.platform)
            let boarding: Bool? = latest ? (update.boardingAllowed ?? old.boardingAllowed)
                : (old.boardingAllowed ?? update.boardingAllowed)
            let alighting: Bool? = latest ? (update.alightingAllowed ?? old.alightingAllowed)
                : (old.alightingAllowed ?? update.alightingAllowed)
            let observation = [old.observedAt, update.observedAt].compactMap { $0 }.max()
            merged[key] = RealtimeStopEventPatch(stopID: old.stopID,
                                scheduledDeparture: old.scheduledDeparture ?? update.scheduledDeparture,
                                effectiveDeparture: departure ? update.effectiveDeparture : old.effectiveDeparture,
                                departureSource: departure ? update.departureSource : old.departureSource,
                                scheduledArrival: old.scheduledArrival ?? update.scheduledArrival,
                                effectiveArrival: arrival ? update.effectiveArrival : old.effectiveArrival,
                                arrivalSource: arrival ? update.arrivalSource : old.arrivalSource,
                                platform: platform, stopSequence: old.stopSequence,
                                boardingAllowed: boarding, alightingAllowed: alighting,
                                observedAt: observation,
                                departureObservedAt: departure ? update.departureObservedAt : old.departureObservedAt,
                                arrivalObservedAt: arrival ? update.arrivalObservedAt : old.arrivalObservedAt)
        }
        let oldDate = events.compactMap(\.observedAt).max() ?? .distantPast
        let newDate = incoming.events.compactMap(\.observedAt).max() ?? .distantPast
        let status: RealtimeTripStatus
        if oldDate == newDate {
            status = self.status == .cancelled || incoming.status == .cancelled ? .cancelled
                : (self.status == .unreachable || incoming.status == .unreachable ? .unreachable : .active)
        } else { status = newDate > oldDate ? incoming.status : self.status }
        let result = RealtimeTripPatch(tripID: tripID, serviceDate: serviceDate, status: status,
                                      events: merged.values.sorted {
            if let left = $0.stopSequence, let right = $1.stopSequence { return left < right }
            return ($0.scheduledDeparture ?? $0.scheduledArrival ?? .distantPast)
                < ($1.scheduledDeparture ?? $1.scheduledArrival ?? .distantPast)
        })
        return result.status != .active || result.isChronological ? result
            : (newDate >= oldDate ? incoming : self)
    }

    /// Freshness belongs to each observation, not to the whole trip. Keep
    /// scheduled events so accumulated pages can shed expired live timings.
    func retainingFreshObservations(at now: Date, maximumAge: TimeInterval = 60) -> Self {
        func fresh(_ date: Date?) -> Bool {
            date.map { now.timeIntervalSince($0) < maximumAge && $0.timeIntervalSince(now) <= 60 } ?? true
        }
        let retained = events.map { event in
            let departure = fresh(event.departureObservedAt)
            let arrival = fresh(event.arrivalObservedAt)
            let metadata = fresh(event.observedAt)
            let stamps = [metadata ? event.observedAt : nil,
                          departure ? event.departureObservedAt : nil,
                          arrival ? event.arrivalObservedAt : nil].compactMap { $0 }
            return RealtimeStopEventPatch(stopID: event.stopID,
                scheduledDeparture: event.scheduledDeparture,
                effectiveDeparture: departure ? event.effectiveDeparture : event.scheduledDeparture,
                departureSource: departure ? event.departureSource : .scheduled,
                scheduledArrival: event.scheduledArrival,
                effectiveArrival: arrival ? event.effectiveArrival : event.scheduledArrival,
                arrivalSource: arrival ? event.arrivalSource : .scheduled,
                platform: metadata ? event.platform : nil, stopSequence: event.stopSequence,
                boardingAllowed: metadata ? event.boardingAllowed : nil,
                alightingAllowed: metadata ? event.alightingAllowed : nil,
                observedAt: stamps.max(),
                departureObservedAt: departure ? event.departureObservedAt : nil,
                arrivalObservedAt: arrival ? event.arrivalObservedAt : nil)
        }
        let latest = events.compactMap(\.observedAt).max()
        return .init(tripID: tripID, serviceDate: serviceDate,
                     status: fresh(latest) ? status : .active, events: retained)
    }

    func event(stopID: String, sequence: Int) -> RealtimeStopEventPatch? {
        events.first { $0.stopID == stopID && $0.stopSequence == sequence }
            ?? events.first { $0.stopID == stopID && $0.stopSequence == nil }
    }
}
