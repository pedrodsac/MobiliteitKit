import Foundation

/// Matches optional ATP predictions to this provider's immutable GTFS generation.
/// Acquisition, matching and event construction are separate from RAPTOR.
public actor HafasRealtimeRoutingProvider: RealtimeRoutingProvider {
    struct BoardResult: Sendable {
        let stopID: String
        let board: HafasDepartureBoard?
        let fetchedAt: Date
        let incomplete: Bool
        let requests: Int
        let hits: Int
        let bytes: Int
        var httpMilliseconds: Int = 0
        var decodeMilliseconds: Int = 0
        var transport: [HTTPTransportMeasurement] = []
        var observations: [String: Date] = [:]
        /// When the board's data became available to this batch.
        var arrivedAt: ContinuousClock.Instant? = nil
    }
    struct RealtimeMatchingFailure: Error { let reason: RealtimeMatchingRejection }
    struct Candidate {
        let departure: ScheduledDeparture
        let serviceDate: GTFSDate
        let scheduledDate: Date
        let score: Int
    }
    struct PreparedDeparture: Sendable {
        let departure: ScheduledDeparture
        let serviceDate: GTFSDate
        let scheduledDate: Date
    }
    struct PreparedSchedules: Sendable {
        let byStopID: [String: [PreparedDeparture]]
        let milliseconds: Int
    }
    struct ScheduleCache {
        let from: Date
        let through: Date
        let values: [PreparedDeparture]
    }
    struct MatchedJourney {
        let tripID: String
        let serviceDate: GTFSDate
        let fetchedAt: Date
    }

    let store: GTFSStore
    let client: MobiliteitAPIClient
    let maximumConcurrentBoardRequests: Int
    let boardRequestScheduler: RealtimeBoardRequestScheduler
    let cacheLifetime: TimeInterval
    let requestTimeout: Duration
    let matchingNow: @Sendable () -> ContinuousClock.Instant
    let now: @Sendable () -> Date
    let fullTimestampFormatter: DateFormatter
    let minuteTimestampFormatter: DateFormatter
    var timestampCache: [String: Date] = [:]
    var invalidTimestamps: Set<String> = []
    struct AlignmentKey: Hashable { let tripID: String; let date: GTFSDate; let stops: [HafasPasslistStop] }
    var alignments: [AlignmentKey: [Int: HafasPasslistStop]] = [:]
    var normalizedNames: [String: String] = [:]
    var serviceDayStarts: [GTFSDate: Date] = [:]
    var schedulesByStopID: [String: ScheduleCache] = [:]
    var matchedJourneys: [String: MatchedJourney] = [:]
    /// Batches whose matching is running; the memoization below is cleared when none are.
    var activeMatchingBatches = 0
    var stopTimesByTripID: [String: [TripStopTime]] = [:]
    var stopTimeCacheOrder: [String] = []
    let maximumCachedTripStopTimes = 512

    public init(databaseURL: URL, client: MobiliteitAPIClient,
                maximumConcurrentBoardRequests: Int = 4,
                cacheLifetime: TimeInterval = 60, requestTimeout: Duration = .seconds(4)) throws {
        self.store = try GTFSStore(databaseAt: databaseURL)
        self.client = client
        self.maximumConcurrentBoardRequests = max(1, maximumConcurrentBoardRequests)
        self.boardRequestScheduler = .init(capacity: max(1, maximumConcurrentBoardRequests))
        self.cacheLifetime = max(0, cacheLifetime)
        self.requestTimeout = requestTimeout
        self.now = { .now }; matchingNow = { .now }
        fullTimestampFormatter = Self.makeFormatter("yyyy-MM-dd HH:mm:ss")
        minuteTimestampFormatter = Self.makeFormatter("yyyy-MM-dd HH:mm")
    }

    init(store: GTFSStore, client: MobiliteitAPIClient, maximumConcurrentBoardRequests: Int = 4,
         cacheLifetime: TimeInterval = 60, requestTimeout: Duration = .seconds(4),
         now: @escaping @Sendable () -> Date,
         matchingNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.store = store; self.client = client
        self.maximumConcurrentBoardRequests = max(1, maximumConcurrentBoardRequests)
        self.boardRequestScheduler = .init(capacity: max(1, maximumConcurrentBoardRequests))
        self.cacheLifetime = max(0, cacheLifetime); self.requestTimeout = requestTimeout
        self.now = now; self.matchingNow = matchingNow
        fullTimestampFormatter = Self.makeFormatter("yyyy-MM-dd HH:mm:ss")
        minuteTimestampFormatter = Self.makeFormatter("yyyy-MM-dd HH:mm")
    }

    public func patches(for stopIDs: [String], from: Date, through: Date,
                        refreshPolicy: RealtimeRefreshPolicy) async throws -> RealtimePatchBatch {
        try await patches(for: .init(stopIDs: stopIDs, from: from, through: through,
                                     refreshPolicy: refreshPolicy,
                                     maximumConcurrentRequests: maximumConcurrentBoardRequests,
                                     timeout: requestTimeout))
    }

    public func patches(for request: RealtimeRoutingRequest) async throws -> RealtimePatchBatch {
        try Task.checkCancellation()
        beginMatchingBatch()
        defer { endMatchingBatch() }
        var seen: Set<String> = []
        let stopIDs = request.stopIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        let requested = Set(stopIDs)
        guard !requested.isEmpty, request.through >= request.from else {
            return .init(patches: [], requestedStopIDs: requested, coveredStopIDs: [])
        }
        // An explicit session deadline owns the whole batch budget. The default
        // timeout still bounds standalone board requests.
        let localDeadline = ContinuousClock.now.advanced(by:
            request.deadline == nil ? min(request.timeout, requestTimeout) : request.timeout)
        let deadline = request.deadline.map { min($0, localDeadline) } ?? localDeadline
        // A slow later slice must not consume the time needed to match boards
        // that already arrived. Keep matching inside the original deadline and
        // preserve partial evidence when acquisition reaches its earlier cutoff.
        let remaining = max(.zero, ContinuousClock.now.duration(to: deadline))
        let matchingReserve = min(.milliseconds(500), remaining / 4)
        let acquisitionDeadline = deadline.advanced(by: .zero - matchingReserve)
        let matchingFrom = request.from.addingTimeInterval(-Double(request.scheduledLookbackSeconds))
        async let schedules = prepareSchedules(for: stopIDs, from: matchingFrom, through: request.through, deadline: deadline, targets: request.targets, lookback: request.scheduledLookbackSeconds)
        let started = ContinuousClock.now
        let telemetry = BoardTelemetry()
        let (arrivals, delivery) = AsyncStream.makeStream(of: BoardResult.self)
        async let fetching = fetchBoards(for: stopIDs, request: request, deadline: acquisitionDeadline,
                                         telemetry: telemetry, delivery: delivery)
        let prepared = await schedules
        try Task.checkCancellation()
        // Each board is resolved against the timetable as it arrives, so that work overlaps the
        // remaining board requests. Stops are merged in request order, because `matchedJourneys`
        // reuse and patch merging depend on it.
        let context = MatchingContext(prepared: prepared, request: request, matchingFrom: matchingFrom, deadline: deadline)
        var ordered = OrderedMatching(stopIDs: stopIDs)
        var iterator = arrivals.makeAsyncIterator()
        while let board = await iterator.next() {
            try Task.checkCancellation()
            try await resolve(stopID: board.stopID, result: board, in: context, ordered: &ordered)
            try await mergeReadyBoards(&ordered, in: context)
        }
        // Delivery ended, so the fetch has returned its placeholders for stops that never arrived.
        let (fetched, fetchFinished) = await fetching
        for stopID in stopIDs[ordered.merged...] where ordered.waiting[stopID] == nil {
            try await resolve(stopID: stopID, result: fetched[stopID], in: context, ordered: &ordered)
        }
        try await mergeReadyBoards(&ordered, in: context)
        var timings = RealtimeBatchTimings()
        timings.matchingStarted = ordered.started
        timings.matchingFinished = ordered.finished
        timings.boards = ordered.boards
        let matching = ordered.state
        timings.fetchStarted = started
        timings.fetchFinished = fetchFinished
        timings.preparationMilliseconds = telemetry.preparationMilliseconds
        let fetchMilliseconds = Self.milliseconds(started.duration(to: fetchFinished))
        if matchedJourneys.count > 512 {
            matchedJourneys = Dictionary(uniqueKeysWithValues: matchedJourneys.sorted {
                $0.value.fetchedAt > $1.value.fetchedAt
            }.prefix(512).map { ($0.key, $0.value) })
        }
        return .init(patches: matching.patches.values.sorted { ($0.serviceDate, $0.tripID) < ($1.serviceDate, $1.tripID) },
                     requestedStopIDs: requested, coveredStopIDs: Set(fetched.values.filter { $0.board != nil }.map(\.stopID)),
                     boardFetchMilliseconds: fetchMilliseconds,
                     scheduledPreparationMilliseconds: prepared.milliseconds,
                     boardMatchingMilliseconds: Int(matching.workMilliseconds),
                     networkRequests: fetched.values.reduce(0) { $0 + $1.requests },
                     cacheHits: fetched.values.reduce(0) { $0 + $1.hits },
                     responseBytes: fetched.values.reduce(0) { $0 + $1.bytes },
                     incompleteStopIDs: Set(fetched.values.filter(\.incomplete).map(\.stopID)).union(matching.unfinished).union(requested.subtracting(prepared.byStopID.keys)),
                     fetchedAt: fetched.values.map(\.fetchedAt).min(),
                     httpMilliseconds: fetched.values.reduce(0) { $0 + $1.httpMilliseconds },
                     decodeMilliseconds: fetched.values.reduce(0) { $0 + $1.decodeMilliseconds },
                     matchingRejections: matching.rejections, transport: fetched.values.flatMap(\.transport),
                     timings: timings)
    }

    /// Fetches every board and ends the delivery stream once the final map is complete.
    private func fetchBoards(for stopIDs: [String], request: RealtimeRoutingRequest,
                             deadline: ContinuousClock.Instant, telemetry: BoardTelemetry,
                             delivery: AsyncStream<BoardResult>.Continuation) async
        -> (boards: [String: BoardResult], finished: ContinuousClock.Instant) {
        defer { delivery.finish() }
        let boards = await boards(for: stopIDs, request: request, deadline: deadline, telemetry: telemetry) {
            delivery.yield($0)
        }
        return (boards, .now)
    }

    func prepareSchedules(for stopIDs: [String], from: Date, through: Date, deadline: ContinuousClock.Instant, targets: [RealtimeBoardTarget] = [], lookback: Int = 7_200) async -> PreparedSchedules {
        let started = ContinuousClock.now
        guard ContinuousClock.now < deadline else { return .init(byStopID: [:], milliseconds: 0) }
        let feed = await store.feedInfo()
        let lastDay = feed.firstServiceDate.days(until: feed.lastServiceDate)
        var result: [String: [PreparedDeparture]] = [:]
        for stopID in stopIDs {
            if Task.isCancelled || ContinuousClock.now >= deadline { break }
            let relevant = targets.filter { $0.stopID == stopID }
            let start = relevant.map(\.from).min().map { max(from, $0.addingTimeInterval(-Double(lookback) - 1_800)) } ?? from
            let end = relevant.map(\.through).max().map { min(through, $0) } ?? through
            if let cached = schedulesByStopID[stopID], cached.from <= start, cached.through >= end {
                result[stopID] = cached.values; continue
            }
            let departures = (try? await store.nextScheduledDepartures(
                fromStopID: stopID, at: start, horizon: end.timeIntervalSince(start), limit: 4_000
            )) ?? []
            let values = departures.compactMap { value -> PreparedDeparture? in
                guard value.serviceDay.index >= 0, value.serviceDay.index <= lastDay,
                      let time = value.departure else { return nil }
                let date = feed.firstServiceDate.adding(days: Int(value.serviceDay.index))
                return .init(departure: value, serviceDate: date,
                             scheduledDate: serviceInstant(date, time: time))
            }.sorted { $0.scheduledDate < $1.scheduledDate }
            result[stopID] = values
            schedulesByStopID[stopID] = .init(from: start, through: end, values: values)
        }
        if schedulesByStopID.count > 128 {
            schedulesByStopID = schedulesByStopID.filter { stopIDs.contains($0.key) }
        }
        return .init(byStopID: result, milliseconds: Self.milliseconds(started.duration(to: .now)))
    }

    nonisolated static func fractionalMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
    /// Planned or live track data, which lets an untracked trip still show its platform.
    nonisolated static func hasPlatformSignal(_ value: HafasDeparture) -> Bool {
        func present(_ text: String?) -> Bool {
            text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return present(value.platform?.text) || present(value.realtimePlatform?.text)
            || value.passlist.values.contains {
                present($0.arrivalTrack) || present($0.departureTrack)
                    || present($0.realtimeArrivalTrack) || present($0.realtimeDepartureTrack)
            }
    }
    nonisolated static func hasRealtimeSignal(_ value: HafasDeparture) -> Bool {
        value.realtimeTime != nil || value.cancelled == true || value.reachable == false
            || value.passlist.values.contains {
                $0.realtimeArrivalTime != nil || $0.realtimeDepartureTime != nil
                    || $0.cancelled == true || $0.realtimeBoarding == false || $0.realtimeAlighting == false
            }
    }
}
