# Install and query offline GTFS data

Use the offline layer when the app needs predictable schedule queries without
network access. A feed update has two stages: ``GTFSArchiveInstaller`` imports
the archive into a temporary SQLite file, then replaces the destination only
after the import and indexes have completed.

## Install a local archive

```swift
let info = try await GTFSArchiveInstaller.install(
    archiveAt: archiveURL,
    databaseAt: databaseURL,
    generation: 7
)

print("Feed covers \(info.firstServiceDate) through \(info.lastServiceDate)")
```

The required source files are `agency.txt`, `stops.txt`, `routes.txt`,
`trips.txt`, `stop_times.txt`, `calendar.txt`, and `shapes.txt`. The importer
also understands `calendar_dates.txt`, `frequencies.txt`, and `transfers.txt`
when those files are present. An incomplete or malformed archive throws
``GTFSArchiveError``.

## Open the installed database

``GTFSStore`` opens the database read-only and serializes access through an
actor. Create one store for the installed database and call its methods with
`await` from other concurrency domains.

```swift
let store = try GTFSStore(databaseAt: databaseURL)
let feed = await store.feedInfo()

guard let route = try await store.route(id: "route-1") else { return }
let trips = try await store.trips(forRouteID: route.id, activeOn: feed.firstServiceDate)
```

The returned values are small, `Sendable` value types. The source archive is
not retained at runtime.

## Work with service-day time

GTFS encodes trips that continue after midnight using times such as
`25:10:00`. Parse those values as ``ServiceTime`` rather than converting them
to a Foundation `Date` too early:

```swift
let afterMidnight = try ServiceTime(parsing: "25:10:00")
let departures = try await store.scheduledDepartures(
    fromStopID: "stop-a",
    on: feed.firstServiceDate,
    notBefore: afterMidnight
)
```

Use ``GTFSStore/scheduledArrivals(atStopID:on:notBefore:limit:)`` for alighting
events. Both methods honor GTFS pickup/drop-off restrictions and return the
service day that owns each event.

For a UI clock, ``GTFSStore/nextScheduledDepartures(fromStopID:at:horizon:limit:)``
interprets the supplied `Date` in the feed's agency timezone and searches the
preceding service day when necessary. This preserves trips after midnight and
avoids treating a daylight-saving transition as exactly 24 hours.

## Search and map stops

```swift
let textMatches = try await store.searchStops(matching: "eto")
let nearby = try await store.nearbyStops(
    to: Coordinate(latitude: 49.611, longitude: 6.131),
    withinMeters: 500
)
```

Text matching folds case and diacritics but returns the original display text.
Nearby results are sorted by exact distance after an indexed bounding-box
candidate search.

## Inspect the rest of a feed

The store exposes the source schedule graph without exposing SQLite details:

- ``GTFSStore/stopTimes(forTripID:)`` returns a trip's ordered stops.
- ``GTFSStore/shape(id:)`` decodes a stored shape into coordinates.
- ``GTFSStore/calendar(forServiceID:)`` and
  ``GTFSStore/calendarExceptions(forServiceID:)`` expose regular rules and
  date overrides separately.
- ``GTFSStore/frequencies(forTripID:)`` returns frequency intervals.
- ``GTFSStore/transferRules(fromStopID:)`` returns only source transfer rules;
  it does not invent walking transfers.
