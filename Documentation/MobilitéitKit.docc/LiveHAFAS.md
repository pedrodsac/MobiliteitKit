# Use the live HAFAS endpoints

``MobiliteitAPIClient`` wraps the two documented endpoints used by the
package: nearby stops and departure boards. Requests and responses are typed,
`async`, and `Sendable`.

The host app may let the user enter the API endpoint. This supports relay
services, including ones mounted under a path prefix:

```swift
let client = try MobiliteitAPIClient(
    apiKey: apiKey,
    apiURL: savedAPIURLText
)
```

The entered value must be an absolute HTTP(S) URL. If the app uses the regular
Mobilitéit endpoint, the existing `MobiliteitAPIClient(apiKey:)` initializer
uses it by default.

## Find nearby stops

```swift
let request = HafasNearbyStopsRequest(
    coordinate: Coordinate(latitude: 49.611, longitude: 6.131),
    radiusMeters: 500,
    maximumResults: 20,
    language: "en"
)

let locations = try await client.nearbyStops(request)
for location in locations {
    print(location.id, location.name)
}
```

The returned `id` is the opaque HAFAS `StopLocation.id`. Store it separately
from a ``TransitStop/id``; the two systems do not promise interchangeable IDs.

## Request a departure board

```swift
let request = HafasDepartureBoardRequest(
    stationID: locations[0].id,
    durationMinutes: 60,
    maximumJourneys: 20,
    realtimeMode: .full,
    includePasslist: true
)

let board = try await client.departureBoard(request)
for departure in board.departures.values {
    print(departure.product?.line ?? "", departure.realtimeTime ?? departure.plannedTime ?? "")
}
```

HAFAS sometimes encodes one object and sometimes an array for the same JSON
field. ``OneOrMany`` normalizes both forms to `values`, including nested notes,
pass-list stops, products, and nearby-stop products.

## Product filters

The API's `products` parameter is a bitmask. Combine the raw values of
``HafasProductClass`` when a request should include more than one product:

```swift
let busAndTram = HafasProductClass.bus.rawValue | HafasProductClass.tram.rawValue
let request = HafasNearbyStopsRequest(
    coordinate: Coordinate(latitude: 49.611, longitude: 6.131),
    products: busAndTram
)
```

## Keep live data separate from the feed

Offline GTFS values are scheduled data; HAFAS values may include realtime
times, cancellations, notes, and pass lists. Present the live board as an
overlay keyed by its HAFAS identifiers instead of rewriting offline entities.
This makes failures, stale data, and differences in source coverage visible to
the host app.

## Handle failures

```swift
do {
    let board = try await client.departureBoard(request)
    // Update the live overlay.
} catch let error as MobiliteitAPIError {
    // Keep the offline schedule available and show an appropriate state.
    print(error.localizedDescription)
}
```

``MobiliteitAPIError`` distinguishes invalid caller input, non-HTTP responses,
HTTP failures, and response-decoding failures. Keep the API key in secure app
configuration and avoid logging generated request URLs.
