import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Routing prevention: stable sessions and pagination")
struct RoutingPreventionLifecycleTests {
    func files() -> [String: String] {
        let offsets = [-1200, -600, 0, 300, 600, 900, 1200, 1500, 1800, 2100, 2400, 2700, 3000]
        func time(_ offset: Int) -> String { ServiceTime(rawValue: Int32(8 * 3600 + offset)).gtfsString }
        return preventionFiles(trips: offsets.enumerated().map { "bus,service,run-\($0.offset),,,,\n" }.joined(),
            times: offsets.enumerated().map { index, offset in
                "run-\(index),\(time(offset)),\(time(offset)),a,1\nrun-\(index),\(time(offset + 1200)),\(time(offset + 1200)),d,2\n"
            }.joined())
    }

    // 09, 49: accumulated snapshots, alternating pages and equal-time cursor ordering.
    @Test func twentyAlternatingPagesMakeStrictProgressWithoutDuplicates() async throws {
        let fixture = try await RoutingPreventionFixture(files: files()); defer { fixture.remove() }
        let session = try await fixture.planning()
        var previous = try await session.calculate(refresh: .scheduleOnly)
        for index in 0..<20 {
            let current = try await session.calculate(page: index.isMultiple(of: 2) ? .earlier : .later, refresh: .scheduleOnly)
            #expect(Set(current.journeys.map(\.id)).count == current.journeys.count)
            #expect(Set(previous.journeys.map(\.id)).isSubset(of: Set(current.journeys.map(\.id))))
            #expect(current.revision > previous.revision)
            previous = current
        }
        #expect(previous.journeys.count == 13)
        #expect(!previous.hasEarlier && !previous.hasLater)
    }

    @Test func equalDepartureBoundariesBackfillNoncontiguousInitialSelection() async throws {
        var trips = ""; var times = ""
        for index in 0..<12 {
            trips += "bus,service,run-\(index),,,,\n"
            let arrival = ServiceTime(rawValue: Int32(8 * 3600 + 1200 + index * 60)).gtfsString
            times += "run-\(index),08:05:00,08:05:00,a,1\nrun-\(index),\(arrival),\(arrival),d,2\n"
        }
        // Different accessibility evidence protects tradeoffs from exact dominance.
        var files = preventionFiles(trips: trips, times: times)
        files["trips.txt"] = "route_id,service_id,trip_id,trip_headsign,trip_short_name,direction_id,block_id,wheelchair_accessible\n" + trips.split(separator: "\n").enumerated().map { "\($0.element),\($0.offset % 3)\n" }.joined()
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let session = try await fixture.router.makeSession(for: fixture.query())
        let initial = try await session.initial(count: 2)
        var ids = Set(initial.journeys.map(\.id))
        var cursor = try #require(initial.exploredAfter)
        for _ in 0..<10 {
            let page = try await session.boundedPage(after: cursor.departure, afterID: cursor.id, count: 1, excludingIDs: ids)
            for journey in page.journeys {
                #expect(journey.effectiveDeparture > cursor.departure || journey.effectiveDeparture == cursor.departure && journey.id > (cursor.id ?? .init("")))
                #expect(ids.insert(journey.id).inserted)
            }
            if let boundary = page.exploredAfter { cursor = boundary }
            if !page.hasLater { break }
        }
        let full = try await session.boundedPage(count: 100)
        #expect(ids == Set(full.journeys.map(\.id)))
    }

    // 15, 43, 49: every arrive-by page retains its original deadline.
    @Test func arriveByPagingRetainsDeadline() async throws {
        let fixture = try await RoutingPreventionFixture(files: files()); defer { fixture.remove() }
        let deadline = date(hour: 8, minute: 45)
        let session = try await fixture.planning(.init(origin: .stop(id: "a"), destination: .stop(id: "d"), time: .arriveBy(deadline)))
        var result = try await session.calculate(refresh: .scheduleOnly)
        for _ in 0..<8 {
            result = try await session.calculate(page: .earlier, refresh: .scheduleOnly)
            #expect(result.journeys.allSatisfy { $0.effectiveArrival <= deadline })
        }
        #expect(result.journeys.map(\.effectiveDeparture).max() == date(hour: 8, minute: 25))
    }

    // 33, 44, 48: noise retains the recommendation and IDs; a real cancellation switches immediately.
    @Test func refreshHysteresisAndCancellation() async throws {
        let files = preventionFiles(trips: "bus,service,primary,,,,\nother,service,backup,,,,\n",
            times: "primary,08:07:00,08:07:00,a,1\nprimary,08:25:00,08:25:00,d,2\nbackup,08:06:00,08:06:00,a,1\nbackup,08:25:30,08:25:30,d,2\n")
        let realtime = PreventionMutableRealtime()
        let fixture = try await RoutingPreventionFixture(files: files, realtime: realtime); defer { fixture.remove() }
        let session = try await fixture.planning()
        let initial = try await session.calculate(refresh: .forceRefresh)
        let oldCursor = try #require(initial.laterCursor)
        let recommended = try #require(initial.recommendedJourneyID)
        await realtime.set(delay: 40)
        let noisy = try await session.refreshRealtime(now: date(hour: 8))
        await #expect(throws: JourneyPlanningError.stalePage) { try await session.calculate(after: oldCursor) }
        #expect(noisy.recommendedJourneyID == recommended)
        #expect(noisy.journeys.contains { $0.id == recommended })
        #expect(noisy.refinementTokens[recommended]?.generation != initial.refinementTokens[recommended]?.generation)
        await realtime.set(cancelled: true)
        let cancelled = try await session.refreshRealtime(now: date(hour: 8))
        #expect(cancelled.recommendedJourneyID != recommended)
        #expect(!cancelled.journeys.contains { $0.id == recommended })
        await realtime.set(cancelled: false)
        for page: JourneyPlanningPage in [.later, .earlier, .later] {
            let cached = try await session.calculate(page: page, refresh: .useCache)
            #expect(!cached.journeys.contains { $0.id == recommended })
        }
    }

    @Test func expiredFrozenEvidenceCannotSurviveSnapshotOrPaging() async throws {
        let files = preventionFiles(trips: "bus,service,primary,,,,\nother,service,backup,,,,\n", times: "primary,08:07:00,08:07:00,a,1\nprimary,08:25:00,08:25:00,d,2\nbackup,08:09:00,08:09:00,a,1\nbackup,08:27:00,08:27:00,d,2\n")
        let clock = PreventionClock()
        let fixture = try await RoutingPreventionFixture(files: files, realtime: PreventionMutableRealtime(), clock: { clock.read() }); defer { fixture.remove() }
        let session = try await fixture.planning()
        let initial = try await session.calculate(refresh: .forceRefresh)
        let primary = try #require(initial.journeys.first { $0.firstRide?.tripID == "primary" })
        clock.advance(120)
        #expect(await session.result().journeys.contains { $0.id == primary.id })
        clock.advance(1)
        let expired = await session.result()
        #expect(!expired.journeys.contains { $0.id == primary.id })
        #expect(expired.invalidatedIDs.contains(primary.id))
        #expect(expired.feasibility[primary.id] == .invalid(.contradictoryRealtime))
        #expect(expired.journeys.contains { $0.firstRide?.tripID == "backup" })
        let paged = try await session.calculate(page: .later)
        #expect(!paged.journeys.contains { $0.id == primary.id })
        #expect(paged.invalidatedIDs.contains(primary.id))
    }

    @Test func shiftedAnchorRetainsStillCatchableInstances() async throws {
        let fixture = try await RoutingPreventionFixture(files: files()); defer { fixture.remove() }
        let first = try await fixture.profile(fixture.query(anchor: date(hour: 8).addingTimeInterval(1)))
        let shifted = try await fixture.profile(fixture.query(anchor: date(hour: 8).addingTimeInterval(61)))
        #expect(first.journeys.map(\.id) == shifted.journeys.map(\.id))
    }
}

actor PreventionMutableRealtime: RealtimeRoutingProvider {
    var delay = 0
    var cancelled = false
    func set(delay: Int = 0, cancelled: Bool = false) { self.delay = delay; self.cancelled = cancelled }
    func patches(for stopIDs: [String], from: Date, through: Date, refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        let events = [RealtimeStopEventPatch(stopID: "a", effectiveDeparture: date(hour: 8, minute: 7).addingTimeInterval(Double(delay)), departureSource: .reported, stopSequence: 1, observedAt: date(hour: 8)),
            RealtimeStopEventPatch(stopID: "d", effectiveArrival: date(hour: 8, minute: 25).addingTimeInterval(Double(delay)), arrivalSource: .reported, stopSequence: 2, observedAt: date(hour: 8))]
        return .init(patches: [.init(tripID: "primary", serviceDate: try GTFSDate(parsing: "20260904"), status: cancelled ? .cancelled : .active, events: events)], requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}

private final class PreventionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = date(hour: 8)
    func read() -> Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}
