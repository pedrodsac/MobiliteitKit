import Foundation

extension HafasRealtimeRoutingProvider {
    /// Mutable results of one batch's ordered merge.
    struct MatchingState {
        var patches: [String: RealtimeTripPatch] = [:]
        var unfinished = Set<String>()
        var rejections: [RealtimeMatchingRejection: Int] = [:]
        var workMilliseconds = 0.0
    }

    /// What every board of a batch is matched with.
    struct MatchingContext {
        let prepared: PreparedSchedules
        let request: RealtimeRoutingRequest
        let matchingFrom: Date
        let deadline: ContinuousClock.Instant
    }

    /// A candidate and the patch that follows from it; `patch` is nil when the timeline is invalid.
    struct PatchedCandidate {
        let candidate: Candidate
        let patch: RealtimeTripPatch?
    }

    /// One live departure with what the timetable says about it, independent of other boards.
    struct ResolvedRow {
        let live: HafasDeparture
        let reference: String?
        let planned: Date
        let observedAt: Date
        /// The unique-candidate outcome; nil when the reuse cache supplied the candidate.
        var unique: Result<Candidate, RealtimeMatchingFailure>?
        /// The chosen candidate with its patch; nil when no candidate was chosen.
        var patched: PatchedCandidate?
    }

    enum ResolvedEntry {
        case rejection(RealtimeMatchingRejection)
        case row(ResolvedRow)
    }

    /// A board resolved against the timetable, waiting for its turn in the ordered merge.
    struct ResolvedBoard {
        var entries: [ResolvedEntry] = []
        /// False when the deadline cut the board short.
        var finished = true
        var arrived: ContinuousClock.Instant?
        let started: ContinuousClock.Instant
    }

    /// A batch's matching. Boards are resolved in the order they arrive; the steps that read or write
    /// `matchedJourneys` and merge patches run strictly in request order.
    struct OrderedMatching {
        let stopIDs: [String]
        var state = MatchingState()
        var waiting: [String: ResolvedBoard] = [:]
        var merged = 0
        var boards: [RealtimeBatchTimings.Board] = []
        var started: ContinuousClock.Instant?
        var finished: ContinuousClock.Instant?
        init(stopIDs: [String]) { self.stopIDs = stopIDs }
    }

    /// Resolves one stop's board, which may arrive before the boards of the stops ahead of it.
    func resolve(stopID: String, result: BoardResult?, in context: MatchingContext,
                 ordered: inout OrderedMatching) async throws {
        let started = ContinuousClock.now
        if ordered.started == nil { ordered.started = started }
        var board = ResolvedBoard(arrived: result?.arrivedAt, started: started)
        try await resolveRows(of: result, stopID: stopID, in: context, into: &board)
        ordered.state.workMilliseconds += Self.fractionalMilliseconds(started.duration(to: .now))
        ordered.waiting[stopID] = board
    }

    /// Merges every resolved board whose predecessors in request order are merged.
    func mergeReadyBoards(_ ordered: inout OrderedMatching, in context: MatchingContext) async throws {
        while ordered.merged < ordered.stopIDs.count,
              let board = ordered.waiting.removeValue(forKey: ordered.stopIDs[ordered.merged]) {
            try Task.checkCancellation()
            let stopID = ordered.stopIDs[ordered.merged]
            let started = ContinuousClock.now
            await merge(board, stopID: stopID, in: context, into: &ordered.state)
            let finished = ContinuousClock.now
            ordered.state.workMilliseconds += Self.fractionalMilliseconds(started.duration(to: finished))
            ordered.finished = finished
            ordered.boards.append(.init(stopID: stopID, arrived: board.arrived,
                                        matchingStarted: board.started, matchingFinished: finished))
            ordered.merged += 1
        }
    }

    /// The candidate an earlier match of the same journey reference supplies, if still fresh.
    private func reusableCandidate(reference: String?, planned: Date, scheduled: [PreparedDeparture]) -> Candidate? {
        guard let cached = reference.flatMap({ matchedJourneys[$0] }),
              now().timeIntervalSince(cached.fetchedAt) <= cacheLifetime,
              let value = scheduled.first(where: {
                  $0.departure.tripID == cached.tripID && $0.serviceDate == cached.serviceDate
                      && abs($0.scheduledDate.timeIntervalSince(planned)) <= 90
              }) else { return nil }
        return .init(departure: value.departure, serviceDate: value.serviceDate,
                     scheduledDate: value.scheduledDate, score: 0)
    }

    /// Works out every departure's candidate and patch from board-local data. The reuse cache only
    /// decides which work to skip; the ordered merge decides again, so the order boards arrive in
    /// never changes a result.
    private func resolveRows(of result: BoardResult?, stopID: String, in context: MatchingContext,
                             into resolved: inout ResolvedBoard) async throws {
        let request = context.request, deadline = context.deadline
        guard matchingNow() < deadline else { resolved.finished = false; return }
        guard let result, let board = result.board else { return }
        let scheduled = context.prepared.byStopID[stopID] ?? []
        let desired = request.tripIDs.isEmpty ? [] : scheduled.filter { request.tripIDs.contains($0.departure.tripID) }
        for live in board.departures.values {
            try Task.checkCancellation()
            guard matchingNow() < deadline else { resolved.finished = false; break }
            guard request.includeTripMetadata || Self.hasRealtimeSignal(live) else { continue }
            guard let planned = date(date: live.plannedDate, time: live.plannedTime) else {
                resolved.entries.append(.rejection(.invalidTimestamp)); continue
            }
            guard planned >= context.matchingFrom.addingTimeInterval(-90),
                  planned <= request.through.addingTimeInterval(90) else {
                resolved.entries.append(.rejection(.outsideInterval)); continue
            }
            if !request.tripIDs.isEmpty,
               !desired.contains(where: { abs($0.scheduledDate.timeIntervalSince(planned)) <= 90 }) { continue }
            var row = ResolvedRow(live: live, reference: live.journeyReference?.reference, planned: planned,
                                  observedAt: result.observations[live.cacheIdentity] ?? result.fetchedAt)
            let reusable = reusableCandidate(reference: row.reference, planned: planned, scheduled: scheduled)
            if reusable == nil {
                row.unique = await uniqueCandidate(for: live, planned: planned, scheduled: scheduled, deadline: deadline)
            }
            guard matchingNow() < deadline else {
                if case let .failure(error)? = row.unique { resolved.entries.append(.rejection(error.reason)) }
                resolved.finished = false; break
            }
            let chosen: Candidate? = if let reusable { reusable } else if case let .success(value)? = row.unique { value } else { nil }
            if let chosen, request.tripIDs.isEmpty || request.tripIDs.contains(chosen.departure.tripID) {
                let patch = await patch(for: live, candidate: chosen, boardingStopID: stopID,
                                        observedAt: row.observedAt, deadline: deadline)
                guard matchingNow() < deadline else {
                    if patch == nil { resolved.entries.append(.rejection(.invalidTripTimeline)) }
                    resolved.finished = false; break
                }
                row.patched = .init(candidate: chosen, patch: patch)
            }
            resolved.entries.append(.row(row))
        }
        if matchingNow() >= deadline { resolved.finished = false }
    }

    /// Applies one resolved board to the batch. Reads and writes `matchedJourneys`, so callers must
    /// merge stops in request order.
    private func merge(_ board: ResolvedBoard, stopID: String, in context: MatchingContext,
                       into state: inout MatchingState) async {
        let scheduled = context.prepared.byStopID[stopID] ?? []
        for entry in board.entries {
            switch entry {
            case let .rejection(reason): state.rejections[reason, default: 0] += 1
            case let .row(row):
                guard await merge(row, stopID: stopID, scheduled: scheduled, in: context, into: &state)
                else { state.unfinished.insert(stopID); return }
            }
        }
        if !board.finished { state.unfinished.insert(stopID) }
    }

    /// Returns false when the deadline ended work that only the merge could do.
    private func merge(_ row: ResolvedRow, stopID: String, scheduled: [PreparedDeparture],
                       in context: MatchingContext, into state: inout MatchingState) async -> Bool {
        let request = context.request, deadline = context.deadline
        let candidate: Candidate?
        if let reused = reusableCandidate(reference: row.reference, planned: row.planned, scheduled: scheduled) {
            candidate = reused
        } else {
            let unique: Result<Candidate, RealtimeMatchingFailure>
            if let resolved = row.unique {
                unique = resolved
            } else {
                unique = await uniqueCandidate(for: row.live, planned: row.planned, scheduled: scheduled, deadline: deadline)
                guard matchingNow() < deadline else { return false }
            }
            switch unique {
            case let .success(value): candidate = value
            case let .failure(error): state.rejections[error.reason, default: 0] += 1; candidate = nil
            }
        }
        guard let candidate else { return true }
        // Resolve ambiguity against the complete timetable first.
        guard request.tripIDs.isEmpty || request.tripIDs.contains(candidate.departure.tripID) else { return true }
        let update: RealtimeTripPatch?
        if let patched = row.patched, patched.candidate.hasSameTrip(as: candidate) {
            update = patched.patch
        } else {
            update = await patch(for: row.live, candidate: candidate, boardingStopID: stopID,
                                 observedAt: row.observedAt, deadline: deadline)
            guard matchingNow() < deadline else { return false }
        }
        guard let update else { state.rejections[.invalidTripTimeline, default: 0] += 1; return true }
        if let reference = row.reference {
            matchedJourneys[reference] = .init(tripID: candidate.departure.tripID,
                                               serviceDate: candidate.serviceDate, fetchedAt: row.observedAt)
        }
        let key = "\(update.tripID)@\(update.serviceDate.compactString)"
        state.patches[key] = state.patches[key].map { $0.merging(update) } ?? update
        return true
    }
}

extension HafasRealtimeRoutingProvider.Candidate {
    /// A patch depends on these fields alone, so a patch made for one candidate serves the other.
    fileprivate func hasSameTrip(as other: Self) -> Bool {
        departure.tripID == other.departure.tripID && serviceDate == other.serviceDate
            && scheduledDate == other.scheduledDate
    }
}
