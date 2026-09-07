# MobiliteitKit

An iOS 15+ Swift package for the Mobilitéit.lu static GTFS archive and its
documented HAFAS endpoints.

The package turns a downloaded GTFS ZIP into a replacement SQLite database. It
does not load stop_times.txt or shapes.txt into a Swift collection:

- ZIP entries are extracted and parsed one line at a time.
- GTFS string IDs are kept at entity boundaries and converted to compact SQLite
  integer keys in large tables.
- stop times are indexed by stop/time and retain service-day values after
  midnight (such as 25:10:00).
- each shape is stored as one delta/varint-encoded coordinate blob.
- nearby-stop lookups use an SQLite R-tree; a GTFSStore actor owns each
  connection and returns only value types.

## Install or update a feed

~~~swift
import MobiliteitKit

let databaseURL = try FileManager.default
    .url(for: .applicationSupportDirectory, in: .userDomainMask,
         appropriateFor: nil, create: true)
    .appendingPathComponent("Mobiliteit/gtfs.sqlite")

// Supply the current feed URL selected by the host app.
let info = try await GTFSArchiveInstaller.downloadAndInstall(
    from: latestFeedURL,
    databaseAt: databaseURL,
    generation: 1
)
~~~

The install builds a temporary database and replaces the destination only after
a successful import, leaving an existing installed feed intact on failure.

## Query offline schedules

~~~swift
let store = try GTFSStore(databaseAt: databaseURL)
let stops = try await store.searchStops(matching: "gare")
let departures = try await store.nextScheduledDepartures(
    fromStopID: stops[0].id
)
~~~

scheduledDepartures and scheduledArrivals query a chosen GTFSDate.
nextScheduledDepartures additionally checks the preceding service day, so
late service stored as 24:00:00+ is still visible after wall-clock midnight.
All schedule values are scheduled data; they are not live predictions.

The store exposes agencies, routes, stops, trips, trip stop times, shape
coordinates, calendar rules/exceptions, frequency rows, transfers, local
search, nearby stops, scheduled arrivals, and scheduled departures—the full
set of tables in the audited archive.

The complete API reference and workflow guides are maintained in the DocC
catalog at `Documentation/MobilitéitKit.docc`. Generate a static documentation
archive with:

~~~sh
swift package generate-documentation --target MobiliteitKit \
  --transform-for-static-hosting
~~~

## Live HAFAS endpoints

The API client uses typed Swift concurrency for the two documented endpoints:
nearby stops and departure boards. It intentionally keeps the API key owned by
the calling app.

~~~swift
let client = MobiliteitAPIClient(apiKey: apiKey)
let nearby = try await client.nearbyStops(
    .init(coordinate: .init(latitude: 49.611, longitude: 6.131),
          radiusMeters: 500, maximumResults: 20)
)
let board = try await client.departureBoard(
    .init(stationID: nearby[0].id, realtimeMode: .full, includePasslist: true)
)
~~~

HAFAS stop IDs are opaque and are not assumed to equal GTFS stop IDs. Live
board results should be displayed as an overlay alongside—not a mutation of—the
offline schedule.

## Data boundaries

This particular archive has no useful fare, station hierarchy/accessibility,
translation, GTFS-Realtime, alert, or feed-version data. A GTFS 0
accessibility/bicycle value is preserved as *unknown*, not interpreted as a
negative capability. The package stores source transfer rules only; it does not
invent walking transfers between different stops.

Run the suite with:

~~~sh
swift test
~~~
