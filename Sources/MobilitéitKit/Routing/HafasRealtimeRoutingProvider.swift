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
        var observations: [String: Date] = [:]
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
    let cacheLifetime: TimeInterval
    let requestTimeout: Duration
    let now: @Sendable () -> Date
    let fullTimestampFormatter: DateFormatter
    let minuteTimestampFormatter: DateFormatter
    var timestampCache: [String: Date] = [:]
    var invalidTimestamps: Set<String> = []
    var normalizedNames: [String: String] = [:]
    var serviceDayStarts: [GTFSDate: Date] = [:]
    var schedulesByStopID: [String: ScheduleCache] = [:]
    var matchedJourneys: [String: MatchedJourney] = [:]
    var stopTimesByTripID: [String: [TripStopTime]] = [:]
    var stopTimeCacheOrder: [String] = []
    let maximumCachedTripStopTimes = 512

    public init(databaseURL: URL, client: MobiliteitAPIClient,
                maximumConcurrentBoardRequests: Int = 4,
                cacheLifetime: TimeInterval = 60, requestTimeout: Duration = .seconds(4)) throws {
        self.store = try GTFSStore(databaseAt: databaseURL)
        self.client = client
        self.maximumConcurrentBoardRequests = max(1, maximumConcurrentBoardRequests)
        self.cacheLifetime = max(0, cacheLifetime)
        self.requestTimeout = requestTimeout
        self.now = { .now }
        fullTimestampFormatter = Self.makeFormatter("yyyy-MM-dd HH:mm:ss")
        minuteTimestampFormatter = Self.makeFormatter("yyyy-MM-dd HH:mm")
    }

    init(store: GTFSStore, client: MobiliteitAPIClient, maximumConcurrentBoardRequests: Int = 4,
         cacheLifetime: TimeInterval = 60, requestTimeout: Duration = .seconds(4),
         now: @escaping @Sendable () -> Date) {
        self.store = store; self.client = client
        self.maximumConcurrentBoardRequests = max(1, maximumConcurrentBoardRequests)
        self.cacheLifetime = max(0, cacheLifetime); self.requestTimeout = requestTimeout
        self.now = now
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
        clearMatchingMemoization()
        defer { clearMatchingMemoization() }
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
        let fetched = await boards(for: stopIDs, request: request, deadline: acquisitionDeadline)
        let fetchMilliseconds = Self.milliseconds(started.duration(to: .now))
        let prepared = await schedules
        try Task.checkCancellation()
        let matchingStarted = ContinuousClock.now
        var patches: [String: RealtimeTripPatch] = [:]
        var unfinished = Set<String>()
        var rejections: [RealtimeMatchingRejection: Int] = [:]
        for stopID in stopIDs {
            guard ContinuousClock.now < deadline else { unfinished.insert(stopID); continue }
            guard let result = fetched[stopID], let board = result.board else { continue }
            let scheduled = prepared.byStopID[stopID] ?? []
            let desired = request.tripIDs.isEmpty ? [] : scheduled.filter { request.tripIDs.contains($0.departure.tripID) }
            for live in board.departures.values {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { unfinished.insert(stopID); break }
                guard Self.hasRealtimeSignal(live) else { continue }
                guard let planned = date(date: live.plannedDate, time: live.plannedTime) else {
                    rejections[.invalidTimestamp, default: 0] += 1; continue
                }
                guard planned >= matchingFrom.addingTimeInterval(-90),
                      planned <= request.through.addingTimeInterval(90) else {
                    rejections[.outsideInterval, default: 0] += 1; continue
                }
                if !request.tripIDs.isEmpty,
                   !desired.contains(where: { abs($0.scheduledDate.timeIntervalSince(planned)) <= 90 }) { continue }
                let reference = live.journeyReference?.reference
                let cached = reference.flatMap { matchedJourneys[$0] }
                let reused = cached.flatMap { match -> Candidate? in
                    guard now().timeIntervalSince(match.fetchedAt) <= cacheLifetime,
                          let value = scheduled.first(where: {
                              $0.departure.tripID == match.tripID && $0.serviceDate == match.serviceDate
                                  && abs($0.scheduledDate.timeIntervalSince(planned)) <= 90
                          }) else { return nil }
                    return .init(departure: value.departure, serviceDate: value.serviceDate,
                                 scheduledDate: value.scheduledDate, score: 0)
                }
                let candidate: Candidate?
                if let reused { candidate = reused }
                else {
                    switch await uniqueCandidate(for: live, planned: planned, scheduled: scheduled, deadline: deadline) {
                    case let .success(value): candidate = value
                    case let .failure(error):
                        rejections[error.reason, default: 0] += 1; candidate = nil
                    }
                }
                guard ContinuousClock.now < deadline else { unfinished.insert(stopID); break }
                guard let candidate else { continue }
                // Resolve ambiguity against the complete timetable first.
                guard request.tripIDs.isEmpty || request.tripIDs.contains(candidate.departure.tripID) else { continue }
                guard let update = await patch(for: live, candidate: candidate,
                                               boardingStopID: stopID, observedAt: result.observations[live.cacheIdentity] ?? result.fetchedAt, deadline: deadline)
                else { rejections[.invalidTripTimeline, default: 0] += 1; continue }
                guard ContinuousClock.now < deadline else { unfinished.insert(stopID); break }
                if let reference {
                    matchedJourneys[reference] = .init(tripID: candidate.departure.tripID,
                                                       serviceDate: candidate.serviceDate,
                                                       fetchedAt: result.observations[live.cacheIdentity] ?? result.fetchedAt)
                }
                let key = "\(update.tripID)@\(update.serviceDate.compactString)"
                patches[key] = patches[key].map { $0.merging(update) } ?? update
            }
            if ContinuousClock.now >= deadline { unfinished.insert(stopID) }
        }
        if matchedJourneys.count > 512 {
            matchedJourneys = Dictionary(uniqueKeysWithValues: matchedJourneys.sorted {
                $0.value.fetchedAt > $1.value.fetchedAt
            }.prefix(512).map { ($0.key, $0.value) })
        }
        return .init(patches: patches.values.sorted { ($0.serviceDate, $0.tripID) < ($1.serviceDate, $1.tripID) },
                     requestedStopIDs: requested, coveredStopIDs: Set(fetched.values.filter { $0.board != nil }.map(\.stopID)),
                     boardFetchMilliseconds: fetchMilliseconds,
                     scheduledPreparationMilliseconds: prepared.milliseconds,
                     boardMatchingMilliseconds: Self.milliseconds(matchingStarted.duration(to: .now)),
                     networkRequests: fetched.values.reduce(0) { $0 + $1.requests },
                     cacheHits: fetched.values.reduce(0) { $0 + $1.hits },
                     responseBytes: fetched.values.reduce(0) { $0 + $1.bytes },
                     incompleteStopIDs: Set(fetched.values.filter(\.incomplete).map(\.stopID)).union(unfinished).union(requested.subtracting(prepared.byStopID.keys)),
                     fetchedAt: fetched.values.map(\.fetchedAt).min(),
                     httpMilliseconds: fetched.values.reduce(0) { $0 + $1.httpMilliseconds },
                     decodeMilliseconds: fetched.values.reduce(0) { $0 + $1.decodeMilliseconds },
                     matchingRejections: rejections)
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

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
    nonisolated static func hasRealtimeSignal(_ value: HafasDeparture) -> Bool {
        value.realtimeTime != nil || value.cancelled == true || value.reachable == false
            || value.passlist.values.contains {
                $0.realtimeArrivalTime != nil || $0.realtimeDepartureTime != nil
                    || $0.cancelled == true || $0.realtimeBoarding == false || $0.realtimeAlighting == false
            }
    }
}
