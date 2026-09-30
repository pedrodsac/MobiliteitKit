import Foundation

/// Errors produced by the documented HAFAS endpoints.
public enum MobiliteitAPIError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case invalidResponse
    case httpStatus(Int, body: String?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let value): return "Invalid Mobilitéit API request: \(value)"
        case .invalidResponse: return "The Mobilitéit API returned a non-HTTP response."
        case .httpStatus(let status, _): return "The Mobilitéit API returned HTTP \(status)."
        case .decoding(let reason): return "Could not decode the Mobilitéit API response: \(reason)"
        }
    }
}

/// Controls whether HAFAS realtime fields are populated.
public enum HafasRealtimeMode: String, Sendable, Codable, Hashable {
    case serverDefault = "SERVER_DEFAULT"
    /// Compatibility spelling; ATP does not accept the legacy FULL value.
    public static var full: Self { .serverDefault }
    case off = "OFF"
}

/// Product-class bitmasks documented by the API.
public enum HafasProductClass: Int, Sendable, Codable, Hashable, CaseIterable {
    case expressTrain = 1
    case nationalTrain = 2
    case localTrain = 4
    case bus = 32
    case tram = 256
}

/// Parameters for the HAFAS nearby-stops endpoint.
///
/// Optional values are passed through to HAFAS when present. The `products`
/// field is a product-class bitmask; combine ``HafasProductClass`` raw values
/// when a filter is needed.
public struct HafasNearbyStopsRequest: Hashable, Sendable {
    public let coordinate: Coordinate
    public let radiusMeters: Int?
    public let maximumResults: Int?
    public let requestID: String?
    public let language: String?
    public let products: Int?
    public let locationType: String?
    public let locationSelectionMode: String?
    public let meta: String?
    public let stationAttributes: String?
    public let stationInfoTexts: String?

    public init(
        coordinate: Coordinate,
        radiusMeters: Int? = nil,
        maximumResults: Int? = nil,
        requestID: String? = nil,
        language: String? = nil,
        products: Int? = nil,
        locationType: String? = nil,
        locationSelectionMode: String? = nil,
        meta: String? = nil,
        stationAttributes: String? = nil,
        stationInfoTexts: String? = nil
    ) {
        self.coordinate = coordinate
        self.radiusMeters = radiusMeters
        self.maximumResults = maximumResults
        self.requestID = requestID
        self.language = language
        self.products = products
        self.locationType = locationType
        self.locationSelectionMode = locationSelectionMode
        self.meta = meta
        self.stationAttributes = stationAttributes
        self.stationInfoTexts = stationInfoTexts
    }
}

/// Parameters for the HAFAS departure-board endpoint.
///
/// `stationID` must be the opaque HAFAS `StopLocation.id`. It is not assumed
/// to be the same identifier as a GTFS stop ID.
public struct HafasDepartureBoardRequest: Hashable, Sendable {
    /// A HAFAS stop id (`StopLocation.id`) or, for Luxembourg's current feed,
    /// the numeric GTFS stop id accepted by the ATP departure-board endpoint.
    public let stationID: String
    /// Deprecated by HAFAS, retained for callers that need legacy behavior.
    public let externalStationID: String?
    public let requestID: String?
    public let language: String?
    public let directionStationID: String?
    public let date: GTFSDate?
    public let time: ServiceTime?
    public let durationMinutes: Int?
    public let maximumJourneys: Int?
    public let products: Int?
    public let operators: [String]
    public let lines: [String]
    public let filterEquivalentStops: Bool?
    public let attributes: [String]
    public let platforms: [String]
    public let realtimeMode: HafasRealtimeMode?
    public let includePasslist: Bool

    public init(
        stationID: String,
        externalStationID: String? = nil,
        requestID: String? = nil,
        language: String? = nil,
        directionStationID: String? = nil,
        date: GTFSDate? = nil,
        time: ServiceTime? = nil,
        durationMinutes: Int? = nil,
        maximumJourneys: Int? = nil,
        products: Int? = nil,
        operators: [String] = [],
        lines: [String] = [],
        filterEquivalentStops: Bool? = nil,
        attributes: [String] = [],
        platforms: [String] = [],
        realtimeMode: HafasRealtimeMode? = nil,
        includePasslist: Bool = false
    ) {
        self.stationID = stationID
        self.externalStationID = externalStationID
        self.requestID = requestID
        self.language = language
        self.directionStationID = directionStationID
        self.date = date
        self.time = time
        self.durationMinutes = durationMinutes
        self.maximumJourneys = maximumJourneys
        self.products = products
        self.operators = operators
        self.lines = lines
        self.filterEquivalentStops = filterEquivalentStops
        self.attributes = attributes
        self.platforms = platforms
        self.realtimeMode = realtimeMode
        self.includePasslist = includePasslist
    }
}

/// Typed async client for the two published Mobilitéit HAFAS API endpoints.
/// Keep the API key outside source control—e.g. in an app's Keychain-backed
/// configuration—and avoid logging generated request URLs.
public struct MobiliteitAPIClient: Sendable {
    /// The default Mobilitéit HAFAS API endpoint.
    public static let defaultBaseURL = URL(string: "https://cdt.hafas.de/opendata/apiserver")!
    private static let departureBoardCache = DepartureBoardCache()

    /// The HAFAS access key used for requests.
    public let apiKey: String
    /// The endpoint root. Override this for a relay or compatible test server.
    public let baseURL: URL
    private let session: URLSession

    /// Creates a client for the Mobilitéit HAFAS API.
    ///
    /// - Parameters:
    ///   - apiKey: The access key issued for the API.
    ///   - baseURL: The API endpoint root.
    ///   - session: The URL session used for requests.
    public init(
        apiKey: String,
        baseURL: URL = MobiliteitAPIClient.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// Creates a client from a URL entered or stored by the host app.
    ///
    /// This overload is useful for settings screens and relay deployments,
    /// where the endpoint is typically kept as a `String` in app storage.
    /// The value may include a path prefix, such as
    /// `https://relay.example.com/hafas`.
    ///
    /// - Parameters:
    ///   - apiKey: The access key issued for the API, or the value expected by
    ///     the relay service.
    ///   - apiURL: An absolute HTTP or HTTPS API endpoint root.
    ///   - session: The URL session used for requests.
    /// - Throws: ``MobiliteitAPIError/invalidRequest(_:)`` when `apiURL` is
    ///   not an absolute HTTP(S) URL with a host.
    public init(
        apiKey: String,
        apiURL: String,
        session: URLSession = .shared
    ) throws {
        let value = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              url.host != nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MobiliteitAPIError.invalidRequest("apiURL must be an absolute HTTP(S) URL")
        }
        self.init(apiKey: apiKey, baseURL: url, session: session)
    }

    /// Fetches stops near a WGS-84 coordinate.
    ///
    /// - Throws: ``MobiliteitAPIError/invalidRequest(_:)`` for invalid
    ///   coordinates or limits, or a transport, HTTP, or decoding error.
    public func nearbyStops(_ request: HafasNearbyStopsRequest) async throws -> [HafasStopLocation] {
        guard request.coordinate.latitude.isFinite, request.coordinate.longitude.isFinite,
              (-90...90).contains(request.coordinate.latitude), (-180...180).contains(request.coordinate.longitude) else {
            throw MobiliteitAPIError.invalidRequest("coordinate is outside WGS-84 bounds")
        }
        if let radius = request.radiusMeters, radius < 0 {
            throw MobiliteitAPIError.invalidRequest("radiusMeters must not be negative")
        }
        if let maximum = request.maximumResults, !(1...5_000).contains(maximum) {
            throw MobiliteitAPIError.invalidRequest("maximumResults must be in 1...5000")
        }
        var items = baseItems()
        items += [
            .init(name: "originCoordLat", value: String(request.coordinate.latitude)),
            .init(name: "originCoordLong", value: String(request.coordinate.longitude)),
            .init(name: "r", value: request.radiusMeters.map(String.init)),
            .init(name: "maxNo", value: request.maximumResults.map(String.init)),
            .init(name: "requestId", value: request.requestID),
            .init(name: "lang", value: request.language),
            .init(name: "products", value: request.products.map(String.init)),
            .init(name: "type", value: request.locationType),
            .init(name: "locationSelectionMode", value: request.locationSelectionMode),
            .init(name: "meta", value: request.meta),
            .init(name: "sattributes", value: request.stationAttributes),
            .init(name: "sinfotexts", value: request.stationInfoTexts),
        ].filter { $0.value != nil }
        let response: HafasNearbyStopsEnvelope = try await fetch(path: "location.nearbystops", queryItems: items)
        return response.stopLocations.values
    }

    /// Fetches a departure board for an opaque HAFAS station identifier.
    /// Identical requests share a 60-second cache across all client instances,
    /// including callers in departure views and journey planning.
    ///
    /// - Throws: ``MobiliteitAPIError/invalidRequest(_:)`` when the station or
    ///   duration is invalid, or a transport, HTTP, or decoding error.
    public func departureBoard(
        _ request: HafasDepartureBoardRequest,
        refreshPolicy: RealtimeRefreshPolicy = .useCache
    ) async throws -> HafasDepartureBoard {
        try await departureBoardResponse(request, refreshPolicy: refreshPolicy).board
    }

    func departureBoardResponse(
        _ request: HafasDepartureBoardRequest, refreshPolicy: RealtimeRefreshPolicy
    ) async throws -> CachedBoardResponse {
        guard !request.stationID.isEmpty else { throw MobiliteitAPIError.invalidRequest("stationID is required") }
        if let duration = request.durationMinutes, !(0...1_439).contains(duration) {
            throw MobiliteitAPIError.invalidRequest("durationMinutes must be in 0...1439")
        }
        var items = baseItems()
        items += [
            .init(name: "id", value: request.stationID),
            .init(name: "extId", value: request.externalStationID),
            .init(name: "requestId", value: request.requestID),
            .init(name: "lang", value: request.language),
            .init(name: "direction", value: request.directionStationID),
            .init(name: "date", value: request.date?.description),
            .init(name: "time", value: request.time?.gtfsString),
            .init(name: "duration", value: request.durationMinutes.map(String.init)),
            .init(name: "maxJourneys", value: request.maximumJourneys.map(String.init)),
            .init(name: "products", value: request.products.map(String.init)),
            .init(name: "operators", value: request.operators.isEmpty ? nil : request.operators.joined(separator: ",")),
            .init(name: "lines", value: request.lines.isEmpty ? nil : request.lines.joined(separator: ",")),
            .init(name: "filterEquiv", value: request.filterEquivalentStops.map { $0 ? "1" : "0" }),
            .init(name: "attributes", value: request.attributes.isEmpty ? nil : request.attributes.joined(separator: ",")),
            .init(name: "platforms", value: request.platforms.isEmpty ? nil : request.platforms.joined(separator: ",")),
            .init(name: "rtMode", value: request.realtimeMode?.rawValue),
            .init(name: "passlist", value: request.includePasslist ? "1" : nil),
        ].filter { $0.value != nil }
        let requestURL = try url(path: "departureBoard", queryItems: items)
        return try await Self.departureBoardCache.response(
            for: requestURL.absoluteString, refreshPolicy: refreshPolicy
        ) {
            let response: HafasDepartureBoardEnvelope = try await fetch(requestURL: requestURL)
            guard response.departureBoard.errorCode == nil else {
                throw MobiliteitAPIError.invalidRequest(response.departureBoard.errorText ?? "HAFAS rejected the board")
            }
            return response.departureBoard
        }
    }

    private func baseItems() -> [URLQueryItem] {
        [.init(name: "accessId", value: apiKey), .init(name: "format", value: "json")]
    }

    private func fetch<Response: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> Response {
        try await fetch(requestURL: url(path: path, queryItems: queryItems))
    }

    private func url(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let url = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MobiliteitAPIError.invalidRequest("invalid endpoint")
        }
        components.queryItems = queryItems
        guard let requestURL = components.url else { throw MobiliteitAPIError.invalidRequest("invalid query") }
        return requestURL
    }

    private func fetch<Response: Decodable>(requestURL: URL) async throws -> Response {
        var request = URLRequest(url: requestURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobiliteitAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw MobiliteitAPIError.httpStatus(http.statusCode, body: String(data: data.prefix(8_192), encoding: .utf8))
        }
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.hafasResponseBytes] = data.count
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw MobiliteitAPIError.decoding(error.localizedDescription)
        }
    }
}

/// The decoded response envelope returned by `location.nearbystops`.
public struct HafasNearbyStopsEnvelope: Hashable, Sendable, Decodable {
    public let stopLocations: OneOrMany<HafasStopLocation>

    enum CodingKeys: String, CodingKey { case stopLocations = "StopLocation" }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicKey.self)

        // The ATP relay returns the documented HAFAS locations in a wrapper
        // array. Older responses exposed StopLocation directly at the root.
        if let key = DynamicKey(stringValue: "stopLocationOrCoordLocation"), values.contains(key) {
            let locations = try values.decode([HafasNearbyLocation].self, forKey: key)
            stopLocations = OneOrMany(locations.compactMap(\.stopLocation))
            return
        }

        guard let key = DynamicKey(stringValue: "StopLocation") else {
            stopLocations = OneOrMany([])
            return
        }
        stopLocations = try values.decodeIfPresent(OneOrMany<HafasStopLocation>.self, forKey: key) ?? OneOrMany([])
    }
}

private struct HafasNearbyLocation: Hashable, Sendable, Decodable {
    let stopLocation: HafasStopLocation?

    enum CodingKeys: String, CodingKey { case stopLocation = "StopLocation" }
}

/// The decoded response returned by `departureBoard`.
///
/// The current ATP endpoint puts `Departure` directly at the top level. Older
/// HAFAS deployments have wrapped the same value in `DepartureBoard`, so
/// accept both shapes while the public client continues to return a single
/// canonical board value.
public struct HafasDepartureBoardEnvelope: Hashable, Sendable, Decodable {
    public let departureBoard: HafasDepartureBoard
    enum CodingKeys: String, CodingKey { case departureBoard = "DepartureBoard" }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let wrapped = try values.decodeIfPresent(HafasDepartureBoard.self, forKey: .departureBoard) {
            departureBoard = wrapped
        } else {
            departureBoard = try HafasDepartureBoard(from: decoder)
        }
    }
}

/// A decoded HAFAS departure-board payload.
public struct HafasDepartureBoard: Hashable, Sendable, Decodable {
    public let departures: OneOrMany<HafasDeparture>
    public let errorCode: String?
    public let errorText: String?
    public let requestID: String?
    public let serverVersion: String?
    /// Decoded response bytes, before discarding unused HAFAS metadata.
    public let responseBytes: Int

    enum CodingKeys: String, CodingKey {
        case departures = "Departure"
        case errorCode, errorText, requestID = "requestId", serverVersion
    }

    init(departures: [HafasDeparture], responseBytes: Int = 0) {
        self.departures = .init(departures)
        self.responseBytes = responseBytes
        errorCode = nil; errorText = nil; requestID = nil; serverVersion = nil
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        departures = try values.decodeIfPresent(OneOrMany<HafasDeparture>.self, forKey: .departures) ?? .init([])
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
        errorText = try values.decodeIfPresent(String.self, forKey: .errorText)
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID)
        serverVersion = try values.decodeIfPresent(String.self, forKey: .serverVersion)
        responseBytes = decoder.userInfo[.hafasResponseBytes] as? Int ?? 0
    }
}

/// A stop location returned by HAFAS.
public struct HafasStopLocation: Hashable, Sendable, Codable {
    public let id: String
    public let externalID: String?
    public let name: String
    public let longitude: Double?
    public let latitude: Double?
    public let weight: Int?
    public let distanceMeters: Int?
    public let products: Int?
    public let productsAtStop: OneOrMany<HafasProduct>

    enum CodingKeys: String, CodingKey {
        case id, name, weight, products
        case externalID = "extId"
        case longitude = "lon"
        case latitude = "lat"
        case distanceMeters = "dist"
        case productsAtStop = "productAtStop"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        externalID = try values.decodeIfPresent(String.self, forKey: .externalID)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        weight = try values.decodeFlexibleInt(forKey: .weight)
        distanceMeters = try values.decodeFlexibleInt(forKey: .distanceMeters)
        products = try values.decodeFlexibleInt(forKey: .products)
        productsAtStop = try values.decodeIfPresent(OneOrMany<HafasProduct>.self, forKey: .productsAtStop) ?? .init([])
    }
}

/// One departure-board row, including optional realtime and pass-list data.
public struct HafasDeparture: Hashable, Sendable, Codable {
    public let journeyReference: HafasJourneyReference?
    public let product: HafasProduct?
    public let notes: OneOrMany<HafasNote>
    public let passlist: OneOrMany<HafasPasslistStop>
    public let name: String?
    public let type: String?
    public let stop: String?
    public let stopID: String?
    public let stopExternalID: String?
    public let plannedTime: String?
    public let plannedDate: String?
    public let realtimeTime: String?
    public let realtimeDate: String?
    public let prognosisType: String?
    public let cancelled: Bool?
    public let reachable: Bool?
    public let direction: String?
    public let platform: HafasPlatform?
    public let realtimePlatform: HafasPlatform?
    public let trainNumber: String?
    public let trainCategory: String?

    enum CodingKeys: String, CodingKey {
        case journeyReference = "JourneyDetailRef"
        case product = "Product"
        case notes = "Notes"
        case passlist = "Stops"
        case name, type, stop, stopID = "stopid", stopExternalID = "stopExtId"
        case plannedTime = "time", plannedDate = "date", realtimeTime = "rtTime", realtimeDate = "rtDate"
        case prognosisType, cancelled, reachable, direction, platform, realtimePlatform = "rtPlatform"
        case trainNumber, trainCategory
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        journeyReference = try values.decodeIfPresent(HafasJourneyReference.self, forKey: .journeyReference)
        if let singleProduct = try? values.decode(HafasProduct.self, forKey: .product) {
            product = singleProduct
        } else {
            product = try values.decodeIfPresent(OneOrMany<HafasProduct>.self, forKey: .product)?.values.first
        }
        notes = try Self.decodeNestedArray(values, key: .notes, nested: "Note")
        passlist = try Self.decodeNestedArray(values, key: .passlist, nested: "Stop")
        name = try values.decodeIfPresent(String.self, forKey: .name)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        stop = try values.decodeIfPresent(String.self, forKey: .stop)
        stopID = try values.decodeIfPresent(String.self, forKey: .stopID)
        stopExternalID = try values.decodeIfPresent(String.self, forKey: .stopExternalID)
        plannedTime = try values.decodeIfPresent(String.self, forKey: .plannedTime)
        plannedDate = try values.decodeIfPresent(String.self, forKey: .plannedDate)
        realtimeTime = try values.decodeIfPresent(String.self, forKey: .realtimeTime)
        realtimeDate = try values.decodeIfPresent(String.self, forKey: .realtimeDate)
        prognosisType = try values.decodeIfPresent(String.self, forKey: .prognosisType)
        cancelled = try values.decodeIfPresent(Bool.self, forKey: .cancelled)
        reachable = try values.decodeIfPresent(Bool.self, forKey: .reachable)
        direction = try values.decodeIfPresent(String.self, forKey: .direction)
        platform = try values.decodeIfPresent(HafasPlatform.self, forKey: .platform)
        realtimePlatform = try values.decodeIfPresent(HafasPlatform.self, forKey: .realtimePlatform)
        trainNumber = try values.decodeIfPresent(String.self, forKey: .trainNumber)
        trainCategory = try values.decodeIfPresent(String.self, forKey: .trainCategory)
    }

    private static func decodeNestedArray<Value: Codable & Hashable & Sendable, Key: CodingKey>(
        _ values: KeyedDecodingContainer<Key>, key: Key, nested: String
    ) throws -> OneOrMany<Value> {
        guard values.contains(key), !(try values.decodeNil(forKey: key)) else { return .init([]) }
        if let container = try? values.nestedContainer(keyedBy: DynamicKey.self, forKey: key),
           let nestedKey = DynamicKey(stringValue: nested), container.contains(nestedKey) {
            return try container.decodeIfPresent(OneOrMany<Value>.self, forKey: nestedKey) ?? .init([])
        }
        return try values.decode(OneOrMany<Value>.self, forKey: key)
    }
}

/// A platform/quay value. ATP normally returns an object, but some HAFAS
/// deployments return the display text directly.
public struct HafasPlatform: Hashable, Sendable, Codable {
    public let type: String?
    public let text: String?

    enum CodingKeys: String, CodingKey { case type, text }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            type = nil
            self.text = text
            return
        }

        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        text = try values.decodeIfPresent(String.self, forKey: .text)
    }
}

/// An opaque reference that can be used to identify a HAFAS journey.
public struct HafasJourneyReference: Hashable, Sendable, Codable {
    public let reference: String
    enum CodingKeys: String, CodingKey { case reference = "ref" }
}

/// Product and operator information attached to a HAFAS journey.
public struct HafasProduct: Hashable, Sendable, Codable {
    public let icon: HafasIcon?
    public let name: String?
    public let line: String?
    public let lineID: String?
    public let category: String?
    public let productClass: Int?
    public let categoryShort: String?
    public let categoryLong: String?
    public let operatorCode: String?
    public let operatorName: String?
    /// The API returns either one administrator code or an array, depending on
    /// operator; the client consistently exposes an array.
    public let administrations: [String]

    enum CodingKeys: String, CodingKey {
        case icon, name, line, lineID = "lineId", category = "catOut", productClass = "cls"
        case categoryShort = "catOutS", categoryLong = "catOutL", operatorCode, operatorName = "operator", administrations = "admin"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        icon = try values.decodeIfPresent(HafasIcon.self, forKey: .icon)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        line = try values.decodeIfPresent(String.self, forKey: .line)
        lineID = try values.decodeIfPresent(String.self, forKey: .lineID)
        category = try values.decodeIfPresent(String.self, forKey: .category)
        productClass = try values.decodeFlexibleInt(forKey: .productClass)
        categoryShort = try values.decodeIfPresent(String.self, forKey: .categoryShort)
        categoryLong = try values.decodeIfPresent(String.self, forKey: .categoryLong)
        operatorCode = try values.decodeIfPresent(String.self, forKey: .operatorCode)
        operatorName = try values.decodeIfPresent(String.self, forKey: .operatorName)
        administrations = try values.decodeStringArray(forKey: .administrations)
    }
}

/// Display metadata for a HAFAS product.
public struct HafasIcon: Hashable, Sendable, Codable {
    public let resource: String?
    public let foregroundColor: HafasColor?
    public let backgroundColor: HafasColor?
    enum CodingKeys: String, CodingKey { case resource = "res", foregroundColor, backgroundColor }
}

/// An RGB or hexadecimal color supplied by HAFAS.
public struct HafasColor: Hashable, Sendable, Codable {
    public let red: Int?
    public let green: Int?
    public let blue: Int?
    public let hex: String?
    enum CodingKeys: String, CodingKey { case red = "r", green = "g", blue = "b", hex }
}

/// A note or service message attached to a HAFAS departure.
public struct HafasNote: Hashable, Sendable, Codable {
    public let value: String?
    public let key: String?
    public let type: String?
    public let routeIndexFrom: Int?
    public let routeIndexTo: Int?
    public let priority: Int?
    public let textNormal: String?
    public let textLong: String?
    public let textShort: String?
    enum CodingKeys: String, CodingKey {
        case value, key, type, routeIndexFrom = "routeIdxFrom", routeIndexTo = "routeIdxTo", priority
        case textNormal = "textN", textLong = "textL", textShort = "textS"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        key = try values.decodeIfPresent(String.self, forKey: .key)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        routeIndexFrom = try values.decodeFlexibleInt(forKey: .routeIndexFrom)
        routeIndexTo = try values.decodeFlexibleInt(forKey: .routeIndexTo)
        priority = try values.decodeFlexibleInt(forKey: .priority)
        textNormal = try values.decodeIfPresent(String.self, forKey: .textNormal)
        textLong = try values.decodeIfPresent(String.self, forKey: .textLong)
        textShort = try values.decodeIfPresent(String.self, forKey: .textShort)
    }
}

/// A stop in a HAFAS departure's optional pass list.
public struct HafasPasslistStop: Hashable, Sendable, Codable {
    public let name: String?
    public let id: String?
    public let externalID: String?
    public let routeIndex: Int?
    public let longitude: Double?
    public let latitude: Double?
    public let departureTime: String?
    public let departureDate: String?
    public let arrivalTime: String?
    public let arrivalDate: String?
    /// Optional per-stop predictions. HAFAS deployments vary, so these remain
    /// deliberately optional rather than turning an omitted field into an
    /// on-time assertion.
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
    enum CodingKeys: String, CodingKey {
        case name, id, externalID = "extId", routeIndex = "routeIdx", longitude = "lon", latitude = "lat"
        case departureTime = "depTime", departureDate = "depDate", arrivalTime = "arrTime", arrivalDate = "arrDate"
        case realtimeDepartureTime = "rtDepTime", realtimeDepartureDate = "rtDepDate"
        case realtimeArrivalTime = "rtArrTime", realtimeArrivalDate = "rtArrDate"
        case realtimeDepartureTrack = "rtDepTrack", realtimeArrivalTrack = "rtArrTrack"
        case cancelled, boarding, alighting, realtimeBoarding = "rtBoarding", realtimeAlighting = "rtAlighting"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        externalID = try values.decodeIfPresent(String.self, forKey: .externalID)
        routeIndex = try values.decodeFlexibleInt(forKey: .routeIndex)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        departureTime = try values.decodeIfPresent(String.self, forKey: .departureTime)
        departureDate = try values.decodeIfPresent(String.self, forKey: .departureDate)
        arrivalTime = try values.decodeIfPresent(String.self, forKey: .arrivalTime)
        arrivalDate = try values.decodeIfPresent(String.self, forKey: .arrivalDate)
        realtimeDepartureTime = try values.decodeIfPresent(String.self, forKey: .realtimeDepartureTime)
        realtimeDepartureDate = try values.decodeIfPresent(String.self, forKey: .realtimeDepartureDate)
        realtimeArrivalTime = try values.decodeIfPresent(String.self, forKey: .realtimeArrivalTime)
        realtimeArrivalDate = try values.decodeIfPresent(String.self, forKey: .realtimeArrivalDate)
        realtimeDepartureTrack = try values.decodeIfPresent(String.self, forKey: .realtimeDepartureTrack)
        realtimeArrivalTrack = try values.decodeIfPresent(String.self, forKey: .realtimeArrivalTrack)
        cancelled = try values.decodeIfPresent(Bool.self, forKey: .cancelled)
        boarding = try values.decodeIfPresent(Bool.self, forKey: .boarding)
        alighting = try values.decodeIfPresent(Bool.self, forKey: .alighting)
        realtimeBoarding = try values.decodeIfPresent(Bool.self, forKey: .realtimeBoarding)
        realtimeAlighting = try values.decodeIfPresent(Bool.self, forKey: .realtimeAlighting)
    }
}

/// Accepts HAFAS's inconsistent one-object-or-array response fields.
public struct OneOrMany<Element: Codable & Hashable & Sendable>: Hashable, Sendable, Codable {
    /// The decoded values, normalized to an array.
    public let values: [Element]
    /// Creates a normalized one-or-many wrapper from an array.
    public init(_ values: [Element]) { self.values = values }

    public init(from decoder: Decoder) throws {
        if let array = try? [Element](from: decoder) {
            values = array
        } else {
            values = [try Element(from: decoder)]
        }
    }

    public func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) throws -> Int? {
        if let integer = try? decode(Int.self, forKey: key) { return integer }
        if let string = try? decode(String.self, forKey: key) { return Int(string) }
        return nil
    }

    func decodeStringArray(forKey key: Key) throws -> [String] {
        if let values = try? decode([String].self, forKey: key) { return values }
        if let value = try? decode(String.self, forKey: key) { return [value] }
        return []
    }
}

private extension CodingUserInfoKey {
    static let hafasResponseBytes = CodingUserInfoKey(rawValue: "hafasResponseBytes")!
}
