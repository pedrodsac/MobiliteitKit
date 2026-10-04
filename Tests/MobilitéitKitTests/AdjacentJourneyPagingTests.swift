import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Adjacent journey time windows")
struct AdjacentJourneyPagingTests {
    private func files(_ offsets: [Int], duration: Int = 1200) -> [String: String] {
        func time(_ value: Int) -> String { ServiceTime(rawValue: Int32(8 * 3600 + value)).gtfsString }
        return preventionFiles(trips: offsets.enumerated().map { "bus,service,run-\($0.offset),,,,\n" }.joined(),
            times: offsets.enumerated().map { index, offset in
                "run-\(index),\(time(offset)),\(time(offset)),a,1\nrun-\(index),\(time(offset + duration)),\(time(offset + duration)),d,2\n"
            }.joined())
    }

    private func request(_ time: JourneyPlanningTime = .departAt(date(hour: 8))) -> JourneyPlanningRequest {
        .init(origin: .stop(id: "a"), destination: .stop(id: "d"), time: time,
              pagingPolicy: .adjacentTimeWindows)
    }

    @Test(arguments: [JourneyRefreshPolicy.scheduleOnly, .useCache])
    func nowAndLeaveAtUseIdenticalResolvedInstant(refresh: JourneyRefreshPolicy) async throws {
        let patch = RealtimeTripPatch(tripID: "run-0", serviceDate: try GTFSDate(parsing: "20260904"), events: [
            .init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 7), departureSource: .reported,
                  stopSequence: 1, observedAt: date(hour: 8)),
            .init(stopID: "d", effectiveArrival: date(hour: 8, minute: 27), arrivalSource: .reported,
                  stopSequence: 2, observedAt: date(hour: 8))
        ])
        let fixture = try await RoutingPreventionFixture(files: files(Array(stride(from: 300, through: 3600, by: 300))),
            realtime: PreventionRealtime(patches: [patch]))
        defer { fixture.remove() }
        let immediate = try await fixture.planning(request(.now))
        let explicit = try await fixture.planning(request())
        let a = try await immediate.calculate(refresh: refresh, now: date(hour: 8))
        let b = try await explicit.calculate(refresh: refresh)
        #expect(a.journeys == b.journeys)
        #expect(a.recommendedJourneyID == b.recommendedJourneyID)
        #expect(a.validationContexts == b.validationContexts)
        if refresh == .useCache { #expect(a.journeys.contains { $0.effectiveDeparture == date(hour: 8, minute: 7) }) }
    }

    @Test func laterUsesNormalForwardSuggestionsAndKeepsEarlierResults() async throws {
        let fixture = try await RoutingPreventionFixture(files: files(Array(stride(from: 300, through: 5400, by: 300))))
        defer { fixture.remove() }
        let session = try await fixture.planning(request())
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let latest = try #require(initial.journeys.map(\.effectiveDeparture).max())
        // Timetable events use whole seconds, so this excludes the consumed
        // boundary vehicle exactly as the stable-ID adjacent search does.
        let normal = try await fixture.planning(request(.departAt(latest.addingTimeInterval(1))))
        let expected = try await normal.calculate(refresh: .scheduleOnly)
        let later = try await session.calculate(page: .later, refresh: .scheduleOnly)
        let priorIDs = Set(initial.journeys.map(\.id))
        let added = later.journeys.filter { !priorIDs.contains($0.id) }
        #expect(added.map(\.id) == expected.journeys.map(\.id))
        #expect(added.count == 5)
        #expect(priorIDs.isSubset(of: Set(later.journeys.map(\.id))))
        #expect(added.allSatisfy { $0.effectiveDeparture > latest })
    }

    @Test func earlierAddsNearestPastTimetableJourneys() async throws {
        let fixture = try await RoutingPreventionFixture(files: files([-7200, -1800, -1200, -600, 300, 600]))
        defer { fixture.remove() }
        let session = try await fixture.planning(request())
        _ = try await session.calculate(refresh: .scheduleOnly)
        let earlier = try await session.calculate(page: .earlier)
        let historical = earlier.journeys.filter { $0.effectiveDeparture < date(hour: 8) }
        #expect(historical.count == 4)
        #expect(historical.allSatisfy { $0.statusEvidence.status(at: date(hour: 8)) == .missed })
        #expect(historical.allSatisfy { $0.statusEvidence.coverage == .scheduleOnly })
        #expect(historical.allSatisfy { earlier.validationContexts[$0.id]!.anchor <= $0.effectiveDeparture })
    }

    @Test func arriveByPagesMoveArrivalWindowAndPreserveEveryDeadline() async throws {
        let fixture = try await RoutingPreventionFixture(files: files(Array(stride(from: -1800, through: 7200, by: 300))))
        defer { fixture.remove() }
        let deadline = date(hour: 8, minute: 40)
        let session = try await fixture.planning(request(.arriveBy(deadline)))
        let initial = try await session.calculate(refresh: .scheduleOnly)
        #expect(initial.journeys.allSatisfy { $0.effectiveArrival <= deadline })
        #expect(initial.journeys.first { $0.id == initial.recommendedJourneyID }?.effectiveDeparture == date(hour: 8, minute: 20))
        let later = try await session.calculate(page: .later, refresh: .scheduleOnly)
        #expect(later.journeys.contains { $0.effectiveArrival > deadline })
        #expect(later.browsingWindow?.axis == .arrival)
        for journey in later.journeys {
            let context = try #require(later.validationContexts[journey.id])
            #expect(!JourneyItineraryValidator.assess(journey, context: context).isInvalid)
            if initial.journeys.contains(where: { $0.id == journey.id }) { #expect(context.anchor == deadline) }
        }
        let earliest = try #require(later.journeys.map(\.effectiveArrival).min())
        let earlier = try await session.calculate(page: .earlier, refresh: .scheduleOnly)
        #expect(earlier.journeys.contains { $0.effectiveArrival < earliest })
        #expect(Set(later.journeys.map(\.id)).isSubset(of: Set(earlier.journeys.map(\.id))))
    }

    @Test func laterArrivalsCanDepartBeforeThePreviousArrivalBoundary() async throws {
        var data = files([0, 600], duration: 1200)
        data["stop_times.txt"] = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nrun-0,08:00:00,08:00:00,a,1\nrun-0,08:20:00,08:20:00,d,2\nrun-1,08:10:00,08:10:00,a,1\nrun-1,08:40:00,08:40:00,d,2\n"
        let fixture = try await RoutingPreventionFixture(files: data)
        defer { fixture.remove() }
        let session = try await fixture.planning(request(.arriveBy(date(hour: 8, minute: 20))))
        _ = try await session.calculate(refresh: .scheduleOnly)
        let later = try await session.calculate(page: .later, refresh: .scheduleOnly)
        #expect(later.journeys.contains { $0.firstRide?.tripID == "run-1" })
    }

    @Test func arriveByRecommendsLatestFeasibleDepartureEvenWhenEarlierVehicleIsFaster() async throws {
        var data = files([300, 900])
        data["stop_times.txt"] = "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nrun-0,08:05:00,08:05:00,a,1\nrun-0,08:20:00,08:20:00,d,2\nrun-1,08:15:00,08:15:00,a,1\nrun-1,08:40:00,08:40:00,d,2\n"
        let fixture = try await RoutingPreventionFixture(files: data)
        defer { fixture.remove() }
        let session = try await fixture.planning(request(.arriveBy(date(hour: 8, minute: 45))))
        let result = try await session.calculate(refresh: .scheduleOnly)
        let recommended = try #require(result.journeys.first { $0.id == result.recommendedJourneyID })
        #expect(recommended.firstRide?.tripID == "run-1")
    }

    @Test func sparseTimetableExpandsAcrossEmptyWindowsAndStops() async throws {
        let fixture = try await RoutingPreventionFixture(files: files([-7 * 3600, 300, 8 * 3600]))
        defer { fixture.remove() }
        let session = try await fixture.planning(request())
        let first = try await session.calculate(refresh: .scheduleOnly)
        #expect(first.journeys.count == 1)
        let later = try await session.calculate(page: .later, refresh: .scheduleOnly)
        #expect(later.journeys.contains { $0.effectiveDeparture == date(hour: 16) })
        #expect(later.hasLater) // A partial page does not establish exhaustion.
        let earlier = try await session.calculate(page: .earlier, refresh: .scheduleOnly)
        #expect(earlier.journeys.contains { $0.effectiveDeparture == date(hour: 1) })
        let empty = try await session.calculate(page: .later, refresh: .scheduleOnly)
        #expect(!empty.hasLater)
        #expect(empty.journeys.map(\.id) == earlier.journeys.map(\.id))
    }

    @Test func equalTimeBoundariesAndAlternatingPagesNeverDuplicate() async throws {
        // Identical times with distinct trip IDs exercise stable tie ordering.
        let fixture = try await RoutingPreventionFixture(files: files(Array(repeating: 300, count: 13)))
        defer { fixture.remove() }
        let session = try await fixture.planning(request())
        var previous = try await session.calculate(refresh: .scheduleOnly)
        for index in 0..<20 {
            let current = try await session.calculate(page: index.isMultiple(of: 2) ? .later : .earlier, refresh: .scheduleOnly)
            #expect(Set(previous.journeys.map(\.id)).isSubset(of: Set(current.journeys.map(\.id))))
            #expect(Set(current.journeys.map(\.id)).count == current.journeys.count)
            previous = current
        }
        #expect(previous.journeys.count == 13)
        #expect(!previous.hasEarlier && !previous.hasLater)
    }

    @Test func overnightServiceTimesRemainOnTheirActualServiceDate() async throws {
        let fixture = try await RoutingPreventionFixture(files: files([15 * 3600 + 50 * 60, 16 * 3600 + 10 * 60]))
        defer { fixture.remove() }
        let session = try await fixture.planning(request(.departAt(date(hour: 23, minute: 40))))
        let initial = try await session.calculate(refresh: .scheduleOnly)
        #expect(initial.journeys.count == 2)
        let last = try #require(initial.journeys.last)
        #expect(last.effectiveDeparture.timeIntervalSince(date(hour: 23, minute: 40)) == TimeInterval(1800))
        #expect(initial.journeys.allSatisfy { $0.firstRide?.instance?.serviceDate == (try? GTFSDate(parsing: "20260904")) })
    }

    @Test func coordinateEndpointsRespectAccessAndEgressAndPageRefinementDeadline() async throws {
        let origin = Coordinate(latitude: 49.5999, longitude: 6.1)
        let destination = Coordinate(latitude: 49.6301, longitude: 6.1)
        let walking = PreventionWalking(edges: [
            .init(from: origin, to: .init(latitude: 49.6, longitude: 6.1), seconds: 300),
            .init(from: .init(latitude: 49.63, longitude: 6.1), to: destination, seconds: 600)
        ])
        let fixture = try await RoutingPreventionFixture(files: files([600, 1200, 1800]), walking: walking)
        defer { fixture.remove() }
        var departureRequest = request()
        departureRequest.origin = .coordinate(origin, label: "Origin")
        departureRequest.destination = .coordinate(destination, label: "Destination")
        let departureSession = try await fixture.planning(departureRequest)
        let departures = try await departureSession.calculate(refresh: .scheduleOnly)
        #expect(departures.journeys.allSatisfy { $0.effectiveDeparture >= date(hour: 8) })
        #expect(departures.journeys.first?.effectiveDeparture == date(hour: 8, minute: 5))

        var arrivalRequest = departureRequest
        let deadline = date(hour: 8, minute: 45)
        arrivalRequest.time = .arriveBy(deadline)
        let session = try await fixture.planning(arrivalRequest)
        let initial = try await session.calculate(refresh: .scheduleOnly)
        #expect(initial.journeys.count == 1)
        #expect(initial.journeys.first?.effectiveArrival == date(hour: 8, minute: 40))
        let paged = try await session.calculate(page: .later, refresh: .scheduleOnly)
        let journey = try #require(paged.journeys.first { $0.firstRide?.tripID == "run-1" })
        let token = try #require(paged.refinementTokens[journey.id])
        let lastIndex = journey.legs.count - 1
        guard case let .walk(egress) = journey.legs[lastIndex] else {
            Issue.record("Expected an egress walk"); return
        }
        let corrected = try await session.submitWalkingRefinement(.init(token: token,
            range: lastIndex..<(lastIndex + 1),
            route: .init(durationSeconds: 900, distanceMeters: 100,
                         polyline: [egress.from.coordinate, egress.to.coordinate], evidence: .routedPedestrian),
            departure: egress.departure, arrival: egress.departure.addingTimeInterval(900)))
        let retained = try #require(corrected.journeys.first { $0.id == journey.id })
        #expect(retained.effectiveArrival > deadline)
        #expect(corrected.validationContexts[retained.id]?.anchor == paged.validationContexts[retained.id]?.anchor)
        #expect(!corrected.invalidatedIDs.contains(retained.id))
    }

    @Test func historicalPagesRetainFreshnessEvidenceForExistingLiveJourneys() async throws {
        let clock = AdjacentPagingClock()
        let patch = RealtimeTripPatch(tripID: "run-2", serviceDate: try GTFSDate(parsing: "20260904"), events: [
            .init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 7), departureSource: .reported,
                  stopSequence: 1, observedAt: date(hour: 8))
        ])
        let fixture = try await RoutingPreventionFixture(files: files([-1800, -1200, 300, 600]),
            realtime: PreventionRealtime(patches: [patch]), clock: { clock.read() })
        defer { fixture.remove() }
        let session = try await fixture.planning(request())
        let initial = try await session.calculate()
        let live = try #require(initial.journeys.first { $0.firstRide?.tripID == "run-2" })
        _ = try await session.calculate(page: .earlier)
        // The second earlier search is wholly historical and acquires no patches.
        _ = try await session.calculate(page: .earlier)
        clock.advance(121)
        let result = await session.result()
        #expect(result.invalidatedIDs.contains(live.id))
        #expect(!result.journeys.contains { $0.id == live.id })
    }
}

private final class AdjacentPagingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = date(hour: 8)
    func read() -> Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}
