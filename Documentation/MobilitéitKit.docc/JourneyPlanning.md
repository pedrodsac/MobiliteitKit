# Journey planning

`TransitRouter` builds an immutable, dense routing snapshot from the installed
GTFS database and creates a `JourneyPlanningSession` for each `RouteQuery`.
The timetable scan is synchronous CPU work: it performs neither SQLite access
nor network requests. Sessions provide up to five initial profile results and
three further results through `later()`.

Departure and arrival are door-to-door values. A coordinate endpoint includes
its resolved walking leg; a stop endpoint has zero walking at that stop.

## Profile rule

`JourneyQualityPolicy` retains tradeoffs in departure, arrival, transfer count
and walking duration. A journey dominates another only when no metric is worse
and at least one is better, with matching accessibility and mode-preference
evidence. Distinct equal-quality journeys remain visible and page by stable ID.
Results appear chronologically; the recommendation uses the package’s quality
score and rider preferences. Direct walking comparisons do not consume transit
alternative slots.

## Offline operation

GTFS stop-to-stop routing, service calendars, transfers, pathways, and
service-day times work without live data. Coordinate routes require a supplied
`WalkingRoutingProvider`; the package never fabricates final walking durations
from straight-line distance.

## Complete planning sessions

`JourneyPlanner` owns prepared router caching and detects installed database changes.
Use `makePlanningSession(databaseURL:request:now:)` for a request-scoped
`JourneyResultSession`. Its `calculate(page:refresh:)`, `refreshRealtime(now:)`,
`updatePreferences(_:)` and `submitWalkingRefinement(_:)` operations return complete
`JourneyPlanningResult` snapshots. Adjacent empty pages succeed and retain the
accumulated profile. Render snapshots directly; do not rank or filter them again.

Results include the recommendation, pagination availability, feasibility, refinement
tokens and lazily loaded transit polylines. `Journey.summary` supplies display metrics
without recounting transfers across in-seat continuations. `JourneyQualityPolicy` owns the profile
quality decisions. `JourneyStatusEvidence.status(at:feasibility:)` and
`JourneySelectionPolicy` support time-dependent status and manual-selection fallback.

Clients continue supplying `WalkingRoutingProvider` and computing pedestrian
refinements. Submit each refined native walking span with its token, measured route
and adjusted departure/arrival times. Native leg indices remain stable during a
generation, including when several walks are replaced by one. Zero-length placeholder
walks retain indices and can be omitted from presentation. The package preserves
transit and continuation legs, rejects superseded tokens, updates walking caches,
validates the itinerary and permits one replacement search per generation.

The existing `TransitRouter` and `JourneyPlanningSession` remain available for
lower-level integrations. The package has no MapKit, SwiftUI or Valhalla dependency.

The facade preserves five initial transit alternatives, three per adjacent page,
three transfers by default, a three-hour initial forward horizon and a bounded
24-hour adjacent/arrival profile. Initial and later realtime lookbacks are 1,200
and 600 seconds. Its HAFAS provider retains the existing 32-request concurrency,
60-second cache and four-second acquisition deadline. The “avoid tight transfers”
choice uses a 180-second buffer and no same-stop shortfall; otherwise the buffer
is 120 seconds with up to 180 seconds of same-stop shortfall tolerance.
