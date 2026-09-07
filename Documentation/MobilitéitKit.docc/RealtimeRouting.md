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
