# Journey planning

`TransitRouter` builds an immutable, dense routing snapshot from the installed
GTFS database and creates a `JourneyPlanningSession` for each `RouteQuery`.
The timetable scan is synchronous CPU work: it performs neither SQLite access
nor network requests. Sessions provide up to five initial profile results and
three further results through `later()`.

Departure and arrival are door-to-door values. A coordinate endpoint includes
its resolved walking leg; a stop endpoint has zero walking at that stop.

## Profile rule

A journey is removed only when another journey leaves *strictly later* and
arrives *strictly earlier*. Equality intentionally remains visible, so two
different journeys with exactly the same departure can be paged separately.

## Offline operation

GTFS stop-to-stop routing, service calendars, transfers, pathways, and
service-day times work without live data. Coordinate routes require a supplied
`WalkingRoutingProvider`; the package never fabricates final walking durations
from straight-line distance.
