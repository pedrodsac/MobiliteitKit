# ``MobiliteitKit``

MobiliteitKit provides a local, queryable view of a static GTFS feed and a
small typed client for the documented Mobilitéit HAFAS endpoints.

## Overview

Use the package as two complementary data layers:

- **Offline schedules:** install a GTFS ZIP with ``GTFSArchiveInstaller``, then
  query the replacement SQLite database through the actor-isolated ``GTFSStore``.
- **Live overlays:** use ``MobiliteitAPIClient`` for nearby stops and departure
  boards. HAFAS identifiers are opaque and should not be treated as GTFS IDs.

The importer is designed for mobile-sized memory budgets. ZIP entries are
extracted and parsed a row at a time, large GTFS string identifiers are mapped
to compact SQLite keys, stop lookups use an R-tree, and shapes are stored as
compressed coordinate deltas. Installation happens through a staging database,
so a previously installed feed remains available when an update fails.

## A typical offline flow

```swift
import MobiliteitKit

let databaseURL = try FileManager.default
    .url(for: .applicationSupportDirectory, in: .userDomainMask,
         appropriateFor: nil, create: true)
    .appendingPathComponent("Mobiliteit/gtfs.sqlite")

let feed = try await GTFSArchiveInstaller.downloadAndInstall(
    from: latestFeedURL,
    databaseAt: databaseURL,
    generation: 1
)

let store = try GTFSStore(databaseAt: databaseURL)
let stops = try await store.searchStops(matching: "gare")
let departures = try await store.nextScheduledDepartures(
    fromStopID: stops[0].id
)
```

``ServiceTime`` deliberately retains service-day overflow: `25:10:00` is
later than `24:00:00` and still belongs to the preceding GTFS service day.
Use ``GTFSStore/nextScheduledDepartures(fromStopID:at:horizon:limit:)`` when
turning a wall-clock `Date` into a departure window across midnight.

## A typical live flow

```swift
let client = MobiliteitAPIClient(apiKey: apiKey)
let nearby = try await client.nearbyStops(
    .init(coordinate: .init(latitude: 49.611, longitude: 6.131),
          radiusMeters: 500, maximumResults: 20)
)

let board = try await client.departureBoard(
    .init(stationID: nearby[0].id,
          realtimeMode: .full,
          includePasslist: true)
)
```

If the app lets the user configure an API relay, pass the saved text value to
the string-based initializer. The value can include a relay path prefix:

```swift
let client = try MobiliteitAPIClient(
    apiKey: apiKey,
    apiURL: savedAPIURLText
)
```

Keep the API key in the host app's secure configuration and present live board
results as an overlay beside the offline schedule. The package does not merge
or mutate the installed GTFS database with realtime responses.

## Topics

### Installing and querying GTFS

- ``GTFSArchiveInstaller``
- ``GTFSStore``
- <doc:OfflineGTFS>

### Live HAFAS API

- ``MobiliteitAPIClient``
- ``HafasNearbyStopsRequest``
- ``HafasDepartureBoardRequest``
- <doc:LiveHAFAS>

### Time, dates, and geography

- ``ServiceTime``
- ``GTFSDate``
- ``ServiceDay``
- ``Coordinate``

### Offline feed models

- ``FeedInfo``
- ``Agency``
- ``TransitRoute``
- ``TransitStop``
- ``TransitTrip``
- ``TripStopTime``
- ``ScheduledDeparture``
- ``ServiceCalendar``
- ``CalendarException``
- ``Frequency``
- ``TransferRule``
- ``Shape``

### Live response models

- ``HafasNearbyStopsEnvelope``
- ``HafasDepartureBoardEnvelope``
- ``HafasDepartureBoard``
- ``HafasStopLocation``
- ``HafasDeparture``
- ``HafasJourneyReference``
- ``HafasProduct``
- ``HafasIcon``
- ``HafasColor``
- ``HafasNote``
- ``HafasPasslistStop``
- ``OneOrMany``

### Errors and API constants

- ``GTFSArchiveError``
- ``MobiliteitAPIError``
- ``HafasRealtimeMode``
- ``HafasProductClass``
