import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Whole trip stop snapshots")
struct TransitTripSnapshotTests {
    @Test func fullRunPreservesReportsPredictionsAndMissingTimes() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let body = liveBoard(stops: [
            liveStop("a", planned: "08:00:00", predicted: "08:03:00", extra: ",\"depPrognosisType\":\"REPORTED\""),
            liveStop("b", planned: "08:10:00"),
            liveStop("c", planned: "08:20:00", predicted: "08:22:00", arrival: "08:22:00",
                extra: ",\"arrPrognosisType\":\"PROGNOSED\"")
        ].joined(separator: ","), time: "08:10:00", realtime: nil, stop: "b")
        let (client, host) = RealtimeBoardProtocol.client { _ in body }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let generation = await router.snapshot.info.generation
        let run = TransitInstanceIdentity(feedGeneration: generation, tripID: "trip", serviceDate: try GTFSDate(parsing: "20260930"))
        let result = try await router.tripSnapshot(for: run, boardingSequence: 2)
        #expect(result.stops.map(\.sequence) == [1, 2, 3])
        #expect(result.stops[0].departure?.realtime == RealtimeTestFixture.date("08:03:00"))
        #expect(result.stops[0].departure?.prognosisType == "REPORTED")
        #expect(result.stops[1].departure?.realtime == nil)
        #expect(result.stops[2].arrival?.realtime == RealtimeTestFixture.date("08:22:00"))
        #expect(result.stops[2].arrival?.prognosisType == "PROGNOSED")
        #expect(result.liveDataAvailable)
        let query = try #require(RealtimeBoardProtocol.requests(host).first?.url)
        #expect(URLComponents(url: query, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "passlist", value: "1")) == true)
    }

    @Test func repeatedStopsKeepDistinctOccurrences() async throws {
        let fixture = try await RealtimeTestFixture(stopTimes: "trip,08:00:00,08:00:00,a,1\ntrip,08:10:00,08:10:00,b,2\ntrip,08:20:00,08:20:00,a,3\ntrip,08:30:00,08:30:00,c,4\n")
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let generation = await router.snapshot.info.generation
        let result = try await router.tripSnapshot(for: .init(feedGeneration: generation, tripID: "trip",
            serviceDate: try GTFSDate(parsing: "20260930")), boardingSequence: 3)
        #expect(result.stops.map(\.id) == [1, 2, 3, 4])
        #expect(result.stops[0].stop.id == result.stops[2].stop.id)
        #expect(result.stops[0].departure?.scheduled != result.stops[2].departure?.scheduled)
        #expect(!result.liveDataAvailable)
    }

    @Test(arguments: ["20260329", "20261025"])
    func overnightRunUsesSelectedServiceDateAcrossDST(day: String) async throws {
        let fixture = try await RealtimeTestFixture(stopTimes: "trip,23:50:00,23:50:00,a,1\ntrip,24:10:00,24:10:00,c,2\n",
            serviceDates: "service,\(day),1\n")
        defer { fixture.remove() }
        let router = try await TransitRouter(databaseURL: fixture.database)
        let generation = await router.snapshot.info.generation
        let result = try await router.tripSnapshot(for: .init(feedGeneration: generation, tripID: "trip",
            serviceDate: try GTFSDate(parsing: day)), boardingSequence: 1)
        let first = try #require(result.stops.first?.departure?.scheduled)
        let last = try #require(result.stops.last?.arrival?.scheduled)
        #expect(last.timeIntervalSince(first) == 20 * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Luxembourg")!
        #expect(calendar.component(.day, from: last) == (day == "20260329" ? 30 : 26))
        #expect(calendar.component(.hour, from: last) == 0)
        #expect(calendar.component(.minute, from: last) == 10)
    }

    @Test func cancellationsAndObsoleteFeedAreExplicit() async throws {
        let fixture = try await RealtimeTestFixture(); defer { fixture.remove() }
        let (client, host) = RealtimeBoardProtocol.client { _ in
            liveBoard(stops: "", realtime: nil, extra: ",\"cancelled\":true")
        }
        defer { RealtimeBoardProtocol.remove(host) }
        let provider = try HafasRealtimeRoutingProvider(databaseURL: fixture.database, client: client)
        let router = try await TransitRouter(databaseURL: fixture.database, realtimeProvider: provider)
        let generation = await router.snapshot.info.generation
        let date = try GTFSDate(parsing: "20260930")
        let result = try await router.tripSnapshot(for: .init(feedGeneration: generation, tripID: "trip", serviceDate: date), boardingSequence: 1)
        #expect(result.isCancelled)
        #expect(result.stops.allSatisfy { $0.departure?.isCancelled == true })
        await #expect(throws: TransitTripSnapshotError.self) {
            try await router.tripSnapshot(for: .init(feedGeneration: generation + 1, tripID: "trip", serviceDate: date), boardingSequence: 1)
        }
    }
}
