import Foundation
import Testing
import ZIPFoundation
@testable import MobiliteitKit

@Suite("Public journey planner")
struct JourneyPlannerTests {
    @Test func missingFeedIsTypedAndRecoverable() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: JourneyPlannerError.noInstalledFeed) {
            try await JourneyPlanner().router(for: url)
        }
    }

    @Test func initialPagingAndEmptyPages() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let planner = JourneyPlanner()
        let router = try await planner.router(for: fixture.database)
        #expect(router === (try await planner.router(for: fixture.database)))
        let session = try await planner.makePlanningSession(databaseURL: fixture.database,
            request: fixture.request, now: fixture.anchor)
        let initial = try await session.calculate(refresh: .scheduleOnly)
        #expect(initial.journeys.count == 5)
        #expect(initial.recommendedJourneyID == initial.journeys.first?.id)
        #expect(initial.journeys.allSatisfy { $0.statusEvidence.coverage == .scheduleOnly })
        let later = try await session.calculate(page: .later, refresh: .scheduleOnly)
        #expect(later.journeys.count == 6)
        #expect(!later.hasLater)
        let empty = try await session.calculate(page: .later, refresh: .scheduleOnly)
        #expect(empty.journeys.map(\.id) == later.journeys.map(\.id))
        #expect(!empty.hasLater)
        let updated = try await session.updatePreferences(.init(preferredMode: nil, avoidTightTransfers: true))
        #expect(updated.validationContext.minimumTransferSeconds == 180)
        #expect(updated.validationContext.sameStopTransferShortfallSeconds == 0)
        #expect(updated.refinementTokens.values.first?.generation != initial.refinementTokens.values.first?.generation)
    }

    @Test func earlierJourneysAreNotRejectedByOriginalAnchor() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        var request = fixture.request
        request.time = .departAt(fixture.anchor.addingTimeInterval(12 * 60))
        let session = try await JourneyPlanner().makePlanningSession(databaseURL: fixture.database, request: request)
        let first = try await session.calculate(refresh: .scheduleOnly)
        let earlier = try await session.calculate(page: .earlier, refresh: .scheduleOnly)
        #expect(earlier.journeys.count > first.journeys.count)
        #expect(earlier.journeys.contains { $0.effectiveDeparture < fixture.anchor.addingTimeInterval(12 * 60) })
    }

    @Test func geometryIsClippedAndMissingShapesFallBack() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let session = try await JourneyPlanner().makePlanningSession(databaseURL: fixture.database,
            request: fixture.request)
        let result = try await session.calculate(refresh: .scheduleOnly)
        let ride = try #require(result.journeys.first?.legs.compactMap {
            if case let .transit(t) = $0 { t } else { nil }
        }.first)
        #expect(ride.polyline.count == 3)
        #expect(ride.polyline.first == ride.board.stop.coordinate)
        #expect(ride.polyline.last == ride.alight.stop.coordinate)
        let fallback = JourneyGeometry.segment(of: [], from: ride.board.stop.coordinate,
                                                to: ride.alight.stop.coordinate)
        #expect(fallback.count == 2)
        let loop = [ride.board.stop.coordinate, Coordinate(latitude: 49.605, longitude: 6.11),
                    ride.alight.stop.coordinate, ride.board.stop.coordinate]
        #expect(JourneyGeometry.segment(of: loop, from: ride.board.stop.coordinate,
                                        to: ride.alight.stop.coordinate).count == 3)
    }

    @Test func frequencyGeometryUsesBaseTripShape() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let session = try await JourneyPlanner().makePlanningSession(databaseURL: fixture.database, request: fixture.request)
        let result = try await session.calculate(refresh: .scheduleOnly)
        let journey = try #require(result.journeys.first)
        guard case let .transit(t) = journey.legs[0] else { return }
        let frequency = TransitLeg(tripID: t.tripID + "#frequency-480", route: t.route,
            headsign: t.headsign, board: t.board, alight: t.alight, intermediateStops: t.intermediateStops,
            scheduledDeparture: t.scheduledDeparture, scheduledArrival: t.scheduledArrival,
            effectiveDeparture: t.effectiveDeparture, effectiveArrival: t.effectiveArrival,
            status: t.status, requiredTransferSecondsAfterWalking: t.requiredTransferSecondsAfterWalking)
        let enriched = await JourneyGeometry.enrich([journey.replacing(legs: [.transit(frequency)])],
                                                    store: try GTFSStore(databaseAt: fixture.database))
        guard case let .transit(ride)? = enriched.first?.legs.first else { return }
        #expect(ride.polyline.count == 3)
    }

    @Test func summariesPreserveContinuationTransferSemantics() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let session = try await JourneyPlanner().makePlanningSession(databaseURL: fixture.database, request: fixture.request)
        let result = try await session.calculate(refresh: .scheduleOnly)
        let journey = try #require(result.journeys.first)
        guard case let .transit(t) = journey.legs[0] else { return }
        let continuation = JourneyLeg.inSeatContinuation(.init(fromTripID: t.tripID, toTripID: "continued"))
        let continued = journey.replacing(legs: [journey.legs[0], continuation, journey.legs[0]])
        #expect(continued.summary.transferCount == 0)
        #expect(continued.summary.transferGaps.isEmpty)
        #expect(continued.summary.firstBoarding == t.effectiveDeparture)
        #expect(continued.statusEvidence.tightTransfer == false)
    }

    @Test func invalidRefinementCannotReplaceTransit() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let session = try await JourneyPlanner().makePlanningSession(databaseURL: fixture.database, request: fixture.request)
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let journey = try #require(initial.journeys.first)
        let token = try #require(initial.refinementTokens[journey.id])
        let update = JourneyWalkingRefinement(token: token, range: 0..<1,
            route: .init(durationSeconds: 60, distanceMeters: 60),
            departure: fixture.anchor, arrival: fixture.anchor.addingTimeInterval(60))
        await #expect(throws: JourneyPlanningError.invalidRefinement) {
            try await session.submitWalkingRefinement(update)
        }
        let untouched = await session.result()
        #expect(untouched.journeys == initial.journeys)
    }

    @Test func independentRefinementsAndStaleTokens() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let planner = JourneyPlanner(walkingProvider: PlannerWalking())
        var request = fixture.request
        request.origin = .coordinate(.init(latitude: 49.5999, longitude: 6.1), label: nil)
        request.destination = .coordinate(.init(latitude: 49.6101, longitude: 6.1), label: nil)
        let session = try await planner.makePlanningSession(databaseURL: fixture.database, request: request)
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let journey = try #require(initial.journeys.first { $0.transferCount == 0 && $0.legs.count >= 3 })
        let token = try #require(initial.refinementTokens[journey.id])
        let accessIndex = try #require(journey.legs.firstIndex { if case .walk = $0 { true } else { false } })
        let egressIndex = try #require(journey.legs.lastIndex { if case .walk = $0 { true } else { false } })
        guard case let .walk(access) = journey.legs[accessIndex],
              case let .walk(egress) = journey.legs[egressIndex] else { return }
        let accessUpdate = JourneyWalkingRefinement(token: token, range: accessIndex..<(accessIndex + 1),
            route: .init(durationSeconds: 90, distanceMeters: 90, polyline: [access.from.coordinate, access.to.coordinate]),
            departure: access.arrival.addingTimeInterval(-90), arrival: access.arrival)
        _ = try await session.submitWalkingRefinement(accessUpdate)
        let egressUpdate = JourneyWalkingRefinement(token: token, range: egressIndex..<(egressIndex + 1),
            route: .init(durationSeconds: 120, distanceMeters: 120, polyline: [egress.from.coordinate, egress.to.coordinate]),
            departure: egress.departure, arrival: egress.departure.addingTimeInterval(120))
        let updated = try await session.submitWalkingRefinement(egressUpdate)
        let refined = try #require(updated.journeys.first { $0.id == journey.id })
        #expect(refined.walkingDuration == 210)
        #expect(refined.walkingDistance == 210)
        #expect(refined.transitFingerprint == journey.transitFingerprint)
        _ = try await session.refreshRealtime(now: fixture.anchor)
        await #expect(throws: JourneyPlanningError.staleRefinement) {
            try await session.submitWalkingRefinement(accessUpdate)
        }
    }

    @Test func correctedAccessInvalidatesAndReplansOnlyOnce() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        var request = fixture.request
        request.origin = .coordinate(.init(latitude: 49.5999, longitude: 6.1), label: nil)
        let session = try await JourneyPlanner(walkingProvider: PlannerWalking()).makePlanningSession(
            databaseURL: fixture.database, request: request)
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let journey = try #require(initial.journeys.first)
        let token = try #require(initial.refinementTokens[journey.id])
        guard case let .walk(walk) = journey.legs[0] else { return }
        let duration = Int(walk.arrival.timeIntervalSince(fixture.anchor)) + 600
        let update = JourneyWalkingRefinement(token: token, range: 0..<1,
            route: .init(durationSeconds: duration, distanceMeters: 800),
            departure: walk.arrival.addingTimeInterval(-Double(duration)), arrival: walk.arrival)
        let result = try await session.submitWalkingRefinement(update)
        #expect(result.invalidatedIDs.contains(journey.id))
        #expect(!result.journeys.contains { $0.id == journey.id })
        #expect(await session.replacementSearchCount == 1)
        #expect(result.journeys.allSatisfy { $0.effectiveDeparture >= fixture.anchor })
        #expect(!result.journeys.isEmpty)
        #expect(result.journeys.contains { $0.walkingDuration == Double(duration) })
        let next = try #require(result.journeys.first { $0.walkingDuration == Double(duration) })
        let nextToken = try #require(result.refinementTokens[next.id])
        guard case let .walk(nextWalk) = next.legs[0] else { return }
        let nextDuration = Int(nextWalk.arrival.timeIntervalSince(fixture.anchor)) + 600
        let second = try await session.submitWalkingRefinement(.init(token: nextToken, range: 0..<1,
            route: .init(durationSeconds: nextDuration, distanceMeters: 1_000),
            departure: nextWalk.arrival.addingTimeInterval(-Double(nextDuration)), arrival: nextWalk.arrival))
        #expect(second.invalidatedIDs.contains(next.id))
        #expect(!second.journeys.contains { $0.id == next.id })
        #expect(await session.replacementSearchCount == 1)
        await #expect(throws: JourneyPlanningError.staleRefinement) {
            try await session.submitWalkingRefinement(update)
        }
        #expect(await session.replacementSearchCount == 1)
    }

    @Test func cancellationsAndUnavailableRealtime() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let cancelledPlanner = JourneyPlanner(realtimeProvider: PlannerRealtime(unavailable: false))
        let session = try await cancelledPlanner.makePlanningSession(databaseURL: fixture.database, request: fixture.request)
        let result = try await session.calculate(refresh: .forceRefresh)
        #expect(result.journeys.allSatisfy { !$0.hasCancelledTransitLeg })
        #expect(result.journeys.allSatisfy { journey in
            !journey.legs.contains { if case let .transit(t) = $0 { t.tripID == "run-1" } else { false } }
        })
        let unavailable = try await JourneyPlanner(realtimeProvider: PlannerRealtime(unavailable: true))
            .makePlanningSession(databaseURL: fixture.database, request: fixture.request)
        let scheduled = try await unavailable.calculate(refresh: .forceRefresh)
        #expect(scheduled.journeys.count == 5)
        #expect(scheduled.journeys.allSatisfy { $0.statusEvidence.coverage == .scheduleOnly })
    }

    @Test func delayedRealtimeTravelsThroughFacade() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        let session = try await JourneyPlanner(realtimeProvider: PlannerDelay(anchor: fixture.anchor))
            .makePlanningSession(databaseURL: fixture.database, request: fixture.request)
        let result = try await session.calculate(refresh: .forceRefresh)
        let delayed = try #require(result.journeys.first { journey in
            journey.legs.contains { if case let .transit(t) = $0 { t.tripID == "run-1" } else { false } }
        })
        #expect(delayed.effectiveDeparture == fixture.anchor.addingTimeInterval(7 * 60))
        #expect(delayed.statusEvidence.coverage == .live)
        #expect(delayed.statusEvidence.status(at: fixture.anchor) == .delayed)
        #expect(delayed.statusEvidence.status(at: fixture.anchor.addingTimeInterval(10 * 60)) == .missed)
    }

    @Test func directWalkRemainsAnInitialComparison() async throws {
        let fixture = try await PlannerFixture()
        defer { fixture.remove() }
        var request = fixture.request
        request.origin = .coordinate(.init(latitude: 49.5999, longitude: 6.1), label: nil)
        request.destination = .coordinate(.init(latitude: 49.6101, longitude: 6.1), label: nil)
        let session = try await JourneyPlanner(walkingProvider: PlannerWalking(longWalkDuration: 2_000))
            .makePlanningSession(databaseURL: fixture.database, request: request)
        let result = try await session.calculate(refresh: .scheduleOnly)
        #expect(result.journeys.contains { $0.id.value.hasPrefix("walk:") })
        #expect(result.journeys.filter { !$0.id.value.hasPrefix("walk:") }.count == 5)
        #expect(result.recommendedJourneyID?.value.hasPrefix("walk:") == false)
    }

    @Test func realtimeWindowsAndTransferConfiguration() {
        guard case let .bestEffort(initial, _) = JourneyPlanningPage.initial.realtimePolicy(.forceRefresh),
              case let .bestEffort(later, _) = JourneyPlanningPage.later.realtimePolicy(.useCache) else { return }
        #expect(initial.scheduledLookbackSeconds == 1_200)
        #expect(later.scheduledLookbackSeconds == 600)
        #expect(RoutingPreferences(preferredMode: nil, avoidTightTransfers: false).sameStopTransferShortfallSeconds == 180)
        #expect(JourneyPlanningPage.initial.realtimePolicy(.scheduleOnly) == .disabled)
    }
}

private struct PlannerFixture {
    let directory: URL
    var database: URL { directory.appendingPathComponent("transit.sqlite") }
    let anchor = ISO8601DateFormatter().date(from: "2026-09-04T06:00:00Z")!
    var request: JourneyPlanningRequest {
        .init(origin: .stop(id: "origin"), destination: .stop(id: "destination"), time: .departAt(anchor))
    }
    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("fixture.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let files = [
            "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\noperator,Operator,https://example.com,Europe/Berlin\n",
            "calendar_dates.txt": "service_id,date,exception_type\nservice,20260904,1\n",
            "routes.txt": "route_id,agency_id,route_short_name,route_long_name,route_type\nbus,operator,10,Bus,3\n",
            "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\norigin,Origin,49.6,6.1\ndestination,Destination,49.61,6.1\n",
            "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\nshape,49.6,6.1,1\nshape,49.605,6.11,2\nshape,49.61,6.1,3\n",
            "trips.txt": "route_id,service_id,trip_id,shape_id\n" + (1...6).map { "bus,service,run-\($0),shape\n" }.joined(),
            "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" + (1...6).map {
                let departure = String(format: "08:%02d:00", $0 * 5)
                let arrival = String(format: "08:%02d:00", $0 * 5 + 20)
                return "run-\($0),\(departure),\(departure),origin,1\nrun-\($0),\(arrival),\(arrival),destination,2\n"
            }.joined()
        ]
        for (path, content) in files {
            let data = Data(content.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: .deflate) { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                }
        }
        _ = try await GTFSArchiveInstaller.install(archiveAt: archiveURL, databaseAt: database)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct PlannerWalking: WalkingRoutingProvider {
    var longWalkDuration: Int? = nil
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        .init(durationSeconds: 60, distanceMeters: 60)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        // Do not allow access across the entire route, which would hide all transit results.
        guard abs(request.source.latitude - request.destination.latitude) < 0.002 else {
            if let longWalkDuration {
                return .init(durationSeconds: longWalkDuration, distanceMeters: 2_000,
                             polyline: [request.source, request.destination])
            }
            throw JourneyPlanningError.noRouteFound
        }
        return .init(durationSeconds: 60, distanceMeters: 60,
                     polyline: [request.source, request.destination])
    }
}

private struct PlannerRealtime: RealtimeRoutingProvider {
    let unavailable: Bool
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        if unavailable { throw JourneyPlanningError.noRouteFound }
        return .init(patches: [.init(tripID: "run-1", serviceDate: try GTFSDate(parsing: "20260904"),
                                    status: .cancelled, events: [])],
                     requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}

private struct PlannerDelay: RealtimeRoutingProvider {
    let anchor: Date
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        .init(patches: [.init(tripID: "run-1", serviceDate: try GTFSDate(parsing: "20260904"), events: [
            .init(stopID: "origin", effectiveDeparture: anchor.addingTimeInterval(7 * 60), departureSource: .reported),
            .init(stopID: "destination", effectiveArrival: anchor.addingTimeInterval(27 * 60), arrivalSource: .reported)
        ])], requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}
