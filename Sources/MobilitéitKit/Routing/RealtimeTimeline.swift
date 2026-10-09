import Foundation

/// Resolves sparse overlays against EVERY scheduled event. Missing predictions
/// retain bounded delay evidence; they never imply an unreported recovery.
enum RealtimeTimeline {
    static let maximumObservationAge: TimeInterval = 120
    static let maximumDelay: TimeInterval = 2 * 60 * 60
    static let maximumPropagation: TimeInterval = 2 * 60 * 60

    /// ATP minute precision can put a report just before an unreported GTFS
    /// event at the preceding stop. That report bounds the earlier event, but
    /// cannot override another report or justify a larger timetable conflict.
    static func constrainingMinutePrecision(_ patch: RealtimeTripPatch) -> RealtimeTripPatch {
        guard patch.status == .active, !patch.isChronological else { return patch }
        var nextReport: (time: Date, observed: Date?)?
        let events = patch.events.reversed().map { event in
            func constrain(_ time: Date?, source: RealtimeTimingSource, observed: Date?)
                -> (Date?, RealtimeTimingSource, Date?) {
                guard let time else { return (nil, source, observed) }
                if source == .reported {
                    nextReport = (time, observed)
                    return (time, source, observed)
                }
                guard let nextReport, time > nextReport.time,
                      time.timeIntervalSince(nextReport.time) <= 90 else { return (time, source, observed) }
                return (nextReport.time, .estimated, nextReport.observed)
            }
            let departure = constrain(event.effectiveDeparture, source: event.departureSource,
                                      observed: event.departureObservedAt)
            let arrival = constrain(event.effectiveArrival, source: event.arrivalSource,
                                    observed: event.arrivalObservedAt)
            return RealtimeStopEventPatch(stopID: event.stopID,
                scheduledDeparture: event.scheduledDeparture, effectiveDeparture: departure.0,
                departureSource: departure.1, scheduledArrival: event.scheduledArrival,
                effectiveArrival: arrival.0, arrivalSource: arrival.1, platform: event.platform,
                stopSequence: event.stopSequence, boardingAllowed: event.boardingAllowed,
                alightingAllowed: event.alightingAllowed, observedAt: event.observedAt,
                departureObservedAt: departure.2, arrivalObservedAt: arrival.2,
                departurePrognosisType: event.departurePrognosisType, arrivalPrognosisType: event.arrivalPrognosisType,
                cancelledDeparture: event.cancelledDeparture, cancelledArrival: event.cancelledArrival)
        }
        return .init(tripID: patch.tripID, serviceDate: patch.serviceDate,
                     status: patch.status, events: events.reversed())
    }

    /// A departure proves the vehicle has already arrived at that same stop.
    /// Sparse ATP boards omit the boarding arrival, and minute precision can
    /// put an on-time report before GTFS's scheduled seconds. Constrain only an
    /// unreported arrival; conflicting direct observations remain invalid.
    static func consistentArrival(
        _ arrival: (Date?, RealtimeTimingSource),
        departure: (Date?, RealtimeTimingSource)
    ) -> (Date?, RealtimeTimingSource) {
        guard arrival.1 != .reported, departure.1 == .reported,
              let arrivalTime = arrival.0, let departureTime = departure.0,
              arrivalTime > departureTime else { return arrival }
        return (departureTime, .estimated)
    }

    static func resolved(_ patch: RealtimeTripPatch, snapshot: RoutingSnapshot, now: Date) -> RealtimeTripPatch {
        guard patch.status == .active, let index = snapshot.tripByID[patch.tripID] else { return patch }
        let trip = snapshot.trips[index]
        func rejected() -> RealtimeTripPatch {
            .init(tripID: patch.tripID, serviceDate: patch.serviceDate, status: .unreachable, events: [])
        }
        for event in patch.events where event.stopSequence == nil {
            let matches = trip.times.filter { snapshot.stops[$0.stop].id == event.stopID }
            if matches.count > 1 {
                let timedMatches = matches.filter { occurrence in
                    let a = occurrence.arrival.map { snapshot.converter.date(serviceDate: patch.serviceDate, serviceSeconds: $0) }
                    let d = occurrence.departure.map { snapshot.converter.date(serviceDate: patch.serviceDate, serviceSeconds: $0) }
                    return (a != nil && a == event.scheduledArrival) || (d != nil && d == event.scheduledDeparture)
                }
                if timedMatches.count != 1 { return rejected() }
            }
        }
        var events: [RealtimeStopEventPatch] = []
        var delay: (seconds: TimeInterval, scheduled: Date, observed: Date?)?
        for time in trip.times {
            let stopID = snapshot.stops[time.stop].id
            let arrival = time.arrival.map { snapshot.converter.date(serviceDate: patch.serviceDate, serviceSeconds: $0) }
            let departure = time.departure.map { snapshot.converter.date(serviceDate: patch.serviceDate, serviceSeconds: $0) }
            let exact = patch.events.filter { $0.stopID == stopID && $0.stopSequence == time.sequence }
            let legacy = patch.events.filter { event in
                guard event.stopID == stopID, event.stopSequence == nil else { return false }
                if trip.times.filter({ $0.stop == time.stop }).count == 1 { return true }
                return (arrival != nil && event.scheduledArrival == arrival)
                    || (departure != nil && event.scheduledDeparture == departure)
            }
            let event = (exact + legacy).max { ($0.observedAt ?? .distantPast) < ($1.observedAt ?? .distantPast) }
            var failed = false
            func timing(_ scheduled: Date?, prediction: Date?, source: RealtimeTimingSource, observed: Date?) -> (Date?, RealtimeTimingSource) {
                guard let scheduled else { return (nil, .scheduled) }
                if prediction != nil, source != .scheduled, let observed,
                   now.timeIntervalSince(observed) > maximumObservationAge || observed.timeIntervalSince(now) > 60 {
                    failed = true; return (nil, .scheduled)
                }
                let explicit = prediction != nil && (source == .reported || prediction != scheduled && source != .estimated)
                if explicit, let prediction {
                    let seconds = prediction.timeIntervalSince(scheduled)
                    guard abs(seconds) <= maximumDelay else { failed = true; return (nil, .scheduled) }
                    delay = (seconds, scheduled, observed)
                    return (prediction, .reported)
                }
                if let delay, scheduled >= delay.scheduled {
                    guard scheduled.timeIntervalSince(delay.scheduled) <= maximumPropagation else {
                        failed = true; return (nil, .scheduled)
                    }
                    return (scheduled.addingTimeInterval(delay.seconds), .estimated)
                }
                if let prediction, source == .estimated {
                    guard abs(prediction.timeIntervalSince(scheduled)) <= maximumDelay else { failed = true; return (nil, .scheduled) }
                    return (prediction, .estimated)
                }
                return (scheduled, .scheduled)
            }
            let arrivalTiming = timing(arrival, prediction: event?.effectiveArrival, source: event?.arrivalSource ?? .scheduled, observed: event?.arrivalObservedAt)
            let d = timing(departure, prediction: event?.effectiveDeparture, source: event?.departureSource ?? .scheduled, observed: event?.departureObservedAt)
            let a = consistentArrival(arrivalTiming, departure: d)
            if failed { return rejected() }
            events.append(.init(stopID: stopID, scheduledDeparture: departure, effectiveDeparture: d.0,
                departureSource: d.1, scheduledArrival: arrival, effectiveArrival: a.0, arrivalSource: a.1,
                platform: event?.platform, stopSequence: time.sequence,
                boardingAllowed: event?.boardingAllowed, alightingAllowed: event?.alightingAllowed,
                observedAt: event?.observedAt ?? delay?.observed, departureObservedAt: event?.departureObservedAt ?? delay?.observed, arrivalObservedAt: event?.arrivalObservedAt ?? delay?.observed,
                departurePrognosisType: event?.departurePrognosisType, arrivalPrognosisType: event?.arrivalPrognosisType,
                cancelledDeparture: event?.cancelledDeparture, cancelledArrival: event?.cancelledArrival))
        }
        let result = constrainingMinutePrecision(RealtimeTripPatch(tripID: patch.tripID, serviceDate: patch.serviceDate, events: events))
        return result.isChronological ? result : rejected()
    }
}
