import Foundation

/// A whole vehicle run. Stop occurrences retain both arrival and departure
/// evidence; routing extrapolations deliberately do not become live reports.
public struct TransitTripSnapshot: Hashable, Sendable {
    public let instance: TransitInstanceIdentity
    public let stops: [TransitTripStop]
    public let isCancelled: Bool
    public let liveDataAvailable: Bool
    public let fetchedAt: Date
}

public struct TransitTripTiming: Hashable, Sendable {
    public let scheduled: Date
    public let realtime: Date?
    /// ATP's REPORTED value identifies historical reports; other values remain predictions.
    public let prognosisType: String?
    public let observedAt: Date?
    public let isCancelled: Bool
}

public struct TransitTripStop: Hashable, Sendable, Identifiable {
    public let sequence: Int
    public let stop: TransitStop
    public let arrival: TransitTripTiming?
    public let departure: TransitTripTiming?
    public let platform: String?
    public var id: Int { sequence }
}

public enum TransitTripSnapshotError: Error, Sendable {
    case obsoleteFeed, tripNotFound, invalidBoardingOccurrence
}

extension TransitRouter {
    /// Uses the same matched ATP pass lists as routing, without running a new
    /// route search. The service date belongs to the selected run, not today.
    public func tripSnapshot(
        for instance: TransitInstanceIdentity,
        boardingSequence: Int,
        refreshPolicy: RealtimeRefreshPolicy = .useCache
    ) async throws -> TransitTripSnapshot {
        guard instance.feedGeneration == snapshot.info.generation else {
            throw TransitTripSnapshotError.obsoleteFeed
        }
        guard let index = snapshot.tripByID[instance.tripID] else {
            throw TransitTripSnapshotError.tripNotFound
        }
        let trip = snapshot.trips[index]
        guard let boarding = trip.times.first(where: { $0.sequence == boardingSequence }),
              let boardingTime = boarding.departure else {
            throw TransitTripSnapshotError.invalidBoardingOccurrence
        }
        let scheduled = snapshot.converter.date(serviceDate: instance.serviceDate, serviceSeconds: boardingTime)
        let from = scheduled.addingTimeInterval(-90)
        let through = scheduled.addingTimeInterval(RealtimeTimeline.maximumDelay + 90)
        let stopID = snapshot.stops[boarding.stop].id
        let lines = snapshot.routes[trip.route].shortName.map { [$0] } ?? []
        let batch = try await realtimePatches(for: .init(
            stopIDs: [stopID], from: from, through: through,
            refreshPolicy: refreshPolicy,
            targets: [.init(stopID: stopID, from: from, through: through, lines: lines)],
            tripIDs: [instance.tripID]
        ))
        try Task.checkCancellation()
        let patch = batch?.patches.first {
            $0.tripID == instance.tripID && $0.serviceDate == instance.serviceDate
        }
        let stops = trip.times.map { time in
            let stop = snapshot.stops[time.stop].model
            let event = patch?.event(stopID: stop.id, sequence: time.sequence)
            func timing(_ seconds: Int32?, prediction: Date?, source: RealtimeTimingSource?,
                        prognosis: String?, observed: Date?, cancelled: Bool?) -> TransitTripTiming? {
                guard let seconds else { return nil }
                return TransitTripTiming(
                    scheduled: snapshot.converter.date(serviceDate: instance.serviceDate, serviceSeconds: seconds),
                    realtime: source == .reported && prognosis?.uppercased() != "UNKNOWN" ? prediction : nil,
                    prognosisType: prognosis, observedAt: observed,
                    isCancelled: patch?.status == .cancelled || cancelled == true
                )
            }
            return TransitTripStop(sequence: time.sequence, stop: stop,
                arrival: timing(time.arrival, prediction: event?.effectiveArrival, source: event?.arrivalSource,
                    prognosis: event?.arrivalPrognosisType, observed: event?.arrivalObservedAt,
                    cancelled: event?.cancelledArrival),
                departure: timing(time.departure, prediction: event?.effectiveDeparture, source: event?.departureSource,
                    prognosis: event?.departurePrognosisType, observed: event?.departureObservedAt,
                    cancelled: event?.cancelledDeparture),
                platform: event?.platform ?? stop.platformCode)
        }
        return TransitTripSnapshot(instance: instance, stops: stops,
            isCancelled: patch?.status == .cancelled,
            liveDataAvailable: batch?.coveredStopIDs.contains(stopID) == true
                && batch?.incompleteStopIDs.contains(stopID) == false,
            fetchedAt: batch?.fetchedAt ?? clock())
    }
}
