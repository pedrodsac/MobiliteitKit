# Routing preferences

`RoutingPreferences` defaults to at most three transfers and a 120-second
minimum transfer safety time. `maxTransfers` may be `nil`, which runs until no
label improves rather than imposing a product limit. Route-type filtering is a
hard filter; other route preferences are deterministic secondary ordering.

GTFS minimum-transfer rules are resolved at their highest specificity. Type 3
rejects a transfer; type 1 and linked type 4 permit the declared connection
without adding the generic safety buffer; type 2 uses the stronger of the
feed's minimum and the configured safety time.
