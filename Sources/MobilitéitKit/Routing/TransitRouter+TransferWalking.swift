import Foundation

extension TransitRouter {
    /// Every stop-to-stop request `relaxWalkingTransfers` can issue, without a
    /// departure time. Ordered by source stop index, then the precomputed
    /// nearby order. Coordinates come from the same snapshot values RAPTOR
    /// uses, so they are bit-identical to its requests.
    ///
    /// A walking provider that varies its result by departure time must not
    /// memoise these: the router's own walking cache ignores departures too.
    public nonisolated func transferWalkingRequests() -> [WalkingRequest] {
        snapshot.nearbyTransferStopsByStop.indices.flatMap { from in
            snapshot.nearbyTransferStopsByStop[from].map { to in
                WalkingRequest(source: snapshot.stops[from].model.coordinate,
                               destination: snapshot.stops[to].model.coordinate)
            }
        }
    }
}
