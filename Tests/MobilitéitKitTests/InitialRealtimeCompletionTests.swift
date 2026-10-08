import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct InitialRealtimeCompletionTests {
    @Test func newlySelectedThirdVehicleIsCheckedWhenTheCPUAllowanceIsSpent() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\n"
                + "connection,08:08:00,08:08:00,b,1\nconnection,08:23:00,08:23:00,c,2\n"
                + "third,08:35:00,08:35:00,c,1\nthird,08:45:00,08:45:00,d,2\n"
                + "fallback,08:20:00,08:20:00,b,1\nfallback,08:50:00,08:50:00,d,2\n",
            trips: "route,service,first,Transfer\nconnecting,service,connection,Destination\n"
                + "last,service,third,Final\nslow,service,fallback,Final\n",
            additionalStops: "d,Final,49.75,6.25\n",
            additionalRoutes: "connecting,operator,202,Connection,3\nlast,operator,204,Last,3\nslow,operator,203,Fallback,3\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "id" }?.value
            switch stop {
            case "a": return Self.board("201", "first", "a", "b", "08:00:00", "08:10:00", "08:01:00", "08:11:00")
            case "b":
                let connection = Self.board("202", "connection", "b", "c", "08:08:00", "08:23:00", "08:14:00", "08:29:00")
                let fallback = Self.board("203", "fallback", "b", "d", "08:20:00", "08:50:00", "08:20:00", "08:50:00")
                let prefix = "{\"Departure\":["
                return prefix + String(connection.dropFirst(prefix.count).dropLast(2)) + ","
                    + String(fallback.dropFirst(prefix.count).dropLast(2)) + "]}"
            case "c": return Self.board("204", "third", "c", "d", "08:35:00", "08:45:00", "08:37:00", "08:47:00")
            default: return #"{"Departure":[]}"#
            }
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let hafas = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let provider = FirstBatchWithoutThirdStop(hafas: hafas)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "d"),
            departureTime: RealtimeTestFixture.date("07:55:00"), preferences: .init(maxTransfers: 2),
            realtimePolicy: .bestEffort(configuration: .init(acquisitionBudgetMilliseconds: 2_500,
                searchWorkBudgetMilliseconds: 1)))).initial(count: 10, searchHorizon: 10_800)
        let journey = try #require(page.journeys.first { journey in
            journey.legs.compactMap { if case let .transit(ride) = $0 { ride.tripID } else { nil } }
                == ["first", "connection", "third"]
        })
        #expect(journey.statusEvidence.coverage == .live)
        #expect(journey.effectiveArrival == RealtimeTestFixture.date("08:47:00"))
        #expect(await provider.requests.count == 2)
        #expect(RealtimeBoardProtocol.requests(host).contains { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "id" }?.value == "c"
        })
    }

    @Test func onTimeReportsUpdateEvidenceWithoutRepeatingTheFullScan() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in
            Self.board("201", "trip", "a", "c", "08:00:00", "08:20:00", "08:00:00", "08:20:00")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = EmptyDiscoveryBatch(hafas: try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client))
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort()))
            .initial(count: 10, searchHorizon: 10_800)
        #expect(page.journeys.first?.statusEvidence.coverage == .live)
        #expect(page.journeys.first?.effectiveArrival == RealtimeTestFixture.date("08:20:00"))
        #expect(page.metrics.pointRaptorScans == 1)
        #expect(await provider.requests == 2)
    }

    @Test func confirmedDelayReplacesTheConservativeEstimatedBoardingDeadline() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let serviceDate = try GTFSDate(parsing: "20260930")
        func patch(_ source: RealtimeTimingSource) -> RealtimeTripPatch {
            .init(tripID: "trip", serviceDate: serviceDate, events: [
                .init(stopID: "a", effectiveDeparture: RealtimeTestFixture.date("08:05:00"),
                      departureSource: source, stopSequence: 1),
                .init(stopID: "b", effectiveDeparture: RealtimeTestFixture.date("08:15:00"), departureSource: source,
                      effectiveArrival: RealtimeTestFixture.date("08:15:00"), arrivalSource: source, stopSequence: 2),
                .init(stopID: "c", effectiveDeparture: RealtimeTestFixture.date("08:25:00"), departureSource: source,
                      effectiveArrival: RealtimeTestFixture.date("08:25:00"), arrivalSource: source, stopSequence: 3)
            ])
        }
        let provider = ConfirmingDelayProvider(estimated: patch(.estimated), confirmed: patch(.reported))
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let page = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00"), realtimePolicy: .bestEffort()))
            .initial(count: 10, searchHorizon: 10_800)
        #expect(page.journeys.first?.statusEvidence.coverage == .live)
        #expect(page.journeys.first?.effectiveDeparture == RealtimeTestFixture.date("08:05:00"))
        #expect(page.metrics.pointRaptorScans == 2)
    }

    private static func board(_ line: String, _ trip: String, _ from: String, _ to: String,
                              _ departure: String, _ arrival: String,
                              _ predictedDeparture: String, _ predictedArrival: String) -> String {
        liveBoard(stops: liveStop(from, planned: departure, predicted: predictedDeparture) + ","
            + liveStop(to, planned: arrival, predicted: predictedArrival, arrival: predictedArrival),
            time: departure, realtime: predictedDeparture, stop: from)
            .replacingOccurrences(of: "\"201\"", with: "\"\(line)\"")
            .replacingOccurrences(of: "same-journey", with: trip)
    }
}

private actor FirstBatchWithoutThirdStop: RealtimeRoutingProvider {
    let hafas: HafasRealtimeRoutingProvider
    var requests: [RealtimeRoutingRequest] = []
    init(hafas: HafasRealtimeRoutingProvider) { self.hafas = hafas }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests.append(request)
        guard requests.count == 1 else { return try await hafas.patches(for: request) }
        // Discovery may miss a board on its first bounded pass. A vehicle that
        // becomes selected must get its own acquisition before publication.
        return try await hafas.patches(for: .init(stopIDs: request.stopIDs.filter { $0 != "c" },
            from: request.from, through: request.through, scheduledLookbackSeconds: request.scheduledLookbackSeconds,
            refreshPolicy: request.refreshPolicy, maximumConcurrentRequests: request.maximumConcurrentRequests,
            timeout: request.timeout, deadline: request.deadline, targets: request.targets.filter { $0.stopID != "c" },
            tripIDs: request.tripIDs))
    }
}

private actor EmptyDiscoveryBatch: RealtimeRoutingProvider {
    let hafas: HafasRealtimeRoutingProvider
    var requests = 0
    init(hafas: HafasRealtimeRoutingProvider) { self.hafas = hafas }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through, refreshPolicy: refreshPolicy))
    }
    func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        requests += 1
        if requests == 1 { return .init(patches: [], requestedStopIDs: Set(request.stopIDs), coveredStopIDs: []) }
        return try await hafas.patches(for: request)
    }
}

private actor ConfirmingDelayProvider: RealtimeRoutingProvider {
    let estimated: RealtimeTripPatch
    let confirmed: RealtimeTripPatch
    var requests = 0
    init(estimated: RealtimeTripPatch, confirmed: RealtimeTripPatch) {
        self.estimated = estimated; self.confirmed = confirmed
    }
    func patches(for stopIDs: [String], from: Date, through: Date,
                 refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        requests += 1
        return .init(patches: [requests == 1 ? estimated : confirmed],
                     requestedStopIDs: Set(stopIDs), coveredStopIDs: Set(stopIDs))
    }
}
