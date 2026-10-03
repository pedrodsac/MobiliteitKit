import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimePagingUpdateTests {
    @Test func mixedAgeTripKeepsFreshOccurrenceAndDowngradesExpiredTiming() throws {
        let now = Date.now
        let scheduled = RealtimeTestFixture.date("08:00:00")
        let patch = RealtimeTripPatch(tripID: "trip", serviceDate: try GTFSDate(parsing: "20260930"), events: [
            .init(stopID: "a", scheduledDeparture: scheduled, effectiveDeparture: scheduled.addingTimeInterval(60),
                  departureSource: .reported, scheduledArrival: scheduled, effectiveArrival: scheduled.addingTimeInterval(30),
                  arrivalSource: .reported, stopSequence: 1, observedAt: now,
                  departureObservedAt: now, arrivalObservedAt: now.addingTimeInterval(-61))
        ])
        let event = try #require(patch.retainingFreshObservations(at: now).events.first)
        #expect(event.departureSource == .reported && event.departureObservedAt == now)
        #expect(event.arrivalSource == .scheduled && event.effectiveArrival == scheduled)
    }

    @Test(arguments: [false, true])
    func newPageRevalidatesAccumulatedResults(cancelled: Bool) async throws {
        var times = ""
        var trips = ""
        for index in 0..<7 {
            let minute = index == 6 ? 0 : index * 10
            let hour = index == 6 ? 12 : 8
            let departure = String(format: "%02d:%02d:00", hour, minute)
            let arrival = String(format: "%02d:%02d:00", hour, minute + 5)
            times += "run-\(index),\(departure),\(departure),a,1\n"
            if index == 0 { times += "run-0,08:02:00,08:02:00,b,2\n" }
            times += "run-\(index),\(arrival),\(arrival),c,3\n"
            trips += "route,service,run-\(index),Destination\n"
        }
        let fixture = try await RealtimeTestFixture(stopTimes: times, trips: trips)
        defer { fixture.remove() }
        let provider = PagingUpdates()
        let planner = JourneyPlanner(realtimeProvider: provider)
        let session = try await planner.makePlanningSession(databaseURL: fixture.database,
            request: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
                time: .departAt(RealtimeTestFixture.date("08:00:00"))))
        let first = try await session.calculate()
        let original = try #require(first.journeys.first { $0.effectiveDeparture == RealtimeTestFixture.date("08:00:00") })
        await provider.revise(cancelled: cancelled)
        let page = try await session.calculate(page: .later)
        #expect(page.laterCursor?.generation == first.laterCursor?.generation)
        #expect(page.journeys.contains { $0.effectiveDeparture == RealtimeTestFixture.date("12:00:00") })
        if cancelled {
            #expect(page.invalidatedIDs.contains(original.id))
            #expect(!page.journeys.contains { $0.id == original.id })
        } else {
            // The delay makes run-0 dominated by run-1, so the accumulated
            // result is re-ranked rather than kept as the old recommendation.
            #expect(!page.journeys.contains { $0.id == original.id })
            #expect(page.recommendedJourneyID != original.id)
            let batch = try await provider.patches(for: ["a"], from: RealtimeTestFixture.date("08:00:00"),
                through: RealtimeTestFixture.date("13:00:00"), refreshPolicy: .useCache)
            let updates = Dictionary(uniqueKeysWithValues: batch.patches.map {
                (RealtimePatchKey(tripID: $0.tripID, serviceDate: $0.serviceDate), $0)
            })
            let revised = try #require(original.applyingRealtime(updates))
            #expect(revised.effectiveArrival == RealtimeTestFixture.date("08:18:00"))
            let ride = try #require(revised.legs.compactMap { leg -> TransitLeg? in
                if case let .transit(ride) = leg { ride } else { nil }
            }.first)
            #expect(ride.intermediateStops.first?.effectiveTime == RealtimeTestFixture.date("08:16:00"))
        }
    }
}

private actor PagingUpdates: RealtimeRoutingProvider {
    var revised = false
    var cancelled = false
    let observed = Date.now
    func revise(cancelled: Bool) { revised = true; self.cancelled = cancelled }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        let indices = revised ? [0, 6] : Array(0..<6)
        let day = try GTFSDate(parsing: "20260930")
        let values = indices.map { index in
            let departure = RealtimeTestFixture.date(index == 6 ? "12:00:00" : String(format: "08:%02d:00", index * 10))
            let arrival = departure.addingTimeInterval(300)
            let effective = revised && index == 0 ? RealtimeTestFixture.date("08:18:00") : arrival
            let stamp = observed.addingTimeInterval(revised ? 1 : 0)
            return RealtimeTripPatch(tripID: "run-\(index)", serviceDate: day,
                status: revised && cancelled && index == 0 ? .cancelled : .active, events: [
                    .init(stopID: "a", scheduledDeparture: departure, effectiveDeparture: departure,
                          departureSource: .reported, stopSequence: 1, observedAt: stamp),
                    .init(stopID: "c", scheduledArrival: arrival, effectiveArrival: effective,
                          arrivalSource: .reported, stopSequence: 3, observedAt: stamp)
                ])
        }
        let completed = values.map { patch in
            guard patch.tripID == "run-0" else { return patch }
            let scheduled = RealtimeTestFixture.date("08:02:00")
            let middle = RealtimeStopEventPatch(stopID: "b", scheduledArrival: scheduled,
                effectiveArrival: revised ? RealtimeTestFixture.date("08:16:00") : scheduled,
                arrivalSource: .reported, stopSequence: 2, observedAt: observed.addingTimeInterval(revised ? 1 : 0))
            return RealtimeTripPatch(tripID: patch.tripID, serviceDate: patch.serviceDate, status: patch.status,
                                     events: [patch.events[0], middle, patch.events[1]])
        }
        return .init(patches: completed, requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs), fetchedAt: observed)
    }
}
