# MobilitéitKit On-Device Journey Planner
## Codex implementation specification

**Status:** implementation-ready design specification  
**Date:** 2026-09-07  
**Revision:** 2 — realtime catch-up / delayed-past-trip injection  
**Target:** Swift / iOS application, app deployment target iOS 26  
**Primary package:** `MobiliteitKit`  
**Static source:** GTFS imported by MobiliteitKit  
**Live source:** Mobilitéit HAFAS API exposed by `MobiliteitAPIClient`  
**Walking/address source:** Apple MapKit  

---

# 0. Instruction to Codex

Build the journey-planning engine described in this document inside **MobiliteitKit**, with MapKit and HAFAS integrations kept behind explicit interfaces so that the timetable core remains deterministic and testable.

Do not replace this design with a generic Dijkstra implementation over a naïve time-expanded graph. Do not route by recursively calling HAFAS departure boards. Do not execute thousands of SQLite queries from the inner routing loop. Do not treat GTFS `route_id` as a RAPTOR route pattern. Do not assume GTFS stop IDs and HAFAS stop IDs are the same.

The implementation must optimize for four things, in this order:

1. **Correct journey semantics** according to the product rules in this document.
2. **Very low on-device CPU latency** once walking information is available.
3. **Graceful degradation** when MapKit or HAFAS is unavailable.
4. **Maintainable Swift 6 concurrency**, with no data races and no actor hops inside hot timetable loops.

Start with correctness and a measurable, cache-friendly RAPTOR core. Do not prematurely parallelize route-pattern scans. The timetable network is small enough that one well-written cache-friendly CPU task should generally beat a synchronization-heavy parallel implementation. Use concurrency aggressively for independent MapKit and HAFAS network work.

The current attached MobiliteitKit source is the baseline. Preserve existing public APIs unless a change is required; add new APIs rather than unnecessarily breaking old ones.

**Revision-2 critical requirement:** do not implement realtime as only “patch the static journeys we already found.” The engine must discover delayed vehicles whose scheduled departure is already in the past but whose effective realtime departure remains catchable, including at transfers. Sections 1.12A, 13, 18, and tests 24.33–24.40 are mandatory acceptance criteria.

---

# 1. Product behavior: non-negotiable requirements

These rules are product requirements, not suggestions.

## 1.1 Inputs

A user selects:

- an origin bus/train/tram/funicular stop; or
- an origin address/place resolved through MapKit; and
- a destination stop; or
- a destination address/place resolved through MapKit; and
- a departure time.

The routing engine itself should not own text-address autocomplete. The app resolves an address or place to a coordinate/label using MapKit, then passes a resolved endpoint into MobiliteitKit.

A selected transit stop still has a coordinate. The engine may discover that walking from that stop to another nearby transit stop produces a better journey. The fact that the user selected a stop does not mean the first transit vehicle must board at that exact stop.

## 1.2 Meaning of “fastest”

For a leave-after query at time `T`:

> Find the journey that reaches the destination as early as possible, where the user does not have to leave the origin before `T`.

This is **earliest arrival subject to departure >= T**.

When realtime is enabled, the feasibility comparison uses the journey's **effective realtime door departure**, not only its scheduled GTFS departure. A vehicle whose scheduled departure is already in the past may still be catchable if HAFAS predicts that it has not yet departed.

It is not “minimum in-vehicle time” and it is not simply “take the next vehicle.”

## 1.3 Door-to-door timestamps

For an address/coordinate origin, the journey departure is the time the user must start walking from the origin, not the first vehicle's departure.

Example:

- walk from home: 7 minutes
- bus departs: 17:12
- latest feasible time to leave home: 17:05

The journey's departure time is **17:05**.

For an address/coordinate destination, the journey arrival is the time the user finishes the final walk at the destination, not the transit alighting time.

For a stop endpoint, access/egress can be zero when the selected stop itself is used, but alternative nearby-stop walking access/egress is allowed.

## 1.4 Initial result count

Return **5 journeys** for the initial screen when at least 5 qualifying journeys exist.

They must represent the journey profile moving forward in time, rather than five arbitrary route variants for the same request.

The first item is the fastest/earliest-arriving usable journey. Subsequent items are the next useful journeys that can be taken if earlier options are missed.

## 1.5 Strict discard rule

The user's rule is intentionally stricter than textbook weak Pareto dominance.

Journey `A` discards journey `B` only when **both** are true:

```text
A.departure > B.departure
AND
A.arrival   < B.arrival
```

In words: `A` lets the user leave **strictly later** and arrive **strictly earlier**.

Only then is `B` useless and removed.

Do **not** discard on equality.

Examples:

| Journey | Departure | Arrival | Keep? |
|---|---:|---:|---|
| A | 17:10 | 17:40 | yes |
| B | 17:00 | 17:45 | no — A strictly dominates B |

But:

| Journey | Departure | Arrival | Keep? |
|---|---:|---:|---|
| A | 17:10 | 17:40 | yes |
| B | 17:00 | 17:40 | yes — arrival is equal, not strictly earlier |

And:

| Journey | Departure | Arrival | Keep? |
|---|---:|---:|---|
| A | 17:00 | 17:35 | yes |
| B | 17:00 | 17:45 | yes — departure is equal |

This equality behavior is required because the user explicitly wants multiple routes that leave at the same time to remain visible.

This rule applies to the **final effective times** after realtime refinement when realtime is available.

## 1.6 Same-departure alternatives

If two useful journeys have the same door-to-door departure time, they may both be shown.

Do not collapse results by timestamp.

Within one exact departure cohort, sort by:

1. earlier arrival;
2. fewer transfers;
3. less walking;
4. shorter total duration;
5. deterministic journey signature.

The page cursor must therefore be an ordering cursor, not just a departure timestamp.

## 1.7 Later / Earlier

The route screen has:

- **Later**: append/generate the next **3** journeys after the last displayed journey.
- **Earlier**: prepend/generate the previous **3** journeys before the first displayed journey.

“After” and “before” refer to the deterministic profile ordering. Equal-departure journeys may be adjacent across a page boundary and must not be skipped.

The implementation must keep a session-level cursor/profile cache so repeated Later/Earlier taps do not restart every calculation from scratch.

## 1.8 Maximum transfers

Routing preferences include:

```swift
maxTransfers: Int?
```

Semantics:

- default: `3`
- `0`: only one transit vehicle; no transit-to-transit transfer
- `3`: up to four boarded transit legs
- `nil`: no explicit product limit

When `nil`, the algorithm must still terminate naturally when no label improves. It must not generate cyclic “ride around the network” alternatives.

An in-seat continuation where the rider remains on the same physical vehicle does **not** increment the transfer count.

## 1.9 Minimum transfer safety time

The user-configurable default minimum transfer time is:

```text
120 seconds
```

This is a safety buffer between transit legs, especially when operating from static GTFS without realtime.

It is separate from actual physical walking duration between different stops.

The exact transfer-rule behavior is specified later in this document.

## 1.10 Transport modes

By default include everything represented by the feed:

- bus
- tram
- rail/train
- funicular
- any other fixed-route GTFS mode that MobiliteitKit can represent

Architecture must allow mode filtering/avoidance later.

## 1.11 Direct walking journey

Always evaluate a direct origin-to-destination walking route with MapKit when MapKit directions are available.

Let:

- `W.duration` = direct MapKit walking duration
- `W.departure` = the explicit query anchor time `T`
- `W.arrival = T + W.duration`
- `minTransitDuration` = minimum door-to-door duration among candidate transit journeys
- `earliestTransitArrival` = earliest candidate transit arrival

Apply this product rule:

### Case A — walking is strictly shorter in total duration than every transit journey

If:

```text
W.duration < minTransitDuration
```

return **only the walking journey**.

Do not show slower transit alternatives on that result set.

### Case B — walking arrives first but at least one transit journey has a shorter total travel duration

If:

```text
W.arrival < earliestTransitArrival
AND
W.duration >= minTransitDuration
```

include the walking journey among the transit journeys.

Example: walking can leave immediately and arrive before a bus that has a long wait, while the bus itself has a shorter door-to-door duration once the user leaves for it.

### Case C — walking does not arrive first and is not the strictly shortest-duration option

Do not show the direct walking route.

### Pagination rule for direct walking

Direct walking is a special journey tied to the explicit search anchor. Do **not** synthesize an infinite sequence of “start walking 1 minute later” journeys for Later/Earlier pagination.

If Case A applies and walking is the only result, Later/Earlier should not manufacture transit results unless the app explicitly starts a new transit-only query mode in the future.

## 1.12 Offline behavior

The timetable core must work without HAFAS.

Stop-to-stop routing must remain useful using only installed GTFS and the user's transfer buffer.

Because Apple `MKDirections` is server-backed, **do not pretend arbitrary MapKit walking directions are available offline**. When MapKit cannot resolve a new walking leg:

- same-stop transfers can still use GTFS + user transfer buffer;
- GTFS `transfers.txt` rules with usable `min_transfer_time` can still be used;
- GTFS station pathways can still be used if imported;
- already-resolved in-memory walking information from the current session may be reused;
- do not invent a final walking duration from straight-line distance;
- an address route that requires unresolved MapKit access/egress may be unavailable offline.

This is the only honest way to satisfy both “use Apple Maps for walking” and “GTFS routing works offline.”

## 1.12A Realtime catch-up: scheduled-in-the-past but still catchable

This is a **required correctness behavior**, not an optional enhancement.

Example:

```text
query/door departure anchor:       18:00
Bus A scheduled departure:         17:50
Bus A realtime departure:          18:05  (+15 min)
Bus A effective destination:       18:30
Bus B scheduled/effective depart:  18:03
Bus B effective destination:       18:42
```

A static GTFS-only leave-after search at 18:00 would never examine Bus A because its scheduled departure is 17:50. The realtime router **must** be able to inject Bus A back into the active query because its effective departure is 18:05 and it is still physically catchable. Bus A should then win because it arrives at 18:30.

The same rule applies at transfers. If the passenger reaches an interchange at 18:20, the configured transfer requirement is 2 minutes, and a connecting vehicle was scheduled at 18:18 but is now predicted to depart at 18:24, the connection is catchable because:

```text
18:20 + 00:02 <= 18:24
```

Therefore:

- never use only scheduled departure ordering to decide that a realtime-patched trip is no longer boardable;
- maintain scheduled and effective event times separately;
- build a query-local realtime overlay that can surface a trip even when its scheduled event falls before the normal RAPTOR lower-bound search cursor;
- use effective timestamps for boarding feasibility, transfer feasibility, final dominance, final sorting, and Earlier/Later ordering whenever high-confidence realtime exists;
- keep the scheduled timestamps for display, provenance, matching, and offline fallback;
- if realtime is unavailable, revert cleanly to ordinary GTFS behavior.

The realtime provider cannot be queried from the RAPTOR hot loop. The engine must discover and fetch promising delayed-past services in bounded asynchronous waves, then rerun the pure synchronous RAPTOR core against an immutable realtime overlay snapshot. Section 13 defines this process.

## 1.13 Complete journey output

A final `Journey` must provide enough information for the app to render the full route screen and map:

- origin and destination
- scheduled door departure/arrival
- realtime/effective door departure/arrival when available
- total duration
- total walking time and distance
- total waiting time
- total in-vehicle time
- transfer count
- walking legs
- boarding/alighting stops
- every intermediate transit stop
- route/line information
- trip/headsign/direction display information
- operator
- platform where known
- scheduled times at relevant stops
- realtime times where known
- cancellation/reachability status
- GTFS transit shape section for each transit leg
- MapKit geometry for each final walking leg
- realtime provenance/confidence
- feed generation used to calculate it

---

# 2. Baseline analysis of the current MobiliteitKit package

The attached archive contains the MobiliteitKit Swift package at commit `56096a7` (`fix range fatal error`). Relevant existing source files are:

```text
Sources/MobilitéitKit/
  GTFSArchiveInstaller.swift
  GTFSStore.swift
  MobiliteitAPIClient.swift
  Models.swift
  SQLite.swift
  ShapeCodec.swift
  StreamingCSV.swift
```

The package already has several good foundations.

## 2.1 Existing GTFS strengths

The installer already:

- streams CSV instead of building a giant in-memory GTFS object graph;
- imports to SQLite;
- replaces the finished database atomically;
- converts major GTFS string IDs to compact integer SQLite IDs;
- preserves GTFS service-day times above `24:00:00` in `ServiceTime`;
- materializes active `service_date` rows;
- compresses shapes;
- creates an SQLite R-tree for stop coordinates;
- stores `frequencies.txt`;
- stores basic `transfers.txt` route/trip-specific fields;
- creates useful stop-time departure/arrival indexes.

The existing `GTFSStore` is an actor and is appropriate for ordinary bounded data queries.

## 2.2 Existing HAFAS strengths

`MobiliteitAPIClient` already:

- is async;
- is `Sendable`;
- supports the documented nearby-stops endpoint;
- supports the documented departure-board endpoint;
- supports realtime mode;
- can request pass lists;
- correctly treats a HAFAS station ID as opaque rather than assuming it equals the GTFS ID;
- normalizes HAFAS fields that alternate between one object and arrays.

Keep those decisions.

## 2.3 Why `GTFSStore` must not be the routing inner loop

Do not implement the router as code like this:

```text
for each possible stop:
    await store.scheduledDepartures(...)
    await store.stopTimes(...)
    await store.transferRules(...)
    ...
```

That architecture would cause:

- repeated SQLite statement preparation/execution;
- repeated string-ID lookups;
- actor serialization and actor-hop overhead;
- object allocation for values that the search immediately discards;
- poor memory locality;
- unnecessary joins during the hottest part of the algorithm.

`GTFSStore` should remain the canonical query/presentation store, but the journey router needs a **dedicated immutable routing snapshot** using dense numeric IDs and contiguous arrays.

## 2.4 Current importer limitations that matter to routing

Codex must address these before claiming a robust router.

### A. `calendar.txt` is currently mandatory

Current installer `required` includes `calendar.txt`.

GTFS allows `calendar.txt` to be omitted if `calendar_dates.txt` contains all service dates. The importer should support that valid form.

### B. `shapes.txt` is currently mandatory

GTFS defines `shapes.txt` as optional. Routing itself must not depend on shapes. Keep shapes when provided, but do not reject an otherwise routable feed solely because shapes are absent.

### C. transfer stop IDs are currently required even for linked trips

The current transfer schema uses:

```sql
from_stop_id INTEGER NOT NULL
to_stop_id   INTEGER NOT NULL
```

and the parser requires both columns/values.

Current GTFS transfer types `4` and `5` can have conditionally optional stop IDs and require linked trip IDs. Fix the schema/import logic.

### D. transfer-rule specificity must be implemented

GTFS transfer rules are not “take every matching row.” A route/trip-specific precedence order exists. The routing engine needs a resolver that chooses the maximally specific applicable rule for the arriving/departing trip pair.

### E. linked-trip transfer types 4/5 are not modeled semantically

Type `4` means in-seat continuation; type `5` explicitly forbids an in-seat continuation. Implement both.

### F. parent-station transfer semantics are not expanded/resolved

A transfer rule referencing a station applies to its child stops. The router must honor that.

### G. station pathways are not imported

Import `pathways.txt` and relevant station fields if present. MapKit is useful for outdoor walking, but GTFS pathways are the authoritative source for internal station movement such as stairs, fare gates, elevators and platform links.

### H. realtime pass-list stop model lacks realtime stop fields

`HafasPasslistStop` currently decodes planned `depTime`, `depDate`, `arrTime`, and `arrDate`, but common HAFAS StopType payloads also expose fields such as:

```text
rtDepTime
rtDepDate
rtArrTime
rtArrDate
rtDepTrack
rtArrTrack
cancelled
boarding / alighting
rtBoarding / rtAlighting
```

Add decoding for fields that the Mobilitéit endpoint actually returns. Keep them optional and add fixtures. Do not assume every HAFAS installation returns every field.

### I. routing needs shape-position information

To draw only the relevant section of a trip shape, import `stop_times.shape_dist_traveled` when present. If absent, provide a monotonic nearest-point shape matcher for final journey materialization.

### J. routing needs `timepoint`

Import `stop_times.timepoint` so approximate times can be marked correctly.

### K. pickup/drop-off types need exact semantics

Do not treat every value other than `1` as ordinary boardable/alightable service.

GTFS values `2` and `3` require rider action. Architecture should retain them and expose a policy. Default fixed-route journey planning may include them only when the app explicitly supports request/coordination behavior; otherwise filter them out with a reason rather than silently treating them as regular pickup.

---

# 3. External-source constraints

## 3.1 Mobilitéit HAFAS API

The documentation repository supplied by the user documents two relevant endpoints:

1. `location.nearbystops`
2. `departureBoard`

It does **not** document a trip-planning endpoint.

Therefore:

- GTFS is the network/timetable routing source.
- HAFAS is a realtime refinement source.
- Never recursively explore departure boards as the routing algorithm.

The public documentation historically mentions default request quotas around 500/hour and 5000/day. Treat quota values as deployment-specific and potentially changed; the app/relay configuration is already handled by the host project. Nonetheless, the client must deduplicate and batch live requests because route planning should not create one API request per candidate trip.

## 3.2 MapKit

Use `MKDirections.Request` with:

```swift
request.transportType = .walking
```

For candidate cost resolution, prefer `calculateETA()` when only distance/time is needed.

For walking legs that will be displayed, use `calculate()` so the app gets an `MKRoute` and its polyline/steps. Convert MapKit objects into MobiliteitKit value types before they cross package concurrency boundaries.

Apple documents that `MKDirections` is server-backed and that frequent requests in a short period can produce `MKError.Code.loadingThrottled`.

Therefore:

- use bounded concurrency;
- deduplicate identical requests;
- use lazy walking-edge resolution rather than exhaustively requesting every stop pair;
- cancel stale directions when the user changes a query;
- treat throttling as a recoverable degraded-data condition;
- never make final route claims based on an unresolved geometric estimate.

---

# 4. Core algorithm decision

## 4.1 Use RAPTOR for timetable routing

The core timetable algorithm should be RAPTOR-family routing.

Reasons:

- public-transit schedules are its native data model;
- transfer count corresponds naturally to rounds;
- no Dijkstra heap is needed in the hot timetable scan;
- route patterns can be scanned in contiguous memory;
- realtime modifications are straightforward to overlay;
- max transfers is a natural query parameter;
- it is proven suitable for interactive transit routing;
- the Luxembourg network is small enough that a carefully implemented RAPTOR scan should be extremely fast on a modern iPhone.

## 4.2 Do not make full Range RAPTOR a v1 requirement

A full rRAPTOR implementation is valid, but the product has an unusual strict dominance rule and must preserve equal-departure options. A simpler profile iterator can produce the required result sequence from a highly optimized point RAPTOR core.

Implement:

```text
Optimized point RAPTOR
        +
event-driven profile iterator
        +
one-result-cohort lookahead
        +
same-departure alternative expansion
```

This has several advantages:

- much simpler correctness reasoning;
- naturally supports the exact Later semantics;
- naturally applies the user's strict domination rule;
- easy cancellation and incremental pagination;
- reuses the same walking/realtime snapshot;
- only a small number of CPU RAPTOR scans is needed for 5 or 3 results.

Keep a protocol boundary such as:

```swift
protocol TimetableProfileEngine: Sendable { ... }
```

so a true Range RAPTOR implementation can replace the iterator later if real-device benchmarks show the CPU core is a bottleneck. Do not implement rRAPTOR just for academic purity if repeated point scans are already sub-frame.

## 4.3 Why not CSA as the primary engine

CSA is excellent for earliest arrival and has very cache-friendly connection arrays. It remains a reasonable fallback/benchmark implementation.

RAPTOR is preferred because:

- transfer limits are first-class;
- route reconstruction by transit legs is natural;
- transfer-round alternatives are useful to preserve direct-vs-transfer choices;
- realtime trip changes fit well;
- route-pattern based pruning is a better fit for this app's preferences.

## 4.4 Why not a time-expanded graph

Do not materialize every stop event as graph vertices and run generic Dijkstra/A*.

It increases memory, complicates updates, and adds heap/edge traversal overhead without providing a product advantage on this network.

---

# 5. Time model — this must be correct before routing

Time handling is one of the easiest places to make a planner appear correct while producing wrong midnight/DST results.

## 5.1 Keep service time as integer seconds

Continue using `ServiceTime`-style values that can exceed 24 hours.

For hot routing data use `Int32` service seconds.

For comparisons across service days use an `Int64` nominal GTFS timeline:

```swift
absoluteServiceSecond = Int64(serviceDayIndex) * 86_400 + Int64(serviceTime)
```

This is an ordering coordinate, not a Unix timestamp.

## 5.2 GTFS DST semantics

GTFS defines Time relative to “noon minus 12 hours” of the service day, specifically so DST transition days remain unambiguous.

Do not convert a GTFS time by simply creating local midnight and adding wall-clock components.

Implement a single tested conversion utility:

```swift
struct ServiceInstantConverter {
    let timeZone: TimeZone

    func date(serviceDate: GTFSDate, serviceSeconds: Int32) -> Date
    func possibleServiceInstants(for date: Date, maximumServiceTime: Int32) -> [ServiceInstant]
}
```

Conversion to `Date`:

1. create local **12:00 noon** for the service date in the agency timezone;
2. convert it to an absolute `Date`;
3. subtract 12 *elapsed* hours to obtain the GTFS anchor;
4. add `serviceSeconds` as elapsed seconds.

Do not use a naïve midnight `DateComponents` construction for schedule arithmetic.

## 5.3 Querying around midnight

A wall-clock query on calendar day `D` may match trips whose GTFS service day is `D-1`, `D`, or even earlier if the feed has service times above 48 hours.

Use `FeedInfo.maximumServiceTime` to determine how many previous service days can overlap the query window.

Never hard-code “check yesterday and today only.”

## 5.4 Realtime dates

HAFAS returns explicit planned/realtime date and time strings. Parse them in the feed/operator timezone and map them to the same internal `Date`/absolute ordering model.

Never infer a realtime date solely from a time-of-day when the response includes a date.

---

# 6. Routing-data preprocessing

The installer may spend additional CPU during GTFS installation. This is explicitly desired: pay preprocessing cost once, then make every interactive route query cheap.

## 6.1 Keep SQLite as canonical source

SQLite remains:

- the persistent GTFS entity store;
- source for display metadata;
- source for stop search;
- source for individual agency/route/trip queries;
- a rebuild source for the routing cache.

## 6.2 Add a versioned routing sidecar

Build a sidecar file next to the SQLite database, e.g.:

```text
transit.sqlite
transit.routing
```

The sidecar is a compact, versioned binary snapshot optimized for sequential reads.

Header must include at least:

```text
magic
formatVersion
feedGeneration
feedFingerprint
stopCount
tripCount
patternCount
serviceDayCount
section offsets/sizes
checksum
```

Use a cryptographic or strong content fingerprint of the source feed/database metadata, not only the caller-supplied generation integer.

If the cache is missing, corrupt, or does not match the database fingerprint, rebuild it from SQLite.

Build into a temporary sidecar and atomically replace it only after validation.

## 6.3 Memory mapping / loading

The network is small enough that loading the complete routing arrays is acceptable, but design the binary so `Data(contentsOf:options: .mappedIfSafe)` can be used.

Do not prematurely introduce unsafe zero-copy pointer machinery if plain contiguous Swift arrays meet performance/memory targets.

Start with safe immutable arrays. Optimize representation only after profiling.

## 6.4 Dense identifiers

Use dense integer IDs internally:

```swift
typealias StopIndex = UInt32
typealias TripIndex = UInt32
typealias RouteIndex = UInt32
typealias PatternIndex = UInt32
typealias ServiceIndex = UInt32
```

Never compare GTFS strings inside the routing loop.

Keep mapping tables between dense IDs and SQLite/GTFS IDs for final materialization.

## 6.5 Route patterns

A RAPTOR route is **not** the same as `routes.txt.route_id`.

Construct patterns by at least:

```text
GTFS route_id
+
ordered stop occurrence sequence
```

Do not use `direction_id` as a routing key. GTFS explicitly says it is for separating directions in published timetables, not route computation.

A loop can visit the same stop ID multiple times. Store stop **occurrences/positions**, not a set of stops.

Per-trip pickup/drop-off restrictions remain trip-stop attributes and do not have to be identical for pattern membership.

## 6.6 Non-overtaking route families

Classic RAPTOR relies on trips in a route family having a consistent ordering: a later trip should not overtake an earlier trip downstream.

After grouping by stop pattern, detect overtaking.

Partition each pattern into one or more **non-overtaking families**.

A practical deterministic partitioner:

1. sort trips by departure at the first timed stop, then stable trip ID;
2. maintain families/chains;
3. a trip is compatible with a family only if its arrival/departure values are no earlier than the family's last trip at every comparable pattern position;
4. place it in the compatible family whose last trip is latest while remaining compatible;
5. create a new family when none is compatible.

Then validate every family in tests:

```text
for every consecutive trip pair in family:
    at every pattern position:
        earlierTrip.time <= laterTrip.time
```

If a trip has missing timing data that prevents this comparison, normalize timing first or isolate it conservatively rather than pretending FIFO.

This avoids subtle wrong-route bugs from express/local overtaking.

## 6.7 Stop-to-pattern incidence

Build a compressed adjacency structure:

```text
stopPatternOffsets[stopCount + 1]
patternOccurrences[] = (patternIndex, position)
```

When a stop label improves, this tells RAPTOR exactly which pattern families need scanning and from which earliest position.

## 6.8 Trip timing arrays

Store pattern-aligned trip times contiguously.

Conceptually:

```swift
struct PackedTrip {
    var sourceTripID: UInt32
    var serviceIndex: UInt32
    var patternIndex: UInt32
    var timeOffset: UInt32
}

arrivalSeconds[]
departureSeconds[]
pickupFlags[]
dropOffFlags[]
timepointFlags[]
```

Use `Int32.max` or a separate validity bit for missing times. Do not use optional Swift objects per stop in hot arrays.

## 6.9 Active-service representation

The existing `service_date` table is useful.

For the routing sidecar, materialize active service/trip bitsets by service day.

Example:

```text
activeTripBitset[day][trip]
```

At realistic Luxembourg feed sizes this is compact and makes activity testing an O(1) bit operation.

Optionally build an immutable `ServiceDayView` lazily that contains active trip slices per pattern for the relevant day(s). Cache a few recent day views.

## 6.10 Query timetable window

A query around midnight may need trip instances from multiple service days.

Build a query-local `TimetableWindow` that merges active trip instances from every service day whose schedule can overlap the requested interval.

Trip instance identity is:

```swift
struct TripInstanceID: Hashable, Sendable {
    let tripIndex: TripIndex
    let serviceDay: ServiceDay
    // Frequency instance discriminator if required.
}
```

Never identify a physical scheduled instance with `trip_id` alone across days.

## 6.11 Minimum in-vehicle lower-bound graph

During preprocessing, create a small time-independent lower-bound graph:

For every consecutive stop occurrence along a trip, retain the minimum observed non-negative in-vehicle travel time for that directed stop pair.

This graph is **not** the final router. It is only an admissible/optimistic helper for query pruning and lazy walking-edge discovery.

A reverse Dijkstra over this small static graph can cheaply estimate an optimistic remaining transit duration to the destination.

## 6.12 String/display data

Do not pull names, colors, agencies, shapes and full `TransitStop` models through the hot algorithm.

Once a page candidate set is finalized, bulk-materialize the required metadata in one/few SQLite queries.

Add batch APIs such as:

```swift
func materializeTrips(ids: Set<TripID>) throws -> [TripID: TransitTrip]
func materializeStops(ids: Set<StopID>) throws -> [StopID: TransitStop]
func materializeRoutes(ids: Set<RouteID>) throws -> [RouteID: TransitRoute]
```

or equivalent internal dense-ID versions.

---

# 7. GTFS importer/schema changes

Implement schema migration by rebuilding from GTFS; the installed database is derived data, so do not create a complex in-place migration system unless the app already requires it.

Increase a schema version in `metadata`.

## 7.1 Required/optional files

Change archive requirements to match routing needs and current GTFS semantics:

Required/conditionally required:

```text
agency.txt
stops.txt              (for normal fixed-route feed)
routes.txt
trips.txt
stop_times.txt
calendar.txt OR complete calendar_dates.txt
```

Optional:

```text
calendar_dates.txt
shapes.txt
frequencies.txt
transfers.txt
pathways.txt
levels.txt
feed_info.txt
```

Future flexible/on-demand files may be retained later, but fixed-route planning is the immediate target.

## 7.2 `stop` additions

Consider adding:

```text
parent_station_id as integer FK after a second resolution pass
stop_timezone
level_id
stop_access
```

The existing raw parent-station GTFS ID can remain if useful, but routing should have a dense parent index.

## 7.3 `stop_time` additions

Retain/import:

```text
shape_dist_traveled
 timepoint
 continuous_pickup
 continuous_drop_off
```

The last two may initially be stored but unsupported by fixed-stop route planning. If unsupported, explicitly exclude those flexible board/alight operations rather than silently misrouting them.

## 7.4 Transfer table

Support nullable stop fields where GTFS permits them.

Example conceptual schema:

```sql
CREATE TABLE transfer_rule (
    id INTEGER PRIMARY KEY,
    from_stop_id INTEGER REFERENCES stop(id),
    to_stop_id INTEGER REFERENCES stop(id),
    transfer_type INTEGER NOT NULL,
    min_transfer_sec INTEGER,
    from_route_id INTEGER REFERENCES route(id),
    to_route_id INTEGER REFERENCES route(id),
    from_trip_id INTEGER REFERENCES trip(id),
    to_trip_id INTEGER REFERENCES trip(id)
);
```

Validate legal combinations based on transfer type.

## 7.5 Pathways

Add source models/tables needed to calculate station-internal transfer duration and accessibility.

At minimum preserve:

```text
pathway_id
from_stop_id
to_stop_id
pathway_mode
is_bidirectional
length
traversal_time
stair_count
max_slope
min_width
signposted_as
reversed_signposted_as
```

Use `traversal_time` when supplied. When pathway edges exhaustively describe a station, respect them instead of inventing impossible shortcuts through station geometry.

## 7.6 Frequency trips

Handle both meanings correctly.

### `exact_times = 1`

These represent exact scheduled instances. At day-view construction, materialize lightweight virtual trip instances at:

```text
start_time + n * headway_secs
```

while the generated departure is `< end_time` according to GTFS semantics.

Do not duplicate all of them permanently if that materially enlarges the database; query/day-level expansion is fine.

### `exact_times = 0` or empty

These are genuinely frequency-based and do not define exact fixed departures.

Do not present an invented second-perfect departure as if it were scheduled truth.

Implement a policy enum, e.g.:

```swift
public enum FrequencyRoutingPolicy: Sendable {
    case conservative        // worst-case wait up to headway
    case expected            // e.g. expected wait; mark approximate
    case excludeInexact
}
```

Default to a conservative behavior if the Luxembourg feed actually contains such service, and mark the resulting times as frequency-derived/approximate.

If the production feed has no `exact_times=0` rows, this path remains dormant.

---

# 8. Transfer semantics

Create one authoritative `TransferRuleResolver`. Do not scatter this logic through RAPTOR code.

Input should include:

```swift
arrivingTripInstance
fromStopOccurrence
candidateDepartingTripInstance
toStopOccurrence
resolvedPhysicalWalkDuration?
userPreferences
```

Output:

```swift
struct TransferDecision: Sendable {
    let allowed: Bool
    let requiredSeconds: Int
    let countsAsTransfer: Bool
    let inSeat: Bool
    let source: TransferDecisionSource
}
```

## 8.1 Rule specificity

For a given arriving/departing trip pair, choose the applicable transfer rule with greatest GTFS specificity.

Implement the precedence documented by GTFS, from most to least specific:

1. `from_trip_id` + `to_trip_id`
2. one trip ID + opposite route ID
3. one trip ID
4. both route IDs
5. one route ID
6. stop pair only

Trip-specific values take precedence over route-specific values where both are present.

Parent-station rules must be made applicable to their child stops.

## 8.2 Type 0 — recommended/default transfer

If same stop:

```text
required = user.minimumTransferSeconds
```

If different stops and MapKit walk is known:

```text
required = mapKitWalkSeconds + user.minimumTransferSeconds
```

If GTFS pathways provide an authoritative station-internal duration, use pathway duration instead of an outdoor MapKit shortcut for that internal segment.

## 8.3 Type 1 — timed transfer

The feed declares that the departing service is expected to wait and provide enough transfer time.

Honor the timed-transfer guarantee.

For the default policy, do not add the generic 120-second delay buffer on top of a guaranteed timed transfer. Still require the actual physical movement duration if the rider must move between distinct locations.

Expose a future preference if the app wants to force an additional safety buffer even on timed transfers.

## 8.4 Type 2 — minimum transfer time

Do not double-count physical walking.

If the GTFS rule says `min_transfer_time = M` and MapKit says the physical walk takes `W` with user buffer `B`, use:

```text
required = max(M, W + B)
```

For same-stop transfer:

```text
required = max(M, B)
```

The GTFS minimum already represents the total transfer time required by the producer; summing `M + W + B` would often count walking twice.

Offline, if MapKit is unavailable and the rule supplies `M`, `M` is usable GTFS-defined transfer time.

## 8.5 Type 3 — forbidden transfer

Reject it.

Do not let inferred nearby-stop walking resurrect a transfer that an applicable type-3 rule forbids.

## 8.6 Type 4 — linked in-seat transfer

The rider remains on the same vehicle into a linked trip.

- no walking;
- no generic transfer safety buffer;
- no transfer-count increment;
- preserve the trip boundary internally;
- presentation may either join the leg or show a line/trip continuation marker if public line identity changes.

## 8.7 Type 5 — in-seat transfer forbidden

Treat the sequential trip pair as requiring an actual alight/reboard operation.

Apply normal transfer feasibility and increment transfer count.

## 8.8 `block_id`

`block_id` indicates sequential trips made by the same vehicle but current GTFS says transfer type 4 is the explicit mechanism for in-seat transfer information.

Do not automatically convert every shared `block_id` into a zero-transfer in-seat continuation.

If type-4/type-5 linked-trip information exists and conflicts with block implications, linked-trip rules win.

---

# 9. Walking architecture

Walking is the hardest integration because MapKit is network-backed while the timetable engine must remain fast.

The correct design is **lazy exact walking refinement**.

## 9.1 Never use straight-line duration in a final journey

Geodesic distance may be used for:

- spatial ordering;
- candidate discovery;
- optimistic lower bounds;
- pruning;

It may **not** be used as the final displayed walking duration when the requirement says Apple Maps.

Every final external walking leg must have been resolved through MapKit.

## 9.2 Walking-provider protocol

Define a package protocol independent from MapKit object types:

```swift
public protocol WalkingRoutingProvider: Sendable {
    func estimate(_ request: WalkingRequest) async throws -> WalkingEstimate
    func route(_ request: WalkingRequest) async throws -> WalkingRoute
}
```

Value types:

```swift
public struct WalkingRequest: Hashable, Sendable {
    public let source: Coordinate
    public let destination: Coordinate
    public let departure: Date?
}

public struct WalkingEstimate: Hashable, Sendable {
    public let durationSeconds: Int
    public let distanceMeters: Double
}

public struct WalkingRoute: Sendable {
    public let durationSeconds: Int
    public let distanceMeters: Double
    public let polyline: [Coordinate]
    public let steps: [WalkingStep]
}
```

The MapKit adapter uses `calculateETA()` for `estimate` and `calculate()` for `route`.

Tests inject a deterministic fake provider.

## 9.3 In-memory deduplication/cache

Use an actor for outstanding/resolved MapKit work:

```swift
actor WalkingRouteCache {
    // Key -> in-flight task or resolved result
}
```

Deduplicate identical edge requests in a session.

Use an LRU for recent estimates/routes in memory.

Do not persist Apple-provided route geometry across launches unless current Apple terms explicitly permit the intended storage. This specification does not assume such permission.

## 9.4 Bounded concurrency

Start with a maximum of **4 concurrent MapKit directions operations**.

Make this an internal tuning constant, not a user preference.

Benchmark 2/4/6 on real devices and watch throttling. Do not create one Task per candidate stop pair without a concurrency gate.

## 9.5 Cancellation

Wrap each `MKDirections` operation in task cancellation handling and call `directions.cancel()` when the Swift task is cancelled.

A superseded route query must stop consuming MapKit capacity.

## 9.6 No user maximum walking distance

There is no user-configured maximum access/egress distance.

Do not expose a hidden “1 km and stop” semantic that silently makes longer valid routes impossible.

However, querying MapKit for every one of ~thousands of stops and every stop pair is infeasible and would violate practical request constraints.

Use adaptive candidate expansion instead of a hard maximum.

## 9.7 Direct walk as an upper bound

Resolve the direct MapKit walk early.

Its exact arrival provides a strong initial upper bound for route discovery.

Any transit journey containing a single walking leg that already makes it impossible to beat the relevant bound cannot become the fastest result.

The direct-walk bound therefore helps avoid absurd long-access candidates without introducing a fixed distance limit.

## 9.8 Lazy unresolved walking edges

Represent a possible walking edge in one of these states:

```swift
enum WalkingEdgeState {
    case unresolved(optimisticSeconds: Int)
    case resolved(seconds: Int, distance: Double)
    case unavailable
}
```

The unresolved cost is only a search lower bound. It must never be displayed.

Workflow:

1. generate a provisional RAPTOR candidate using unresolved optimistic footpaths;
2. inspect every unresolved walking edge that appears in candidate journeys that could enter the page;
3. resolve those edges through MapKit concurrently;
4. update the query-scoped walking graph;
5. rerun RAPTOR;
6. continue until all page-worthy candidates contain resolved walking legs and no unresolved optimistic candidate can outrank them;
7. obtain full `MKRoute` geometry for displayed walking legs;
8. revalidate once more if full route travel time differs from ETA.

This is substantially better than querying MapKit for the complete theoretical walking graph.

## 9.9 Candidate stop expansion

Use the existing stop R-tree / a dense in-memory spatial index.

For access/egress and transfer discovery:

- enumerate stops in increasing geodesic distance/rings;
- combine a walking lower bound with an optimistic remaining-transit lower bound;
- stop expanding when farther candidates cannot improve the current result envelope;
- expand again if a candidate is invalidated and the bound becomes weaker.

There is no fixed user maximum; the search radius is derived from the current query and best known solution.

## 9.10 Fundamental MapKit limitation

Be explicit in code comments/documentation:

> An exhaustive proof over every possible arbitrary stop-to-stop walking path would require asking MapKit about an unbounded/near-quadratic number of pairs. MapKit is not designed for that request pattern. The engine therefore uses optimistic spatial search and lazy exact refinement. All displayed walking legs are exact MapKit results, while candidate discovery is adaptive.

If MapKit throttles before an unresolved candidate can be validated, return the best fully validated journeys available and mark the search as degraded rather than fabricating walking times.

---

# 10. Point RAPTOR core

Implement a pure synchronous CPU core that accepts only immutable numeric snapshot data and a query workspace.

No `await` inside this core.

## 10.1 Core input

Conceptually:

```swift
struct RaptorRequest {
    let earliestDoorDeparture: ServiceInstant
    let accessEdges: [AccessEdge]
    let egressEdges: [EgressEdge]
    let transferGraph: QueryTransferGraph
    let timetable: TimetableWindow
    let maxTransfers: Int?
    let modeFilter: TransitModeMask
    let accessibility: AccessibilityPreferences
}
```

## 10.2 Rounds

Round semantics:

- round 0: origin/access walking only;
- round 1: first transit boarding;
- round 2: one transit transfer;
- ...

If `maxTransfers = N`, maximum transit boarding round is `N + 1`.

If `nil`, run until an entire round produces no improvement.

## 10.3 Labels

For the default fastest search, keep compact labels per stop/round.

At minimum:

```swift
struct StopLabel {
    var arrival: Int64
    var originDeparture: Int64
    var parent: ParentRef
}
```

Internal query pruning can use stronger dominance than the final user-facing strict rule. In particular, do not keep cyclic labels merely because they started at the same time.

For optional fewer-transfer/less-walking preference modes, support a bounded multi-criteria label set when requested.

## 10.4 Tie behavior

For equal arrival time during the profile iterator's point query, prefer the path with the **earlier actual door departure** so equal-arrival, later-departure journeys can still be discovered by the next profile threshold rather than skipped.

Keep deterministic tie parents when needed for same-time route diversity.

## 10.5 Marked stops and routes

Use the standard RAPTOR marked-stop optimization:

- only patterns serving newly improved stops need scanning next;
- for each marked pattern, remember the earliest relevant pattern position;
- scan the pattern once per round.

Use generation/stamp arrays to avoid clearing large Boolean arrays on every point query.

Example:

```swift
var stopStamp: [UInt32]
var patternStamp: [UInt32]
var queryGeneration: UInt32
```

## 10.6 Earliest boardable trip

Within a non-overtaking pattern family, binary-search the first trip whose boardable departure at the current position is >= the stop ready time, then skip inactive/unboardable instances as needed.

Because the family is non-overtaking, once onboard, scanning that trip downstream is valid.

If realtime modifications cause overtaking inside the small patched candidate set, do not assume the static family order remains FIFO. Either:

- use a small realtime-aware local candidate scan at affected patterns; or
- build a query-local order for patched trip instances.

Correctness beats saving a few comparisons for a handful of realtime-patched trips.

## 10.7 Pickup/drop-off restrictions

Board only when current policy allows `pickup_type`.

Update destination stop labels only when alighting is allowed by `drop_off_type`.

Do not allow boarding at a no-pickup stop or alighting at a no-drop-off stop.

## 10.8 Transfer relaxation

After each transit round, relax transfer/footpath edges from newly improved stops.

An unresolved MapKit edge may participate only with its optimistic lower-bound cost in provisional searches. A page candidate containing it is not final until the edge is resolved.

## 10.9 Destination egress

Whenever an alightable stop improves, evaluate destination egress edges.

Destination arrival is:

```text
transitArrivalAtStop + resolvedOrOptimisticEgressDuration
```

Again, unresolved egress can create provisional candidates but not a final displayed journey.

## 10.10 Parent arena

Avoid allocating recursive class objects for every label.

Use a query-local arena:

```swift
struct ParentNode {
    let kind: ParentKind
    let previous: Int32
    ... numeric payload ...
}

var parentArena: [ParentNode]
```

A label stores an integer index into the arena.

Only reconstruct full `JourneyLeg` values for destination candidates that survive selection.

## 10.11 Destination shadow candidates

The user wants routes sharing the same departure time to remain visible even if one arrives later.

Therefore, when a valid path reaches the destination, keep a small **destination candidate/shadow arena** before normal internal earliest-arrival pruning discards it.

Keep unique path signatures sufficient to fill the requested page. The engine does not need to retain hundreds of terrible alternatives; it needs enough valid equal-departure alternatives to satisfy a 5/3-result page.

Internal loop/cycle suppression still applies.

---

# 11. Event-driven journey-profile iterator

This section is the central piece that turns point RAPTOR into the requested “next useful route” behavior.

## 11.1 Key observation

For a threshold `T`, point RAPTOR returns the minimum possible arrival among all journeys whose **actual effective door departure** is >= `T`.

With no realtime overlay, effective time equals scheduled time. With a realtime overlay, the RAPTOR boarding candidate iterator must merge ordinary scheduled candidates with query-local realtime boarding events, including delayed trip instances whose **scheduled** departure is before `T` but whose **effective** departure is at or after the stop's boarding threshold.

Suppose that best journey departs at `D`.

Any journey departing between `T` and `D` that arrives strictly later than the best journey is strictly dominated by it, because the best journey leaves later and arrives earlier.

This allows the engine to jump directly between useful departure cohorts instead of evaluating every departure event.

## 11.2 Point query result must contain actual latest feasible door departure

A point RAPTOR search starts with “user may leave no earlier than T,” but a chosen itinerary may board a vehicle much later.

During reconstruction calculate:

```text
actualDoorDeparture = firstBoardingDeparture - exactAccessWalkDuration
```

(or exact stop departure if access duration is zero).

Do not label the journey's departure as the threshold `T` unless that is actually when the user must leave.

## 11.3 Forward profile algorithm

Pseudo-code:

```text
threshold = requestedTime
realtimeOverlay = current immutable query-local overlay (possibly empty)
lookahead = pointRaptor(threshold, realtimeOverlay)

while needMoreResults and lookahead exists:
    best = lookahead.best
    D = best.actualEffectiveDoorDeparture

    cohort = expandSameEffectiveDepartureCohort(D, realtimeOverlay)

    next = pointRaptor(D + 1 second, realtimeOverlay)

    if next exists:
        earliestFutureArrival = next.best.effectiveArrival
        cohort.removeAll { candidate in
            candidate.effectiveArrival > earliestFutureArrival
            // future effective departure is guaranteed > D, so both strict conditions hold
        }

    finalize/refine cohort walking edges
    if new HAFAS data changes the realtime overlay:
        discard this provisional profile step and rerun against the new immutable overlay revision
    final strict-dominance filter using effective times
    enqueue deterministic cohort journeys

    lookahead = next
```

Do not advance the profile cursor using a scheduled departure timestamp when realtime is active. A delayed trip scheduled at 17:50 but effectively departing at 18:05 belongs in the 18:05 effective-departure cohort.

The one-cohort lookahead is important.

A slower route leaving at the same time `D` cannot be dominated by another same-departure route, but it **can** be dominated by a later departure. The next point query tells us the earliest arrival achievable by any later departure, so it safely removes same-cohort routes that should disappear under the user's rule.

If the future route has equal arrival rather than earlier arrival, keep the earlier cohort because the discard rule requires strict arrival improvement.

## 11.4 Same-departure cohort expansion

After finding a useful departure time `D`, identify all plausible first-board triggers whose latest door departure equals `D`.

For each access stop `s` with exact/validated access duration `w`, a transit trip departing `s` at:

```text
D + w
```

is a trigger.

Run a small constrained RAPTOR continuation for those trigger boardings to capture distinct route alternatives at the same departure time.

Because result pages are only 5/3 items, expansion can stop after it has enough distinct candidates to fill the current page plus a small lookahead reserve.

Do not use an arbitrary “only one journey per departure timestamp” rule.

## 11.5 Journey identity/deduplication

Build a stable signature from meaningful legs, e.g.:

```text
walk access endpoint
trip instance + board stop occurrence + alight stop occurrence
transfer walk endpoints
next trip instance ...
final walk endpoint
```

Do not include realtime timestamps in the identity itself.

If two reconstructed candidates have the same functional leg sequence, keep one.

## 11.6 Final strict dominance

After walking and realtime refinement, run the exact product filter over the candidate envelope:

```swift
func strictlyDominates(_ a: Journey, _ b: Journey) -> Bool {
    a.effectiveDeparture > b.effectiveDeparture &&
    a.effectiveArrival < b.effectiveArrival
}
```

Use an O(k²) comparison for the tiny final candidate pool. Simplicity is preferable; `k` is small.

## 11.7 Sorting

Final profile order:

```text
1. effective door departure ascending
2. effective arrival ascending
3. transfer count ascending
4. walking duration ascending
5. total duration ascending
6. stable journey signature
```

The first surviving result is still an earliest-arrival journey: any earlier-departing journey with strictly worse arrival would have been removed by the fastest later journey, except equality cases which are tied under the user's semantics.

## 11.8 Adaptive search horizon

Do not impose a fixed “next 4 hours” product limit.

The point RAPTOR timetable window can start with a practical horizon, then expand automatically until:

- enough profile results exist;
- the feed ends; or
- no future service can be reached.

Suggested expansion sequence:

```text
3h -> 6h -> 12h -> 24h -> 48h -> feed boundary
```

Reuse work/snapshot structures where possible.

Late-night routes must be allowed to discover next-morning service.

---

# 12. Earlier/Later session design

Create a query session actor.

Suggested API:

```swift
public actor JourneyPlanningSession {
    public func initial(count: Int = 5) async throws -> JourneyPage
    public func later(count: Int = 3) async throws -> JourneyPage
    public func earlier(count: Int = 3) async throws -> JourneyPage
    public func refreshRealtime() async throws -> JourneyPage
}
```

And router factory:

```swift
public actor TransitRouter {
    public func makeSession(for query: RouteQuery) async throws -> JourneyPlanningSession
}
```

## 12.1 Forward cache

The session keeps:

- resolved endpoint walking data;
- query-scoped transfer walking graph;
- timetable window/day views;
- generated forward profile journeys;
- one-cohort lookahead;
- HAFAS stop mappings;
- HAFAS board cache;
- materialized metadata/shape cache for shown journeys.

`later()` continues the iterator rather than repeating `initial()`.

## 12.2 Page cursor

Use a stable cursor:

```swift
struct JourneyCursor: Hashable, Sendable {
    let departure: Date
    let arrival: Date
    let signature: JourneySignature
    let feedGeneration: Int
    let sessionRevision: UInt64
}
```

Do not use only `departure` because equal-departure routes exist.

## 12.3 Earlier search

The simplest correct implementation is:

1. choose an earlier adaptive threshold before the current first profile item;
2. generate a forward profile from there through the current boundary;
3. locate the current cursor/signature;
4. take the previous 3 items;
5. if fewer than 3 exist, expand the start threshold backward and repeat;
6. cache the resulting prefix so later Earlier taps are cheap.

Start with a 60-minute backward window, then expand 2h, 4h, 8h, 16h, etc. until enough predecessors exist or the feed boundary is reached.

Do not implement a separate reverse RAPTOR unless profiling shows Earlier latency is unacceptable.

## 12.4 Realtime and cursor stability

Realtime can alter departure/arrival ordering.

Within one displayed page session:

- each live refresh increments `sessionRevision`;
- rebuild final dominance/order for affected cached candidates;
- preserve journey identities where possible;
- if the order materially changes, return a refreshed page rather than silently applying an old cursor to a new order.

The app should replace the visible page on explicit realtime refresh rather than trying to merge incompatible cursor versions.

When realtime is active, cursor ordering uses **effective** door-departure and arrival values. A trip that was scheduled before the query anchor but is delayed into the future must appear in the same ordering position as any other upcoming trip at its effective departure time. It must not be hidden behind the Earlier cursor merely because its scheduled timestamp is old.

---

# 13. Realtime HAFAS refinement

Static GTFS always produces the baseline. HAFAS can improve it but must never be required for a result.

## 13.1 High-level loop

Do not simply put `+5` next to static routes after the fact. Also do **not** make the static candidate set the only universe of trips eligible for realtime routing. That would miss a delayed vehicle whose scheduled departure is already before the query time.

Realtime delays can:

- make a transfer impossible;
- make a previously worse route become best;
- make a route scheduled in the past become catchable again;
- make a scheduled route effectively depart before the user can reach it;
- make a scheduled-missed transfer become catchable because the connecting vehicle is late;
- cancel a trip;
- change platform;
- alter final dominance and pagination order.

Use this refinement loop:

```text
0. resolve endpoints and exact MapKit access candidates
1. create the initial set of promising first-board stops
2. fetch HAFAS departure boards around those stops using a scheduled-time LOOKBACK window
3. match HAFAS departures/pass-lists to GTFS trip instances
4. build immutable realtime overlay revision R0
5. run point/profile RAPTOR against GTFS + R0
6. collect:
      a. candidate boarding/interchange stops from surviving/reserve journeys
      b. realtime-sensitive reached stops where a scheduled departure shortly BEFORE
         the computed boarding threshold could become catchable if delayed
7. fetch any missing HAFAS boards for that bounded frontier concurrently
8. build immutable overlay revision R1
9. if R1 changes boardability, cancellation, stop times, or top-page ordering:
      rerun RAPTOR against R1
10. repeat until:
      - the requested page is stable, AND
      - there are no unfetched promising realtime-sensitive frontier stops, OR
      - the provider/policy budget is exhausted
11. validate exact MapKit walking legs and final transfer feasibility
12. run final strict dominance using effective times
13. return the best stable page available
```

Normally one or two live refinement waves should be enough. The algorithm must nevertheless be structurally capable of discovering a delayed-past first vehicle **and** a delayed-past transfer connection.

The network call is never performed from the numerical RAPTOR scan. Each wave creates an immutable `RealtimeSnapshot`/overlay which is passed into a pure synchronous scan.

Do not set a user-visible hard dependency on finishing all live waves; network failure or quota pressure returns the best scheduled/partially-live result.

## 13.2 Static candidate reserve

Ask the static/profile engine for more candidates than the final page, e.g. at least:

```text
max(requestedCount * 3, requestedCount + 8)
```

and expand again if cancellations invalidate too many.

Also retain nearby “shadow” destination candidates so a route that was not on the scheduled frontier can be promoted if the scheduled winner is delayed/cancelled.

Do not fetch realtime for the entire feed.

## 13.2A Catch-up lookback windows and frontier discovery

A HAFAS request centered only at the passenger's boarding time is not enough. To discover a service that was scheduled earlier but is still delayed, departure-board discovery must look **backward in scheduled time**.

For a stop with computed earliest feasible boarding threshold `B`:

```text
boardRequestStart = B - realtimeLookback
boardRequestEnd   = max(B + forwardRealtimeHorizon, current candidate arrival bound as useful)
```

Recommended internal defaults:

```text
initial realtimeLookback:        120 minutes
minimum forward live horizon:     90 minutes
maximum concurrent HAFAS boards:   4
```

The lookback is an internal/provider policy, not a user-visible transfer preference. Make it configurable in `RealtimeConfiguration`. Do not scatter magic constants through the router.

A finite lookback means the engine can only guarantee catch-up discovery inside that configured lookback unless the provider itself returns currently expected departures whose scheduled times lie farther back. Document this honestly. The default must comfortably handle ordinary severe delays such as the required 10-minutes-past / +15-minutes-late scenario.

For first boarding, `B` is:

```text
query door anchor + exact MapKit access walking duration
```

For a transit transfer, `B` is:

```text
effective arrival at transfer stop
+ applicable walking/pathway duration
+ applicable GTFS/user transfer safety requirement
```

Do not query every stop in Luxembourg. Build a **realtime-sensitive frontier**. A stop is promising when all are true:

1. RAPTOR/access logic can reach it;
2. the static timetable contains at least one relevant scheduled departure in `[B - lookback, B)` or a candidate future departure that needs live validation;
3. a conservative lower bound from that trip/stop to the destination could still improve or fill the requested page;
4. the stop has not already been covered by a cached HAFAS board window at sufficient freshness.

This frontier is how the router discovers a transfer that is statically missed but becomes catchable due to delay without issuing network requests from inside RAPTOR.

When there is not yet a destination upper bound, use the normal access candidate selection plus a reasonable initial frontier and widen only if necessary. Geodesic/lower-bound calculations may prune candidates, but every walking leg that survives into an actual journey must still use MapKit as required elsewhere in this document.

## 13.3 HAFAS stop mapping

Maintain a `HafasStopMappingIndex`.

Never assume:

```text
GTFS stop_id == HAFAS id
```

Mapping strategy:

1. prefer an exact known external-ID mapping when proven from data;
2. compare coordinate proximity;
3. compare normalized stop name;
4. compare product/mode overlap;
5. compare parent/main-station relationship where available;
6. require a confidence threshold before applying realtime data.

The documented nearby-stops endpoint can return many stops in one request. When quota/response behavior permits, a single broad Luxembourg nearby-stop fetch can create a reusable HAFAS location index more efficiently than one nearby request per GTFS stop. Fall back to lazy local mapping if the broad request is unavailable.

HAFAS mapping data is not Apple Maps route data and may be persisted in app/package storage if desired. Key it by feed identity and HAFAS source version/context.

## 13.4 Batch departure-board requests

Group candidate journeys **and realtime-sensitive frontier stops** by HAFAS boarding stop and a compact time window.

One departure board can cover several candidate trips and delayed-past discovery events. The request start time must honor the catch-up lookback from section 13.2A rather than always starting at the passenger's current/threshold time.

Use:

- `format=json`
- realtime `FULL`
- `passlist=1`
- a narrow `date/time/duration`
- line filters when they meaningfully reduce payload without risking a mismatch

Deduplicate requests at the session level.

Start with max **4 concurrent HAFAS requests** and benchmark. Respect relay/server quotas.

## 13.5 Matching a departure to a GTFS trip instance

Score using multiple signals:

```text
mapped stop identity
planned departure date/time
line / route short name
transport category
headsign/direction
operator
pass-list stop sequence
planned downstream times
```

A planned departure timestamp + line alone may not be unique at busy stations.

Use a match confidence enum:

```swift
enum RealtimeMatchConfidence {
    case exact
    case high
    case ambiguous
    case none
}
```

Only mutate routing times for exact/high matches.

Ambiguous data may be shown as a generic stop-level message but must not corrupt a specific trip.

`JourneyDetailRef.ref` is opaque. Cache/use it as identity within the live session, but do not parse undocumented numeric fields to infer semantics.

## 13.6 Pass-list realtime fields

Extend `HafasPasslistStop` to decode actual fields returned by the API, including when present:

```swift
public let realtimeDepartureTime: String?
public let realtimeDepartureDate: String?
public let realtimeArrivalTime: String?
public let realtimeArrivalDate: String?
public let realtimeDepartureTrack: String?
public let realtimeArrivalTrack: String?
public let cancelled: Bool?
public let boarding: Bool?
public let alighting: Bool?
public let realtimeBoarding: Bool?
public let realtimeAlighting: Bool?
```

Add JSON fixtures containing both single and array pass-list forms.

## 13.7 Delay propagation

For a matched trip instance:

Priority for a stop event:

1. explicit realtime stop timestamp;
2. inferred timestamp from a known delay propagated from the latest upstream realtime point;
3. scheduled GTFS timestamp.

Mark the source of each effective timestamp:

```swift
enum TimeProvenance {
    case realtimeExplicit
    case realtimeInferred
    case scheduled
    case frequencyEstimated
}
```

Do not present inferred downstream delay with the same certainty as an explicit prediction.

## 13.7A Query-local realtime overlay and delayed-trip injection

Do not mutate the static routing snapshot. Build an immutable, query/session-scoped overlay revision. A practical representation is:

```swift
struct RealtimeTripPatch: Sendable {
    let tripInstanceID: TripInstanceID
    let status: RealtimeTripStatus
    let effectiveStopEvents: [RealtimeStopEventPatch]
    let matchConfidence: RealtimeMatchConfidence
}

struct RealtimeBoardingEvent: Sendable {
    let stopID: StopIndex
    let routeFamilyID: RouteFamilyIndex
    let patternPosition: Int32
    let tripInstanceID: TripInstanceID
    let scheduledDeparture: Int64
    let effectiveDeparture: Int64
}

struct RealtimeSnapshot: Sendable {
    let revision: UInt64
    let tripPatches: ContiguousArray<RealtimeTripPatch>
    let boardingEventsByStop: RealtimeBoardingIndex
}
```

The exact packed representation can differ, but it must support this operation cheaply:

> Given stop `s` and earliest boardable effective time `B`, enumerate both normal GTFS trip candidates and realtime-injected candidates with `effectiveDeparture >= B`.

A delayed trip with:

```text
scheduledDeparture < B
effectiveDeparture >= B
```

**must be returned by this merged candidate iterator.** This is the mechanism that fixes the required delayed-past scenario.

Implementation rules:

- keep static trip arrays sorted by scheduled time; do not resort the entire feed for every live update;
- keep a tiny per-query/per-stop overlay list sorted by **effective** departure;
- merge/deduplicate static and overlay candidates by `tripInstanceID`;
- when a patched trip also appears in the static future list, use the patched effective events, not a duplicate scheduled copy;
- a cancelled/unreachable patch masks the static trip instance;
- if realtime delays cause overtaking, use the existing realtime-safe local candidate scan rather than assuming the preprocessed static non-overtaking family order still applies;
- only exact/high-confidence matches may create a routing patch.

The overlay is query-local because live data expires rapidly. The HAFAS board response cache may be shared by the coordinator, but every RAPTOR execution receives an immutable snapshot revision.

## 13.8 Cancellations/reachability

If a matched HAFAS trip/departure is cancelled, make the affected trip instance unavailable.

If `reachable == false` for the relevant boarding, do not route the user onto it.

If realtime boarding/alighting flags explicitly forbid an operation, honor them.

## 13.9 Transfer feasibility can change in both directions

After effective timestamps are applied, rerun transfer feasibility with the same transfer rule and user safety buffer.

Realtime can invalidate a static transfer:

```text
first leg now arrives too late -> connection disappears
```

But realtime can also **create** a connection that static GTFS considered missed:

```text
passenger effective arrival:       18:20
required transfer time:             2 min
connection scheduled departure:    18:18
connection effective departure:    18:24

18:20 + 2 min <= 18:24 -> catchable
```

The second case requires the realtime-sensitive frontier + boarding-event injection described above. It cannot be solved by merely patching journeys that the static router already found.

Whenever new realtime data changes transfer boardability:

1. build a new immutable overlay revision;
2. rerun RAPTOR from the query origin;
3. reconstruct affected journeys;
4. rerun final profile ordering and strict dominance.

Do not locally splice a newly catchable transfer into an old parent chain without rerunning feasibility; doing so can violate the transfer-count and arrival-label invariants.

## 13.10 Realtime failure

If any live call fails:

- do not fail the whole route search;
- keep scheduled data;
- attach a `realtimeState` such as `.unavailable`, `.partial`, or `.stale`;
- do not label unqueried service “on time.”

---

# 14. Public Swift models

Exact naming can be adjusted to project conventions, but keep the separation of query, internal IDs, and presentation values.

## 14.1 Endpoint

```swift
public enum JourneyEndpoint: Hashable, Sendable, Codable {
    case stop(id: String)
    case coordinate(Coordinate, label: String?)
}
```

Do not put `MKMapItem` into the core public model; convert it in the iOS integration layer.

## 14.2 Query

```swift
public struct RouteQuery: Hashable, Sendable {
    public let origin: JourneyEndpoint
    public let destination: JourneyEndpoint
    public let departureTime: Date
    public let preferences: RoutingPreferences
    public let realtimePolicy: RealtimePolicy
}

public enum RealtimePolicy: Hashable, Sendable {
    case disabled
    case bestEffort(RealtimeConfiguration = .default)
}

public struct RealtimeConfiguration: Hashable, Sendable {
    public var scheduledLookbackSeconds: Int = 2 * 60 * 60
    public var minimumForwardHorizonSeconds: Int = 90 * 60
    public var maximumConcurrentBoardRequests: Int = 4
    public var maximumRefinementWaves: Int = 4

    public static let `default` = RealtimeConfiguration()
}
```

`scheduledLookbackSeconds` exists specifically to discover delayed vehicles whose scheduled departure is already in the past. It is not the user's minimum-transfer setting. Keep it configurable so the host app/provider can tune quota/latency tradeoffs without changing the routing algorithm.

`maximumRefinementWaves` is a network/refinement safety budget, not a route transfer limit. If it is exhausted, return the best stable scheduled/partial-live page available and mark the page realtime state accordingly.

## 14.3 Preferences

```swift
public struct RoutingPreferences: Hashable, Sendable {
    public var maxTransfers: Int? = 3
    public var minimumTransferSeconds: Int = 120
    public var allowedModes: TransitModeMask = .all
    public var wheelchair: WheelchairPreference = .noPreference
    public var bike: BikePreference = .noPreference
    public var routePreference: JourneyPreference = .fastest
    public var frequencyPolicy: FrequencyRoutingPolicy = .conservative
}
```

Validate:

```text
maxTransfers >= 0 when non-nil
minimumTransferSeconds >= 0
```

## 14.4 Future preference architecture

```swift
public enum JourneyPreference: Hashable, Sendable {
    case fastest
    case fewerTransfers
    case lessWalking
    case preferDirect
}
```

For now, preserve the time-profile semantics and use these preferences as secondary criteria/label-generation criteria unless the product later explicitly changes primary ranking.

Hard filters such as “avoid bus” belong in `allowedModes`.

## 14.5 Journey

```swift
public struct Journey: Identifiable, Sendable {
    public let id: JourneySignature
    public let origin: JourneyEndpoint
    public let destination: JourneyEndpoint
    public let scheduledDeparture: Date
    public let scheduledArrival: Date
    public let effectiveDeparture: Date
    public let effectiveArrival: Date
    public let transferCount: Int
    public let walkingDuration: TimeInterval
    public let walkingDistance: Double
    public let waitingDuration: TimeInterval
    public let inVehicleDuration: TimeInterval
    public let legs: [JourneyLeg]
    public let realtimeState: JourneyRealtimeState
    public let feedGeneration: Int
}
```

`duration` is derived from effective door departure/arrival.

## 14.6 Legs

Use an enum:

```swift
public enum JourneyLeg: Sendable {
    case walk(WalkingLeg)
    case transit(TransitLeg)
    case inSeatContinuation(InSeatContinuationLeg)
}
```

Waiting can be derived between legs rather than necessarily rendered as a separate leg.

### Walking leg

```swift
public struct WalkingLeg: Sendable {
    public let from: JourneyLocation
    public let to: JourneyLocation
    public let departure: Date
    public let arrival: Date
    public let duration: TimeInterval
    public let distanceMeters: Double
    public let polyline: [Coordinate]
    public let steps: [WalkingStep]
    public let source: WalkingSource // MapKit or GTFS pathway where appropriate
}
```

### Transit leg

```swift
public struct TransitLeg: Sendable {
    public let tripInstance: PublicTripInstanceID
    public let route: TransitRoute
    public let agency: Agency?
    public let headsign: String?
    public let board: JourneyStopEvent
    public let alight: JourneyStopEvent
    public let intermediateStops: [JourneyStopEvent]
    public let shape: [Coordinate]
    public let scheduledDeparture: Date
    public let scheduledArrival: Date
    public let effectiveDeparture: Date
    public let effectiveArrival: Date
    public let realtimeState: LegRealtimeState
}
```

## 14.7 Journey page

```swift
public struct JourneyPage: Sendable {
    public let journeys: [Journey]
    public let hasEarlier: Bool
    public let hasLater: Bool
    public let realtimeState: PageRealtimeState
    public let revision: UInt64
}
```

---

# 15. Shape handling

Search does not need shapes.

Only decode/materialize shapes after a journey survives final selection.

## 15.1 Segment extraction

Preferred:

- use imported `shape_dist_traveled` to locate boarding/alighting points on the trip shape.

Fallback:

- decode the shape;
- project each transit stop coordinate to the nearest polyline location while enforcing monotonic progress along the shape;
- cache the mapping for the trip/shape during the session.

This monotonic constraint matters for loop routes where a geometrically nearest segment can occur multiple times.

## 15.2 No shape

If `shape_id` is absent, produce a transit leg without a GTFS shape or use stop-to-stop line segments only as a presentation fallback clearly distinguished from source route geometry. Routing correctness must not depend on shape presence.

---

# 16. Concurrency and multithreading

Swift concurrency should reduce latency, not infect the numerical hot loop with synchronization.

## 16.1 Actor boundaries

Recommended ownership:

```text
TransitDataRepository actor
    owns current routing snapshot generation / day-view cache

TransitRouter actor
    creates sessions and coordinates snapshot acquisition

JourneyPlanningSession actor
    owns query/profile state, caches, pagination, live revision

WalkingRouteCache actor
    owns MapKit in-flight dedup / bounded request state

HafasRealtimeCoordinator actor
    owns HAFAS request dedup / board cache / rate state

RAPTOR CPU function
    pure synchronous, local mutable workspace, immutable snapshot input
```

Do not make `RaptorEngine` itself an actor if that causes every pattern access to become isolated.

## 16.2 CPU work

Execute RAPTOR on a user-initiated task outside the main actor.

Example concept:

```swift
let result = try await Task.detached(priority: .userInitiated) {
    try Task.checkCancellation()
    return RaptorEngine.search(snapshot: snapshot, request: request)
}.value
```

The immutable snapshot must be safely `Sendable`.

## 16.3 Do not parallelize per pattern initially

Creating tasks for individual routes/patterns will probably cost more than it saves for Luxembourg.

The RAPTOR paper describes parallelization possibilities, but start single-threaded and cache-friendly.

Only add round-level route partition parallelism if Instruments on real devices shows the timetable CPU scan is a meaningful bottleneck after walking/HAFAS latency has been removed.

If added later:

- partition marked patterns into coarse chunks;
- each worker writes to local improvement buffers;
- merge once per round;
- never lock per stop update.

## 16.4 Network concurrency

MapKit and HAFAS are where concurrency matters.

Use bounded task groups:

```text
MapKit: start at 4 concurrent operations
HAFAS:  default 4 concurrent board requests (from RealtimeConfiguration)
```

These limits are separate.

Do not nest unbounded task groups.

## 16.5 Overlap independent work

Once provisional transit candidates identify likely first-board stops, it can be beneficial to overlap:

- MapKit validation of candidate walking edges; and
- HAFAS board lookup for candidate transit stops.

Only do this when the requests have a reasonable chance of being used. Avoid speculative HAFAS calls for hundreds of paths.

The initial realtime catch-up board requests for already-resolved access stops may begin as soon as their exact MapKit access durations and HAFAS mappings are known; they do not need to wait for the full static candidate envelope. This hides latency while still keeping the request set bounded.

## 16.6 Query cancellation

When the user changes origin/destination/time/preferences:

- cancel the old session task;
- propagate cancellation to MapKit;
- URLSession/HAFAS tasks should be cancellable;
- CPU RAPTOR checks `Task.isCancelled` / `Task.checkCancellation()` at least once per round and periodically during large pattern scans.

A cancelled search must not publish its page into the new UI state.

## 16.7 Feed updates during a query

A query captures one immutable routing snapshot reference.

When a new GTFS generation installs:

- repository atomically swaps the current snapshot;
- existing sessions may finish with their captured generation;
- new sessions use the new generation;
- old snapshot memory is freed when no session references it.

Do not mutate an active snapshot in place.

---

# 17. Memory/performance engineering

## 17.1 No strings in hot loops

Use dense IDs and integers.

## 17.2 Preallocate workspaces

A point query performs several scans. Reuse query-session buffers instead of allocating fresh `[Int64](repeating:...)` for every profile step where practical.

Use generation stamps to lazily reset labels.

## 17.3 Avoid dictionaries for dense data

Use arrays for:

- stop labels
- pattern marks
- trip metadata
- pattern metadata
- service bits

Use dictionaries only at boundaries where sparse external IDs are mapped to dense indices.

## 17.4 Integer timing

Use `Int64` for cross-day absolute service seconds and `Int32` for within-service-day times.

Avoid `Date` arithmetic in the inner loop.

Convert to `Date` only at query boundaries/final materialization/realtime integration.

## 17.5 Shape decode cache

Keep a small LRU of decoded final shapes. Do not decode all feed shapes at router startup.

## 17.6 Instrumentation

Add `os_signpost` / `OSLog` intervals for:

```text
routing.snapshot.load
routing.dayView.build
routing.walk.direct
routing.walk.refinementWave
routing.raptor.point
routing.profile.cohort
routing.realtime.fetch
routing.realtime.reroute
routing.materialize
routing.total
```

Add counters:

```text
RAPTOR rounds
patterns scanned
trips inspected
stop labels improved
point queries per page
walking edges provisional
walking ETA requests
walking full-route requests
HAFAS board requests
HAFAS catch-up lookback requests
realtime-sensitive frontier stops considered/fetched/pruned
realtime-injected delayed-past boardings
realtime matches exact/high/ambiguous
realtime overlay revisions / RAPTOR reruns
candidate journeys generated
candidate journeys removed by strict dominance
```

Do not log API keys or full URLs containing credentials.

---

# 18. Realtime-aware route ordering and catchability

The final page and live feasibility checks must use effective values. Scheduled values remain available for display, matching, and fallback.

For every journey define:

```swift
var effectiveDeparture: Date {
    realtimeDoorDeparture ?? scheduledDeparture
}

var effectiveArrival: Date {
    realtimeDoorArrival ?? scheduledArrival
}
```

Recalculate access departure when the first vehicle's realtime departure changes:

```text
realtimeDoorDeparture = realtimeFirstBoardDeparture - MapKitAccessDuration
```

A trip is eligible for the leave-after query when:

```text
effectiveDoorDeparture >= query.departureTime
```

This check intentionally allows:

```text
scheduledDoorDeparture < query.departureTime
effectiveDoorDeparture >= query.departureTime
```

That is the delayed-past catch-up case. Do **not** reject it because the scheduled timestamp is old.

Conversely, if a realtime change moves the effective door departure before the query threshold, that route is no longer catchable for the original leave-after query and must be rejected/researched.

For every transit boarding/transfer use:

```text
canBoard = effectiveTransitDeparture >= effectiveReadyAtStop
```

where `effectiveReadyAtStop` already includes the exact access/transfer walking time plus the applicable GTFS/user transfer rule. Never compare against scheduled transit departure when a high-confidence realtime patch exists.

The RAPTOR boarding candidate iterator must merge the static scheduled arrays with the realtime boarding overlay. This is required because a binary search into a scheduled array beginning at `B` will never see a trip scheduled before `B`, even if that trip is delayed past `B`.

Final egress arrival uses predicted transit alighting + exact final walking duration.

After every overlay revision:

1. rerun point/profile RAPTOR if boardability or stop times changed;
2. re-check all transfers;
3. re-check the query threshold using effective door departure;
4. re-run strict dominance using effective departure/arrival;
5. re-sort using effective profile ordering;
6. fill missing page slots from reserve or extend profile search;
7. issue a new page `revision` if visible ordering changed.

Earlier/Later also use the effective ordering for the current live snapshot revision. A bus scheduled at 17:50 but predicted at 18:05 belongs among upcoming 18:05 journeys, not automatically on the Earlier page.

---

# 19. Direct-walk selection implementation

Keep direct walking outside the infinite transit departure profile.

Pseudo-code:

```swift
func applyDirectWalkingRule(
    directWalk: Journey?,
    transit: [Journey],
    explicitAnchor: Date
) -> [Journey] {
    guard let walk = directWalk else { return transit }
    guard !transit.isEmpty else { return [walk] }

    let minimumTransitDuration = transit.map(\.duration).min()!
    let earliestTransitArrival = transit.map(\.effectiveArrival).min()!

    if walk.duration < minimumTransitDuration {
        return [walk]
    }

    if walk.effectiveArrival < earliestTransitArrival {
        return insertWalkIntoInitialPage(walk, transit)
    }

    return transit
}
```

After insertion, honor the exact initial count of five. Direct walking consumes a result slot when it is included.

Do not apply the regular profile dominance rule to shifted hypothetical walking departures; only the single explicit-anchor walking candidate exists.

---

# 20. Preference architecture

The initial product ranking is fastest profile routing, but build enough structure for future settings.

## 20.1 Fewer transfers

RAPTOR already computes rounds by number of boarded vehicles.

For `.fewerTransfers`, keep multiple destination labels across rounds and use transfer count as a stronger secondary score.

Do not allow a preference to resurrect a journey that violates the user's explicit strict time-discard rule unless product requirements change later.

## 20.2 Less walking

When enabled, use a small McRAPTOR-style label set with criteria such as:

```text
arrival time
walking seconds
transit boardings
```

Do not run this heavier label mode for the default fastest query unless needed for same-departure diversity.

## 20.3 Prefer direct

Use directness as a tie/soft preference among non-discarded candidates, not as permission to show a route that leaves earlier *and* arrives later than another route.

## 20.4 Wheelchair

Use GTFS:

- stop `wheelchair_boarding`
- trip `wheelchair_accessible`
- pathway modes/properties

Unknown (`0`) must remain unknown, not interpreted as inaccessible.

MapKit walking directions do not automatically constitute a guaranteed wheelchair-accessible path. Do not claim wheelchair accessibility for a MapKit walk unless the app has a source that supports that claim.

## 20.5 Bikes

Retain `bikes_allowed` and make future bike filtering possible.

---

# 21. Error/degradation model

Expose structured states rather than throwing away useful results.

Suggested:

```swift
public enum JourneyPlannerWarning: Hashable, Sendable {
    case realtimeUnavailable
    case realtimePartial
    case walkingDirectionsUnavailable
    case walkingDirectionsThrottled
    case feedOutsideCoverage
    case frequencyTimesApproximate
    case ambiguousRealtimeMatch
}
```

Fatal errors:

- no installed GTFS when transit routing requested;
- corrupt/incompatible routing snapshot that cannot rebuild;
- invalid query/preferences;
- unresolved endpoint with no routable representation.

Nonfatal errors:

- HAFAS unavailable;
- MapKit failure for an optional transfer candidate;
- one candidate trip cannot be live-matched;
- shape missing.

Return other valid journeys whenever possible.

---

# 22. Proposed package file layout

Add a routing subtree instead of making existing files enormous.

```text
Sources/MobilitéitKit/
  Routing/
    TransitRouter.swift
    JourneyPlanningSession.swift
    RouteQuery.swift
    JourneyModels.swift
    RoutingPreferences.swift

    Data/
      RoutingSnapshot.swift
      RoutingSnapshotFormat.swift
      RoutingSnapshotBuilder.swift
      ServiceDayView.swift
      TimetableWindow.swift
      DenseIdentifiers.swift
      SpatialStopIndex.swift
      LowerBoundGraph.swift

    RAPTOR/
      RaptorEngine.swift
      RaptorWorkspace.swift
      RaptorLabel.swift
      RoutePattern.swift
      PatternFamilyBuilder.swift
      ProfileIterator.swift
      DepartureCohortExpander.swift
      JourneyReconstructor.swift

    Transfers/
      TransferRuleResolver.swift
      TransferModels.swift
      PathwayGraph.swift

    Walking/
      WalkingRoutingProvider.swift
      MapKitWalkingRouter.swift
      WalkingRouteCache.swift
      QueryWalkingGraph.swift
      LazyWalkingRefiner.swift

    Realtime/
      RealtimeProvider.swift
      HafasRealtimeCoordinator.swift
      HafasStopMappingIndex.swift
      HafasTripMatcher.swift
      RealtimeSnapshot.swift
      RealtimeBoardingIndex.swift
      RealtimeFrontierPlanner.swift
      RealtimeRefiner.swift

    Diagnostics/
      RoutingMetrics.swift
      RoutingValidation.swift
```

Tests:

```text
Tests/MobilitéitKitTests/Routing/
  RaptorCoreTests.swift
  ProfileIteratorTests.swift
  StrictDominanceTests.swift
  TransferRuleTests.swift
  RoutePatternTests.swift
  OvertakingTests.swift
  WalkingRefinementTests.swift
  DirectWalkingRuleTests.swift
  RealtimeRefinementTests.swift
  ServiceTimeDSTTests.swift
  FrequencyTests.swift
  PaginationTests.swift
  ReferenceRouterPropertyTests.swift
  RoutingPerformanceTests.swift
```

---

# 23. Implementation phases

Do not attempt the entire system in one untestable change.

## Phase 1 — importer correctness and routing prerequisites

Implement:

- schema version metadata;
- optional `calendar.txt` / complete `calendar_dates.txt` support;
- optional shapes;
- transfer types 0–5 schema validity;
- transfer specificity data retention;
- pathways/levels import;
- `shape_dist_traveled`;
- `timepoint`;
- required HAFAS pass-list realtime fields;
- new fixture tests.

**Exit criterion:** existing tests pass; new GTFS edge-case fixtures pass.

## Phase 2 — routing snapshot builder

Implement:

- dense IDs;
- route patterns;
- non-overtaking family partition;
- stop-pattern incidence;
- packed trip times/flags;
- active trip/day bitsets;
- lower-bound ride graph;
- versioned sidecar;
- validation/checksum;
- load/rebuild path.

Add diagnostics that print counts in tests/benchmarks.

**Exit criterion:** snapshot reconstructed from fixtures exactly matches source semantics.

## Phase 3 — pure point RAPTOR

Implement stop-to-stop routing with:

- zero walking except exact selected stops;
- service calendars;
- pickup/dropoff rules;
- same-stop generic transfer buffer;
- max transfers;
- parent reconstruction;
- >24h service.

No MapKit/HAFAS yet.

**Exit criterion:** compare earliest arrivals against a brute-force reference router on synthetic feeds.

## Phase 4 — GTFS transfer semantics

Add:

- transfer specificity;
- types 0–5;
- parent-station expansion;
- pathways;
- in-seat continuations;
- cross-stop GTFS-defined transfers.

**Exit criterion:** dedicated transfer-rule fixture matrix passes.

## Phase 5 — profile iterator and pagination

Implement:

- actual door-departure reconstruction;
- strict dominance;
- one-cohort lookahead;
- same-departure cohort expansion;
- initial 5;
- Later 3;
- Earlier 3;
- stable cursors/session cache.

**Exit criterion:** all profile examples and equality cases pass.

## Phase 6 — MapKit walking

Implement:

- provider protocol;
- MapKit adapter;
- direct walk;
- endpoint access/egress;
- query walking graph;
- lazy optimistic edges;
- bounded ETA refinement;
- final full walking route geometry;
- throttling/cancellation behavior;
- direct-walk product rule.

**Exit criterion:** fake provider deterministic tests pass; manual device MapKit integration returns validated routes.

## Phase 7 — realtime HAFAS + delayed-past catch-up

Implement:

- HAFAS stop mapping;
- configurable scheduled-time lookback windows;
- initial catch-up boards for promising access stops;
- batched departure boards;
- candidate matching;
- immutable query-local realtime snapshot revisions;
- realtime boarding index merged with static RAPTOR candidate enumeration;
- delayed-past first-boarding injection;
- realtime-sensitive transfer frontier discovery;
- delayed-past transfer-boarding injection;
- realtime stop-time patches and delay propagation;
- cancellations/reachability;
- transfers that become impossible **or newly possible** because of realtime;
- iterative RAPTOR reruns after overlay changes;
- effective-time dominance/pagination;
- partial/offline state.

**Exit criterion:** fixtures can (1) make a scheduled winner lose, (2) cancel it, (3) invalidate a transfer, (4) promote a backup route, (5) discover and board a vehicle scheduled before the query time but delayed into the future, and (6) discover a transfer that was statically missed but becomes catchable because the connecting vehicle is delayed.

## Phase 8 — preferences

Implement/finish:

- allowed transport modes;
- max transfer setting including nil;
- fewer-transfer mode;
- less-walking mode;
- wheelchair filters;
- bike filters;
- direct preference.

**Exit criterion:** preferences change candidates without violating hard routing constraints.

## Phase 9 — performance hardening

Use a production Luxembourg feed in the host app/environment when available.

Profile:

- installer time;
- sidecar size;
- memory footprint;
- point RAPTOR p50/p95;
- number of point scans per page;
- MapKit request count;
- HAFAS request count;
- end-to-end latency.

Only then consider unsafe buffers or multicore RAPTOR.

---

# 24. Test plan — mandatory

A journey planner needs much stronger testing than ordinary data-access code.

## 24.1 Strict dominance matrix

Test every equality case:

```text
later dep + earlier arr       => discard old
later dep + equal arr         => keep both
equal dep + earlier arr       => keep both
equal dep + equal arr         => keep both
earlier dep + earlier arr     => keep both
later dep + later arr         => keep both
```

## 24.2 Same departure

Create two lines leaving exactly 10:00.

Verify both can be present.

If one arrives later, verify it is not removed merely because departure is equal.

Then add a 10:05 route that arrives before the slower 10:00 route and verify only that slower 10:00 route is discarded if both strict inequalities hold.

## 24.3 Earliest-arrival sequence

Synthetic schedule:

```text
A 10:00 -> 10:30
B 10:05 -> 10:35
C 10:10 -> 10:32
D 10:15 -> 10:40
```

`B` is strictly dominated by `C` and should not appear.

Verify profile iteration jumps correctly.

## 24.4 Transfer limit

Test max transfers:

```text
0
1
3
nil
```

Verify no explicit limit terminates and does not output cycles.

## 24.5 Minimum transfer buffer

Arrival 10:00, next departure:

```text
10:01:59 => reject with default 120 s
10:02:00 => accept
```

## 24.6 Different-stop walking transfer

Fake MapKit:

```text
Stop A -> Stop B = 180 seconds
buffer = 120
```

Require 300 seconds absent stronger GTFS rule.

## 24.7 Transfer type 2

MapKit = 180, user buffer = 120, GTFS min = 240:

```text
max(300, 240) = 300
```

GTFS min = 420:

```text
max(300, 420) = 420
```

## 24.8 Transfer type 3

Even if stops are 5 meters apart and MapKit is 10 seconds, reject the specifically forbidden transfer.

## 24.9 Timed transfer

Verify type 1 can remain usable with a scheduled gap below generic 120-second safety buffer when physical movement is feasible.

## 24.10 Linked trip 4/5

Type 4:

- no transfer increment;
- continuation works.

Type 5:

- requires alight/reboard;
- transfer count increments;
- buffer applies.

## 24.11 Rule specificity

Create conflicting stop-only, route-specific and trip-specific rules. Verify only the highest-specificity applicable rule governs the pair.

## 24.12 Parent station

A station-level rule must apply to child platforms.

## 24.13 Pathways

Create a station where straight-line platform distance is tiny but pathway traversal takes 5 minutes. Verify the internal station transfer uses the pathway graph.

## 24.14 Pickup/dropoff

No pickup => cannot board.  
No dropoff => cannot alight.  
Request-only pickup => obey policy.

## 24.15 Overtaking

Create local and express trips with same stop pattern where the later express overtakes the local.

Verify preprocessing separates them into safe route families and RAPTOR still finds the express.

## 24.16 Repeated stop in loop

A trip visits stop X twice. Verify pattern occurrence positions remain distinct and boarding/alighting reconstruction uses the correct occurrence.

## 24.17 Midnight

Trip service date Friday:

```text
23:55 -> 24:20
```

Query Saturday 00:05 and verify Friday-service trip is considered.

## 24.18 >48-hour service

Create a deliberately extreme fixture with a time above `48:00:00`. Verify service-day overlap logic uses `maximumServiceTime`, not a yesterday-only assumption.

## 24.19 DST spring transition

Europe/Luxembourg/Berlin timezone test on the spring-forward service day.

Verify GTFS service-second ordering remains monotonic and conversion uses noon-minus-12h semantics.

## 24.20 DST fall transition

Test the repeated wall-clock hour. Verify two distinct absolute instants are not accidentally collapsed.

## 24.21 Calendar without `calendar.txt`

Use only `calendar_dates.txt` additions and verify feed imports/routes.

## 24.22 Frequency exact times

Generate exact trip instances correctly and stop before `end_time` according to spec.

## 24.23 Inexact frequency

Verify policy marks approximate/conservative service rather than claiming a fixed exact departure.

## 24.24 Address door departure

MapKit access = 7 min; first vehicle = 17:12. Verify journey departure = 17:05.

## 24.25 Direct walk rules

Test all three cases from section 1.11.

## 24.26 Pagination equal timestamp

Ensure page 1 can end with one journey at 17:30 and `later()` may return another journey also at 17:30 when its stable sort key follows the cursor.

No same-time journey may be skipped because the cursor used only `departure + 1`.

## 24.27 Cancellation

Cancel a search during:

- CPU RAPTOR;
- MapKit request;
- HAFAS request.

Verify no stale page is emitted.

## 24.28 Realtime cancellation

Scheduled winner is cancelled. Backup becomes first and page is refilled.

## 24.29 Realtime missed transfer

Delay the first leg so the second leg can no longer be caught. Verify reroute chooses a different connection.

## 24.30 Realtime promotion

A route that is slower scheduled becomes better because the scheduled winner is delayed. Verify it can be promoted from reserve/refinement.

## 24.31 Ambiguous HAFAS match

Two departures share line/time signals. Verify ambiguous data is not applied to the wrong GTFS trip.

## 24.32 MapKit throttle

Fake `.loadingThrottled` during refinement. Verify fully validated routes survive and unresolved walking candidates are not presented as exact.

## 24.33 Delayed-past first boarding — mandatory regression

Fixture/query:

```text
query anchor:                         18:00
access walk:                           0 min
Trip A scheduled depart:              17:50
Trip A realtime depart:               18:05
Trip A effective destination arrival: 18:30
Trip B scheduled/effective depart:    18:03
Trip B effective destination arrival: 18:42
```

Verify:

- static-only RAPTOR returns Trip B and does not invent Trip A;
- best-effort realtime catch-up queries a lookback window containing 17:50;
- the HAFAS match creates a delayed-past `RealtimeBoardingEvent` for Trip A;
- merged RAPTOR can board Trip A at effective 18:05;
- Trip A becomes the first result;
- final output keeps scheduled 17:50 and effective 18:05 separately;
- with realtime disabled/unavailable, behavior returns to the static result.

## 24.34 Delayed-past transfer becomes catchable — mandatory regression

Fixture:

```text
first leg effective arrival:          18:20
minimum transfer requirement:          2 min
Trip C scheduled departure:           18:18
Trip C realtime departure:            18:24
```

Verify the static router rejects the transfer, the realtime-sensitive frontier fetches the stop's lookback board, the overlay injects Trip C, and the rerun accepts the transfer because 18:22 <= 18:24.

## 24.35 Delayed-past trip still not catchable

```text
ready at stop:                         18:20
Trip D scheduled departure:            18:10
Trip D realtime departure:             18:19
```

Verify Trip D remains unavailable. Realtime catch-up must not mean “allow any past scheduled trip”; effective departure must still satisfy the boarding threshold.

## 24.36 Effective-time dominance after catch-up

Use:

```text
A effective: 18:03 -> 18:42
B scheduled: 17:50, effective: 18:05 -> 18:30
```

Verify B strictly dominates A using effective times and A is removed even though B's scheduled departure was before the original query anchor.

## 24.37 Earlier/Later with delayed-past trip

A trip scheduled at 17:50 is predicted at 18:05. Verify it is ordered in the effective 18:05 cohort and is not skipped by a cursor derived from scheduled time. Equal effective-departure alternatives must still be preserved.

## 24.38 Realtime lookback boundary

Test a delayed trip whose scheduled event is exactly at the configured lookback boundary and one just outside it. Verify the boundary semantics are deterministic and the page realtime state does not falsely claim exhaustive live discovery outside the configured provider window.

## 24.39 Overlay deduplication

A future trip appears in both the normal scheduled candidate stream and the HAFAS overlay. Verify it is boarded once, uses effective patched events, and cannot generate duplicate journeys.

## 24.40 Catch-up cancellation/reachability

A delayed-past trip would otherwise be catchable, but HAFAS marks it cancelled or `reachable == false`. Verify the overlay masks the static trip and it is never returned.

---

# 25. Reference/brute-force correctness router for tests

Create a deliberately slow reference implementation used **only in tests**.

For small synthetic feeds, build a time-dependent/event graph and run a straightforward earliest-arrival Dijkstra or exhaustive dynamic program.

Generate random tiny networks and compare RAPTOR results for:

- earliest arrival;
- transfer-limit feasibility;
- pickup/dropoff restrictions;
- service-day activation;
- same-stop transfer buffers.

Property testing against an independently structured reference algorithm is one of the best defenses against a fast router that is subtly wrong.

Do not ship the reference router in the production target if it materially increases size.

---

# 26. Performance targets

The real production GTFS archive was not provided in this task, so do not fake exact feed row counts in code comments. Instrument the actual feed when available.

Reasonable engineering targets on a modern iPhone after snapshot load and walking resolution:

```text
point RAPTOR CPU p50:       < 10 ms preferred
point RAPTOR CPU p95:       < 25 ms preferred
5-result profile CPU:       < 100 ms preferred
Later/3 profile CPU:        < 60 ms preferred
routing snapshot warm load: < 200 ms preferred
```

These are targets, not correctness requirements. Network-backed MapKit/HAFAS latency is outside the CPU target and should be measured separately.

Aim for routing snapshot incremental memory comfortably below ~100 MB, ideally substantially lower. If the real feed requires more, profile first before adding lossy compression or unsafe complexity.

Most importantly:

> Once MapKit/HAFAS data is already cached for a session, tapping Later should feel immediate.

---

# 27. Production-feed diagnostics

After GTFS install, expose an internal diagnostic summary:

```text
feed fingerprint
date range
maximum service time
agencies
stops by location_type
routes
trips
stop_times
services
active trip instances per representative day
route patterns before overtaking partition
route families after partition
families split because of overtaking
transfer rules by type
frequency rows by exact_times
pathway rows
shape rows
routing sidecar bytes
snapshot build duration
```

This will let the project tune the implementation once the actual Luxembourg archive is available without rewriting the design.

For live routing diagnostics, additionally expose per-query debug metrics (not persisted as user history): configured lookback, board windows requested, board-cache hits, frontier stop count, delayed-past events injected, overlay revisions, and RAPTOR reruns caused by realtime. These values are essential to verify that catch-up discovery works without silently exploding HAFAS traffic.

---

# 28. Security/privacy boundaries

The API-key/relay architecture is already handled by the app. The router should nevertheless:

- never log API keys;
- never include API keys in diagnostic error text;
- not persist user origin/destination history inside MobiliteitKit unless explicitly requested by the app;
- keep MapKit request caching ephemeral by default;
- allow the app to cancel/discard a session and release endpoint data.

---

# 29. Documentation requirements

Update DocC with:

```text
JourneyPlanning.md
RoutingPreferences.md
RealtimeRouting.md
WalkingRouting.md
RoutingDataFormat.md (internal/developer-facing)
```

Explain clearly:

- static vs realtime semantics;
- door-to-door departure/arrival;
- the strict dominance rule;
- offline limitations of MapKit;
- max transfer behavior;
- why a result can disappear after realtime refinement;
- why equal-departure routes can both appear.

---

# 30. API example the finished package should support

Conceptual host-app flow:

```swift
let router = try await TransitRouter(
    databaseURL: gtfsDatabaseURL,
    walkingProvider: MapKitWalkingRouter(),
    realtimeProvider: hafasProvider
)

let query = RouteQuery(
    origin: .coordinate(
        Coordinate(latitude: 49.611, longitude: 6.131),
        label: "Home"
    ),
    destination: .stop(id: "200405060"),
    departureTime: selectedDate,
    preferences: RoutingPreferences(
        maxTransfers: 3,
        minimumTransferSeconds: 120
    ),
    realtimePolicy: .preferRealtime
)

let session = try await router.makeSession(for: query)
let firstPage = try await session.initial()   // up to 5
let nextPage = try await session.later()     // up to 3
let prevPage = try await session.earlier()   // up to 3
```

Exact initializers may differ; preserve this level of simplicity for app code.

---

# 31. Acceptance criteria / Definition of Done

Do not mark this feature complete until all of the following are true.

## Data correctness

- [ ] GTFS imports without loading the whole feed object graph.
- [ ] calendar-only and calendar-dates-only service definitions work.
- [ ] times above 24:00 work.
- [ ] DST conversion follows GTFS service-time semantics.
- [ ] route patterns use stop occurrence sequences, not just route IDs.
- [ ] overtaking is detected/partitioned safely.
- [ ] transfer specificity works.
- [ ] transfer types 0–5 work.
- [ ] parent station rules work.
- [ ] pickup/dropoff restrictions work.
- [ ] exact frequency service works.
- [ ] inexact frequency service is not falsely presented as exact.

## Routing behavior

- [ ] first route is earliest-arriving subject to leave-after time.
- [ ] door departure includes origin walking.
- [ ] door arrival includes destination walking.
- [ ] initial returns up to 5.
- [ ] Later returns next 3.
- [ ] Earlier returns previous 3.
- [ ] equal departure routes are not automatically discarded.
- [ ] only strict later-departure + earlier-arrival domination removes a journey.
- [ ] max transfers default 3.
- [ ] max transfers nil terminates correctly.
- [ ] default transfer safety buffer is 120 seconds.
- [ ] direct walking obeys the exact special rules.
- [ ] all transit modes are considered by default.

## Walking

- [ ] direct walking uses MapKit when available.
- [ ] displayed access/egress/transfer walking durations use MapKit or authoritative GTFS pathways/transfer times as specified.
- [ ] no unresolved geometric duration appears as a final exact route.
- [ ] MapKit requests are deduplicated and concurrency-bounded.
- [ ] MapKit cancellation works.
- [ ] throttling degrades gracefully.

## Realtime

- [ ] static routing works with HAFAS disabled.
- [ ] HAFAS stop IDs are mapped, not assumed equal to GTFS IDs.
- [ ] board requests are grouped by relevant stop/time window.
- [ ] pass-list realtime stop times are used where available.
- [ ] cancellations remove trips.
- [ ] delayed missed transfers trigger rerouting.
- [ ] final dominance uses effective/realtime times.
- [ ] ambiguous live matches never mutate the wrong trip.
- [ ] HAFAS failure returns scheduled routes.

## Performance/concurrency

- [ ] no SQLite calls in the numerical RAPTOR inner loop.
- [ ] no actor hops per route/stop scan.
- [ ] routing snapshot is immutable and safely shared.
- [ ] stale searches are cancellable.
- [ ] feed generation can swap while an old session finishes safely.
- [ ] Later uses cached session/profile state.
- [ ] Instruments/signposts exist for all major phases.
- [ ] production-feed benchmark numbers are recorded before final merge.

## Testing

- [ ] synthetic unit matrix passes.
- [ ] DST tests pass.
- [ ] brute-force reference comparisons pass on randomized tiny feeds.
- [ ] realtime fixtures pass.
- [ ] delayed-past first-boarding regression (24.33) passes.
- [ ] delayed-past transfer-catchability regression (24.34) passes.
- [ ] effective-time dominance and Earlier/Later catch-up regressions pass.
- [ ] fake MapKit refinement tests pass.
- [ ] no existing MobiliteitKit tests regress.

---

# 32. Important implementation notes / traps to avoid

1. **Do not use final weak Pareto dominance.** The product requires both departure and arrival improvements to be strict.
2. **Do not skip equal departure timestamps when paging.** Cursor includes signature/order.
3. **Do not assume a GTFS route is one RAPTOR pattern.** Stop sequences vary.
4. **Do not assume route patterns are FIFO.** Detect overtaking.
5. **Do not use `direction_id` as routing direction logic.**
6. **Do not use local midnight + wall seconds on DST days.**
7. **Do not assume only previous service day matters after midnight.** Use maximum service time.
8. **Do not add GTFS `min_transfer_time` on top of MapKit walk blindly.** Use `max(...)` where appropriate.
9. **Do not apply default transfer buffer to in-seat type 4.**
10. **Do not infer in-seat transfer merely from `block_id`.**
11. **Do not invent exact fixed departures for frequency `exact_times=0`.**
12. **Do not trust HAFAS ID equality with GTFS.**
13. **Do not parse `JourneyDetailRef.ref` as a stable documented schema.** Treat it as opaque.
14. **Do not call HAFAS per trip.** Batch by stop/time window.
15. **Do not call MapKit for all stop pairs.** Lazy-refine candidates.
16. **Do not show optimistic/geodesic walk estimates to users as exact.**
17. **Do not let MapKit failure kill GTFS routing.**
18. **Do not let HAFAS failure kill GTFS routing.**
19. **Do not decode every shape during route calculation.** Only final candidates.
20. **Do not allocate dictionaries/classes inside the hot route scan if dense arrays suffice.**
21. **Do not over-parallelize the CPU core before profiling.**
22. **Do cancel stale MapKit/HAFAS work.**
23. **Do retain feed generation in journey/session state.**
24. **Do rerun transfer feasibility after realtime changes.**
25. **Do re-run final strict dominance after realtime and final MapKit durations.**
26. **Do not restrict realtime to trips found by static RAPTOR.** Delayed-past boardings must be discoverable through HAFAS lookback + overlay injection.
27. **Do not binary-search only scheduled departures when a realtime overlay is active.** Merge effective-time overlay events into boarding candidate enumeration.
28. **Do not put a delayed service on the Earlier page merely because its scheduled timestamp is old.** Live pagination uses effective ordering.

---

# 33. Sources / technical references

The implementation should be checked against current specifications while coding.

- GTFS Schedule Reference: <https://gtfs.org/documentation/schedule/reference/>
- RAPTOR paper, Delling/Pajor/Werneck: <https://www.microsoft.com/en-us/research/publication/round-based-public-transit-routing/>
- Apple `MKDirections`: <https://developer.apple.com/documentation/mapkit/mkdirections>
- Apple `MKDirections.Request`: <https://developer.apple.com/documentation/mapkit/mkdirections/request>
- Apple `MKError.Code.loadingThrottled`: <https://developer.apple.com/documentation/mapkit/mkerror/code/loadingthrottled>
- Mobilitéit API documentation supplied by the user: <https://github.com/Felix3qH4/Mobiliteit.lu-API-documentation>

For HAFAS stop/pass-list field names that are not documented in the user-supplied Mobilitéit repository, use response fixtures from the actual Mobilitéit endpoint and keep decoding optional. A generic HAFAS interface specification can be used as a clue, not as proof that Mobilitéit returns a field.

---

# 34. Final implementation direction

The intended final system is:

```text
                 ┌──────────────────────────────┐
                 │       App / SwiftUI UI       │
                 │ MapKit search -> coordinates │
                 └──────────────┬───────────────┘
                                │ RouteQuery
                                ▼
                 ┌──────────────────────────────┐
                 │      TransitRouter actor     │
                 │ captures immutable snapshot  │
                 └──────────────┬───────────────┘
                                ▼
                 ┌──────────────────────────────┐
                 │ JourneyPlanningSession actor │
                 │ profile + page + live state  │
                 └──────┬───────────────┬───────┘
                        │               │
             walking    │               │ realtime
                        ▼               ▼
              ┌────────────────┐  ┌──────────────────┐
              │ MapKit walking │  │ HAFAS coordinator│
              │ lazy refinement│  │ batched overlays │
              └───────┬────────┘  └────────┬─────────┘
                      │                    │
                      └──────────┬─────────┘
                                 ▼
                 ┌──────────────────────────────┐
                 │  Query-local immutable view  │
                 │ timetable + walks + realtime │
                 └──────────────┬───────────────┘
                                ▼
                 ┌──────────────────────────────┐
                 │  Pure cache-friendly RAPTOR  │
                 │ no await / no SQLite / no UI │
                 └──────────────┬───────────────┘
                                ▼
                 ┌──────────────────────────────┐
                 │ Event-driven profile iterator│
                 │ + cohort lookahead + paging  │
                 └──────────────┬───────────────┘
                                ▼
                 ┌──────────────────────────────┐
                 │ Final strict dominance/filter│
                 │ + complete Journey material. │
                 └──────────────────────────────┘
```

The core principle is simple:

> **Preprocess static GTFS heavily, keep the interactive timetable scan entirely in compact memory, ask MapKit only for walking edges that may matter, ask HAFAS only for live data around candidate journeys and bounded realtime-sensitive catch-up frontiers, then rerun and validate before presentation.**

That architecture gives the app the best combination of speed, offline resilience, exact timetable semantics, route quality, and future extensibility on a phone.


---

# 35. Revision 2 changelog — realtime catch-up

Revision 2 closes a correctness gap in a static-first-only refinement design. It explicitly requires discovery and injection of trips that RAPTOR would otherwise skip because their **scheduled** departure is before the boarding threshold even though their **effective realtime** departure is still in the future.

The required architecture is now:

```text
MapKit access resolution
        ↓
HAFAS lookback bootstrap for promising access stops
        ↓
query-local immutable realtime boarding overlay
        ↓
RAPTOR over static GTFS + overlay
        ↓
realtime-sensitive interchange frontier discovery
        ↓
additional HAFAS lookback boards
        ↓
new overlay revision + RAPTOR rerun as needed
        ↓
MapKit final validation
        ↓
effective-time dominance + pagination
```

Scheduled timestamps remain first-class data, but **effective timestamps govern live catchability and final live profile ordering** whenever a high-confidence HAFAS patch exists. Offline behavior remains unchanged.
