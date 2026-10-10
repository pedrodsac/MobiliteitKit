import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct InitialArrivalSearchTests {
    @Test func recentSelectionMatchesTheFullLookbackWithoutScanningOlderDepartures() async throws {
        var trips = "route,service,older,Destination\n"
        var times = "older,00:30:00,00:30:00,a,1\nolder,09:10:00,09:10:00,c,2\n"
        for run in 0..<20 {
            let departure = String(format: "08:%02d:00", run * 2)
            let arrival = String(format: "09:%02d:00", run * 2)
            trips += "route,service,recent-\(run),Destination\n"
            times += "recent-\(run),\(departure),\(departure),a,1\nrecent-\(run),\(arrival),\(arrival),c,2\n"
        }
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips)
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let query = Self.query("10:00:00")
        let recent = try await router.makeSession(for: query).initialArrivals()
        let full = try await router.makeSession(for: query).expanded(count: 10)
        #expect(recent.journeys.map(\.id) == full.journeys.map(\.id))
        #expect(recent.metrics.pointRaptorScans == 1)
        #expect(recent.journeys.count == 10)
    }

    @Test func sparseServiceStillExploresTheFullDayAndRetainsALongRide() async throws {
        let fixture = try await RealtimeTestFixture(stopTimes:
            "trip,00:30:00,00:30:00,a,1\ntrip,04:00:00,04:00:00,b,2\ntrip,09:10:00,09:10:00,c,3\n")
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let recent = try await router.makeSession(for: Self.query("10:00:00")).initialArrivals()
        #expect(recent.journeys.first?.effectiveDeparture == RealtimeTestFixture.date("00:30:00"))
        #expect(recent.metrics.pointRaptorScans == 4)
    }

    @Test func anOlderFastServiceOutsideTheFirstWindowStillAffectsSuggestions() async throws {
        var trips = "route,service,older,Destination\n"
        var times = "older,07:59:00,07:59:00,a,1\nolder,08:04:00,08:04:00,c,2\n"
        for run in 0..<12 {
            let departure = String(format: "08:%02d:00", run)
            let arrival = String(format: "09:%02d:00", run)
            trips += "route,service,recent-\(run),Destination\n"
            times += "recent-\(run),\(departure),\(departure),a,1\nrecent-\(run),\(arrival),\(arrival),c,2\n"
        }
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips)
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let query = Self.query("11:00:00")
        let recent = try await router.makeSession(for: query).initialArrivals()
        let full = try await router.makeSession(for: query).expanded(count: 10)
        #expect(recent.journeys.map(\.id) == full.journeys.map(\.id))
        #expect(recent.journeys.contains { $0.firstRide?.tripID == "older" })
        #expect(recent.metrics.pointRaptorScans > 1)
    }

    @Test func anEarlierPickupOfTheSameVehiclePreventsStoppingTooSoon() async throws {
        var trips = "route,service,loop,Destination\n"
        var times = "loop,06:50:00,06:50:00,a,1\nloop,07:20:00,07:20:00,b,2\n"
            + "loop,08:50:00,08:50:00,a,3\nloop,09:10:00,09:10:00,c,4\n"
        for run in 0..<20 {
            let departure = String(format: "08:%02d:00", run * 2)
            let arrival = String(format: "09:%02d:00", run * 2)
            trips += "route,service,recent-\(run),Destination\n"
            times += "recent-\(run),\(departure),\(departure),a,1\nrecent-\(run),\(arrival),\(arrival),c,2\n"
        }
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips)
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let query = Self.query("10:00:00")
        let recent = try await router.makeSession(for: query).initialArrivals()
        let full = try await router.makeSession(for: query).expanded(count: 10)
        #expect(recent.journeys.map(\.id) == full.journeys.map(\.id))
        #expect(recent.journeys.contains { $0.firstRide?.tripID == "loop" })
        #expect(recent.metrics.pointRaptorScans > 1)
    }

    @Test func sixRecentArrivalsMatchTheFullProfileWithinNinetyMinutes() async throws {
        var trips = ""
        var times = ""
        for run in 0..<18 {
            let departure = String(format: "09:%02d:00", run * 2)
            let arrival = String(format: "09:%02d:00", run * 2 + 10)
            trips += "route,service,recent-\(run),Destination\n"
            times += "recent-\(run),\(departure),\(departure),a,1\nrecent-\(run),\(arrival),\(arrival),c,2\n"
        }
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips)
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let recent = try await router.makeSession(for: Self.query("10:00:00"))
            .initialSuggestions(count: 6, searchHorizon: 5400)
        let full = try await router.makeSession(for: Self.query("10:00:00")).expanded(count: 6)
        #expect(recent.journeys.map(\.id) == full.journeys.map(\.id))
        #expect(recent.journeys.count == 6)
        #expect(recent.diagnostics.searchPasses.map(\.horizonSeconds) == [5400])
    }

    private static func query(_ deadline: String) -> RouteQuery {
        .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
              departureTime: RealtimeTestFixture.date(deadline), direction: .arriveBy)
    }
}
