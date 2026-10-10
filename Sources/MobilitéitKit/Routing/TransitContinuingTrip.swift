import Foundation

/// A verified continuation of a selected vehicle, retaining its own trip identity.
public struct TransitContinuingTrip: Hashable, Sendable {
    public let instance: TransitInstanceIdentity
    public let route: TransitRoute
    public let headsign: String?
    public let boardingSequence: Int
    public let alightingSequence: Int
}

extension TransitRouter {
    /// Follows scheduled stay-aboard links without performing a destination search.
    /// Each run must be refreshed independently; live evidence never crosses a link.
    public func continuingTrips(for instance: TransitInstanceIdentity) throws -> [TransitContinuingTrip] {
        guard instance.feedGeneration == snapshot.info.generation else { throw TransitTripSnapshotError.obsoleteFeed }
        guard var index = snapshot.tripByID[instance.tripID],
              let day = snapshot.serviceDayByDate[instance.serviceDate],
              day.activeServices.contains(snapshot.trips[index].service) else { throw TransitTripSnapshotError.tripNotFound }
        var seen: Set<Int> = [index]
        var result: [TransitContinuingTrip] = []
        while true {
            let trip = snapshot.trips[index]
            guard let last = trip.times.last, let arrival = last.arrival else { break }
            let time = snapshot.date(serviceDate: instance.serviceDate, serviceSeconds: arrival)
            let incoming = Raptor.TransitLeg(trip: index, board: trip.times[0].stop, alight: last.stop,
                boardPos: 0, alightPos: trip.times.count - 1, day: instance.serviceDate,
                scheduledBoard: time, scheduledAlight: time, boardTime: time, alightTime: time,
                requiredTransferSecondsAfterWalking: 0)
            let block = Raptor.blockSuccessor(snapshot: snapshot, incoming: incoming)
            let explicit = snapshot.continuations.explicitTargetsByTrip[index]
            let targets = Set(explicit + [block].compactMap { $0 }).filter { target in
                let next = snapshot.trips[target]
                return !seen.contains(target) && day.activeServices.contains(next.service)
                    && next.times.first?.stop == last.stop && next.firstServiceTime >= trip.lastServiceTime
                    && Raptor.permitsContinuation(snapshot: snapshot, incoming: incoming, outgoing: target, blockTarget: block)
            }
            guard targets.count == 1, let target = targets.first else { break }
            let next = snapshot.trips[target]
            result.append(.init(instance: .init(feedGeneration: instance.feedGeneration, tripID: next.id, serviceDate: instance.serviceDate),
                route: snapshot.routes[next.route], headsign: next.headsign,
                boardingSequence: next.times[0].sequence, alightingSequence: next.times[next.times.count - 1].sequence))
            seen.insert(target)
            index = target
        }
        return result
    }
}
