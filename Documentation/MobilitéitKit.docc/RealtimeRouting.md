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

Boards request `SERVER_DEFAULT` and `passlist=1`. Acquisition covers up to
90 minutes in 30-minute slices with at most 50 journeys each. Full slices are
split, up to eight requests per stop; exhausted slices are explicitly incomplete.
Destination-aware discovery queries access stops and reachable outgoing trips,
including delayed departures absent from static winners, before a final RAPTOR
scan. Discovery carries its optimistic envelope forward one ride per wave,
avoiding repeated scans of prior waves. It stops after four waves, 24 stop targets, or one shared four-second
deadline; at most four requests run concurrently. Coverage outside those bounds
remains partial.

The shared request cache coalesces in-flight requests, lets waiters cancel
independently, and expires after 60 seconds. The provider's bounded caches reuse
only complete intervals that contain the request. Pass `.forceRefresh` to
bypass both caches when starting or refreshing a calculation. GTFS candidate
and matched journey-reference caches avoid repeated preparation and matching;
a reference never suppresses a later, better observation of the same vehicle.

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

Overlapping boards merge by trip, service date and stop sequence, preferring
reported predictions over estimates, then newer observations. Non-monotonic
active predictions and ambiguous matches are ignored. `RoutingMetrics` includes
network requests, cache hits, bytes, coverage, and reported-event counts.

RAPTOR evaluates walking access and transfers against effective times. This
means a vehicle scheduled before a rider reaches a stop can still be boarded
when its reported delay leaves enough walking or station-transfer time. A
delay on the arriving vehicle can likewise invalidate a formerly valid
connection.
