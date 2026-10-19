import Foundation
import Testing
@testable import MobiliteitKit

@Suite("Routing snapshot file format")
struct RoutingSnapshotCodecTests {
    private func builtSnapshot(files: [String: String] = SnapshotFixture.files()) async throws -> (snapshot: RoutingSnapshot, folder: URL, database: URL) {
        let folder = try temporaryDirectory()
        let database = try await SnapshotFixture.install(files: files, in: folder)
        return (try SnapshotBuilder.load(databaseURL: database), folder, database)
    }

    @Test func loadedSnapshotEqualsBuiltSnapshot() async throws {
        let (built, folder, _) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        // The fixture must reach every stored table, or the comparison proves too little.
        #expect(built.trips.contains { $0.id.contains("#frequency-") } && built.trips.contains { $0.times.contains { $0.headsign != nil } })
        #expect(built.trips.contains { !$0.consecutiveSequences } && built.trips.contains { $0.times.contains { $0.arrival == nil || $0.departure == nil } })
        #expect(built.trips.contains { $0.times.contains { $0.pickup != 0 } } && built.trips.contains { $0.times.contains { $0.dropoff != 0 } })
        #expect(built.trips.contains { $0.blockID != nil } && built.trips.contains { $0.bikesAllowed != 0 })
        #expect(built.rulesByGroup.values.flatMap { $0 }.contains { $0.type == 4 && $0.fromTrip != nil })
        #expect(built.pathsByFrom.flatMap { $0 }.contains { $0.stairCount == nil } && built.pathsByFrom.flatMap { $0 }.contains { $0.stairCount != nil })
        #expect(built.pathsByTo.flatMap { $0 }.contains { ($0.stairCount ?? 0) < 0 })
        #expect(built.continuations.hasLinks && !built.nearbyTransferStopsByStop.allSatisfy(\.isEmpty) && built.patterns.count > 1)
        #expect(built.stops.contains { $0.model.name != $0.model.name.precomposedStringWithCanonicalMapping || $0.model.name.utf8.contains(0xCC) })

        let loaded = try roundTrip(built)
        #expect(snapshotDifferences(built, loaded).isEmpty, "\(snapshotDifferences(built, loaded))")
    }

    @Test func fieldInventory() async throws {
        let (built, folder, _) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        let fields = Set(Mirror(reflecting: built).children.compactMap(\.label))
        #expect(fields == SnapshotFixture.snapshotFields, "RoutingSnapshot changed. Store or derive the new field in RoutingSnapshotCodec, compare it in snapshotDifferences, bump formatVersion, then update snapshotFields. Difference: \(fields.symmetricDifference(SnapshotFixture.snapshotFields))")
    }

    @Test func encodingIsDeterministic() async throws {
        let (first, folder, database) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        let second = try SnapshotBuilder.load(databaseURL: database)
        let identity = Data("identity".utf8)
        #expect(try RoutingSnapshotCodec.encode(first, identity: identity) == RoutingSnapshotCodec.encode(second, identity: identity))
        #expect(try RoutingSnapshotCodec.encode(first, identity: identity) == RoutingSnapshotCodec.encode(roundTrip(first), identity: identity))
    }

    /// Fails when the stored bytes of the fixture change. If the change is intended, bump
    /// `RoutingSnapshotCodec.formatVersion` (so no stale file is ever loaded) and update `expected`.
    @Test func goldenDigest() async throws {
        let (built, folder, _) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        let payload = try RoutingSnapshotCodec.encodePayload(built)
        let digest = payload.withUnsafeBytes { SnapshotChecksum.hash($0) }
        let expected: [UInt32: UInt64] = [1: 8_018_761_030_551_960_332]
        #expect(digest == expected[RoutingSnapshotCodec.formatVersion], "format \(RoutingSnapshotCodec.formatVersion) digest is \(digest) (payload \(payload.count) bytes)")
    }

    @Test func checksumMatchesKnownVectors() {
        // XXH64 reference values (seed 0).
        func hash(_ text: String) -> UInt64 { Array(text.utf8).withUnsafeBytes { SnapshotChecksum.hash($0) } }
        #expect(hash("") == 0xEF46_DB37_51D8_E999)
        #expect(hash("a") == 0xD24E_C4F1_A98C_6E5B)
        #expect(hash("abc") == 0x44BC_2CF5_AD77_0999)
        #expect(hash("Nobody inspects the spammish repetition") == 0xFBCE_A83C_8A37_8BF1)
    }

    @Test func rejectsForeignFilesAndOtherFormats() async throws {
        let (built, folder, _) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        let identity = Data("identity".utf8)
        let file = try RoutingSnapshotCodec.encode(built, identity: identity)
        func decode(_ data: Data, identity: Data = identity) throws -> RoutingSnapshot { try aligned(data) { try RoutingSnapshotCodec.decode($0, identity: identity) } }

        #expect(throws: RoutingSnapshotCodec.Rejection.notASnapshot) { try decode(Data()) }
        #expect(throws: RoutingSnapshotCodec.Rejection.notASnapshot) { try decode(Data("not a snapshot, just text of some length".utf8)) }
        #expect(throws: RoutingSnapshotCodec.Rejection.identity) { try decode(file, identity: Data("another feed".utf8)) }
        var newer = file
        newer.withUnsafeMutableBytes { $0.storeBytes(of: UInt64(RoutingSnapshotCodec.formatVersion + 1), toByteOffset: 8, as: UInt64.self) }
        #expect(throws: RoutingSnapshotCodec.Rejection.formatVersion(RoutingSnapshotCodec.formatVersion + 1)) { try decode(newer) }
    }

    @Test func rejectsEveryDamagedFile() async throws {
        let (built, folder, _) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        let identity = Data("identity".utf8)
        let file = try RoutingSnapshotCodec.encode(built, identity: identity)
        func accepts(_ data: Data) -> Bool { (try? aligned(data) { try RoutingSnapshotCodec.decode($0, identity: identity) }) != nil }
        #expect(accepts(file))
        // A flipped byte anywhere in the payload fails the checksum.
        let payloadStart = file.count - (try RoutingSnapshotCodec.encodePayload(built)).count
        for position in stride(from: payloadStart, to: file.count, by: max(1, (file.count - payloadStart) / 97)) {
            var damaged = file; damaged[position] ^= 0x40
            #expect(!accepts(damaged), "flipped byte \(position)")
        }
        // Truncation at any length is rejected without trapping.
        for length in stride(from: 0, to: file.count, by: max(1, file.count / 211)) {
            #expect(!accepts(file.prefix(length)), "truncated to \(length)")
        }
        #expect(!accepts(file.dropLast()))
    }

    @Test func refusesValuesTheColumnsCannotHoldExactly() async throws {
        let (built, folder, _) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        var trips = built.trips
        let original = trips[0]
        var times = original.times
        times[0] = SnapshotTime(stop: times[0].stop, sequence: Int(Int32.max) + 1, arrival: times[0].arrival, departure: times[0].departure, pickup: 0, dropoff: 0)
        trips[0] = SnapshotTrip(id: original.id, route: original.route, service: original.service, times: times, headsign: original.headsign, wheelchairAccessible: original.wheelchairAccessible)
        let oversized = RoutingSnapshot(
            info: built.info, converter: built.converter, stops: built.stops, stopByID: built.stopByID, routes: built.routes, trips: trips, tripByID: built.tripByID,
            tripIndicesByDepartureStop: built.tripIndicesByDepartureStop, serviceRoutesByStop: built.serviceRoutesByStop, boardableStops: built.boardableStops,
            alightableStops: built.alightableStops, serviceDays: built.serviceDays, lastActiveDayStartByService: built.lastActiveDayStartByService,
            rulesByGroup: built.rulesByGroup, stationGroupByStop: built.stationGroupByStop, pathsByFrom: built.pathsByFrom, pathsByTo: built.pathsByTo,
            nearbyTransferStopsByStop: built.nearbyTransferStopsByStop, serviceDayByDate: built.serviceDayByDate,
            nearbyTransferSourcesByStop: built.nearbyTransferSourcesByStop, continuations: built.continuations, patterns: built.patterns,
            patternOccurrencesByStop: built.patternOccurrencesByStop, loadMilliseconds: 0)
        #expect(throws: SnapshotFileError.self) { try RoutingSnapshotCodec.encode(oversized, identity: Data()) }
    }

    @Test func serviceInstantsFollowTheRunningTimeZoneDatabase() async throws {
        let (built, folder, _) = try await builtSnapshot(); defer { try? FileManager.default.removeItem(at: folder) }
        let loaded = try roundTrip(built)
        let day = try #require(built.serviceDays.first)
        #expect(loaded.serviceDays.first?.start == day.start)
        // 2026-09-01 00:00 local time in Europe/Luxembourg (UTC+2 in summer).
        #expect(day.start == ISO8601DateFormatter().date(from: "2026-08-31T22:00:00Z"))
    }
}
