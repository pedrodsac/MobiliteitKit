import Foundation

extension Raptor {
    static func transitAllowed(snapshot: RoutingSnapshot, trip: Int, stop: Int,
                               preferences: RoutingPreferences, stayingAboard: Bool = false) -> Bool {
        let vehicle = snapshot.trips[trip]
        if preferences.bike == .required && vehicle.bikesAllowed != 1 { return false }
        guard preferences.wheelchair == .required else { return true }
        guard vehicle.wheelchairAccessible == 1 else { return false }
        if stayingAboard { return true }
        let station = snapshot.stops[stop]
        let boarding = station.model.wheelchairBoarding == 0
            ? station.parent.flatMap { snapshot.stopByID[$0] }.map { snapshot.stops[$0].model.wheelchairBoarding } ?? 0
            : station.model.wheelchairBoarding
        return vehicle.wheelchairAccessible == 1 && boarding == 1
    }

    static func pathwayAllowed(_ path: SnapshotPath, preferences: RoutingPreferences) -> Bool {
        guard path.seconds > 0, path.distance.isFinite, path.distance >= 0 else { return false }
        guard preferences.wheelchair == .required else { return true }
        if path.mode == 2 || path.mode == 4 || path.stairCount.map({ $0 != 0 }) == true
            || path.maxSlope.map({ abs($0) > 1.0 / 12.0 }) == true
            || path.minWidth.map({ $0 < 0.9 }) == true { return false }
        return path.mode == 5 || (path.mode == 1 && path.stairCount == 0 && path.maxSlope != nil && path.minWidth != nil)
    }
}
