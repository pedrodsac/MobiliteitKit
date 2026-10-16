import Foundation
@testable import MobiliteitKit

/// Two boards for the one-vehicle fixture timetable, with per-stop response delays.
enum RealtimeBatchFixture {
    static let from = RealtimeTestFixture.date("07:55:00")
    static let through = RealtimeTestFixture.date("08:30:00")

    /// Stop "a" reports its own departure and the vehicle's departure at "b"; stop "b" reports
    /// the same vehicle at its own stop, with the same prediction.
    static func response(for request: URLRequest) -> String {
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
        switch id {
        case "a":
            return liveBoard(stops: liveStop("a", planned: "08:00:00", predicted: "08:01:00") + ","
                + liveStop("b", planned: "08:10:00", predicted: "08:19:00", arrival: "08:17:00"),
                realtime: "08:01:00", stop: "a")
        case "b":
            return liveBoard(stops: liveStop("b", planned: "08:10:00", predicted: "08:19:00", arrival: "08:17:00"),
                time: "08:10:00", realtime: "08:19:00", stop: "b")
        default:
            return liveBoard(stops: liveStop("c", planned: "08:20:00", predicted: "08:21:00"),
                time: "08:20:00", realtime: "08:21:00", stop: "c")
        }
    }

    static func provider(_ fixture: RealtimeTestFixture, delays: [String: Duration])
        async throws -> (HafasRealtimeRoutingProvider, String) {
        let (client, host) = RealtimeBoardProtocol.client(responseDelay: { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value
            return id.flatMap { delays[$0] } ?? .zero
        }, response)
        let fixed = RealtimeTestFixture.date("08:00:00")
        return (HafasRealtimeRoutingProvider(store: try GTFSStore(databaseAt: fixture.database), client: client,
                                             now: { fixed }), host)
    }
}
