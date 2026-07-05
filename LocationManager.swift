//
//  LocationManager.swift
//
//  A comprehensive singleton class for all location-related tasks in iOS/macOS apps.
//  Handles permissions, current location, continuous updates, geocoding, region monitoring, and more.
//
//  Requirements:
//  - Add NSLocationWhenInUseUsageDescription to Info.plist
//  - Add NSLocationAlwaysAndWhenInUseUsageDescription to Info.plist (if using Always access)
//  - Add NSLocationAlwaysUsageDescription to Info.plist (for iOS 10 and earlier)
//

import Foundation
import CoreLocation
import Combine
#if os(iOS)
import UIKit
#endif

// MARK: - Supporting Types

/// Represents the current authorization state of location services
enum LocationAuthorizationStatus {
    case notDetermined
    case restricted
    case denied
    case authorizedWhenInUse
    case authorizedAlways
    case unknown

    var description: String {
        switch self {
        case .notDetermined:      return "Not Determined"
        case .restricted:         return "Restricted"
        case .denied:             return "Denied"
        case .authorizedWhenInUse:return "Authorized When In Use"
        case .authorizedAlways:   return "Authorized Always"
        case .unknown:            return "Unknown"
        }
    }

    var isAuthorized: Bool {
        return self == .authorizedWhenInUse || self == .authorizedAlways
    }
}

/// The minimum authorization level a feature in your app requires.
/// Used with `authorizationUpdateNeeded(for:)` to detect when the user
/// needs to grant additional / upgraded location permission.
enum RequiredAuthorizationLevel {
    /// Feature only needs the app to be in the foreground
    case whenInUse
    /// Feature needs background access (e.g. geofencing, background tracking)
    case always
}

/// Result of checking whether the current permission satisfies a feature's requirement
enum AuthorizationUpdateCheck: Equatable {
    /// Current permission already satisfies the requirement — nothing to do
    case satisfied
    /// User hasn't been asked yet — call `requestWhenInUseAuthorization()` / `requestAlwaysAuthorization()`
    case needsInitialRequest(RequiredAuthorizationLevel)
    /// User granted WhenInUse but the feature needs Always — call `requestAlwaysAuthorization()`
    case needsUpgradeToAlways
    /// User denied or the OS restricted access — only fixable via `openAppSettings()`
    case blocked(LocationAuthorizationStatus)
}

/// Errors specific to LocationManager operations
enum LocationError: LocalizedError {
    case notAuthorized(LocationAuthorizationStatus)
    case locationServicesDisabled
    case locationUnavailable
    case geocodingFailed(Error)
    case timeout
    case regionMonitoringUnavailable
    case unknownError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let status):
            return "Location access denied. Current status: \(status.description)."
        case .locationServicesDisabled:
            return "Location services are disabled on this device."
        case .locationUnavailable:
            return "Unable to retrieve current location."
        case .geocodingFailed(let error):
            return "Geocoding failed: \(error.localizedDescription)"
        case .timeout:
            return "Location request timed out."
        case .regionMonitoringUnavailable:
            return "Region monitoring is not available on this device."
        case .unknownError(let error):
            return "An unknown error occurred: \(error.localizedDescription)"
        }
    }
}

/// Represents a human-readable address from reverse geocoding
struct PlacemarkInfo {
    let name: String?
    let thoroughfare: String?     // Street name
    let subThoroughfare: String?  // Street number
    let locality: String?         // City
    let subLocality: String?      // Neighborhood
    let administrativeArea: String? // State/Province
    let postalCode: String?
    let country: String?
    let isoCountryCode: String?
    let coordinate: CLLocationCoordinate2D

    var formattedAddress: String {
        let parts: [String?] = [
            subThoroughfare != nil && thoroughfare != nil
                ? "\(subThoroughfare!) \(thoroughfare!)" : thoroughfare,
            locality,
            administrativeArea,
            postalCode,
            country
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    init(from placemark: CLPlacemark) {
        self.name               = placemark.name
        self.thoroughfare       = placemark.thoroughfare
        self.subThoroughfare    = placemark.subThoroughfare
        self.locality           = placemark.locality
        self.subLocality        = placemark.subLocality
        self.administrativeArea = placemark.administrativeArea
        self.postalCode         = placemark.postalCode
        self.country            = placemark.country
        self.isoCountryCode     = placemark.isoCountryCode
        self.coordinate         = placemark.location?.coordinate ?? kCLLocationCoordinate2DInvalid
    }
}

// MARK: - LocationManager Delegate Protocol

/// Optional delegate for receiving location events
protocol LocationManagerDelegate: AnyObject {
    func locationManager(_ manager: LocationManager, didUpdateLocation location: CLLocation)
    func locationManager(_ manager: LocationManager, didFailWithError error: LocationError)
    func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus)
    func locationManager(_ manager: LocationManager, didEnterRegion region: CLRegion)
    func locationManager(_ manager: LocationManager, didExitRegion region: CLRegion)
}

/// Provide default (no-op) implementations so conformers can adopt only what they need
extension LocationManagerDelegate {
    func locationManager(_ manager: LocationManager, didUpdateLocation location: CLLocation) {}
    func locationManager(_ manager: LocationManager, didFailWithError error: LocationError) {}
    func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus) {}
    func locationManager(_ manager: LocationManager, didEnterRegion region: CLRegion) {}
    func locationManager(_ manager: LocationManager, didExitRegion region: CLRegion) {}
}

// MARK: - LocationManager Singleton

/// A comprehensive singleton for all CoreLocation tasks.
///
/// Usage:
/// ```swift
/// // Request permission
/// LocationManager.shared.requestWhenInUseAuthorization()
///
/// // Get current location (async/await)
/// let location = try await LocationManager.shared.getCurrentLocation()
///
/// // Start continuous updates
/// LocationManager.shared.startUpdatingLocation()
///
/// // Reverse geocode
/// let info = try await LocationManager.shared.reverseGeocode(location: location)
/// ```
final class LocationManager: NSObject {

    // MARK: - Singleton

    static let shared = LocationManager()

    private override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = kCLDistanceFilterNone
    }

    // MARK: - Public Properties

    /// Delegate for receiving location event callbacks
    weak var delegate: LocationManagerDelegate?

    /// Most recently received location (nil if never received)
    private(set) var lastKnownLocation: CLLocation?

    /// Current authorization status (Combine-observable)
    @Published private(set) var authorizationStatus: LocationAuthorizationStatus = .notDetermined

    /// Publisher that emits each new location update
    let locationPublisher = PassthroughSubject<CLLocation, Never>()

    /// Publisher that emits location errors
    let errorPublisher = PassthroughSubject<LocationError, Never>()

    // MARK: - Configuration

    /// Desired accuracy for location updates. Defaults to kCLLocationAccuracyBest.
    var desiredAccuracy: CLLocationAccuracy {
        get { clManager.desiredAccuracy }
        set { clManager.desiredAccuracy = newValue }
    }

    /// Minimum distance (meters) before a new location event is generated.
    var distanceFilter: CLLocationDistance {
        get { clManager.distanceFilter }
        set { clManager.distanceFilter = newValue }
    }

    /// Whether the app should pause location updates automatically. Defaults to false.
    var pausesAutomatically: Bool {
        get { clManager.pausesLocationUpdatesAutomatically }
        set { clManager.pausesLocationUpdatesAutomatically = newValue }
    }

    // MARK: - Private Properties

    private let clManager = CLLocationManager()
    private let geocoder  = CLGeocoder()

    /// Pending single-fetch completions waiting for the first valid location
    private var singleFetchCompletions: [(Result<CLLocation, LocationError>) -> Void] = []

    /// Pending permission request completions
    private var permissionCompletions: [(LocationAuthorizationStatus) -> Void] = []

    /// Timeout for getCurrentLocation()
    private var fetchTimeoutTimer: Timer?
    private let defaultFetchTimeout: TimeInterval = 15
}

// MARK: - Authorization

extension LocationManager {

    /// Whether location services are enabled system-wide
    var areLocationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    /// Checks the current authorization status without prompting
    var currentAuthorizationStatus: LocationAuthorizationStatus {
        return mapCLStatus(clManager.authorizationStatus)
    }

    /// Requests "When In Use" location authorization.
    /// Calls the completion with the resulting status once the user responds.
    func requestWhenInUseAuthorization(completion: ((LocationAuthorizationStatus) -> Void)? = nil) {
        guard areLocationServicesEnabled else {
            completion?(.denied)
            return
        }
        if let completion { permissionCompletions.append(completion) }
        clManager.requestWhenInUseAuthorization()
    }

    /// Requests "Always" location authorization.
    /// NOTE: You must first have WhenInUse authorization before requesting Always.
    func requestAlwaysAuthorization(completion: ((LocationAuthorizationStatus) -> Void)? = nil) {
        guard areLocationServicesEnabled else {
            completion?(.denied)
            return
        }
        if let completion { permissionCompletions.append(completion) }
        clManager.requestAlwaysAuthorization()
    }

    /// Returns whether the app currently has any authorized location access
    var isAuthorized: Bool {
        currentAuthorizationStatus.isAuthorized
    }

    /// Asynchronously request WhenInUse authorization and return the resulting status
    @discardableResult
    func requestWhenInUseAuthorizationAsync() async -> LocationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requestWhenInUseAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Asynchronously request Always authorization and return the resulting status
    @discardableResult
    func requestAlwaysAuthorizationAsync() async -> LocationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requestAlwaysAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    #if os(iOS)
    /// Opens the app's Settings page so the user can change location permissions.
    /// iOS only — there is no equivalent deep link on macOS; direct users to
    /// System Settings > Privacy & Security > Location Services manually there.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
    #endif

    /// Checks whether the current authorization satisfies what a given feature requires,
    /// and tells you exactly what action (if any) is needed to update/upgrade it.
    ///
    /// Use this before gating a feature behind location access — it distinguishes
    /// "never asked yet" from "granted but needs upgrading" from "blocked in Settings",
    /// so you can drive the correct prompt in your UI.
    ///
    /// - Parameter requirement: The minimum level the calling feature needs.
    /// - Returns: An `AuthorizationUpdateCheck` describing what's needed, if anything.
    func authorizationUpdateNeeded(for requirement: RequiredAuthorizationLevel) -> AuthorizationUpdateCheck {
        guard areLocationServicesEnabled else {
            return .blocked(.denied)
        }

        let status = currentAuthorizationStatus

        switch status {
        case .notDetermined:
            return .needsInitialRequest(requirement)

        case .denied, .restricted:
            return .blocked(status)

        case .authorizedWhenInUse:
            return requirement == .always ? .needsUpgradeToAlways : .satisfied

        case .authorizedAlways:
            return .satisfied

        case .unknown:
            return .blocked(status)
        }
    }

    /// Convenience wrapper that performs `authorizationUpdateNeeded(for:)` and automatically
    /// triggers the correct system prompt for `.needsInitialRequest` / `.needsUpgradeToAlways`.
    /// For `.blocked`, it does NOT open Settings automatically — surface that to the user first.
    ///
    /// - Returns: The check result so the caller can react to `.blocked` (e.g. show an alert
    ///            with a button that calls `openAppSettings()`).
    @discardableResult
    func resolveAuthorizationUpdateIfNeeded(
        for requirement: RequiredAuthorizationLevel,
        completion: @escaping (AuthorizationUpdateCheck) -> Void
    ) -> AuthorizationUpdateCheck {
        let check = authorizationUpdateNeeded(for: requirement)

        switch check {
        case .satisfied, .blocked:
            completion(check)

        case .needsInitialRequest(let level):
            if level == .always {
                requestAlwaysAuthorization { _ in
                    completion(self.authorizationUpdateNeeded(for: requirement))
                }
            } else {
                requestWhenInUseAuthorization { _ in
                    completion(self.authorizationUpdateNeeded(for: requirement))
                }
            }

        case .needsUpgradeToAlways:
            requestAlwaysAuthorization { _ in
                completion(self.authorizationUpdateNeeded(for: requirement))
            }
        }

        return check
    }
}

// MARK: - Location Fetching

extension LocationManager {

    /// Fetches the current location once and returns it via completion.
    /// - Parameters:
    ///   - accuracy: Desired accuracy override for this request only
    ///   - timeout: Seconds before the request fails with `.timeout`
    ///   - completion: Called on the main thread with the result
    func getCurrentLocation(
        accuracy: CLLocationAccuracy? = nil,
        timeout: TimeInterval? = nil,
        completion: @escaping (Result<CLLocation, LocationError>) -> Void
    ) {
        guard areLocationServicesEnabled else {
            completion(.failure(.locationServicesDisabled))
            return
        }
        guard isAuthorized else {
            completion(.failure(.notAuthorized(currentAuthorizationStatus)))
            return
        }

        if let accuracy { clManager.desiredAccuracy = accuracy }

        singleFetchCompletions.append(completion)

        // Start a timeout timer
        let timeoutInterval = timeout ?? defaultFetchTimeout
        fetchTimeoutTimer?.invalidate()
        fetchTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            self?.handleFetchTimeout()
        }

        clManager.requestLocation()
    }

    /// Async/await version of getCurrentLocation
    func getCurrentLocation(
        accuracy: CLLocationAccuracy? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            getCurrentLocation(accuracy: accuracy, timeout: timeout) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Generates and returns a CLLocation from a given coordinate (useful for testing/mapping)
    func generateLocation(latitude: Double, longitude: Double) -> CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    /// Generates a CLLocation with full metadata
    func generateLocation(
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        horizontalAccuracy: Double = 10,
        verticalAccuracy: Double = 10,
        course: Double = 0,
        speed: Double = 0,
        timestamp: Date = Date()
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
    }

    // MARK: - Private fetch helpers

    private func handleFetchTimeout() {
        let completions = singleFetchCompletions
        singleFetchCompletions.removeAll()
        clManager.stopUpdatingLocation()
        completions.forEach { $0(.failure(.timeout)) }
        delegate?.locationManager(self, didFailWithError: .timeout)
        errorPublisher.send(.timeout)
    }

    private func resolveSingleFetchCompletions(with result: Result<CLLocation, LocationError>) {
        fetchTimeoutTimer?.invalidate()
        fetchTimeoutTimer = nil
        let completions = singleFetchCompletions
        singleFetchCompletions.removeAll()
        DispatchQueue.main.async {
            completions.forEach { $0(result) }
        }
    }
}

// MARK: - Continuous Updates

extension LocationManager {

    /// Starts delivering continuous location updates.
    /// Listen via `delegate`, `locationPublisher`, or observe `lastKnownLocation`.
    func startUpdatingLocation() {
        guard isAuthorized else {
            let error = LocationError.notAuthorized(currentAuthorizationStatus)
            delegate?.locationManager(self, didFailWithError: error)
            errorPublisher.send(error)
            return
        }
        clManager.startUpdatingLocation()
    }

    /// Stops delivering continuous location updates.
    func stopUpdatingLocation() {
        clManager.stopUpdatingLocation()
    }

    /// Starts significant-change location updates (lower power, cell-tower accuracy).
    /// Requires Always authorization for background delivery.
    func startMonitoringSignificantLocationChanges() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        clManager.startMonitoringSignificantLocationChanges()
    }

    /// Stops significant-change location monitoring.
    func stopMonitoringSignificantLocationChanges() {
        clManager.stopMonitoringSignificantLocationChanges()
    }

    #if os(iOS)
    /// Enables background location updates. Requires "Always" permission +
    /// "Location updates" background mode in project capabilities.
    /// iOS only — `allowsBackgroundLocationUpdates` and
    /// `showsBackgroundLocationIndicator` have no macOS equivalent (apps
    /// there aren't suspended the same way, so there's nothing to opt into).
    func enableBackgroundLocationUpdates(allowsIndicator: Bool = true) {
        clManager.allowsBackgroundLocationUpdates = true
        clManager.showsBackgroundLocationIndicator = allowsIndicator
    }

    /// Disables background location updates. iOS only, see above.
    func disableBackgroundLocationUpdates() {
        clManager.allowsBackgroundLocationUpdates = false
        clManager.showsBackgroundLocationIndicator = false
    }
    #endif
}

// MARK: - Geocoding

extension LocationManager {

    /// Reverse geocodes a CLLocation into a human-readable PlacemarkInfo.
    func reverseGeocode(
        location: CLLocation,
        completion: @escaping (Result<PlacemarkInfo, LocationError>) -> Void
    ) {
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            if let error {
                completion(.failure(.geocodingFailed(error)))
                return
            }
            guard let placemark = placemarks?.first else {
                completion(.failure(.locationUnavailable))
                return
            }
            completion(.success(PlacemarkInfo(from: placemark)))
        }
    }

    /// Async/await version of reverseGeocode
    func reverseGeocode(location: CLLocation) async throws -> PlacemarkInfo {
        try await withCheckedThrowingContinuation { continuation in
            reverseGeocode(location: location) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Forward geocodes an address string into coordinates.
    func forwardGeocode(
        address: String,
        completion: @escaping (Result<[PlacemarkInfo], LocationError>) -> Void
    ) {
        geocoder.geocodeAddressString(address) { placemarks, error in
            if let error {
                completion(.failure(.geocodingFailed(error)))
                return
            }
            let results = (placemarks ?? []).map { PlacemarkInfo(from: $0) }
            completion(.success(results))
        }
    }

    /// Async/await version of forwardGeocode
    func forwardGeocode(address: String) async throws -> [PlacemarkInfo] {
        try await withCheckedThrowingContinuation { continuation in
            forwardGeocode(address: address) { result in
                continuation.resume(with: result)
            }
        }
    }
}

// MARK: - Distance & Bearing Utilities

extension LocationManager {

    /// Returns the distance in meters between two coordinates
    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let locFrom = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let locTo   = CLLocation(latitude: to.latitude,   longitude: to.longitude)
        return locFrom.distance(from: locTo)
    }

    /// Returns the distance in meters from the last known location to a coordinate
    func distanceFromCurrentLocation(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let current = lastKnownLocation else { return nil }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return current.distance(from: target)
    }

    /// Calculates the bearing (in degrees, 0–360) from one coordinate to another
    func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude  * .pi / 180
        let lat2 = to.latitude    * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Checks whether a coordinate lies within a given radius (meters) of another coordinate
    func isCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        within radius: CLLocationDistance,
        of center: CLLocationCoordinate2D
    ) -> Bool {
        distance(from: center, to: coordinate) <= radius
    }
}

// MARK: - Region Monitoring

extension LocationManager {

    /// Starts monitoring a circular geographic region.
    /// - Parameters:
    ///   - center: Center of the region
    ///   - radius: Radius in meters (clamped to maximumRegionMonitoringDistance)
    ///   - identifier: A unique string identifier for the region
    func startMonitoringRegion(
        center: CLLocationCoordinate2D,
        radius: CLLocationDistance,
        identifier: String
    ) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            let error = LocationError.regionMonitoringUnavailable
            delegate?.locationManager(self, didFailWithError: error)
            errorPublisher.send(error)
            return
        }
        let clampedRadius = min(radius, clManager.maximumRegionMonitoringDistance)
        let region = CLCircularRegion(center: center, radius: clampedRadius, identifier: identifier)
        region.notifyOnEntry = true
        region.notifyOnExit  = true
        clManager.startMonitoring(for: region)
    }

    /// Stops monitoring a region with a given identifier
    func stopMonitoringRegion(identifier: String) {
        for region in clManager.monitoredRegions where region.identifier == identifier {
            clManager.stopMonitoring(for: region)
        }
    }

    /// Stops monitoring all regions
    func stopMonitoringAllRegions() {
        clManager.monitoredRegions.forEach { clManager.stopMonitoring(for: $0) }
    }

    /// Returns all currently monitored regions
    var monitoredRegions: Set<CLRegion> {
        clManager.monitoredRegions
    }

    /// Requests the state of a specific region (inside or outside)
    func requestRegionState(identifier: String) {
        for region in clManager.monitoredRegions where region.identifier == identifier {
            clManager.requestState(for: region)
        }
    }
}

// MARK: - Heading

#if os(iOS)
extension LocationManager {

    /// Whether heading updates are available on this device.
    /// iOS only — Macs have no magnetometer/compass hardware.
    var isHeadingAvailable: Bool {
        CLLocationManager.headingAvailable()
    }

    /// Starts delivering heading (compass) updates
    /// Listen via CLLocationManagerDelegate heading methods if you need custom handling
    func startUpdatingHeading() {
        guard isHeadingAvailable else { return }
        clManager.startUpdatingHeading()
    }

    /// Stops heading updates
    func stopUpdatingHeading() {
        clManager.stopUpdatingHeading()
    }
}
#endif

// MARK: - Visit Monitoring

#if os(iOS)
extension LocationManager {

    /// Starts visit monitoring (detects when user arrives/departs from locations).
    /// Requires Always authorization. iOS only — not available on macOS.
    func startMonitoringVisits() {
        clManager.startMonitoringVisits()
    }

    /// Stops visit monitoring
    func stopMonitoringVisits() {
        clManager.stopMonitoringVisits()
    }
}
#endif

// MARK: - Coordinate Validation

extension LocationManager {

    /// Returns true if the coordinate is valid (not kCLLocationCoordinate2DInvalid)
    func isValidCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate)
    }

    /// Returns true if the location's horizontal accuracy is within acceptable bounds
    func isAccurateEnough(_ location: CLLocation, threshold: CLLocationAccuracy = 50) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= threshold
    }

    /// Returns true if the location's timestamp is recent (within the given age in seconds)
    func isRecent(_ location: CLLocation, maxAge: TimeInterval = 30) -> Bool {
        abs(location.timestamp.timeIntervalSinceNow) <= maxAge
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        lastKnownLocation = location

        // Notify continuous update listeners
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didUpdateLocation: location)
            self.locationPublisher.send(location)
        }

        // Resolve single-fetch completions if any are pending
        if !singleFetchCompletions.isEmpty {
            resolveSingleFetchCompletions(with: .success(location))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let locationError = LocationError.unknownError(error)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didFailWithError: locationError)
            self.errorPublisher.send(locationError)
        }

        if !singleFetchCompletions.isEmpty {
            resolveSingleFetchCompletions(with: .failure(locationError))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = mapCLStatus(manager.authorizationStatus)
        authorizationStatus = status

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didChangeAuthorizationStatus: status)
            self.permissionCompletions.forEach { $0(status) }
            self.permissionCompletions.removeAll()
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didEnterRegion: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.locationManager(self, didExitRegion: region)
        }
    }

    // MARK: - Private Helpers

    private func mapCLStatus(_ status: CLAuthorizationStatus) -> LocationAuthorizationStatus {
        switch status {
        case .notDetermined:         return .notDetermined
        case .restricted:            return .restricted
        case .denied:                return .denied
        case .authorizedWhenInUse:   return .authorizedWhenInUse
        case .authorizedAlways:      return .authorizedAlways
        @unknown default:            return .unknown
        }
    }
}
