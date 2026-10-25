<p align="center">
  <h1 align="center">📍 LocationManager</h1>
  <p align="center">
    <strong>A modern, production-ready, thread-safe CoreLocation manager for iOS & macOS.</strong>
  </p>
  <p align="center">
    <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0%2B-orange.svg?style=flat-square" alt="Swift 6.0+" /></a>
    <a href="https://developer.apple.com"><img src="https://img.shields.io/badge/Platforms-iOS%2014.0%2B%20%7C%20macOS%2011.0%2B-blue.svg?style=flat-square" alt="iOS 14.0+ | macOS 11.0+" /></a>
    <a href="https://swift.org/package-manager/"><img src="https://img.shields.io/badge/SPM-compatible-brightgreen.svg?style=flat-square" alt="Swift Package Manager" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey.svg?style=flat-square" alt="MIT License" /></a>
    <a href="#"><img src="https://img.shields.io/badge/Swift%206-Strict%20Concurrency-success.svg?style=flat-square" alt="Swift 6 Strict Concurrency" /></a>
  </p>
</p>

---

## Overview

Working directly with Apple's `CLLocationManager` often requires writing extensive delegate boilerplate, managing race conditions, handling iOS 14+ approximate location permissions, and wrapping legacy callbacks into async/await.

**LocationManager** solves this with a clean, unified, thread-safe API:

- 🚀 **Swift Concurrency First**: Native `async`/`await`, `AsyncStream`s, and `@MainActor` isolation with zero data races.
- ⚡ **Combine & Delegate Support**: Full reactive Combine publishers (`AnyPublisher`, `@Published`) alongside a traditional delegate protocol.
- 🛡️ **Robust Request Engine**: Safely multiplexes concurrent one-shot requests and continuous tracking without violating Core Location's single-flight contracts.
- 🎯 **iOS 14+ Precision Awareness**: Built-in support for Full vs. Reduced (Approximate) Accuracy and temporary accuracy upgrades.
- 🧭 **Complete Sensor & Location Suite**: Continuous updates, geofencing/region monitoring, reverse & forward geocoding, compass heading, and visit monitoring.
- 🪶 **Zero Dependencies**: Pure Swift built entirely on native Apple frameworks (`CoreLocation`, `MapKit`, `Combine`, `Foundation`).

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
  - [Swift Package Manager](#swift-package-manager-recommended)
  - [Manual Installation](#manual-installation)
- [Configuration (Info.plist)](#configuration-infoplist)
- [Quick Start](#quick-start)
- [Key Features & Usage](#key-features--usage)
  - [1. Permissions & Upgrades](#1-permissions--upgrades)
  - [2. Approximate Location & Temporary Precision (iOS 14+)](#2-approximate-location--temporary-precision-ios-14)
  - [3. One-Shot Location Fetching](#3-one-shot-location-fetching)
  - [4. Streaming Updates (AsyncStream & Combine)](#4-streaming-updates-asyncstream--combine)
  - [5. Reverse & Forward Geocoding](#5-reverse--forward-geocoding)
  - [6. Geofencing & Region Monitoring](#6-geofencing--region-monitoring)
  - [7. Compass Heading & Visits (iOS)](#7-compass-heading--visits-ios)
  - [8. Distance & Bearing Calculations](#8-distance--bearing-calculations)
  - [9. Delegate Protocol](#9-delegate-protocol)
- [Error Handling](#error-handling)
- [Running Tests](#running-tests)
- [Contributing](#contributing)
- [License](#license)

---

## Requirements

| Platform / Tool | Minimum Version |
|---|---|
| **iOS** | 14.0+ |
| **macOS** | 11.0+ |
| **Swift** | 6.0+ (Swift 6 language mode, strict concurrency) |
| **Xcode** | 16.0+ |

> Mac Catalyst is supported through iOS. visionOS, tvOS, and watchOS are not supported and fail at compile time with an explicit error.

---

## Installation

### Swift Package Manager (Recommended)

#### In Xcode:
1. Open your project in Xcode.
2. Navigate to **File → Add Package Dependencies...**
3. Paste the repository URL:
   ```
   https://github.com/bhargavkukadiya/LocationManager.git
   ```
4. Set the **Dependency Rule** to **Up to Next Major Version** with `1.0.1`, then click **Add Package**.

#### In `Package.swift`:
```swift
dependencies: [
    .package(url: "https://github.com/bhargavkukadiya/LocationManager.git", from: "1.0.1")
]
```

### Manual Installation
Copy `Sources/LocationManager/LocationManager.swift` directly into your Xcode project.

---

## Configuration (`Info.plist`)

Add the appropriate location description keys to your application's `Info.plist`:

```xml
<!-- Required: Foreground location access -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>We use your location to show nearby places and provide directions.</string>

<!-- Required: Background & Always location access -->
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>We use your location in the background for geofencing alerts.</string>

<!-- Optional: Temporary Full Accuracy (iOS 14+) -->
<key>NSLocationTemporaryUsageDescriptionDictionary</key>
<dict>
    <key>NavigationPurposeKey</key>
    <string>We need high-precision GPS coordinates for turn-by-turn navigation.</string>
</dict>
```

> **Note**: For background updates on iOS, enable **Location updates** under *Signing & Capabilities → Background Modes*. `enableBackgroundLocationUpdates()` returns `false` and reports an error (instead of letting Core Location raise an exception) when that mode is missing. With When In Use permission, start updates while the app is in the foreground so they continue in the background; with Always permission they can also start in the background.

---

## Quick Start

```swift
import LocationManager

Task { @MainActor in
    // 1. Request permission
    let status = await LocationManager.shared.requestWhenInUseAuthorizationAsync()
    guard status.isAuthorized else {
        print("Location permission denied: \(status.description)")
        return
    }

    // 2. Fetch current location once
    do {
        let location = try await LocationManager.shared.getCurrentLocation()
        print("Current Coordinates: \(location.coordinate.latitude), \(location.coordinate.longitude)")
    } catch {
        print("Fetch failed: \(error.localizedDescription)")
    }

    // 3. Stream continuous updates
    LocationManager.shared.startUpdatingLocation()
    for await location in LocationManager.shared.locations {
        print("Live Location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
    }
}
```

---

## Key Features & Usage

### 1. Permissions & Upgrades

```swift
// Check current permission state
let isAuthorized = LocationManager.shared.isAuthorized
let currentStatus = LocationManager.shared.currentAuthorizationStatus

// Async permission requests
let status = await LocationManager.shared.requestWhenInUseAuthorizationAsync()
let alwaysStatus = await LocationManager.shared.requestAlwaysAuthorizationAsync()

// Deep link to App Settings if permission is denied
#if os(iOS)
LocationManager.shared.openAppSettings()
#endif
```

When In Use and Always requests return the current status after 30 seconds if no response arrives (including requests ignored after Allow Once). Concurrent requests share the outstanding prompt. Later permission changes still reach the authorization publisher and delegate. Upgrade tracking resets when authorization returns to Not Determined. If access is revoked, continuous tracking stops and pending one-shot requests fail with `.notAuthorized`.

`areLocationServicesEnabled` returns a cached value that is refreshed off the main thread at launch, whenever the app becomes active, and on every authorization change, so it never blocks the UI. Because disabled Location Services always surface as `.denied`, it never reports disabled while the status is anything else, including inside authorization callbacks right after services are turned back on. Use `await checkLocationServicesEnabled()` when you need a fresh value.

#### Smart Authorization Resolver
Check what permission level is needed before gating a feature:

```swift
let check = LocationManager.shared.authorizationUpdateNeeded(for: .always)

switch check {
case .satisfied:
    print("Ready to start background feature")
case .needsInitialRequest(let level):
    print("Requesting \(level) for the first time")
case .needsUpgradeToAlways:
    print("Upgrading from WhenInUse to Always")
case .blocked(let status):
    print("Blocked by user in Settings (\(status.description))")
}
```

---

### 2. Approximate Location & Temporary Precision (iOS 14+)

In iOS 14+, users can grant "Reduced Accuracy" (approximate location):

```swift
// Check if app has full precision
let accuracy = LocationManager.shared.currentAccuracyAuthorization // .fullAccuracy or .reducedAccuracy

// Request temporary full accuracy for a specific task
if accuracy == .reducedAccuracy {
    let upgraded = await LocationManager.shared.requestTemporaryFullAccuracyAuthorizationAsync(
        purposeKey: "NavigationPurposeKey"
    )
    print("Upgraded precision: \(upgraded.description)")
}
```

---

### 3. One-Shot Location Fetching

`getCurrentLocation()` supports per-request accuracy targets, timeouts, and automatic Swift `Task` cancellation. Without an accuracy override, it captures the configured `desiredAccuracy` when the request starts. Numeric targets are enforced when accepting fixes; the Best and BestForNavigation modes accept any valid fix, as does any request while the user has granted only approximate location (Reduced Accuracy). A cached fix that already meets the request's accuracy and `maxAge` is returned immediately. Otherwise, in the foreground, updates are (re)started so a fresh fix arrives even during continuous tracking with a `distanceFilter`; in the background, a running session is kept (stopping it would end When In Use background access) and the request waits for that session's next fix or its timeout:

```swift
// Async/Await with Task cancellation
do {
    let location = try await LocationManager.shared.getCurrentLocation(
        accuracy: kCLLocationAccuracyNearestTenMeters,
        timeout: 10
    )
    print("Found location: \(location.coordinate)")
} catch is CancellationError {
    print("Fetch request was cancelled")
} catch {
    print("Error: \(error.localizedDescription)")
}

// Callback-based with explicit request cancellation
let requestID = LocationManager.shared.getCurrentLocation(
    accuracy: kCLLocationAccuracyHundredMeters,
    timeout: 15
) { result in
    switch result {
    case .success(let location):
        print("Received: \(location.coordinate)")
    case .failure(let error):
        print("Error: \(error.localizedDescription)")
    }
}

// Cancel manually if needed
if let requestID {
    LocationManager.shared.cancelLocationRequest(id: requestID)
}
```

---

### 4. Streaming Updates (AsyncStream & Combine)

#### Swift Concurrency `AsyncStream`
Streams use bounded buffers to prevent memory accumulation (`locations` & `headings` buffer the 1 newest item; `visits` and `regionEvents` buffer the 10 newest items). Automatic pausing is off by default. If you set `pausesAutomatically = true`, observe `locationManagerDidPauseLocationUpdates(_:)` / `locationManagerDidResumeLocationUpdates(_:)` on the delegate; paused updates do not restart on their own, so call `startUpdatingLocation()` to resume. With When In Use permission, a pause in the background ends location access until the app returns to the foreground, and restarting from the background cannot restore it — restart once the app is active again, and keep `pausesAutomatically = false` if you need uninterrupted background tracking:

```swift
// Stream locations
LocationManager.shared.startUpdatingLocation()
Task {
    for await location in LocationManager.shared.locations {
        print("Location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
    }
}
```

#### Combine Publishers
```swift
import Combine

var cancellables = Set<AnyCancellable>()

LocationManager.shared.locationPublisher
    .sink { location in
        print("Location: \(location.coordinate)")
    }
    .store(in: &cancellables)

LocationManager.shared.$authorizationStatus
    .sink { status in
        print("Auth changed: \(status.description)")
    }
    .store(in: &cancellables)
```

---

### 5. Reverse & Forward Geocoding

Geocoding requests use isolated per-call `CLGeocoder` instances on all supported OS versions to preserve structured street, state, and postal fields. The explicit OS 26 `PlacemarkInfo(from: MKMapItem)` initializer provides display-address data and does not populate those structured fields.

Async geocoding honors `Task` cancellation (throwing `CancellationError`); callback variants return an ID for `cancelGeocode(id:)`. An address with no match returns an empty array, and a location with no address fails with `.locationUnavailable`; `.geocodingFailed` is reserved for real failures such as network errors:

```swift
// Reverse Geocoding (Coordinates → Address)
let info = try await LocationManager.shared.reverseGeocode(location: location)
print(info.formattedAddress)
// "221B Baker Street, London, Greater London, NW1 6XE, United Kingdom"
print(info.locality ?? "")   // "London"
print(info.country ?? "")    // "United Kingdom"

// Forward Geocoding (Address String → Coordinates)
let placemarks = try await LocationManager.shared.forwardGeocode(address: "1 Apple Park Way, Cupertino, CA")
if let first = placemarks.first {
    print("Coordinates: \(first.coordinate.latitude), \(first.coordinate.longitude)")
}
```

---

### 6. Geofencing & Region Monitoring

```swift
let officeCenter = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

// Start monitoring a 200m radius
LocationManager.shared.startMonitoringRegion(
    center: officeCenter,
    radius: 200,
    identifier: "office_geofence"
)

// Request immediate state check (.inside / .outside)
LocationManager.shared.requestRegionState(identifier: "office_geofence")

// Observe entry / exit events (also available via `regionEventPublisher` and the delegate)
Task {
    for await event in LocationManager.shared.regionEvents {
        switch event {
        case .entered(let region): print("Entered \(region.identifier)")
        case .exited(let region):  print("Exited \(region.identifier)")
        }
    }
}

// Stop monitoring
LocationManager.shared.stopMonitoringRegion(identifier: "office_geofence")
LocationManager.shared.stopMonitoringAllRegions()
```

---

### 7. Compass Heading & Visits (iOS)

```swift
#if os(iOS)
// Compass Heading
if LocationManager.shared.isHeadingAvailable {
    LocationManager.shared.startUpdatingHeading()
    Task {
        for await heading in LocationManager.shared.headings {
            print("Magnetic Heading: \(heading.magneticHeading)°, True: \(heading.trueHeading)°")
        }
    }
}

// Visit Tracking (Arrival / Departure)
LocationManager.shared.startMonitoringVisits()
Task {
    for await visit in LocationManager.shared.visits {
        print("Visited: \(visit.coordinate) from \(visit.arrivalDate) to \(visit.departureDate)")
    }
}
#endif
```

---

### 8. Distance & Bearing Calculations

```swift
let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
let la = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

// Great-circle distance (meters)
let distanceMeters = LocationManager.shared.distance(from: sf, to: la)
print("\(distanceMeters / 1000) km") // ~559 km

// Initial bearing (0–360°)
let bearing = LocationManager.shared.bearing(from: sf, to: la)
print("\(bearing)°") // ~137°

// Distance from device's last known location
if let dist = LocationManager.shared.distanceFromCurrentLocation(to: la) {
    print("Distance to LA: \(dist / 1000) km")
}

// Point-in-radius geofence check
let isNearby = LocationManager.shared.isCoordinate(la, within: 600_000, of: sf) // true
```

---

### 9. Delegate Protocol

For UIKit or AppKit architectures, adopt `@MainActor LocationManagerDelegate`:

```swift
@MainActor
final class LocationTracker: LocationManagerDelegate {

    init() {
        LocationManager.shared.delegate = self
    }

    func locationManager(_ manager: LocationManager, didUpdateLocation location: CLLocation) {
        print("Updated location: \(location.coordinate)")
    }

    func locationManager(_ manager: LocationManager, didFailWithError error: LocationError) {
        print("Location error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus) {
        print("Authorization changed: \(status.description)")
    }

    func locationManager(_ manager: LocationManager, didEnterRegion region: CLRegion) {
        print("Entered geofence: \(region.identifier)")
    }

    func locationManager(_ manager: LocationManager, didExitRegion region: CLRegion) {
        print("Exited geofence: \(region.identifier)")
    }

    func locationManager(_ manager: LocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        print("Geofence state: \(state == .inside ? "Inside" : "Outside")")
    }

    // Only called when `pausesAutomatically` is true; paused updates do not restart on their own.
    // With When In Use permission, a pause in the background ends location access until the app
    // is back in the foreground, so restart from your foreground handler rather than from here.
    private var resumeAfterPause = false

    func locationManagerDidPauseLocationUpdates(_ manager: LocationManager) {
        resumeAfterPause = true
    }

    func appDidBecomeActive() { // e.g. call when `scenePhase` becomes `.active`
        guard resumeAfterPause else { return }
        resumeAfterPause = false
        LocationManager.shared.startUpdatingLocation()
    }

    #if os(iOS)
    func locationManager(_ manager: LocationManager, didUpdateHeading heading: CLHeading) {
        print("Heading: \(heading.trueHeading)°")
    }

    func locationManager(_ manager: LocationManager, didVisit visit: CLVisit) {
        print("Visit event: \(visit)")
    }
    #endif
}
```

---

## Error Handling

All errors conform to `LocalizedError`, `Sendable`, and `Equatable`:

| Case | Meaning |
|---|---|
| `.notAuthorized(status)` | Location permission was denied or restricted |
| `.locationServicesDisabled` | Device-wide location services are disabled |
| `.locationUnavailable` | Hardware could not determine current coordinates |
| `.geocodingFailed(message)` | Reverse or forward geocoding failed |
| `.timeout` | One-shot location request timed out |
| `.cancelled` | Location request was explicitly cancelled |
| `.regionMonitoringUnavailable` | Region monitoring is not supported on this device |
| `.regionMonitoringFailed(message)` | Geofence registration failed (also delivered to `monitoringDidFailFor` on the delegate) |
| `.headingFailure(message)` | Magnetometer heading failed |
| `.unknownError(message)` | Underlying Core Location system error |

---

## Running Tests

Execute the automated test suite from the command line:

```bash
swift test
```

---

## Contributing

Contributions, issues, and feature requests are welcome!

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for more information.
