import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Routing prevention: realtime evidence")
struct RoutingPreventionRealtimeTests {
    var files: [String: String] { preventionFiles(trips: "bus,service,ride,,,,\n",
        times: "ride,08:00:00,08:00:00,a,1\nride,08:10:00,08:10:00,b,2\nride,08:20:00,08:20:00,d,3\n") }
    var day: GTFSDate { get throws { try GTFSDate(parsing: "20260904") } }

    // 28–29: sparse +15 minutes cannot teleport back to the scheduled timeline.
    @Test func sparseDelayPropagatesAcrossScheduledFallbackEvents() async throws {
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let patch = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a",
            effectiveDeparture: date(hour: 8, minute: 15), departureSource: .reported, stopSequence: 1, observedAt: date(hour: 8))])
        let resolved = RealtimeTimeline.resolved(patch, snapshot: await fixture.router.snapshot, now: date(hour: 8))
        #expect(resolved.status == .active && resolved.isChronological)
        #expect(resolved.events.last?.effectiveArrival == date(hour: 8, minute: 35))
        #expect(resolved.events.last?.arrivalSource == .estimated)
        #expect(resolved.events[1].effectiveDeparture == date(hour: 8, minute: 25))
    }

    @Test func contradictoryRecoveryAndExpiredEvidenceAreQuarantined() async throws {
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let snapshot = await fixture.router.snapshot
        let delayed = RealtimeStopEventPatch(stopID: "a", effectiveDeparture: date(hour: 8, minute: 15), departureSource: .reported, stopSequence: 1, observedAt: date(hour: 8))
        let recoveredTooSoon = RealtimeStopEventPatch(stopID: "b", effectiveArrival: date(hour: 8, minute: 10), arrivalSource: .reported, stopSequence: 2, observedAt: date(hour: 8))
        #expect(RealtimeTimeline.resolved(.init(tripID: "ride", serviceDate: try day, events: [delayed, recoveredTooSoon]), snapshot: snapshot, now: date(hour: 8)).status == .unreachable)
        #expect(RealtimeTimeline.resolved(.init(tripID: "ride", serviceDate: try day, events: [delayed]), snapshot: snapshot, now: date(hour: 8).addingTimeInterval(121)).status == .unreachable)
        let recovered = RealtimeStopEventPatch(stopID: "d", effectiveArrival: date(hour: 8, minute: 30), arrivalSource: .reported, stopSequence: 3, observedAt: date(hour: 8))
        let valid = RealtimeTimeline.resolved(.init(tripID: "ride", serviceDate: try day, events: [delayed, recovered]), snapshot: snapshot, now: date(hour: 8))
        #expect(valid.status == .active && valid.events.last?.effectiveArrival == date(hour: 8, minute: 30))
    }

    // 30–32: only fresh local reports can prove delay-enabled catchability.
    @Test(arguments: [RealtimeTimingSource.reported, .estimated])
    func delayedPastBoardingNeedsConservativeProof(source: RealtimeTimingSource) async throws {
        let patch = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a",
            effectiveDeparture: date(hour: 8, minute: 15), departureSource: source, stopSequence: 1, observedAt: date(hour: 8, minute: 5))])
        let fixture = try await RoutingPreventionFixture(files: files, realtime: PreventionRealtime(patches: [patch]), now: date(hour: 8, minute: 5)); defer { fixture.remove() }
        let result = try await fixture.profile(fixture.query(anchor: date(hour: 8, minute: 5), live: true))
        #expect(result.journeys.isEmpty == (source == .estimated))
        if source == .reported {
            let journey = try #require(result.journeys.first)
            #expect(journey.effectiveArrival == date(hour: 8, minute: 35))
            #expect(!JourneyPublicationValidator.assess(journey, query: fixture.query(anchor: date(hour: 8, minute: 5))).isInvalid)
        }
    }

    @Test func sparsePatchCannotConfuseRepeatedStopOccurrences() async throws {
        let files = preventionFiles(trips: "bus,service,ride,,,,\n", times: "ride,08:00:00,08:00:00,a,1\nride,08:05:00,08:05:00,b,2\nride,08:10:00,08:10:00,a,3\nride,08:20:00,08:20:00,d,4\n")
        let fixture = try await RoutingPreventionFixture(files: files); defer { fixture.remove() }
        let snapshot = await fixture.router.snapshot
        let ambiguous = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 15), departureSource: .reported)])
        #expect(RealtimeTimeline.resolved(ambiguous, snapshot: snapshot, now: date(hour: 8)).status == .unreachable)
        let scoped = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 15), departureSource: .reported, stopSequence: 3)])
        let resolved = RealtimeTimeline.resolved(scoped, snapshot: snapshot, now: date(hour: 8))
        #expect(resolved.events[0].effectiveDeparture == date(hour: 8))
        #expect(resolved.events[2].effectiveDeparture == date(hour: 8, minute: 15))
        #expect(resolved.events[3].effectiveArrival == date(hour: 8, minute: 25))
    }

    @Test(arguments: [false, true]) func concurrentBoardOrderPreservesFreshDirectReport(reverse: Bool) throws {
        let report = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 15), departureSource: .reported, observedAt: date(hour: 8))])
        let estimate = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 16), departureSource: .estimated, observedAt: date(hour: 8).addingTimeInterval(1))])
        let result = reverse ? estimate.merging(report) : report.merging(estimate)
        #expect(result.events.first?.departureSource == .reported)
        #expect(result.events.first?.effectiveDeparture == date(hour: 8, minute: 15))
    }

    @Test func newerPredictionCanReplaceOldReportedEvidence() throws {
        let early = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 15), departureSource: .reported, observedAt: date(hour: 8))])
        let fresh = RealtimeTripPatch(tripID: "ride", serviceDate: try day, events: [.init(stopID: "a", effectiveDeparture: date(hour: 8, minute: 16), departureSource: .estimated, observedAt: date(hour: 8).addingTimeInterval(121))])
        #expect(early.merging(fresh).events.first?.effectiveDeparture == date(hour: 8, minute: 16))
        #expect(fresh.merging(early).events.first?.effectiveDeparture == date(hour: 8, minute: 16))
    }
}
