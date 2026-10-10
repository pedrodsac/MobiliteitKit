import Foundation

extension Raptor {
    /// One immutable snapshot/session owns this bounded value cache. Overlay
    /// equality is checked before reuse; query-window eligibility is never cached.
    struct PreparationCache: Sendable {
        struct Entry: Sendable {
            let overlay: PatchOverlay?
            let instance: ActiveTripInstance?
        }
        private var entries: [PatchKey: Entry] = [:]
        private var order: [PatchKey] = []
        private var cursor = 0
        private let capacity = 4_096
        private var reachability: (stops: Set<Int>, rides: Int, value: DestinationReachability)?

        mutating func destination(snapshot: RoutingSnapshot, stops: Set<Int>, rides: Int) -> DestinationReachability {
            if let cached = reachability, cached.stops == stops, cached.rides == rides { return cached.value }
            let value = DestinationReachability(snapshot: snapshot, egressStops: stops, maxRides: rides)
            reachability = (stops, rides, value)
            return value
        }
        mutating func instance(tripIndex: Int, trip: SnapshotTrip, day: SnapshotServiceDay,
                               overlay: PatchOverlay?) -> ActiveTripInstance? {
            let key = PatchKey(trip: tripIndex, serviceDate: day.date)
            if let cached = entries[key], cached.overlay == overlay { return cached.instance }
            let old = entries[key]?.instance
            let departures = old?.scheduledDepartures ?? trip.times.map { $0.departure.map { day.start.addingTimeInterval(Double($0)) } }
            let arrivals = old?.scheduledArrivals ?? trip.times.map { $0.arrival.map { day.start.addingTimeInterval(Double($0)) } }
            let effectiveDepartures = overlay == nil ? departures : trip.times.indices.map {
                patchTime(overlay, position: $0, departure: true) ?? departures[$0]
            }
            let effectiveArrivals = overlay == nil ? arrivals : trip.times.indices.map {
                patchTime(overlay, position: $0, departure: false) ?? arrivals[$0]
            }
            var previous: Date?
            var chronological = true
            for position in trip.times.indices {
                if let time = effectiveArrivals[position] {
                    if previous.map({ time < $0 }) == true { chronological = false; break }
                    previous = time
                }
                if let time = effectiveDepartures[position] {
                    if previous.map({ time < $0 }) == true { chronological = false; break }
                    previous = time
                }
            }
            let instance: ActiveTripInstance? = chronological ? .init(tripIndex: tripIndex, serviceDay: day,
                scheduledDepartures: departures, scheduledArrivals: arrivals,
                effectiveDepartures: effectiveDepartures, effectiveArrivals: effectiveArrivals,
                conservativeDepartures: overlay == nil ? departures : trip.times.indices.map { position in
                    if overlay?.eventsByPosition[position]?.departureSource == .estimated,
                       let scheduled = departures[position], let effective = effectiveDepartures[position] {
                        return min(scheduled, effective)
                    }
                    return effectiveDepartures[position]
                }, boardingAllowed: trip.times.indices.map { overlay?.eventsByPosition[$0]?.boardingAllowed != false },
                alightingAllowed: trip.times.indices.map { overlay?.eventsByPosition[$0]?.alightingAllowed != false }) : nil
            if entries[key] == nil {
                if order.count == capacity {
                    entries[order[cursor]] = nil; order[cursor] = key; cursor = (cursor + 1) % capacity
                } else { order.append(key) }
            }
            entries[key] = .init(overlay: overlay, instance: instance)
            return instance
        }
    }
}
