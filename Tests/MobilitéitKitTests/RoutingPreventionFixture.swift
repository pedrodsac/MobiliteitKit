import Foundation
import Testing
@testable import MobiliteitKit

struct RoutingPreventionFixture {
    let directory: URL
    let database: URL
    let router: TransitRouter
    init(files: [String: String], walking: (any WalkingRoutingProvider)? = nil,
         realtime: (any RealtimeRoutingProvider)? = nil, now: Date = date(hour: 8), clock: (@Sendable () -> Date)? = nil) async throws {
        directory = try temporaryDirectory(); database = directory.appendingPathComponent("transit.sqlite")
        let archive = directory.appendingPathComponent("fixture.zip")
        try writeArchive(to: archive, files: files)
        _ = try await GTFSArchiveInstaller.install(archiveAt: archive, databaseAt: database, generation: 7)
        router = try await TransitRouter(databaseURL: database, walkingProvider: walking,
            realtimeProvider: realtime, clock: clock ?? { now })
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func query(preferences: RoutingPreferences = .init(), origin: JourneyEndpoint = .stop(id: "a"),
               destination: JourneyEndpoint = .stop(id: "d"), anchor: Date = date(hour: 8),
               direction: RouteQueryDirection = .departAfter, live: Bool = false) -> RouteQuery {
        .init(origin: origin, destination: destination, departureTime: anchor, direction: direction,
            preferences: preferences, realtimePolicy: live ? .bestEffort() : .disabled)
    }
    func profile(_ query: RouteQuery? = nil) async throws -> JourneyPage {
        let session = try await router.makeSession(for: query ?? self.query())
        return try await session.boundedPage(count: 100)
    }
    func planning(_ request: JourneyPlanningRequest? = nil) async throws -> JourneyResultSession {
        try await JourneyResultSession(router: router, snapshot: router.snapshot, databaseURL: database,
            request: request ?? .init(origin: .stop(id: "a"), destination: .stop(id: "d"), time: .departAt(date(hour: 8))), now: date(hour: 8))
    }
}

func preventionFiles(trips: String, times: String) -> [String: String] {
    scenarioFiles(routes: "bus,operator,16,Bus,3\nother,operator,18,Other,3\n",
        stops: scenarioStops([("a", "A", 49.6), ("b", "B", 49.61), ("c", "C", 49.62), ("d", "D", 49.63)]),
        trips: trips, stopTimes: times)
}

struct PreventionRealtime: RealtimeRoutingProvider {
    let patches: [RealtimeTripPatch]
    func patches(for stopIDs: [String], from: Date, through: Date, refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        .init(patches: patches, requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}

struct PreventionWalking: WalkingRoutingProvider {
    struct Edge: Sendable { let from: Coordinate; let to: Coordinate; let seconds: Int; var meters: Double = 100 }
    let edges: [Edge]
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let value = try await route(request); return .init(durationSeconds: value.durationSeconds, distanceMeters: value.distanceMeters)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        guard let edge = edges.first(where: { $0.from == request.source && $0.to == request.destination }) else { throw JourneyPlanningError.noRouteFound }
        return .init(durationSeconds: edge.seconds, distanceMeters: edge.meters,
            polyline: [edge.from, edge.to])
    }
}
