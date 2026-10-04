# Realtime routing

Realtime is an overlay on the immutable GTFS snapshot, not a post-processing
delay label. A `RealtimeRoutingProvider` supplies high-confidence, matched
`RealtimeTripPatch` values. The query-time scan merges each patch's effective
events with scheduled events, while retaining both for presentation.

The coordinator starts ATP boards at the query's effective-time anchor and
passes a separate GTFS scheduled-time lookback (two hours by default). This permits a trip scheduled in the past, but delayed into the
future, to be boarded when its **effective** departure is catchable. Effective
times govern boardability, transfer feasibility, dominance, and page ordering.
Cancelled and unreachable patches mask their scheduled trip instance.

Live data is optional. A provider failure returns ordinary GTFS routing and a
page state of `unavailable`; it never makes the static timetable unusable.

## Use the HAFAS provider

`HafasRealtimeRoutingProvider` uses the configured `MobiliteitAPIClient` and
the same installed GTFS database as `TransitRouter`:

```swift
let client = MobiliteitAPIClient(apiKey: apiKey)
let realtime = try HafasRealtimeRoutingProvider(
    databaseURL: databaseURL,
    client: client,
    maximumConcurrentBoardRequests: 4,
    cacheLifetime: 60
)
let router = try await TransitRouter(
    databaseURL: databaseURL,
    realtimeProvider: realtime
)
```

Boards request `SERVER_DEFAULT`, `passlist=1`, and `maxJourneys=-1`.
Acquisition targets reachable boarding occurrences and their effective departure
windows for the current search or page. Adjacent windows merge into unrestricted
boards; only ATP's 1,439-minute duration limit requires splitting. A report from
another stop does not cover an occurrence that still lacks a fresh departure
prediction. Destination-aware discovery includes delayed departures and transfers
absent from scheduled winners, then applies acquired predictions in RAPTOR.
The first RAPTOR scan identifies the candidate page before network acquisition.
Every transit leg in that page gets acquisition priority, including walking and
in-seat connections, without discovery's stop or temporal-seed caps. Only the
remaining acquisition time is used for broad discovery, bounded to four waves
and 24 stop targets including already-checked itinerary stops.
Its windows include the permitted two-hour delay range, clipped to the search
horizon. Shared board coverage still avoids duplicate downloads.

Raw observations remain available to discovery even when a sparse, long-trip
overlay cannot yet be resolved into a complete usable timeline. Later stop
reports can complete that overlay without losing the earlier evidence.

New predictions trigger another RAPTOR scan so connecting-trip delays,
cancellations and restrictions affect feasibility and ranking before publication.
Replacement itineraries can acquire previously unseen boardings, for up to four
completion waves; each occurrence is attempted once per calculation. At most
four stop acquisitions run concurrently. The package's total acquisition budget
is four seconds by default; the host can select two seconds. Routing scan time
is measured separately. Unavailable, unmatched or expired reports remain honestly
scheduled or partial; incomplete acquisition never implies live coverage.

Each provider wave reserves a quarter of its remaining time (up to 500 ms)
for matching completed boards to GTFS. Board acquisition stops at that earlier
cutoff, retaining completed slices and marking unfinished coverage partial.
A slow later slice therefore does not discard predictions or cancellations
that already arrived. Matching still stops at the original shared deadline.

The shared departure-board cache reuses fresh compatible interval coverage
across stop boards and routing, fetches uncovered gaps, coalesces overlapping
in-flight requests, and permits independent caller cancellation. Fresh cached
coverage is acquired first so unrelated slow network requests cannot occupy all
request slots until the deadline and hide an already-available live board. Entries expire
60 seconds after their original acquisition and are evicted within a bounded
capacity. Endpoint, credentials, station, language, filters, realtime mode and
passlist availability isolate coverage. Truncated boards do not provide complete
unrestricted coverage. An explicit refresh bypasses completed evidence and older
responses cannot replace refreshed coverage.

Normal searches use `.useCache`. Pass `.forceRefresh` for an explicit refresh.
`RealtimeRoutingRequest.targets` optionally supplies per-stop windows; providers
implementing only the original method continue receiving its global bounds.
Paging retains fresh observations and checks missing coverage for newly explored
occurrences. New evidence revalidates accumulated results within the active
planning generation, including cancellations, transfers, timings and ranking.
Cancelled or superseded operations cannot publish results.

```swift
let query = RouteQuery(
    origin: origin,
    destination: destination,
    departureTime: .now,
    realtimePolicy: .bestEffort(refresh: .forceRefresh)
)
```

The provider only applies a live journey when one GTFS trip instance is the
unique best match by service date, stop, scheduled time, line, destination, and
monotonic pass-list alignment. Ambiguous data is ignored. The matched GTFS
service date remains authoritative for after-midnight trips. Wall times in
the repeated autumn DST hour are ignored until ATP provides a verified offset
contract; they cannot identify an unambiguous trip instance. Arrival and
departure predictions are matched independently at each stop occurrence using
GTFS stop sequence, preserving repeated stops and delay recovery. Missing
predictions propagate only forward from a preceding report, for up to 30
minutes and delays of at most two hours, and are marked estimated. Earlier
unobserved stops stay scheduled. Per-stop cancellations and boarding/alighting
restrictions disable that stop event while keeping the vehicle available
elsewhere; whole-journey cancellations and unreachable journeys mask the trip.

At a stop with a reported departure but no reported arrival, an arrival later
than that departure is constrained to the departure and marked estimated.
This handles ATP minute precision versus GTFS seconds and sparse delay recovery
without discarding a valid report. Scheduled times remain intact, and conflicting
reported arrival/departure times are still rejected.

Overlapping boards merge by trip, service date and stop sequence, preferring
reported predictions over estimates, then newer observations. Non-monotonic
active predictions and ambiguous matches are ignored. `RoutingMetrics` includes
network requests, cache hits, bytes, coverage, and reported-event counts.
`RoutingDiagnostics.realtimeMatchingRejections` separates unmatched, ambiguous,
invalid and expired matching attempts from missing acquisition.

RAPTOR evaluates walking access and transfers against effective times. This
means a vehicle scheduled before a rider reaches a stop can still be boarded
when its reported delay leaves enough walking or station-transfer time. A
delay on the arriving vehicle can likewise invalidate a formerly valid
connection.
