import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RoutingDiagnosticsTests {
    @Test func operationsHaveIndependentTimingsAndCorrelationIDs() async throws {
        let fixture = try await RealtimeTestFixture()
        defer { fixture.remove() }
        let planner = JourneyPlanner()
        let request = JourneyPlanningRequest(origin: .stop(id: "a"), destination: .stop(id: "c"),
            time: .departAt(RealtimeTestFixture.date("07:55:00")))
        let session = try await planner.makePlanningSession(databaseURL: fixture.database, request: request)
        let initial = try await session.calculate(refresh: .scheduleOnly)
        let refreshed = try await session.calculate(refresh: .scheduleOnly)
        #expect(initial.diagnostics.requestID != refreshed.diagnostics.requestID)
        #expect(initial.diagnostics.totalMilliseconds >= initial.diagnostics.milliseconds[.raptor, default: 0])
        #expect(initial.diagnostics.milliseconds[.snapshotPreparation] != nil)
        #expect(refreshed.diagnostics.milliseconds[.snapshotPreparation] == 0)
        #expect(refreshed.diagnostics.milliseconds[.realtime, default: 0] >= 0)
        #expect(refreshed.metrics.raptorNonWalkingMilliseconds == refreshed.metrics.raptorCPUMilliseconds)
        #expect(initial.journeys.map(\.id) == refreshed.journeys.map(\.id))
    }
    @Test func cachedRawPagesDoNotRepeatSearchCosts() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("07:55:00")))
        let initial = try await session.initial()
        let cached = try await session.initial()
        #expect(initial.diagnostics.requestID != cached.diagnostics.requestID)
        #expect(cached.diagnostics.milliseconds[.raptor] == nil)
        #expect(cached.diagnostics.counters.isEmpty)
        #expect(initial.metrics.pointRaptorScans == cached.metrics.pointRaptorScans)
        #expect(initial.journeys.map(\.id) == cached.journeys.map(\.id))
    }

    @Test func spansAndSearchPassesSurviveAggregation() {
        let start = ContinuousClock.now
        var combined = RoutingDiagnostics(startedAt: start)
        var first = RoutingDiagnostics(startedAt: start)
        first.record(.raptor, since: start)
        first.recordSearch(since: start, horizon: 10_800, wave: 0, rounds: [], candidates: 4, walkingMilliseconds: 2)
        var second = RoutingDiagnostics()
        second.recordSearch(since: .now, horizon: 21_600, wave: 1, rounds: [], candidates: 8, walkingMilliseconds: 1)
        combined.include(first); combined.include(second)
        #expect(combined.searchPasses.map(\.horizonSeconds) == [10_800, 21_600])
        #expect(combined.searchPasses.map(\.realtimeWave) == [0, 1])
        #expect(combined.spans.count == 1)
        #expect(combined.searchPasses.allSatisfy { $0.startMilliseconds >= 0 })
        #expect(RoutingDiagnostics.cumulativeWorkStages == [.http, .decode])
    }

    @Test func warmUpScansAndBoardTimingsStayOffTheAuthoritativePasses() {
        let start = ContinuousClock.now
        var combined = RoutingDiagnostics(startedAt: start)
        var session = RoutingDiagnostics(startedAt: start.advanced(by: .milliseconds(20)))
        let round = RoutingRoundMetrics(tripPreparationMilliseconds: 1, patternScanMilliseconds: 2, labelMergeMilliseconds: 3,
            patterns: 4, tripInstances: 5, boardingChecks: 6, feasibleBoardings: 7, alightingChecks: 8, labelAttempts: 9,
            retainedLabels: 10, rejectedBeforeAllocation: 11, slowestChunkMilliseconds: 12, summedChunkMilliseconds: 13)
        let scanStart = session.originDate.timeIntervalSinceReferenceDate
        session.recordWarmUp(since: start.advanced(by: .milliseconds(30)), through: start.advanced(by: .milliseconds(80)),
            horizon: 7_200, rounds: [round], candidates: 3, walkingMilliseconds: 4)
        var timings = RealtimeBatchTimings()
        timings.fetchStarted = start.advanced(by: .milliseconds(25))
        timings.fetchFinished = start.advanced(by: .milliseconds(60))
        timings.matchingStarted = start.advanced(by: .milliseconds(40))
        timings.matchingFinished = start.advanced(by: .milliseconds(65))
        timings.preparationMilliseconds = 7
        timings.boards = [.init(stopID: "a", arrived: start.advanced(by: .milliseconds(35)),
            matchingStarted: start.advanced(by: .milliseconds(40)), matchingFinished: start.advanced(by: .milliseconds(50))),
            .init(stopID: "b")]
        session.recordBoards(timings)
        #expect(session.searchPasses.isEmpty && session.rounds.isEmpty)
        #expect(session.warmUpPasses.first?.rounds == [round])
        let warmUp = session.warmUpPasses[0]
        #expect(abs(warmUp.startMilliseconds - 10) < 1 && abs(warmUp.durationMilliseconds - 50) < 1)
        #expect(session.spans.map(\.stage) == [.providerBoardFetch, .providerStopMatching])
        #expect(session.milliseconds[.providerBoardPreparation] == 7)
        combined.include(session)
        // Included timings move onto the receiving operation's timeline: 20 ms later.
        #expect(abs(combined.warmUpPasses[0].startMilliseconds - 30) < 1)
        #expect(abs((combined.realtimeBoards[0].arrivedMilliseconds ?? 0) - 35) < 1)
        #expect(abs((combined.realtimeBoards[0].matchingFinishedMilliseconds ?? 0) - 50) < 1)
        #expect(combined.realtimeBoards[1].arrivedMilliseconds == nil)
        #expect(combined.searchPasses.isEmpty)
        // Rebasing to an earlier start moves wall-clock time and every offset together.
        var rebased = session
        rebased.rebase(to: start.advanced(by: .milliseconds(-100)))
        #expect(abs(rebased.warmUpPasses[0].startMilliseconds - 130) < 1)
        #expect(abs(rebased.originDate.timeIntervalSinceReferenceDate - (scanStart - 0.12)) < 0.001)
    }

    @Test func anAcquiringSearchRecordsItsSubSpansWarmUpAndBoards() async throws {
        let fixture = try await RealtimeTestFixture(
            stopTimes: "first,08:00:00,08:00:00,a,1\nfirst,08:10:00,08:10:00,b,2\nsecond,08:12:00,08:12:00,b,1\nsecond,08:30:00,08:30:00,c,2\n",
            trips: "route,service,first,Destination\nroute,service,second,Destination\n")
        defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { request in
            let stop = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "id" }!.value!
            if stop == "a" {
                return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
                    + liveStop("b", planned: "08:10:00", predicted: "08:18:00", arrival: "08:18:00"))
            }
            return liveBoard(stops: liveStop("b", planned: "08:12:00", predicted: "08:20:00") + ","
                + liveStop("c", planned: "08:30:00", predicted: "08:38:00", arrival: "08:38:00"),
                time: "08:12:00", realtime: "08:20:00", stop: "b")
                .replacingOccurrences(of: "same-journey", with: "second-journey")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, walkingProvider: DiagnosticsWalking(),
                                             realtimeProvider: provider)
        let session = try await router.makeSession(for: .init(origin: .stop(id: "a"), destination: .stop(id: "c"),
            departureTime: RealtimeTestFixture.date("08:05:00"), realtimePolicy: .bestEffort()))
        let diagnostics = try await session.initial().diagnostics
        // The warm-up scan ran beside the board requests and is reported apart from the passes.
        #expect(diagnostics.warmUpPasses.count == 1)
        #expect(diagnostics.warmUpPasses.first?.rounds.isEmpty == false)
        #expect(!diagnostics.searchPasses.isEmpty)
        #expect(diagnostics.rounds.count == diagnostics.searchPasses.reduce(0) { $0 + $1.rounds.count })
        let stages = Set(diagnostics.spans.map(\.stage))
        for stage: RoutingDiagnostics.Stage in [.patchOverlay, .boardingIndex, .candidateCollection,
                                                .providerBoardFetch, .providerStopMatching, .providerSessionMerge,
                                                .buildTransferGroups, .buildEnvelope, .buildIntermediateStops] {
            #expect(stages.contains(stage), "\(stage)")
        }
        for stage: RoutingDiagnostics.Stage in [.buildNormalisation, .buildStructuralValidation, .buildAssembly,
                                                .buildPublicationValidation, .buildDeduplication, .providerBoardPreparation] {
            #expect(diagnostics.milliseconds[stage] != nil, "\(stage)")
        }
        // Every requested board reports when it arrived and how long it took to match.
        #expect(Set(diagnostics.realtimeBoards.map(\.stopID)) == ["a", "b"])
        for board in diagnostics.realtimeBoards {
            let arrived = try #require(board.arrivedMilliseconds), started = try #require(board.matchingStartedMilliseconds)
            #expect(started >= arrived && (board.matchingFinishedMilliseconds ?? 0) >= started)
        }
        let fetch = try #require(diagnostics.spans.first { $0.stage == .providerBoardFetch })
        let arrivals = diagnostics.realtimeBoards.compactMap(\.arrivedMilliseconds)
        #expect(arrivals.allSatisfy { $0 >= fetch.startMilliseconds && $0 <= fetch.startMilliseconds + fetch.durationMilliseconds + 1 })
    }
}

private struct DiagnosticsWalking: WalkingRoutingProvider {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate {
        let meters = distance(request.source, request.destination)
        return .init(durationSeconds: Int(ceil(meters / 1.2)), distanceMeters: meters)
    }
    func route(_ request: WalkingRequest) async throws -> WalkingRoute {
        let estimate = try await estimate(request)
        return .init(durationSeconds: estimate.durationSeconds, distanceMeters: estimate.distanceMeters,
                     polyline: [request.source, request.destination])
    }
}
