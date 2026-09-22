# Realtime routing

Realtime is an overlay on the immutable GTFS snapshot, not a post-processing
delay label. A `RealtimeRoutingProvider` supplies high-confidence, matched
`RealtimeTripPatch` values. The query-time scan merges each patch's effective
events with scheduled events, while retaining both for presentation.

The coordinator asks providers for a scheduled-time lookback window before the
query anchor. This permits a trip scheduled in the past, but delayed into the
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

Each unique frontier stop contributes at most one departure-board request for
the covered interval. Requests include pass lists, run at a maximum of four at
a time, and share one four-second deadline. A 60-second interval-aware cache is
used by default; pass `.forceRefresh` when the user explicitly starts or
refreshes a calculation.

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
service date remains authoritative for after-midnight trips. A reported delay
at the boarding event is propagated once to later events as an estimate;
cancellations and unreachable journeys mask the complete trip instance.

RAPTOR evaluates walking access and transfers against effective times. This
means a vehicle scheduled before a rider reaches a stop can still be boarded
when its reported delay leaves enough walking or station-transfer time. A
delay on the arriving vehicle can likewise invalidate a formerly valid
connection.
