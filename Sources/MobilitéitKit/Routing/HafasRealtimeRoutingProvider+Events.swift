import Foundation

extension HafasRealtimeRoutingProvider {
    /// Route indices are HAFAS occurrences, not GTFS sequences. Match by ordered
    /// identity + scheduled instant, using the GTFS service date after midnight.
    func align(_ live: [HafasPasslistStop], to scheduled: [TripStopTime],
               serviceDate: GTFSDate, deadline: ContinuousClock.Instant? = nil) -> [Int: HafasPasslistStop] {
        var result: [Int: HafasPasslistStop] = [:]
        var start = 0
        var previousRouteIndex: Int?
        for stop in live {
            if Task.isCancelled || deadline.map({ ContinuousClock.now >= $0 }) == true { return [:] }
            if let index = stop.routeIndex, let previousRouteIndex, index <= previousRouteIndex { continue }
            guard start < scheduled.count,
                  let position = scheduled[start...].firstIndex(where: {
                      passlistStop(stop, matches: $0, serviceDate: serviceDate)
                  }) else { continue }
            result[position] = stop
            start = position + 1
            previousRouteIndex = stop.routeIndex ?? previousRouteIndex
        }
        return result
    }

    func passlistStop(_ live: HafasPasslistStop, matches scheduled: TripStopTime,
                      serviceDate: GTFSDate) -> Bool {
        let identityMatches = [live.externalID, live.id].compactMap { $0 }.contains {
            Self.sameStopID($0, scheduled.stop.id)
        }
        guard identityMatches || live.name.map({ normalizedName($0) == normalizedName(scheduled.stop.name) }) == true
        else { return false }
        let liveDeparture = date(date: live.departureDate, time: live.departureTime)
        let liveArrival = date(date: live.arrivalDate, time: live.arrivalTime)
        if let liveTime = liveDeparture, let departure = scheduled.departure {
            return abs(serviceInstant(serviceDate, time: departure).timeIntervalSince(liveTime)) <= 90
        }
        if let liveTime = liveArrival, let arrival = scheduled.arrival {
            return abs(serviceInstant(serviceDate, time: arrival).timeIntervalSince(liveTime)) <= 90
        }
        // A name without a timestamp cannot identify a repeated/platform stop.
        return identityMatches
    }

    nonisolated static func sameStopID(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        guard left.allSatisfy(\.isNumber), right.allSatisfy(\.isNumber) else { return false }
        return left.drop(while: { $0 == "0" }) == right.drop(while: { $0 == "0" })
    }

    func patch(for live: HafasDeparture, candidate: Candidate,
               boardingStopID: String, observedAt: Date, deadline: ContinuousClock.Instant? = nil) async -> RealtimeTripPatch? {
        let stopTimes = await cachedStopTimes(forTripID: candidate.departure.tripID)
        guard !stopTimes.isEmpty else { return nil }
        let aligned = align(live.passlist.values, to: stopTimes, serviceDate: candidate.serviceDate, deadline: deadline)
        let boarding = stopTimes.indices.min { left, right in
            func distance(_ position: Int) -> TimeInterval {
                let value = stopTimes[position]
                guard Self.sameStopID(value.stop.id, boardingStopID), let departure = value.departure else {
                    return .infinity
                }
                return abs(serviceInstant(candidate.serviceDate, time: departure)
                    .timeIntervalSince(candidate.scheduledDate))
            }
            return distance(left) < distance(right)
        }
        let status: RealtimeTripStatus = live.cancelled == true ? .cancelled
            : (live.reachable == false ? .unreachable : .active)
        let boardingPrediction = date(date: live.realtimeDate ?? live.plannedDate, time: live.realtimeTime)
        var precedingDelay: (seconds: TimeInterval, scheduled: Date)?
        var events: [RealtimeStopEventPatch] = []
        for position in stopTimes.indices {
            if Task.isCancelled || deadline.map({ ContinuousClock.now >= $0 }) == true { return nil }
            let value = stopTimes[position]
            let pass = aligned[position]
            let arrival = value.arrival.map { serviceInstant(candidate.serviceDate, time: $0) }
            let departure = value.departure.map { serviceInstant(candidate.serviceDate, time: $0) }
            let reportedArrival = date(date: pass?.realtimeArrivalDate ?? pass?.arrivalDate,
                                       time: pass?.realtimeArrivalTime)
            let reportedDeparture = date(date: pass?.realtimeDepartureDate ?? pass?.departureDate,
                                         time: pass?.realtimeDepartureTime)
                ?? (position == boarding ? boardingPrediction : nil)
            func timing(_ scheduled: Date?, prediction: Date?) -> (Date?, RealtimeTimingSource) {
                guard let scheduled else { return (nil, .scheduled) }
                if let prediction { return (prediction, .reported) }
                if let precedingDelay,
                   scheduled >= precedingDelay.scheduled,
                   scheduled.timeIntervalSince(precedingDelay.scheduled) <= 30 * 60,
                   abs(precedingDelay.seconds) <= 2 * 60 * 60 {
                    return (scheduled.addingTimeInterval(precedingDelay.seconds), .estimated)
                }
                return (scheduled, .scheduled)
            }
            let initialArrivalTiming = timing(arrival, prediction: reportedArrival)
            if let arrival, let reportedArrival {
                precedingDelay = (reportedArrival.timeIntervalSince(arrival), arrival)
            }
            let departureTiming = timing(departure, prediction: reportedDeparture)
            let arrivalTiming = RealtimeTimeline.consistentArrival(initialArrivalTiming, departure: departureTiming)
            if let departure, let reportedDeparture {
                precedingDelay = (reportedDeparture.timeIntervalSince(departure), departure)
            }
            events.append(.init(stopID: value.stop.id,
                                scheduledDeparture: departure, effectiveDeparture: departureTiming.0,
                                departureSource: departureTiming.1,
                                scheduledArrival: arrival, effectiveArrival: arrivalTiming.0,
                                arrivalSource: arrivalTiming.1,
                                platform: pass?.realtimeDepartureTrack ?? pass?.realtimeArrivalTrack
                                    ?? (position == boarding
                                        ? live.realtimePlatform?.text ?? live.platform?.text : nil)
                                    ?? value.stop.platformCode,
                                stopSequence: value.sequence,
                                boardingAllowed: pass?.cancelled == true ? false
                                    : pass?.realtimeBoarding ?? pass?.boarding,
                                alightingAllowed: pass?.cancelled == true ? false
                                    : pass?.realtimeAlighting ?? pass?.alighting,
                                observedAt: observedAt,
                                departurePrognosisType: pass?.departurePrognosisType
                                    ?? (position == boarding ? live.prognosisType : nil),
                                arrivalPrognosisType: pass?.arrivalPrognosisType,
                                cancelledDeparture: pass?.cancelled == true ? true : pass?.cancelledDeparture,
                                cancelledArrival: pass?.cancelled == true ? true : pass?.cancelledArrival))
        }
        let result = RealtimeTimeline.constrainingMinutePrecision(RealtimeTripPatch(tripID: candidate.departure.tripID,
                                       serviceDate: candidate.serviceDate, status: status, events: events))
        return status != .active || result.isChronological ? result : nil
    }
}
