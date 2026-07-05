# 📍 LocationManager

A comprehensive, production-ready **singleton** for all CoreLocation tasks in iOS apps. Drop in one file and get permissions, location fetching, geocoding, region monitoring, heading, distance utilities, and full Combine/async-await support — with zero third-party dependencies.

---

## Requirements

| | Minimum |
|---|---|
| iOS | 14.0+ |
| Swift | 5.5+ |
| Xcode | 13+ |
| Frameworks | CoreLocation, Combine (UIKit on iOS only) |

### Platform Notes

This file compiles on both iOS and macOS, but a few APIs are wrapped in `#if os(iOS)` because they have no macOS equivalent:

| API | Why iOS-only |
|---|---|
| `openAppSettings()` | Uses `UIApplication`; no Settings deep-link exists on macOS |
| `enableBackgroundLocationUpdates()` / `disableBackgroundLocationUpdates()` | `allowsBackgroundLocationUpdates` / `showsBackgroundLocationIndicator` don't exist on macOS |
| `isHeadingAvailable`, `startUpdatingHeading()`, `stopUpdatingHeading()` | Macs have no magnetometer/compass |
| `startMonitoringVisits()` / `stopMonitoringVisits()` | Visit monitoring is iOS-only |

Everything else (authorization requests, one-shot/continuous location, geocoding, region monitoring, distance/bearing utilities) works on both platforms.

---

## Installation

1. Copy `LocationManager.swift` into your Xcode project.
2. Add the required keys to your `Info.plist`:

```xml
<!-- Required for When In Use -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>We use your location to show nearby content.</string>

<!-- Required if you request Always access -->
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>We use your location in the background to provide timely updates.</string>
```

3. If using background location updates, enable **Location updates** under  
   *Target → Signing & Capabilities → Background Modes*.

---

## Quick Start

```swift
// 1. Request permission
LocationManager.shared.requestWhenInUseAuthorization()

// 2. Get current location
Task {
    do {
        let location = try await LocationManager.shared.getCurrentLocation()
        print("Lat: \(location.coordinate.latitude)")
    } catch {
        print(error.localizedDescription)
    }
}
```

---

## Features at a Glance

| Category | Feature |
|---|---|
| **Authorization** | WhenInUse / Always requests, async variants, open Settings |
| **Location** | One-shot fetch, continuous updates, significant changes, background |
| **Geocoding** | Reverse (coords → address), Forward (address → coords) |
| **Region Monitoring** | Add/remove circular regions, enter/exit callbacks |
| **Heading** | Compass heading start/stop |
| **Visit Monitoring** | Arrival/departure detection |
| **Distance & Bearing** | Distance between coordinates, bearing in degrees, geofence check |
| **Validation** | Coordinate validity, accuracy threshold, recency check |
| **Reactive** | Combine publishers for location & errors, `@Published` auth status |

---

## API Reference

### Authorization

```swift
// Callback-based
LocationManager.shared.requestWhenInUseAuthorization { status in
    print(status.description) // "Authorized When In Use"
}

// Async/await
let status = await LocationManager.shared.requestWhenInUseAuthorizationAsync()

// Always permission (must have WhenInUse first)
LocationManager.shared.requestAlwaysAuthorization()

// Check current state without prompting
let isOk = LocationManager.shared.isAuthorized
let current = LocationManager.shared.currentAuthorizationStatus

// Deep-link to Settings if denied
LocationManager.shared.openAppSettings()
```

#### Checking if a permission update/upgrade is required

Before gating a feature behind location access, check what — if anything — needs to happen. This distinguishes "never asked yet" from "granted but needs upgrading to Always" from "blocked in Settings":

```swift
let check = LocationManager.shared.authorizationUpdateNeeded(for: .always)

switch check {
case .satisfied:
    print("Good to go")
case .needsInitialRequest(let level):
    print("Need to request \(level) for the first time")
case .needsUpgradeToAlways:
    print("Have WhenInUse, need to upgrade to Always")
case .blocked(let status):
    print("Blocked: \(status.description) — direct to Settings")
}
```

Or let it resolve automatically (requests the right permission for you, and only reports back for the cases you must handle in UI, like `.blocked`):

```swift
LocationManager.shared.resolveAuthorizationUpdateIfNeeded(for: .always) { result in
    switch result {
    case .satisfied:
        // proceed with background feature
        break
    case .blocked:
        // show an alert with a button to LocationManager.shared.openAppSettings()
        break
    default:
        break
    }
}
```

| Requirement | Use when |
|---|---|
| `.whenInUse` | Feature only needs foreground location |
| `.always` | Feature needs background access (geofencing, background tracking) |

---

### Fetching Location

#### One-shot fetch

```swift
// Callback
LocationManager.shared.getCurrentLocation(accuracy: kCLLocationAccuracyHundredMeters, timeout: 10) { result in
    switch result {
    case .success(let location):
        print(location.coordinate)
    case .failure(let error):
        print(error.localizedDescription)
    }
}

// Async/await
let location = try await LocationManager.shared.getCurrentLocation()
```

#### Continuous updates

```swift
LocationManager.shared.startUpdatingLocation()  // start
LocationManager.shared.stopUpdatingLocation()   // stop

// Lower-power significant-change monitoring
LocationManager.shared.startMonitoringSignificantLocationChanges()
LocationManager.shared.stopMonitoringSignificantLocationChanges()
```

#### Background updates

```swift
LocationManager.shared.enableBackgroundLocationUpdates()   // shows blue bar
LocationManager.shared.disableBackgroundLocationUpdates()
```

---

### Generating a Location

Useful for testing, mapping, or constructing custom locations:

```swift
// Simple
let london = LocationManager.shared.generateLocation(latitude: 51.5074, longitude: -0.1278)

// With full metadata
let precise = LocationManager.shared.generateLocation(
    latitude: 51.5074,
    longitude: -0.1278,
    altitude: 15,
    horizontalAccuracy: 5,
    speed: 1.4,
    timestamp: Date()
)
```

---

### Geocoding

```swift
// Reverse geocode: coordinates → address
let info = try await LocationManager.shared.reverseGeocode(location: location)
print(info.formattedAddress) // "221B Baker Street, London, ENG, NW1 6XE, United Kingdom"
print(info.locality)         // "London"
print(info.country)          // "United Kingdom"

// Forward geocode: address → coordinates
let results = try await LocationManager.shared.forwardGeocode(address: "1 Infinite Loop, Cupertino")
if let first = results.first {
    print(first.coordinate) // CLLocationCoordinate2D
}
```

---

### Distance & Bearing

```swift
let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
let la = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

// Distance in meters
let meters = LocationManager.shared.distance(from: sf, to: la)
print("\(meters / 1000) km") // ~559 km

// Bearing in degrees (0–360)
let degrees = LocationManager.shared.bearing(from: sf, to: la)
print("\(degrees)°") // ~135°

// Distance from last known location
let dist = LocationManager.shared.distanceFromCurrentLocation(to: la)

// Geofence point check
let inside = LocationManager.shared.isCoordinate(la, within: 600_000, of: sf) // true
```

---

### Region Monitoring

```swift
// Start monitoring a 200m radius around a coordinate
LocationManager.shared.startMonitoringRegion(
    center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
    radius: 200,
    identifier: "office"
)

// Stop specific region
LocationManager.shared.stopMonitoringRegion(identifier: "office")

// Stop all
LocationManager.shared.stopMonitoringAllRegions()

// Query all active regions
let regions = LocationManager.shared.monitoredRegions
```

Entry/exit events are delivered via the delegate (see Delegate section below).

---

### Heading (Compass)

```swift
guard LocationManager.shared.isHeadingAvailable else { return }

LocationManager.shared.startUpdatingHeading()
LocationManager.shared.stopUpdatingHeading()
```

---

### Visit Monitoring

```swift
// Requires Always authorization
LocationManager.shared.startMonitoringVisits()
LocationManager.shared.stopMonitoringVisits()
```

---

### Validation Utilities

```swift
let coord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)

LocationManager.shared.isValidCoordinate(coord)          // true / false
LocationManager.shared.isAccurateEnough(location, threshold: 30)  // within 30m accuracy
LocationManager.shared.isRecent(location, maxAge: 60)    // timestamp within 60 seconds
```

---

## Receiving Updates

### Delegate

Conform to `LocationManagerDelegate` and assign `LocationManager.shared.delegate = self`.  
All methods have default no-op implementations — implement only what you need.

```swift
extension MyViewController: LocationManagerDelegate {

    func locationManager(_ manager: LocationManager, didUpdateLocation location: CLLocation) {
        print("New location: \(location.coordinate)")
    }

    func locationManager(_ manager: LocationManager, didFailWithError error: LocationError) {
        print("Error: \(error.localizedDescription)")
    }

    func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus) {
        print("Auth changed: \(status.description)")
    }

    func locationManager(_ manager: LocationManager, didEnterRegion region: CLRegion) {
        print("Entered: \(region.identifier)")
    }

    func locationManager(_ manager: LocationManager, didExitRegion region: CLRegion) {
        print("Exited: \(region.identifier)")
    }
}
```

---

### Combine Publishers

```swift
import Combine

var cancellables = Set<AnyCancellable>()

// Location stream
LocationManager.shared.locationPublisher
    .receive(on: DispatchQueue.main)
    .sink { location in
        print("Location: \(location.coordinate)")
    }
    .store(in: &cancellables)

// Error stream
LocationManager.shared.errorPublisher
    .sink { error in
        print("Error: \(error.localizedDescription)")
    }
    .store(in: &cancellables)

// Observe authorization status changes
LocationManager.shared.$authorizationStatus
    .sink { status in
        print("Auth: \(status.description)")
    }
    .store(in: &cancellables)

// Start updates
LocationManager.shared.startUpdatingLocation()
```

---

## Configuration

```swift
let lm = LocationManager.shared

lm.desiredAccuracy    = kCLLocationAccuracyBest        // default
lm.distanceFilter     = 10                             // meters before next update
lm.pausesAutomatically = false                         // prevent auto-pause
```

---

## Error Handling

All errors are surfaced as `LocationError`, which conforms to `LocalizedError`:

| Case | Meaning |
|---|---|
| `.notAuthorized(status)` | Permission not granted |
| `.locationServicesDisabled` | System-level location off |
| `.locationUnavailable` | Could not determine location |
| `.geocodingFailed(error)` | Geocoder returned an error |
| `.timeout` | One-shot fetch exceeded time limit |
| `.regionMonitoringUnavailable` | Device doesn't support region monitoring |
| `.unknownError(error)` | Unexpected CoreLocation error |

---

## Supporting Types

### `LocationAuthorizationStatus`

Wraps `CLAuthorizationStatus` with a convenient `.isAuthorized` bool and `.description` string.

### `PlacemarkInfo`

Decoded result from geocoding with properties: `name`, `thoroughfare`, `locality`, `administrativeArea`, `postalCode`, `country`, `isoCountryCode`, `coordinate`, and `formattedAddress`.

---

## License

MIT — use freely in personal and commercial projects.
