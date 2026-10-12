import Foundation
import Testing
@testable import MobiliteitKit

@Suite struct RealtimeBoardPartitionTests {
    @Test(arguments: [0, 1, 8, 9, 17])
    func partitionsRetainEveryLineAndTheCompleteInterval(count: Int) async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let lines = (0..<count).map { String(201 + $0) }
        let probe = PartitionConcurrency()
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { _ in
            probe.started()
            return .milliseconds(30)
        }) { _ in
            probe.finished()
            return #"{"Departure":[]}"#
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client,
            maximumConcurrentBoardRequests: 4)
        let from = RealtimeTestFixture.date("08:00:00")
        let through = RealtimeTestFixture.date("09:30:00")
        let batch = try await provider.patches(for: .init(stopIDs: ["a", "b"], from: from, through: through,
            maximumConcurrentRequests: 2, targets: [
                .init(stopID: "a", from: from, through: through, lines: lines),
                .init(stopID: "b", from: from, through: through, lines: lines)]))
        let requests = RealtimeBoardProtocol.requests(host)
        #expect(requests.count == 2 * max(1, (count + 7) / 8))
        #expect(probe.peak == 2)
        #expect(batch.coveredStopIDs == ["a", "b"])
        #expect(batch.incompleteStopIDs.isEmpty)
        #expect(batch.networkRequests == requests.count)
        for stop in ["a", "b"] {
            var acquired: [String] = []
            for request in requests {
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                guard query["id"] == stop else { continue }
                #expect(query["date"] == "2026-09-30")
                #expect(query["time"] == "08:00:00")
                #expect(query["duration"] == "90")
                #expect(query["maxJourneys"] == "-1")
                #expect(query["passlist"] == "1")
                acquired += query["lines"]?.split(separator: ",").map(String.init) ?? []
            }
            #expect(acquired.sorted() == lines.sorted())
        }
    }

    @Test func aTimedOutPartitionRetainsTheOtherPartitionsLiveEvidence() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { request in
            Self.lines(request).contains("201") ? .milliseconds(20) : .seconds(5)
        }) { request in
            Self.lines(request).contains("201")
                ? liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:08:00") + ","
                    + liveStop("c", planned: "08:20:00", predicted: "08:28:00", arrival: "08:28:00"))
                : #"{"Departure":[]}"#
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client,
            maximumConcurrentBoardRequests: 2)
        let from = RealtimeTestFixture.date("08:00:00")
        let through = RealtimeTestFixture.date("09:30:00")
        let started = ContinuousClock.now
        let batch = try await provider.patches(for: .init(stopIDs: ["a"], from: from, through: through,
            maximumConcurrentRequests: 2, timeout: .milliseconds(500),
            deadline: started.advanced(by: .milliseconds(500)), targets: [
                .init(stopID: "a", from: from, through: through, lines: (201...209).map(String.init))]))
        #expect(batch.coveredStopIDs == ["a"])
        #expect(batch.incompleteStopIDs == ["a"])
        #expect(batch.networkRequests == 2)
        let patch = try #require(batch.patches.first)
        #expect(patch.tripID == "trip")
        #expect(patch.events.first?.effectiveDeparture == RealtimeTestFixture.date("08:08:00"))
        #expect(started.duration(to: .now) < .seconds(2))
    }

    private static func lines(_ request: URLRequest) -> [String] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "lines" }?.value?.split(separator: ",").map(String.init) ?? []
    }
}

private final class PartitionConcurrency: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var active = 0
    private nonisolated(unsafe) var maximum = 0
    var peak: Int { lock.withLock { maximum } }
    func started() { lock.withLock { active += 1; maximum = max(maximum, active) } }
    func finished() { lock.withLock { active -= 1 } }
}
