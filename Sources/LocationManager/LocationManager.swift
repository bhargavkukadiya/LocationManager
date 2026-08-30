//
//  LocationManager.swift
//
//  A comprehensive, production-ready singleton class for all location-related tasks in iOS/macOS apps.
//  Handles permissions, accurate location fetching, continuous updates, geocoding, region monitoring,
//  compass heading, visits, and full Combine / Swift Concurrency (async/await & AsyncStream) support.
//
//  Requirements:
//  - Add NSLocationWhenInUseUsageDescription to Info.plist
//  - Add NSLocationAlwaysAndWhenInUseUsageDescription to Info.plist (if using Always access)
//  - Add NSLocationTemporaryUsageDescriptionDictionary to Info.plist (if using temporary full accuracy)
//

import Foundation
@preconcurrency import CoreLocation
@preconcurrency import Combine
#if canImport(MapKit)
import MapKit
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Supporting Types

/// Represents the current authorization state of location services
public enum LocationAuthorizationStatus: String, Sendable, Equatable, Hashable, Codable {
    case notDetermined
    case restricted
    case denied
    case authorizedWhenInUse
    case authorizedAlways
    case unknown

    public var description: String {
        switch self {
        case .notDetermined:       return "Not Determined"
        case .restricted:          return "Restricted"
        case .denied:              return "Denied"
        case .authorizedWhenInUse: return "Authorized When In Use"
        case .authorizedAlways:    return "Authorized Always"
        case .unknown:             return "Unknown"
        }
    }

    public var isAuthorized: Bool {
        return self == .authorizedWhenInUse || self == .authorizedAlways
    }
}

/// Represents the precision of location data granted by the user (iOS 14+)
public enum AccuracyAuthorizationStatus: String, Sendable, Equatable, Hashable, Codable {
    case fullAccuracy
    case reducedAccuracy
    case unknown

    public var description: String {
        switch self {
        case .fullAccuracy:    return "Full Accuracy"
        case .reducedAccuracy: return "Reduced Accuracy (Approximate)"
        case .unknown:         return "Unknown"
        }
    }

    public var isFullAccuracy: Bool {
        return self == .fullAccuracy
    }
}

/// The minimum authorization level a feature in your app requires.
/// Used with `authorizationUpdateNeeded(for:)` to detect when the user
/// needs to grant additional / upgraded location permission.
public enum RequiredAuthorizationLevel: String, Sendable, Equatable, Hashable, Codable {
    /// Feature only needs the app to be in the foreground
    case whenInUse
    /// Feature needs background access (e.g. geofencing, background tracking)
    case always
}

/// Result of checking whether the current permission satisfies a feature's requirement
public enum AuthorizationUpdateCheck: Sendable, Equatable, Hashable {
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
public enum LocationError: LocalizedError, Sendable, Equatable {
    case notAuthorized(LocationAuthorizationStatus)
    case locationServicesDisabled
    case locationUnavailable
    case geocodingFailed(String)
    case timeout
    case cancelled
    case regionMonitoringUnavailable
    case regionMonitoringFailed(String)
    case headingFailure(String)
    case unknownError(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized(let status):
            return "Location access denied. Current status: \(status.description)."
        case .locationServicesDisabled:
            return "Location services are disabled on this device."
        case .locationUnavailable:
            return "Unable to retrieve current location."
        case .geocodingFailed(let message):
            return "Geocoding failed: \(message)"
        case .timeout:
            return "Location request timed out."
        case .cancelled:
            return "Location request was cancelled."
        case .regionMonitoringUnavailable:
            return "Region monitoring is not available on this device."
        case .regionMonitoringFailed(let message):
            return "Region monitoring failed: \(message)"
        case .headingFailure(let message):
            return "Heading retrieval failed: \(message)"
        case .unknownError(let message):
            return "An unknown error occurred: \(message)"
        }
    }
}

/// Represents a human-readable address from reverse geocoding
public struct PlacemarkInfo: Sendable, Equatable, Hashable {
    public let name: String?
    public let thoroughfare: String?        // Street name
    public let subThoroughfare: String?     // Street number / Building name
    public let locality: String?            // City
    public let subLocality: String?         // Neighborhood / Sub-district
    public let administrativeArea: String?  // State / Province
    public let subAdministrativeArea: String? // County
    public let postalCode: String?
    public let country: String?
    public let isoCountryCode: String?
    public let timeZone: TimeZone?
    public let coordinate: CLLocationCoordinate2D
    public let rawFormattedAddress: String?

    public var formattedAddress: String {
        if let rawFormattedAddress, !rawFormattedAddress.isEmpty {
            return rawFormattedAddress
        }
        let streetParts = [subThoroughfare, thoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let street = streetParts.joined(separator: " ")

        let parts: [String?] = [
            street.isEmpty ? nil : street,
            locality,
            administrativeArea,
            postalCode,
            country
        ]
        return parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    public init(
        name: String? = nil,
        thoroughfare: String? = nil,
        subThoroughfare: String? = nil,
        locality: String? = nil,
        subLocality: String? = nil,
        administrativeArea: String? = nil,
        subAdministrativeArea: String? = nil,
        postalCode: String? = nil,
        country: String? = nil,
        isoCountryCode: String? = nil,
        timeZone: TimeZone? = nil,
        coordinate: CLLocationCoordinate2D = kCLLocationCoordinate2DInvalid,
        rawFormattedAddress: String? = nil
    ) {
        self.name                  = name
        self.thoroughfare          = thoroughfare
        self.subThoroughfare       = subThoroughfare
        self.locality              = locality
        self.subLocality           = subLocality
        self.administrativeArea    = administrativeArea
        self.subAdministrativeArea = subAdministrativeArea
        self.postalCode            = postalCode
        self.country               = country
        self.isoCountryCode        = isoCountryCode
        self.timeZone              = timeZone
        self.coordinate            = coordinate
        self.rawFormattedAddress   = rawFormattedAddress
    }

    public init(from placemark: CLPlacemark) {
        self.name                  = placemark.name
        self.thoroughfare          = placemark.thoroughfare
        self.subThoroughfare       = placemark.subThoroughfare
        self.locality              = placemark.locality
        self.subLocality           = placemark.subLocality
        self.administrativeArea    = placemark.administrativeArea
        self.subAdministrativeArea = placemark.subAdministrativeArea
        self.postalCode            = placemark.postalCode
        self.country               = placemark.country
        self.isoCountryCode        = placemark.isoCountryCode
        self.timeZone              = placemark.timeZone
        self.coordinate            = placemark.location?.coordinate ?? kCLLocationCoordinate2DInvalid
        self.rawFormattedAddress   = nil
    }

    #if canImport(MapKit)
    #if compiler(>=6.2)
    @available(iOS 26.0, macOS 26.0, *)
    public init(from mapItem: MKMapItem) {
        let full = mapItem.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
            ?? mapItem.address?.fullAddress
            ?? mapItem.address?.shortAddress

        let city = mapItem.addressRepresentations?.cityName
        let countryOrRegion = mapItem.addressRepresentations?.regionName
        let isoCode = mapItem.addressRepresentations?.__regionCode

        self.name                  = mapItem.name
        self.thoroughfare          = nil
        self.subThoroughfare       = nil
        self.locality              = city
        self.subLocality           = nil
        self.administrativeArea    = nil
        self.subAdministrativeArea = nil
        self.postalCode            = nil
        self.country               = countryOrRegion
        self.isoCountryCode        = isoCode
        self.timeZone              = mapItem.timeZone
        self.coordinate            = mapItem.location.coordinate
        self.rawFormattedAddress   = full
    }
    #endif
    #endif

    public static func == (lhs: PlacemarkInfo, rhs: PlacemarkInfo) -> Bool {
        return lhs.name == rhs.name &&
            lhs.thoroughfare == rhs.thoroughfare &&
            lhs.subThoroughfare == rhs.subThoroughfare &&
            lhs.locality == rhs.locality &&
            lhs.subLocality == rhs.subLocality &&
            lhs.administrativeArea == rhs.administrativeArea &&
            lhs.subAdministrativeArea == rhs.subAdministrativeArea &&
            lhs.postalCode == rhs.postalCode &&
            lhs.country == rhs.country &&
            lhs.isoCountryCode == rhs.isoCountryCode &&
            lhs.timeZone == rhs.timeZone &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude &&
            lhs.rawFormattedAddress == rhs.rawFormattedAddress
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(thoroughfare)
        hasher.combine(subThoroughfare)
        hasher.combine(locality)
        hasher.combine(subLocality)
        hasher.combine(administrativeArea)
        hasher.combine(subAdministrativeArea)
        hasher.combine(postalCode)
        hasher.combine(country)
        hasher.combine(isoCountryCode)
        hasher.combine(timeZone)
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
        hasher.combine(rawFormattedAddress)
    }
}

// MARK: - LocationManager Delegate Protocol

/// Optional delegate for receiving location and sensor events
@MainActor
public protocol LocationManagerDelegate: AnyObject {
    func locationManager(_ manager: LocationManager, didUpdateLocation location: CLLocation)
    func locationManager(_ manager: LocationManager, didFailWithError error: LocationError)
    func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus)
    func locationManager(_ manager: LocationManager, didChangeAccuracyAuthorization status: AccuracyAuthorizationStatus)
    func locationManager(_ manager: LocationManager, didEnterRegion region: CLRegion)
    func locationManager(_ manager: LocationManager, didExitRegion region: CLRegion)
    func locationManager(_ manager: LocationManager, didDetermineState state: CLRegionState, for region: CLRegion)
    func locationManager(_ manager: LocationManager, monitoringDidFailFor region: CLRegion?, withError error: LocationError)
    #if os(iOS)
    func locationManager(_ manager: LocationManager, didUpdateHeading heading: CLHeading)
    func locationManager(_ manager: LocationManager, didVisit visit: CLVisit)
    #endif
}

/// Default no-op implementations so conformers only adopt what they need
public extension LocationManagerDelegate {
    func locationManager(_ manager: LocationManager, didUpdateLocation location: CLLocation) {}
    func locationManager(_ manager: LocationManager, didFailWithError error: LocationError) {}
    func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus) {}
    func locationManager(_ manager: LocationManager, didChangeAccuracyAuthorization status: AccuracyAuthorizationStatus) {}
    func locationManager(_ manager: LocationManager, didEnterRegion region: CLRegion) {}
    func locationManager(_ manager: LocationManager, didExitRegion region: CLRegion) {}
    func locationManager(_ manager: LocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {}
    func locationManager(_ manager: LocationManager, monitoringDidFailFor region: CLRegion?, withError error: LocationError) {}
    #if os(iOS)
    func locationManager(_ manager: LocationManager, didUpdateHeading heading: CLHeading) {}
    func locationManager(_ manager: LocationManager, didVisit visit: CLVisit) {}
    #endif
}

// MARK: - LocationManager Singleton

/// A comprehensive singleton for all CoreLocation tasks with modern Swift Concurrency and Combine support.
@MainActor
public final class LocationManager: NSObject {

    // MARK: - Singleton

    public static let shared = LocationManager()

    private override init() {
        let cl = CLLocationManager()
        self.authorizationStatus = Self.mapCLAuthorizationStatus(cl.authorizationStatus)
        self.accuracyAuthorization = Self.mapCLAccuracyAuthorization(cl.accuracyAuthorization)
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = kCLDistanceFilterNone
    }

    // MARK: - Public Properties

    /// Delegate for receiving location event callbacks
    public weak var delegate: LocationManagerDelegate?

    /// Most recently received location (nil if never received)
    public private(set) var lastKnownLocation: CLLocation?

    #if os(iOS)
    /// Most recently received compass heading (nil if never received)
    public private(set) var lastKnownHeading: CLHeading?
    #endif

    /// Current authorization status (Combine-observable)
    @Published public private(set) var authorizationStatus: LocationAuthorizationStatus

    /// Current accuracy authorization status (Combine-observable)
    @Published public private(set) var accuracyAuthorization: AccuracyAuthorizationStatus

    // MARK: - Private Subjects & Read-Only Publishers

    private let _locationPublisher = PassthroughSubject<CLLocation, Never>()
    private let _errorPublisher = PassthroughSubject<LocationError, Never>()
    private let _regionStatePublisher = PassthroughSubject<(region: CLRegion, state: CLRegionState), Never>()

    #if os(iOS)
    private let _headingPublisher = PassthroughSubject<CLHeading, Never>()
    private let _visitPublisher = PassthroughSubject<CLVisit, Never>()
    #endif

    /// Publisher that emits each new location update
    public var locationPublisher: AnyPublisher<CLLocation, Never> {
        _locationPublisher.eraseToAnyPublisher()
    }

    /// Publisher that emits location errors
    public var errorPublisher: AnyPublisher<LocationError, Never> {
        _errorPublisher.eraseToAnyPublisher()
    }

    /// Publisher that emits region state determinations
    public var regionStatePublisher: AnyPublisher<(region: CLRegion, state: CLRegionState), Never> {
        _regionStatePublisher.eraseToAnyPublisher()
    }

    #if os(iOS)
    /// Publisher that emits compass heading updates
    public var headingPublisher: AnyPublisher<CLHeading, Never> {
        _headingPublisher.eraseToAnyPublisher()
    }

    /// Publisher that emits visit events
    public var visitPublisher: AnyPublisher<CLVisit, Never> {
        _visitPublisher.eraseToAnyPublisher()
    }
    #endif

    // MARK: - Swift Concurrency AsyncStreams

    private var locationContinuations: [UUID: AsyncStream<CLLocation>.Continuation] = [:]
    #if os(iOS)
    private var headingContinuations: [UUID: AsyncStream<CLHeading>.Continuation] = [:]
    private var visitContinuations: [UUID: AsyncStream<CLVisit>.Continuation] = [:]
    #endif

    /// An `AsyncStream` providing continuous location updates with bounded buffering (1 newest item)
    public var locations: AsyncStream<CLLocation> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            locationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.locationContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    #if os(iOS)
    /// An `AsyncStream` providing compass heading updates with bounded buffering (1 newest item)
    public var headings: AsyncStream<CLHeading> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            headingContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.headingContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// An `AsyncStream` providing visit arrival/departure events with bounded buffering (10 newest items)
    public var visits: AsyncStream<CLVisit> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(10)) { continuation in
            visitContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.visitContinuations.removeValue(forKey: id)
                }
            }
        }
    }
    #endif

    var activeLocationStreamCount: Int {
        locationContinuations.count
    }

    // MARK: - Configuration

    private var configuredDesiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest

    /// Desired accuracy for location updates. Defaults to kCLLocationAccuracyBest.
    public var desiredAccuracy: CLLocationAccuracy {
        get { configuredDesiredAccuracy }
        set {
            configuredDesiredAccuracy = newValue
            updateActiveAccuracy()
        }
    }

    /// Minimum distance (meters) before a new location event is generated.
    public var distanceFilter: CLLocationDistance {
        get { clManager.distanceFilter }
        set { clManager.distanceFilter = newValue }
    }

    /// Whether the app should pause location updates automatically. Defaults to false.
    public var pausesAutomatically: Bool {
        get { clManager.pausesLocationUpdatesAutomatically }
        set { clManager.pausesLocationUpdatesAutomatically = newValue }
    }

    #if os(iOS)
    /// The type of user activity associated with the location updates.
    public var activityType: CLActivityType {
        get { clManager.activityType }
        set { clManager.activityType = newValue }
    }

    /// The minimum angular change (in degrees) required to generate a new heading event.
    public var headingFilter: CLLocationDegrees {
        get { clManager.headingFilter }
        set { clManager.headingFilter = newValue }
    }

    /// The device orientation to use when calculating heading values.
    public var headingOrientation: CLDeviceOrientation {
        get { clManager.headingOrientation }
        set { clManager.headingOrientation = newValue }
    }
    #endif

    /// Whether the one-time WhenInUse -> Always upgrade prompt has already been requested
    public private(set) var hasRequestedAlwaysAuthorization: Bool {
        get {
            UserDefaults.standard.bool(forKey: "LocationManager.hasRequestedAlwaysAuthorization")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "LocationManager.hasRequestedAlwaysAuthorization")
        }
    }

    /// Resets the Always upgrade request tracking flag (internal for unit testing)
    func resetAlwaysAuthorizationRequestTracking() {
        UserDefaults.standard.removeObject(forKey: "LocationManager.hasRequestedAlwaysAuthorization")
    }

    // MARK: - App State & Info.plist Validation Helpers

    var isAppActive: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        return NSApplication.shared.isActive
        #else
        return true
        #endif
    }

    var hasWhenInUseUsageDescription: Bool {
        guard let desc = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String else {
            return false
        }
        return !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAlwaysUsageDescription: Bool {
        guard let desc = Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription") as? String else {
            return false
        }
        return !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasRequiredUsageDescription(for level: RequiredAuthorizationLevel) -> Bool {
        switch level {
        case .whenInUse:
            return hasWhenInUseUsageDescription
        case .always:
            return hasAlwaysUsageDescription && hasWhenInUseUsageDescription
        }
    }

    // MARK: - Private State

    private let clManager = CLLocationManager()
    private var isContinuousUpdatingActive = false

    private struct SingleFetchRequest {
        let id: UUID
        let desiredAccuracy: CLLocationAccuracy?
        let maxAge: TimeInterval
        let completion: @Sendable (Result<CLLocation, LocationError>) -> Void
        let timer: Timer
    }

    private var activeFetchRequests: [UUID: SingleFetchRequest] = [:]
    private var permissionCompletions: [@Sendable (LocationAuthorizationStatus) -> Void] = []
    private var didBecomeActiveObserver: (any NSObjectProtocol)?
    private let defaultFetchTimeout: TimeInterval = 15

    private func updateActiveAccuracy() {
        if activeFetchRequests.isEmpty {
            clManager.desiredAccuracy = configuredDesiredAccuracy
            return
        }

        var bestAccuracy = isContinuousUpdatingActive ? configuredDesiredAccuracy : kCLLocationAccuracyThreeKilometers
        for request in activeFetchRequests.values {
            let reqAcc = request.desiredAccuracy ?? configuredDesiredAccuracy
            bestAccuracy = min(bestAccuracy, reqAcc)
        }
        clManager.desiredAccuracy = bestAccuracy
    }

    private func startLocationUpdatesIfNeeded() {
        clManager.startUpdatingLocation()
    }

    private func stopLocationUpdatesIfNeeded() {
        if activeFetchRequests.isEmpty && !isContinuousUpdatingActive {
            clManager.stopUpdatingLocation()
        }
    }

    private func location(_ location: CLLocation, satisfiesAccuracy targetAccuracy: CLLocationAccuracy?) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard let targetAccuracy else { return true }
        if targetAccuracy < 0 {
            // Negative sentinel values (kCLLocationAccuracyBest = -1, kCLLocationAccuracyBestForNavigation = -2)
            // represent qualitative accuracy modes. Any valid fix is accepted.
            return true
        } else {
            return location.horizontalAccuracy <= targetAccuracy
        }
    }

    private func setupLifecycleObserverForAlwaysRequest() {
        removeLifecycleObserver()

        #if os(iOS)
        let notificationName = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let notificationName = NSApplication.didBecomeActiveNotification
        #endif

        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.removeLifecycleObserver()
                // If the prompt was dismissed (e.g. user selected "Keep Only While Using"),
                // CoreLocation does not change authorization status and never calls the delegate.
                // Allow a brief delay for any potential delegate call, then drain completions.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !self.permissionCompletions.isEmpty {
                        self.drainPermissionCompletions(with: self.currentAuthorizationStatus)
                    }
                }
            }
        }
    }

    private func removeLifecycleObserver() {
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
    }

    private func drainPermissionCompletions(with status: LocationAuthorizationStatus) {
        removeLifecycleObserver()
        let pending = permissionCompletions
        permissionCompletions.removeAll()
        pending.forEach { $0(status) }
    }
}

// MARK: - Authorization

public extension LocationManager {

    /// Whether location services are enabled system-wide
    var areLocationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    /// Checks the current authorization status without prompting
    var currentAuthorizationStatus: LocationAuthorizationStatus {
        Self.mapCLAuthorizationStatus(clManager.authorizationStatus)
    }

    /// Checks the current accuracy authorization status (iOS 14+)
    var currentAccuracyAuthorization: AccuracyAuthorizationStatus {
        Self.mapCLAccuracyAuthorization(clManager.accuracyAuthorization)
    }

    /// Returns whether the app currently has any authorized location access
    var isAuthorized: Bool {
        currentAuthorizationStatus.isAuthorized
    }

    /// Requests "When In Use" location authorization.
    /// Calls completion with the resulting status. If already determined, invokes immediately.
    func requestWhenInUseAuthorization(completion: (@Sendable (LocationAuthorizationStatus) -> Void)? = nil) {
        guard areLocationServicesEnabled else {
            completion?(.denied)
            return
        }

        let current = currentAuthorizationStatus
        if current != .notDetermined {
            completion?(current)
            return
        }

        // Core Location only presents the prompt when the app is in the active foreground
        guard isAppActive else {
            completion?(current)
            return
        }

        // Validate Info.plist key. If missing, Core Location will do nothing; return the actual unchanged status.
        guard hasWhenInUseUsageDescription else {
            completion?(current)
            return
        }

        if let completion {
            permissionCompletions.append(completion)
        }
        clManager.requestWhenInUseAuthorization()
    }

    /// Requests "Always" location authorization.
    /// Safely handles repeat attempts where Core Location silently ignores duplicate upgrade requests,
    /// checks app active state and Info.plist keys to prevent premature attempt recording,
    /// and observes lifecycle reactivation when the prompt is dismissed.
    func requestAlwaysAuthorization(completion: (@Sendable (LocationAuthorizationStatus) -> Void)? = nil) {
        guard areLocationServicesEnabled else {
            completion?(.denied)
            return
        }

        let current = currentAuthorizationStatus
        // If already always authorized or blocked by system
        if current == .authorizedAlways || current == .denied || current == .restricted {
            completion?(current)
            return
        }

        // If WhenInUse and Always upgrade prompt was already requested once before,
        // CoreLocation will not show the prompt again (no-op). Return immediately.
        if current == .authorizedWhenInUse && hasRequestedAlwaysAuthorization {
            completion?(current)
            return
        }

        // Only record the attempt and request if the app is currently in the active foreground
        guard isAppActive else {
            completion?(current)
            return
        }

        // Validate Info.plist keys before recording attempt
        guard hasRequiredUsageDescription(for: .always) else {
            completion?(current)
            return
        }

        // Mark that the prompt has been requested
        hasRequestedAlwaysAuthorization = true

        if let completion {
            permissionCompletions.append(completion)
        }

        // Observe app reactivation in case the user declines the upgrade ("Keep Only While Using")
        // which leaves authorization unchanged without triggering delegate callbacks.
        setupLifecycleObserverForAlwaysRequest()

        clManager.requestAlwaysAuthorization()
    }

    /// Requests temporary full accuracy authorization for a specified purpose key (iOS 14+)
    func requestTemporaryFullAccuracyAuthorization(
        purposeKey: String,
        completion: (@Sendable (AccuracyAuthorizationStatus) -> Void)? = nil
    ) {
        guard areLocationServicesEnabled else {
            completion?(.reducedAccuracy)
            return
        }

        if currentAccuracyAuthorization == .fullAccuracy {
            completion?(.fullAccuracy)
            return
        }

        clManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = self.currentAccuracyAuthorization
                self.accuracyAuthorization = status
                completion?(status)
            }
        }
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

    /// Asynchronously request temporary full accuracy authorization
    @discardableResult
    func requestTemporaryFullAccuracyAuthorizationAsync(purposeKey: String) async -> AccuracyAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requestTemporaryFullAccuracyAuthorization(purposeKey: purposeKey) { status in
                continuation.resume(returning: status)
            }
        }
    }

    #if os(iOS)
    /// Opens the app's Settings page so the user can change location permissions.
    /// iOS only — on macOS, direct users to System Settings > Privacy & Security > Location Services.
    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
    #endif

    /// Checks whether current authorization satisfies what a given feature requires.
    func authorizationUpdateNeeded(for requirement: RequiredAuthorizationLevel) -> AuthorizationUpdateCheck {
        guard areLocationServicesEnabled else {
            return .blocked(.denied)
        }

        let status = currentAuthorizationStatus

        guard hasRequiredUsageDescription(for: requirement) else {
            return .blocked(status)
        }

        switch status {
        case .notDetermined:
            return .needsInitialRequest(requirement)

        case .denied, .restricted:
            return .blocked(status)

        case .authorizedWhenInUse:
            if requirement == .always {
                // If already prompted once for Always upgrade, iOS will not prompt again.
                return hasRequestedAlwaysAuthorization ? .blocked(.authorizedWhenInUse) : .needsUpgradeToAlways
            } else {
                return .satisfied
            }

        case .authorizedAlways:
            return .satisfied

        case .unknown:
            return .blocked(status)
        }
    }

    /// Convenience wrapper that checks and triggers the correct system prompt if needed.
    @discardableResult
    func resolveAuthorizationUpdateIfNeeded(
        for requirement: RequiredAuthorizationLevel,
        completion: @escaping @Sendable (AuthorizationUpdateCheck) -> Void
    ) -> AuthorizationUpdateCheck {
        let check = authorizationUpdateNeeded(for: requirement)

        switch check {
        case .satisfied, .blocked:
            completion(check)

        case .needsInitialRequest(let level):
            if level == .always {
                requestAlwaysAuthorization { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        completion(self.authorizationUpdateNeeded(for: requirement))
                    }
                }
            } else {
                requestWhenInUseAuthorization { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        completion(self.authorizationUpdateNeeded(for: requirement))
                    }
                }
            }

        case .needsUpgradeToAlways:
            requestAlwaysAuthorization { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    completion(self.authorizationUpdateNeeded(for: requirement))
                }
            }
        }

        return check
    }
}

// MARK: - Location Fetching

public extension LocationManager {

    /// Internal method to enqueue a single fetch request with a pre-allocated ID
    @discardableResult
    func enqueueFetchRequest(
        id: UUID,
        accuracy: CLLocationAccuracy? = nil,
        timeout: TimeInterval? = nil,
        maxAge: TimeInterval = 15.0,
        completion: @escaping @Sendable (Result<CLLocation, LocationError>) -> Void
    ) -> Bool {
        guard areLocationServicesEnabled else {
            completion(.failure(.locationServicesDisabled))
            return false
        }
        guard isAuthorized else {
            completion(.failure(.notAuthorized(currentAuthorizationStatus)))
            return false
        }

        let timeoutInterval = timeout ?? defaultFetchTimeout
        let timer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleFetchTimeout(for: id)
            }
        }

        let request = SingleFetchRequest(
            id: id,
            desiredAccuracy: accuracy,
            maxAge: maxAge,
            completion: completion,
            timer: timer
        )
        activeFetchRequests[id] = request
        updateActiveAccuracy()
        startLocationUpdatesIfNeeded()
        return true
    }

    /// Fetches the current location once and returns it via completion.
    /// Multiplexes through location streaming to ensure Core Location API contracts are respected.
    /// - Parameters:
    ///   - accuracy: Desired accuracy override for this request only
    ///   - timeout: Seconds before this specific request times out
    ///   - maxAge: Maximum acceptable age of the location fix in seconds (defaults to 15s)
    ///   - completion: Called with result on the main actor
    /// - Returns: A unique request identifier that can be used to cancel the request
    @discardableResult
    func getCurrentLocation(
        accuracy: CLLocationAccuracy? = nil,
        timeout: TimeInterval? = nil,
        maxAge: TimeInterval = 15.0,
        completion: @escaping @Sendable (Result<CLLocation, LocationError>) -> Void
    ) -> UUID? {
        let requestID = UUID()
        let enqueued = enqueueFetchRequest(
            id: requestID,
            accuracy: accuracy,
            timeout: timeout,
            maxAge: maxAge,
            completion: completion
        )
        return enqueued ? requestID : nil
    }

    /// Cancels a pending single location fetch request and resumes its handler with .cancelled
    func cancelLocationRequest(id: UUID) {
        guard let request = activeFetchRequests.removeValue(forKey: id) else { return }
        request.timer.invalidate()
        updateActiveAccuracy()
        stopLocationUpdatesIfNeeded()
        request.completion(.failure(.cancelled))
    }

    /// Enqueues a fetch request directly for unit testing purposes
    @discardableResult
    func queueFetchRequestForTesting(
        id: UUID = UUID(),
        desiredAccuracy: CLLocationAccuracy? = nil,
        timeout: TimeInterval = 10,
        maxAge: TimeInterval = 15.0,
        completion: @escaping @Sendable (Result<CLLocation, LocationError>) -> Void
    ) -> UUID {
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleFetchTimeout(for: id)
            }
        }
        let request = SingleFetchRequest(
            id: id,
            desiredAccuracy: desiredAccuracy,
            maxAge: maxAge,
            completion: completion,
            timer: timer
        )
        activeFetchRequests[id] = request
        updateActiveAccuracy()
        return id
    }

    /// Async/await version of getCurrentLocation with deterministic Task cancellation support
    func getCurrentLocation(
        accuracy: CLLocationAccuracy? = nil,
        timeout: TimeInterval? = nil,
        maxAge: TimeInterval = 15.0
    ) async throws -> CLLocation {
        try Task.checkCancellation()

        let requestID = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                _ = enqueueFetchRequest(
                    id: requestID,
                    accuracy: accuracy,
                    timeout: timeout,
                    maxAge: maxAge
                ) { result in
                    switch result {
                    case .success(let location):
                        continuation.resume(returning: location)
                    case .failure(let error):
                        if error == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelLocationRequest(id: requestID)
            }
        }
    }

    /// Generates and returns a CLLocation from coordinates (useful for previews and tests)
    func generateLocation(latitude: Double, longitude: Double) -> CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    /// Generates a CLLocation with complete metadata
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

    private func handleFetchTimeout(for requestID: UUID) {
        guard let request = activeFetchRequests.removeValue(forKey: requestID) else { return }
        request.timer.invalidate()
        updateActiveAccuracy()
        stopLocationUpdatesIfNeeded()
        request.completion(.failure(.timeout))
    }
}

// MARK: - Continuous Updates

public extension LocationManager {

    /// Starts delivering continuous location updates.
    /// Listen via `delegate`, `locationPublisher`, `locations` AsyncStream, or observe `lastKnownLocation`.
    func startUpdatingLocation() {
        guard isAuthorized else {
            let error = LocationError.notAuthorized(currentAuthorizationStatus)
            delegate?.locationManager(self, didFailWithError: error)
            _errorPublisher.send(error)
            return
        }
        isContinuousUpdatingActive = true
        updateActiveAccuracy()
        startLocationUpdatesIfNeeded()
    }

    /// Stops delivering continuous location updates.
    func stopUpdatingLocation() {
        isContinuousUpdatingActive = false
        updateActiveAccuracy()
        stopLocationUpdatesIfNeeded()
    }

    /// Starts significant-change location updates (lower power, cell-tower accuracy).
    func startMonitoringSignificantLocationChanges() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        guard isAuthorized else {
            let error = LocationError.notAuthorized(currentAuthorizationStatus)
            delegate?.locationManager(self, didFailWithError: error)
            _errorPublisher.send(error)
            return
        }
        clManager.startMonitoringSignificantLocationChanges()
    }

    /// Stops significant-change location monitoring.
    func stopMonitoringSignificantLocationChanges() {
        clManager.stopMonitoringSignificantLocationChanges()
    }

    #if os(iOS)
    /// Enables background location updates. Requires "Always" permission +
    /// "Location updates" background mode in project capabilities.
    func enableBackgroundLocationUpdates(allowsIndicator: Bool = true) {
        clManager.allowsBackgroundLocationUpdates = true
        clManager.showsBackgroundLocationIndicator = allowsIndicator
    }

    /// Disables background location updates.
    func disableBackgroundLocationUpdates() {
        clManager.allowsBackgroundLocationUpdates = false
        clManager.showsBackgroundLocationIndicator = false
    }
    #endif
}

// MARK: - Geocoding

public extension LocationManager {

    /// Reverse geocodes a CLLocation into a human-readable PlacemarkInfo.
    func reverseGeocode(
        location: CLLocation,
        completion: @escaping @Sendable (Result<PlacemarkInfo, LocationError>) -> Void
    ) {
        #if canImport(MapKit)
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            if let req = MKReverseGeocodingRequest(location: location) {
                Task {
                    do {
                        let items = try await req.mapItems
                        guard let item = items.first else {
                            completion(.failure(.locationUnavailable))
                            return
                        }
                        completion(.success(PlacemarkInfo(from: item)))
                    } catch {
                        completion(.failure(.geocodingFailed(error.localizedDescription)))
                    }
                }
            } else {
                completion(.failure(.locationUnavailable))
            }
        } else {
            performLegacyReverseGeocode(location: location, completion: completion)
        }
        #else
        performLegacyReverseGeocode(location: location, completion: completion)
        #endif
        #else
        performLegacyReverseGeocode(location: location, completion: completion)
        #endif
    }

    @available(iOS, introduced: 14.0, deprecated: 26.0, message: "Use MapKit on macOS 26+ / iOS 26+")
    @available(macOS, introduced: 11.0, deprecated: 26.0, message: "Use MapKit on macOS 26+ / iOS 26+")
    private func performLegacyReverseGeocode(
        location: CLLocation,
        completion: @escaping @Sendable (Result<PlacemarkInfo, LocationError>) -> Void
    ) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(.geocodingFailed(error.localizedDescription)))
                    return
                }
                guard let placemark = placemarks?.first else {
                    completion(.failure(.locationUnavailable))
                    return
                }
                completion(.success(PlacemarkInfo(from: placemark)))
            }
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
        completion: @escaping @Sendable (Result<[PlacemarkInfo], LocationError>) -> Void
    ) {
        #if canImport(MapKit)
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            if let req = MKGeocodingRequest(addressString: address) {
                Task {
                    do {
                        let items = try await req.mapItems
                        let results = items.map { PlacemarkInfo(from: $0) }
                        completion(.success(results))
                    } catch {
                        completion(.failure(.geocodingFailed(error.localizedDescription)))
                    }
                }
            } else {
                completion(.failure(.geocodingFailed("Unable to create geocoding request")))
            }
        } else {
            performLegacyForwardGeocode(address: address, completion: completion)
        }
        #else
        performLegacyForwardGeocode(address: address, completion: completion)
        #endif
        #else
        performLegacyForwardGeocode(address: address, completion: completion)
        #endif
    }

    @available(iOS, introduced: 14.0, deprecated: 26.0, message: "Use MapKit on macOS 26+ / iOS 26+")
    @available(macOS, introduced: 11.0, deprecated: 26.0, message: "Use MapKit on macOS 26+ / iOS 26+")
    private func performLegacyForwardGeocode(
        address: String,
        completion: @escaping @Sendable (Result<[PlacemarkInfo], LocationError>) -> Void
    ) {
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(address) { placemarks, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(.geocodingFailed(error.localizedDescription)))
                    return
                }
                let results = (placemarks ?? []).map { PlacemarkInfo(from: $0) }
                completion(.success(results))
            }
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

public extension LocationManager {

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
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
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

public extension LocationManager {

    /// Starts monitoring a circular geographic region.
    func startMonitoringRegion(
        center: CLLocationCoordinate2D,
        radius: CLLocationDistance,
        identifier: String
    ) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            let error = LocationError.regionMonitoringUnavailable
            delegate?.locationManager(self, didFailWithError: error)
            _errorPublisher.send(error)
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

    /// Requests the state of a specific region (inside or outside).
    /// Result is delivered via `delegate` and `regionStatePublisher`.
    func requestRegionState(identifier: String) {
        for region in clManager.monitoredRegions where region.identifier == identifier {
            clManager.requestState(for: region)
        }
    }
}

// MARK: - Heading

#if os(iOS)
public extension LocationManager {

    /// Whether heading updates are available on this device
    var isHeadingAvailable: Bool {
        CLLocationManager.headingAvailable()
    }

    /// Starts delivering heading (compass) updates
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
public extension LocationManager {

    /// Starts visit monitoring (detects when user arrives/departs from locations).
    /// Requires Always authorization.
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

public extension LocationManager {

    /// Returns true if the coordinate is valid (not kCLLocationCoordinate2DInvalid)
    func isValidCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate)
    }

    /// Returns true if the location's horizontal accuracy is within acceptable bounds
    func isAccurateEnough(_ location: CLLocation, threshold: CLLocationAccuracy = 50) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= threshold
    }

    /// Returns true if the location's timestamp is recent (within maxAge in seconds)
    func isRecent(_ location: CLLocation, maxAge: TimeInterval = 30) -> Bool {
        abs(location.timestamp.timeIntervalSinceNow) <= maxAge
    }
}

// MARK: - CLLocationManagerDelegate

@MainActor
extension LocationManager: @preconcurrency CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Discard negative horizontal accuracy (invalid coordinates)
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate) }) else {
            return
        }

        lastKnownLocation = location
        delegate?.locationManager(self, didUpdateLocation: location)
        _locationPublisher.send(location)

        for continuation in locationContinuations.values {
            continuation.yield(location)
        }

        if !activeFetchRequests.isEmpty {
            var completedRequests: [SingleFetchRequest] = []
            for (id, request) in activeFetchRequests {
                if self.location(location, satisfiesAccuracy: request.desiredAccuracy) && self.isRecent(location, maxAge: request.maxAge) {
                    request.timer.invalidate()
                    completedRequests.append(request)
                    activeFetchRequests.removeValue(forKey: id)
                }
            }

            if !completedRequests.isEmpty {
                updateActiveAccuracy()
                stopLocationUpdatesIfNeeded()

                // Execute completions safely outside iteration
                for request in completedRequests {
                    request.completion(.success(location))
                }
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError {
            // Transient error: CoreLocation will keep searching. Do not fail active fetch requests immediately.
            if clError.code == .locationUnknown && (!activeFetchRequests.isEmpty || isContinuousUpdatingActive) {
                return
            }

            let mappedError: LocationError
            switch clError.code {
            case .denied:
                mappedError = .notAuthorized(currentAuthorizationStatus)
            case .headingFailure:
                mappedError = .headingFailure(clError.localizedDescription)
            case .regionMonitoringDenied, .regionMonitoringFailure, .regionMonitoringSetupDelayed, .regionMonitoringResponseDelayed:
                mappedError = .regionMonitoringFailed(clError.localizedDescription)
            default:
                mappedError = .unknownError(clError.localizedDescription)
            }

            delegate?.locationManager(self, didFailWithError: mappedError)
            _errorPublisher.send(mappedError)

            if !activeFetchRequests.isEmpty {
                let requests = Array(activeFetchRequests.values)
                activeFetchRequests.removeAll()
                updateActiveAccuracy()
                stopLocationUpdatesIfNeeded()

                for request in requests {
                    request.timer.invalidate()
                    request.completion(.failure(mappedError))
                }
            }
        } else {
            let locError = LocationError.unknownError(error.localizedDescription)
            delegate?.locationManager(self, didFailWithError: locError)
            _errorPublisher.send(locError)

            if !activeFetchRequests.isEmpty {
                let requests = Array(activeFetchRequests.values)
                activeFetchRequests.removeAll()
                updateActiveAccuracy()
                stopLocationUpdatesIfNeeded()

                for request in requests {
                    request.timer.invalidate()
                    request.completion(.failure(locError))
                }
            }
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authStatus = Self.mapCLAuthorizationStatus(manager.authorizationStatus)
        let accuracyStatus = Self.mapCLAccuracyAuthorization(manager.accuracyAuthorization)

        let authChanged = self.authorizationStatus != authStatus
        let accuracyChanged = self.accuracyAuthorization != accuracyStatus

        self.authorizationStatus = authStatus
        self.accuracyAuthorization = accuracyStatus

        if authChanged {
            delegate?.locationManager(self, didChangeAuthorizationStatus: authStatus)
            drainPermissionCompletions(with: authStatus)
        }

        if accuracyChanged {
            delegate?.locationManager(self, didChangeAccuracyAuthorization: accuracyStatus)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        delegate?.locationManager(self, didEnterRegion: region)
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        delegate?.locationManager(self, didExitRegion: region)
    }

    public func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        delegate?.locationManager(self, didDetermineState: state, for: region)
        _regionStatePublisher.send((region: region, state: state))
    }

    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let locationError = LocationError.regionMonitoringFailed(error.localizedDescription)
        delegate?.locationManager(self, monitoringDidFailFor: region, withError: locationError)
        _errorPublisher.send(locationError)
    }

    #if os(iOS)
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Discard invalid heading samples (negative headingAccuracy)
        guard newHeading.headingAccuracy >= 0 else { return }

        lastKnownHeading = newHeading
        delegate?.locationManager(self, didUpdateHeading: newHeading)
        _headingPublisher.send(newHeading)

        for continuation in headingContinuations.values {
            continuation.yield(newHeading)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        delegate?.locationManager(self, didVisit: visit)
        _visitPublisher.send(visit)

        for continuation in visitContinuations.values {
            continuation.yield(visit)
        }
    }
    #endif

    // MARK: - Status Mapping Helpers

    public static func mapCLAuthorizationStatus(_ status: CLAuthorizationStatus) -> LocationAuthorizationStatus {
        switch status {
        case .notDetermined:         return .notDetermined
        case .restricted:            return .restricted
        case .denied:                return .denied
        case .authorizedWhenInUse:   return .authorizedWhenInUse
        case .authorizedAlways:      return .authorizedAlways
        @unknown default:            return .unknown
        }
    }

    public static func mapCLAccuracyAuthorization(_ accuracy: CLAccuracyAuthorization) -> AccuracyAuthorizationStatus {
        switch accuracy {
        case .fullAccuracy:    return .fullAccuracy
        case .reducedAccuracy: return .reducedAccuracy
        @unknown default:      return .unknown
        }
    }
}
