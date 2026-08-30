import XCTest
import CoreLocation
import Combine
#if canImport(MapKit)
import MapKit
#endif
@testable import LocationManager

@MainActor
final class LocationManagerTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        cancellables.removeAll()
        LocationManager.shared.resetAlwaysAuthorizationRequestTracking()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        LocationManager.shared.stopUpdatingLocation()
        try await super.tearDown()
    }

    // MARK: - Distance & Bearing Tests

    func testDistanceCalculation() {
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let la = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

        let distance = LocationManager.shared.distance(from: sf, to: la)
        XCTAssertGreaterThan(distance, 550_000, "Distance should be ~559 km")
        XCTAssertLessThan(distance, 570_000, "Distance should be ~559 km")
    }

    func testBearingCalculation() {
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let la = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

        let bearing = LocationManager.shared.bearing(from: sf, to: la)
        XCTAssertGreaterThan(bearing, 130)
        XCTAssertLessThan(bearing, 140)

        // Cardinal North
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let north = CLLocationCoordinate2D(latitude: 10, longitude: 0)
        XCTAssertEqual(LocationManager.shared.bearing(from: origin, to: north), 0.0, accuracy: 0.001)

        // Cardinal East
        let east = CLLocationCoordinate2D(latitude: 0, longitude: 10)
        XCTAssertEqual(LocationManager.shared.bearing(from: origin, to: east), 90.0, accuracy: 0.001)

        // Cardinal South
        let south = CLLocationCoordinate2D(latitude: -10, longitude: 0)
        XCTAssertEqual(LocationManager.shared.bearing(from: origin, to: south), 180.0, accuracy: 0.001)

        // Cardinal West
        let west = CLLocationCoordinate2D(latitude: 0, longitude: -10)
        XCTAssertEqual(LocationManager.shared.bearing(from: origin, to: west), 270.0, accuracy: 0.001)
    }

    func testGeofencePointCheck() {
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let la = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)

        XCTAssertTrue(LocationManager.shared.isCoordinate(la, within: 600_000, of: sf))
        XCTAssertFalse(LocationManager.shared.isCoordinate(la, within: 100_000, of: sf))
    }

    // MARK: - Validation Utilities Tests

    func testCoordinateValidity() {
        let validCoord = CLLocationCoordinate2D(latitude: 45.0, longitude: -75.0)
        let invalidCoord = kCLLocationCoordinate2DInvalid

        XCTAssertTrue(LocationManager.shared.isValidCoordinate(validCoord))
        XCTAssertFalse(LocationManager.shared.isValidCoordinate(invalidCoord))
    }

    func testAccuracyThreshold() {
        let validCoord = CLLocationCoordinate2D(latitude: 45.0, longitude: -75.0)
        let accurateLoc = CLLocation(
            coordinate: validCoord,
            altitude: 10,
            horizontalAccuracy: 15,
            verticalAccuracy: 10,
            course: 0,
            speed: 0,
            timestamp: Date()
        )

        XCTAssertTrue(LocationManager.shared.isAccurateEnough(accurateLoc, threshold: 20))
        XCTAssertFalse(LocationManager.shared.isAccurateEnough(accurateLoc, threshold: 10))

        let negativeAccuracyLoc = CLLocation(
            coordinate: validCoord,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            course: 0,
            speed: 0,
            timestamp: Date()
        )
        XCTAssertFalse(LocationManager.shared.isAccurateEnough(negativeAccuracyLoc, threshold: 50))
    }

    func testRecencyCheck() {
        let validCoord = CLLocationCoordinate2D(latitude: 45.0, longitude: -75.0)
        let freshLoc = CLLocation(
            coordinate: validCoord,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 0,
            timestamp: Date()
        )
        let staleLoc = CLLocation(
            coordinate: validCoord,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 0,
            timestamp: Date().addingTimeInterval(-120)
        )

        XCTAssertTrue(LocationManager.shared.isRecent(freshLoc, maxAge: 10))
        XCTAssertFalse(LocationManager.shared.isRecent(staleLoc, maxAge: 60))
    }

    // MARK: - Invalid Sample Filtering Tests

    func testInvalidLocationFiltering() {
        let initialValidLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 0,
            timestamp: Date()
        )
        // Feed valid location
        LocationManager.shared.locationManager(CLLocationManager(), didUpdateLocations: [initialValidLoc])
        XCTAssertEqual(LocationManager.shared.lastKnownLocation?.coordinate.latitude, 37.7749)

        // Feed invalid location (negative horizontal accuracy)
        let invalidLoc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10.0, longitude: 10.0),
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            course: 0,
            speed: 0,
            timestamp: Date()
        )
        LocationManager.shared.locationManager(CLLocationManager(), didUpdateLocations: [invalidLoc])

        // lastKnownLocation should NOT have been overwritten by invalid sample
        XCTAssertEqual(LocationManager.shared.lastKnownLocation?.coordinate.latitude, 37.7749)
    }

    // MARK: - One-Shot Fetch and Cancellation Tests

    func testOneShotFetchCancellation() async {
        let expectation = expectation(description: "Fetch cancelled")

        let requestID = LocationManager.shared.queueFetchRequestForTesting(timeout: 10) { result in
            switch result {
            case .success:
                XCTFail("Request should have been cancelled")
            case .failure(let error):
                if error == .cancelled {
                    expectation.fulfill()
                } else {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }

        LocationManager.shared.cancelLocationRequest(id: requestID)
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testConcurrentFetchRequestsResolution() async {
        let exp100m = expectation(description: "100m fetch completed")
        let exp10m = expectation(description: "10m fetch should NOT complete for 50m fix")
        exp10m.isInverted = true

        let id100m = LocationManager.shared.queueFetchRequestForTesting(desiredAccuracy: 100, timeout: 5) { result in
            if case .success(let loc) = result, loc.horizontalAccuracy <= 100 {
                exp100m.fulfill()
            }
        }
        defer { LocationManager.shared.cancelLocationRequest(id: id100m) }

        let id10m = LocationManager.shared.queueFetchRequestForTesting(desiredAccuracy: 10, timeout: 5) { _ in
            exp10m.fulfill()
        }
        defer { LocationManager.shared.cancelLocationRequest(id: id10m) }

        // Deliver a 50m fix: satisfies 100m request, but does NOT satisfy 10m request
        let fix50m = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 0,
            horizontalAccuracy: 50,
            verticalAccuracy: 10,
            course: 0,
            speed: 0,
            timestamp: Date()
        )
        LocationManager.shared.locationManager(CLLocationManager(), didUpdateLocations: [fix50m])

        await fulfillment(of: [exp100m, exp10m], timeout: 0.5)
    }

    func testStaleLocationFixDoesNotResolveOneShotFetch() async {
        let expStale = expectation(description: "Stale fix must NOT resolve one-shot request")
        expStale.isInverted = true

        let expFresh = expectation(description: "Fresh fix resolves request")

        let staleTimestamp = Date().addingTimeInterval(-120)
        let freshTimestamp = Date()

        let requestID = LocationManager.shared.queueFetchRequestForTesting(desiredAccuracy: 100, timeout: 5, maxAge: 10) { result in
            switch result {
            case .success(let loc):
                if loc.timestamp <= staleTimestamp.addingTimeInterval(1) {
                    // Stale fix resolved the request -> fulfill inverted expectation so test fails
                    expStale.fulfill()
                } else if loc.timestamp >= freshTimestamp.addingTimeInterval(-1) {
                    // Fresh fix resolved the request
                    expFresh.fulfill()
                }
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
        }
        defer { LocationManager.shared.cancelLocationRequest(id: requestID) }

        // Stale fix (from 2 minutes ago)
        let staleFix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 0,
            timestamp: staleTimestamp
        )
        LocationManager.shared.locationManager(CLLocationManager(), didUpdateLocations: [staleFix])

        // Wait to confirm stale sample did NOT resolve the request
        await fulfillment(of: [expStale], timeout: 0.2)

        // Fresh fix (from now)
        let freshFix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            course: 0,
            speed: 0,
            timestamp: freshTimestamp
        )
        LocationManager.shared.locationManager(CLLocationManager(), didUpdateLocations: [freshFix])

        // Fresh sample must resolve the request
        await fulfillment(of: [expFresh], timeout: 0.5)
    }

    // MARK: - Stream Lifecycle and Termination Tests

    func testAsyncStreamTermination() async {
        let initialCount = LocationManager.shared.activeLocationStreamCount

        let task = Task { @MainActor in
            for await _ in LocationManager.shared.locations {
                // Stream active
            }
        }

        // Allow stream setup
        await Task.yield()
        XCTAssertEqual(LocationManager.shared.activeLocationStreamCount, initialCount + 1)

        // Cancel task to test termination cleanup
        task.cancel()
        _ = await task.result

        // Allow termination handler to execute on MainActor
        await Task.yield()
        XCTAssertEqual(LocationManager.shared.activeLocationStreamCount, initialCount)
    }

    // MARK: - Region State Publisher & Monitoring Tests

    func testRegionStatePublisher() async {
        let expectation = expectation(description: "Region state received")
        let testRegion = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            radius: 100,
            identifier: "test_region"
        )

        LocationManager.shared.regionStatePublisher
            .sink { event in
                if event.region.identifier == "test_region" && event.state == .inside {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        LocationManager.shared.locationManager(CLLocationManager(), didDetermineState: .inside, for: testRegion)

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // MARK: - Supporting Types Tests

    func testAuthorizationStatusProperties() {
        XCTAssertTrue(LocationAuthorizationStatus.authorizedWhenInUse.isAuthorized)
        XCTAssertTrue(LocationAuthorizationStatus.authorizedAlways.isAuthorized)
        XCTAssertFalse(LocationAuthorizationStatus.denied.isAuthorized)
        XCTAssertFalse(LocationAuthorizationStatus.restricted.isAuthorized)
        XCTAssertFalse(LocationAuthorizationStatus.notDetermined.isAuthorized)
        XCTAssertFalse(LocationAuthorizationStatus.unknown.isAuthorized)

        XCTAssertEqual(LocationAuthorizationStatus.authorizedWhenInUse.description, "Authorized When In Use")
        XCTAssertEqual(LocationAuthorizationStatus.authorizedAlways.description, "Authorized Always")
        XCTAssertEqual(LocationAuthorizationStatus.denied.description, "Denied")
    }

    func testAccuracyStatusProperties() {
        XCTAssertTrue(AccuracyAuthorizationStatus.fullAccuracy.isFullAccuracy)
        XCTAssertFalse(AccuracyAuthorizationStatus.reducedAccuracy.isFullAccuracy)
        XCTAssertFalse(AccuracyAuthorizationStatus.unknown.isFullAccuracy)

        XCTAssertEqual(AccuracyAuthorizationStatus.fullAccuracy.description, "Full Accuracy")
        XCTAssertEqual(AccuracyAuthorizationStatus.reducedAccuracy.description, "Reduced Accuracy (Approximate)")
    }

    func testLocationErrorDescriptions() {
        let deniedErr = LocationError.notAuthorized(.denied)
        XCTAssertTrue(deniedErr.localizedDescription.contains("Denied"))

        let timeoutErr = LocationError.timeout
        XCTAssertTrue(timeoutErr.localizedDescription.contains("timed out"))

        let cancelErr = LocationError.cancelled
        XCTAssertTrue(cancelErr.localizedDescription.contains("cancelled"))

        let disabledErr = LocationError.locationServicesDisabled
        XCTAssertTrue(disabledErr.localizedDescription.contains("disabled"))

        let geocodeErr = LocationError.geocodingFailed("Server down")
        XCTAssertTrue(geocodeErr.localizedDescription.contains("Server down"))
    }

    // MARK: - Configuration Tests

    func testConfigurationProperties() {
        let lm = LocationManager.shared
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        XCTAssertEqual(lm.desiredAccuracy, kCLLocationAccuracyHundredMeters)

        lm.distanceFilter = 50
        XCTAssertEqual(lm.distanceFilter, 50)

        lm.pausesAutomatically = true
        XCTAssertTrue(lm.pausesAutomatically)

        lm.pausesAutomatically = false
        XCTAssertFalse(lm.pausesAutomatically)
    }

    // MARK: - Location Generation Helper Tests

    func testGenerateLocation() {
        let loc = LocationManager.shared.generateLocation(latitude: 51.5074, longitude: -0.1278)
        XCTAssertEqual(loc.coordinate.latitude, 51.5074, accuracy: 0.0001)
        XCTAssertEqual(loc.coordinate.longitude, -0.1278, accuracy: 0.0001)

        let detailed = LocationManager.shared.generateLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            altitude: 15,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 2.5
        )
        XCTAssertEqual(detailed.altitude, 15)
        XCTAssertEqual(detailed.horizontalAccuracy, 5)
        XCTAssertEqual(detailed.course, 90)
        XCTAssertEqual(detailed.speed, 2.5)
    }

    // MARK: - Placemark Formatting Tests

    func testPlacemarkFormatting() {
        let placemark = PlacemarkInfo(
            name: "Apple Park",
            thoroughfare: "Apple Park Way",
            subThoroughfare: "1",
            locality: "Cupertino",
            subLocality: nil,
            administrativeArea: "CA",
            subAdministrativeArea: "Santa Clara",
            postalCode: "95014",
            country: "United States",
            isoCountryCode: "US",
            timeZone: TimeZone(identifier: "America/Los_Angeles"),
            coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        )

        XCTAssertTrue(placemark.formattedAddress.contains("1 Apple Park Way"))
        XCTAssertTrue(placemark.formattedAddress.contains("Cupertino"))
        XCTAssertTrue(placemark.formattedAddress.contains("CA"))
        XCTAssertTrue(placemark.formattedAddress.contains("United States"))
    }

    func testPlacemarkInfoFullMapping() {
        let info = PlacemarkInfo(
            name: "Infinite Loop",
            thoroughfare: "Infinite Loop",
            subThoroughfare: "1",
            locality: "Cupertino",
            subLocality: nil,
            administrativeArea: "CA",
            subAdministrativeArea: "Santa Clara",
            postalCode: "95014",
            country: "United States",
            isoCountryCode: "US",
            timeZone: TimeZone(identifier: "America/Los_Angeles"),
            coordinate: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0311),
            rawFormattedAddress: "1 Infinite Loop, Cupertino, CA 95014, United States"
        )

        XCTAssertEqual(info.name, "Infinite Loop")
        XCTAssertEqual(info.locality, "Cupertino")
        XCTAssertEqual(info.country, "United States")
        XCTAssertEqual(info.isoCountryCode, "US")
        XCTAssertEqual(info.formattedAddress, "1 Infinite Loop, Cupertino, CA 95014, United States")
    }

    #if canImport(MapKit)
    #if compiler(>=6.2)
    func testMapKitPlacemarkConversion() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("MapKit geocoding request requires macOS 26+ / iOS 26+")
        }
        let location = CLLocation(latitude: 37.3349, longitude: -122.0090)
        guard let req = MKReverseGeocodingRequest(location: location) else {
            XCTFail("Failed to initialize MKReverseGeocodingRequest")
            return
        }

        let items: [MKMapItem]
        do {
            items = try await req.mapItems
        } catch {
            throw XCTSkip("MapKit live service unavailable in test environment: \(error.localizedDescription)")
        }

        guard let item = items.first else {
            throw XCTSkip("MapKit returned no map items for coordinates in test environment")
        }

        let info = PlacemarkInfo(from: item)
        XCTAssertEqual(info.coordinate.latitude, location.coordinate.latitude, accuracy: 0.01)
        XCTAssertFalse(info.formattedAddress.isEmpty)
        if let expectedCountry = item.addressRepresentations?.regionName {
            XCTAssertEqual(info.country, expectedCountry)
        }
        if let expectedISOCode = item.addressRepresentations?.__regionCode {
            XCTAssertEqual(info.isoCountryCode, expectedISOCode)
        }
    }
    #endif
    #endif
}
