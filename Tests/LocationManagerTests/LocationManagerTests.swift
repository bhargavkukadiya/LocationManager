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
    private let defaultsSuiteName = "LocationManagerTests"

    override func setUp() async throws {
        try await super.setUp()
        cancellables.removeAll()
        let lm = LocationManager.shared
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        lm.userDefaults = defaults
        lm.systemLocationUpdatesHandlerForTesting = { _ in }
        lm.isAppActiveOverrideForTesting = nil
        lm.cachedLocationServicesEnabled = true
        lm.resetFetchStateForTesting()
        lm.resetAlwaysAuthorizationRequestTracking()
        lm.desiredAccuracy = kCLLocationAccuracyBest
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        let lm = LocationManager.shared
        lm.delegate = nil
        lm.authorizationStatusOverrideForTesting = nil
        lm.isAppActiveOverrideForTesting = nil
        lm.infoDictionaryValue = { Bundle.main.object(forInfoDictionaryKey: $0) }
        lm.handleAuthorizationChange(lm.currentAuthorizationStatus, accuracyStatus: lm.currentAccuracyAuthorization)
        lm.stopUpdatingLocation()
        lm.resetFetchStateForTesting()
        try await super.tearDown()
    }

    /// Yields to the main actor until `condition` holds (bounded, so a bug fails instead of hanging)
    private func waitUntil(_ condition: () -> Bool) async {
        var attempts = 0
        while !condition() && attempts < 1_000 {
            attempts += 1
            await Task.yield()
        }
    }

    // MARK: - Review Regression Tests

    private func sample(accuracy: Double, age: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 1,
                   timestamp: Date().addingTimeInterval(-age))
    }

    func testSensorErrorsDoNotFailLocationFetch() async {
        let completed = expectation(description: "GPS survives other sensor failures")
        let lm = LocationManager.shared
        let id = lm.queueFetchRequestForTesting(desiredAccuracy: 10) { result in
            guard case .success(let location) = result else {
                XCTFail("GPS request failed: \(result)")
                return
            }
            XCTAssertEqual(location.horizontalAccuracy, 5)
            completed.fulfill()
        }
        defer { lm.cancelLocationRequest(id: id) }
        for code in [CLError.Code.headingFailure, .regionMonitoringFailure] {
            lm.locationManager(CLLocationManager(), didFailWithError: NSError(domain: kCLErrorDomain, code: code.rawValue))
        }
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 5)])
        await fulfillment(of: [completed], timeout: 1)
    }

    func testFetchSnapshotsConfiguredAccuracy() async {
        let completed = expectation(description: "Only accurate fix resolves default request")
        let lm = LocationManager.shared
        lm.desiredAccuracy = 10
        let id = lm.queueFetchRequestForTesting { result in
            guard case .success(let location) = result else {
                XCTFail("Unexpected result: \(result)")
                return
            }
            XCTAssertEqual(location.horizontalAccuracy, 5)
            completed.fulfill()
        }
        defer { lm.cancelLocationRequest(id: id) }
        lm.desiredAccuracy = 1000
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 1000)])
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 5)])
        await fulfillment(of: [completed], timeout: 1)
    }

    func testBatchResolvesRequestsWithDifferentSamples() async {
        let precise = expectation(description: "Precise request uses earlier fresh sample")
        let coarse = expectation(description: "Coarse request uses latest sample")
        let lm = LocationManager.shared
        let preciseID = lm.queueFetchRequestForTesting(desiredAccuracy: 10, maxAge: 10) { result in
            guard case .success(let location) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(location.horizontalAccuracy, 5)
            precise.fulfill()
        }
        let coarseID = lm.queueFetchRequestForTesting(desiredAccuracy: 100, maxAge: 10) { result in
            guard case .success(let location) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(location.horizontalAccuracy, 50)
            coarse.fulfill()
        }
        defer {
            lm.cancelLocationRequest(id: preciseID)
            lm.cancelLocationRequest(id: coarseID)
        }
        lm.locationManager(CLLocationManager(), didUpdateLocations: [
            sample(accuracy: 1, age: 100), sample(accuracy: 5, age: 1), sample(accuracy: 50)
        ])
        XCTAssertEqual(lm.lastKnownLocation?.horizontalAccuracy, 50)
        await fulfillment(of: [precise, coarse], timeout: 1)
    }

    func testIgnoredAlwaysRequestCompletesAtDeadline() async {
        let completed = expectation(description: "Ignored request completes")
        let lm = LocationManager.shared
        let expectedStatus = lm.currentAuthorizationStatus
        lm.beginAuthorizationRequest(level: .always, completion: { status in
            XCTAssertEqual(status, expectedStatus)
            completed.fulfill()
        }, timeout: 0.01)
        await fulfillment(of: [completed], timeout: 1)
    }

    func testExpiredTemporaryAuthorizationResetsUpgradeTracking() {
        let lm = LocationManager.shared
        lm.handleAuthorizationChange(.authorizedWhenInUse, accuracyStatus: .fullAccuracy)
        lm.beginAuthorizationRequest(level: .always, completion: nil)
        XCTAssertTrue(lm.hasRequestedAlwaysAuthorization)
        lm.handleAuthorizationChange(.notDetermined, accuracyStatus: .fullAccuracy)
        XCTAssertFalse(lm.hasRequestedAlwaysAuthorization)
        lm.handleAuthorizationChange(lm.currentAuthorizationStatus, accuracyStatus: lm.currentAccuracyAuthorization)
    }

    func testConcurrentAlwaysRequestsShareCompletionAndIgnoreOldDeadline() async {
        let first = expectation(description: "First caller")
        let second = expectation(description: "Second caller")
        let newer = expectation(description: "New request")
        let lm = LocationManager.shared
        let oldID = lm.beginAuthorizationRequest(level: .always, completion: { status in
            XCTAssertEqual(status, .authorizedWhenInUse)
            first.fulfill()
        })
        let sharedID = lm.beginAuthorizationRequest(level: .always, completion: { status in
            XCTAssertEqual(status, .authorizedWhenInUse)
            second.fulfill()
        })
        XCTAssertEqual(oldID, sharedID)
        lm.finishAuthorizationRequest(id: oldID, status: .authorizedWhenInUse)
        let newID = lm.beginAuthorizationRequest(level: .always, completion: { status in
            XCTAssertEqual(status, .authorizedAlways)
            newer.fulfill()
        })
        lm.finishAuthorizationRequest(id: oldID, status: .denied)
        lm.finishAuthorizationRequest(id: newID, status: .authorizedAlways)
        await fulfillment(of: [first, second, newer], timeout: 1)
    }

    private final class UpgradeDelegate: LocationManagerDelegate {
        var requestID: UUID?
        let completion: @Sendable (LocationAuthorizationStatus) -> Void
        init(completion: @escaping @Sendable (LocationAuthorizationStatus) -> Void) {
            self.completion = completion
        }
        func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus) {
            if status == .authorizedWhenInUse {
                requestID = manager.beginAuthorizationRequest(level: .always, completion: completion)
            }
        }
    }

    func testAuthorizationDelegateCanEnqueueUpgradeWithoutPrematureCompletion() async {
        let original = expectation(description: "Original request")
        let upgraded = expectation(description: "Reentrant upgrade")
        let lm = LocationManager.shared
        lm.handleAuthorizationChange(.notDetermined, accuracyStatus: .fullAccuracy)
        let delegate = UpgradeDelegate { status in
            XCTAssertEqual(status, .authorizedAlways)
            upgraded.fulfill()
        }
        lm.delegate = delegate
        defer {
            lm.delegate = nil
            lm.handleAuthorizationChange(lm.currentAuthorizationStatus, accuracyStatus: lm.currentAccuracyAuthorization)
        }
        lm.beginAuthorizationRequest(level: .always, completion: { status in
            XCTAssertEqual(status, .authorizedWhenInUse)
            original.fulfill()
        })
        lm.handleAuthorizationChange(.authorizedWhenInUse, accuracyStatus: .fullAccuracy)
        guard let id = delegate.requestID else { return XCTFail("Upgrade was not queued") }
        lm.finishAuthorizationRequest(id: id, status: .authorizedAlways)
        await fulfillment(of: [original, upgraded], timeout: 1)
    }

    // MARK: - Fetch Engine Regression Tests

    func testFetchTimesOut() async {
        let timedOut = expectation(description: "Request times out")
        LocationManager.shared.queueFetchRequestForTesting(timeout: 0.05) { result in
            guard case .failure(.timeout) = result else { return XCTFail("\(result)") }
            timedOut.fulfill()
        }
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertEqual(LocationManager.shared.activeFetchRequestCount, 0)
    }

    func testAsyncFetchCancellationThrowsCancellationError() async {
        let lm = LocationManager.shared
        lm.authorizationStatusOverrideForTesting = .authorizedWhenInUse
        let task = Task { @MainActor in
            try await LocationManager.shared.getCurrentLocation(timeout: 10)
        }
        await waitUntil { lm.activeFetchRequestCount == 1 }
        XCTAssertEqual(lm.activeFetchRequestCount, 1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled fetch returned a location")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(lm.activeFetchRequestCount, 0)
    }

    func testUnauthorizedFetchFailsImmediately() async {
        LocationManager.shared.authorizationStatusOverrideForTesting = .denied
        do {
            _ = try await LocationManager.shared.getCurrentLocation()
            XCTFail("Unauthorized fetch returned a location")
        } catch let error as LocationError {
            XCTAssertEqual(error, .notAuthorized(.denied))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFatalErrorFailsAllPendingFetches() async {
        let failed = expectation(description: "Both requests fail")
        failed.expectedFulfillmentCount = 2
        let lm = LocationManager.shared
        for _ in 0..<2 {
            lm.queueFetchRequestForTesting { result in
                guard case .failure(.unknownError) = result else { return XCTFail("\(result)") }
                failed.fulfill()
            }
        }
        lm.locationManager(CLLocationManager(), didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.Code.network.rawValue))
        XCTAssertEqual(lm.activeFetchRequestCount, 0)
        await fulfillment(of: [failed], timeout: 1)
    }

    func testLocationUnknownIsTransient() async {
        let resolved = expectation(description: "Request survives locationUnknown")
        let reported = expectation(description: "locationUnknown must not be surfaced")
        reported.isInverted = true
        let lm = LocationManager.shared
        lm.errorPublisher.sink { _ in reported.fulfill() }.store(in: &cancellables)
        let id = lm.queueFetchRequestForTesting { result in
            if case .success = result { resolved.fulfill() }
        }
        defer { lm.cancelLocationRequest(id: id) }

        lm.locationManager(CLLocationManager(), didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.Code.locationUnknown.rawValue))
        XCTAssertEqual(lm.activeFetchRequestCount, 1)
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 5)])
        await fulfillment(of: [resolved, reported], timeout: 0.3)
    }

    func testActiveAccuracyTracksMostDemandingRequest() {
        let lm = LocationManager.shared
        lm.desiredAccuracy = 100
        XCTAssertEqual(lm.activeDesiredAccuracy, 100)

        let coarse = lm.queueFetchRequestForTesting(desiredAccuracy: 1000) { _ in }
        XCTAssertEqual(lm.activeDesiredAccuracy, 1000)
        let precise = lm.queueFetchRequestForTesting(desiredAccuracy: 50) { _ in }
        XCTAssertEqual(lm.activeDesiredAccuracy, 50)

        lm.cancelLocationRequest(id: precise)
        XCTAssertEqual(lm.activeDesiredAccuracy, 1000)
        lm.cancelLocationRequest(id: coarse)
        XCTAssertEqual(lm.activeDesiredAccuracy, 100)
    }

    func testFreshCachedFixResolvesFetchImmediately() async {
        let resolved = expectation(description: "Cached fix resolves request")
        let lm = LocationManager.shared
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 5)])
        lm.queueFetchRequestForTesting(desiredAccuracy: 10) { result in
            guard case .success(let location) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(location.horizontalAccuracy, 5)
            resolved.fulfill()
        }
        XCTAssertEqual(lm.activeFetchRequestCount, 0)
        await fulfillment(of: [resolved], timeout: 1)
    }

    func testStaleCachedFixDoesNotResolveFetch() {
        let lm = LocationManager.shared
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 5, age: 60)])
        let id = lm.queueFetchRequestForTesting(maxAge: 10) { _ in }
        XCTAssertEqual(lm.activeFetchRequestCount, 1)
        lm.cancelLocationRequest(id: id)
    }

    func testReusedFetchIDCancelsPreviousRequest() async {
        let cancelled = expectation(description: "Replaced request is cancelled")
        let lm = LocationManager.shared
        let id = UUID()
        lm.queueFetchRequestForTesting(id: id) { result in
            guard case .failure(.cancelled) = result else { return XCTFail("\(result)") }
            cancelled.fulfill()
        }
        lm.queueFetchRequestForTesting(id: id) { _ in }
        XCTAssertEqual(lm.activeFetchRequestCount, 1)
        lm.cancelLocationRequest(id: id)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testReducedAccuracyAcceptsAnyValidFix() async {
        let resolved = expectation(description: "Approximate fix resolves precise request")
        let lm = LocationManager.shared
        lm.handleAuthorizationChange(lm.currentAuthorizationStatus, accuracyStatus: .reducedAccuracy)
        lm.queueFetchRequestForTesting(desiredAccuracy: 10) { result in
            guard case .success(let location) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(location.horizontalAccuracy, 3000)
            resolved.fulfill()
        }
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 3000)])
        await fulfillment(of: [resolved], timeout: 1)
    }

    func testRevokedAuthorizationFailsPendingFetches() async {
        let failed = expectation(description: "Pending fetch fails on revocation")
        let lm = LocationManager.shared
        lm.handleAuthorizationChange(.authorizedWhenInUse, accuracyStatus: .fullAccuracy)
        lm.queueFetchRequestForTesting { result in
            guard case .failure(.notAuthorized(.denied)) = result else { return XCTFail("\(result)") }
            failed.fulfill()
        }
        lm.handleAuthorizationChange(.denied, accuracyStatus: .fullAccuracy)
        XCTAssertEqual(lm.activeFetchRequestCount, 0)
        await fulfillment(of: [failed], timeout: 1)
    }

    func testOlderSampleDoesNotRegressLastKnownLocation() {
        let lm = LocationManager.shared
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 5)])
        lm.locationManager(CLLocationManager(), didUpdateLocations: [sample(accuracy: 10, age: 30)])
        XCTAssertEqual(lm.lastKnownLocation?.horizontalAccuracy, 5)
    }

    // MARK: - System Update Session Regression Tests

    /// Records Core Location start (true) / stop (false) calls
    private final class SystemUpdateRecorder {
        var calls: [Bool] = []
    }

    private func recordSystemUpdates() -> SystemUpdateRecorder {
        let recorder = SystemUpdateRecorder()
        LocationManager.shared.systemLocationUpdatesHandlerForTesting = { recorder.calls.append($0) }
        return recorder
    }

    func testBackgroundFetchPreservesRunningSession() {
        let lm = LocationManager.shared
        let recorder = recordSystemUpdates()
        lm.authorizationStatusOverrideForTesting = .authorizedWhenInUse
        lm.startUpdatingLocation()
        XCTAssertEqual(recorder.calls, [true])

        lm.isAppActiveOverrideForTesting = false
        let backgroundID = lm.getCurrentLocation { _ in }
        XCTAssertNotNil(backgroundID)
        XCTAssertEqual(recorder.calls, [true], "Background fetch must not stop the running session")
        XCTAssertEqual(lm.activeFetchRequestCount, 1)

        lm.isAppActiveOverrideForTesting = true
        let foregroundID = lm.getCurrentLocation { _ in }
        XCTAssertEqual(recorder.calls, [true, false, true], "Foreground fetch restarts for a fresh event")

        backgroundID.map { lm.cancelLocationRequest(id: $0) }
        foregroundID.map { lm.cancelLocationRequest(id: $0) }
    }

    func testStartUpdatingLocationResumesAfterAutomaticPause() {
        let lm = LocationManager.shared
        let recorder = recordSystemUpdates()
        lm.authorizationStatusOverrideForTesting = .authorizedWhenInUse
        lm.startUpdatingLocation()
        lm.startUpdatingLocation()
        XCTAssertEqual(recorder.calls, [true], "Already running: no duplicate start")

        lm.locationManagerDidPauseLocationUpdates(CLLocationManager())
        lm.startUpdatingLocation()
        XCTAssertEqual(recorder.calls, [true, true], "Paused updates must be restartable")

        lm.locationManagerDidResumeLocationUpdates(CLLocationManager())
        lm.stopUpdatingLocation()
        XCTAssertEqual(recorder.calls, [true, true, false])
    }

    private final class PauseRestartDelegate: LocationManagerDelegate {
        func locationManagerDidPauseLocationUpdates(_ manager: LocationManager) {
            manager.startUpdatingLocation()
        }
    }

    func testDelegateCanRestartFromPauseCallback() {
        let lm = LocationManager.shared
        let recorder = recordSystemUpdates()
        let delegate = PauseRestartDelegate()
        lm.delegate = delegate
        lm.authorizationStatusOverrideForTesting = .authorizedWhenInUse
        lm.startUpdatingLocation()
        lm.locationManagerDidPauseLocationUpdates(CLLocationManager())
        XCTAssertEqual(recorder.calls, [true, true])
    }

    // MARK: - Location Services Cache Regression Tests

    private final class ServicesReenabledDelegate: LocationManagerDelegate {
        var servicesEnabled: Bool?
        var updateCheck: AuthorizationUpdateCheck?
        let requested: XCTestExpectation

        init(requested: XCTestExpectation) {
            self.requested = requested
        }

        func locationManager(_ manager: LocationManager, didChangeAuthorizationStatus status: LocationAuthorizationStatus) {
            servicesEnabled = manager.areLocationServicesEnabled
            updateCheck = manager.authorizationUpdateNeeded(for: .whenInUse)
            let requested = requested
            manager.requestWhenInUseAuthorization { result in
                XCTAssertEqual(result, .authorizedWhenInUse)
                requested.fulfill()
            }
        }
    }

    func testReenabledServicesAreNotRejectedByStaleCache() async {
        let lm = LocationManager.shared
        lm.infoDictionaryValue = { $0 == "NSLocationWhenInUseUsageDescription" ? "Foreground" as Any : nil }

        // Services were disabled globally: the app reports `.denied` and the cache is `false`.
        lm.authorizationStatusOverrideForTesting = .denied
        lm.handleAuthorizationChange(.denied, accuracyStatus: .fullAccuracy)
        lm.cachedLocationServicesEnabled = false
        XCTAssertFalse(lm.areLocationServicesEnabled)

        // Re-enabled: the status changes before the off-main refresh can land.
        let requested = expectation(description: "Request sees authorized status")
        let delegate = ServicesReenabledDelegate(requested: requested)
        lm.delegate = delegate
        lm.authorizationStatusOverrideForTesting = .authorizedWhenInUse
        lm.handleAuthorizationChange(.authorizedWhenInUse, accuracyStatus: .fullAccuracy)

        XCTAssertEqual(delegate.servicesEnabled, true)
        XCTAssertEqual(delegate.updateCheck, .satisfied)
        await fulfillment(of: [requested], timeout: 1)
    }

    func testStaleCacheDoesNotRejectNonDeniedStatus() {
        let lm = LocationManager.shared
        lm.cachedLocationServicesEnabled = false
        lm.authorizationStatusOverrideForTesting = .denied
        XCTAssertFalse(lm.areLocationServicesEnabled)
        lm.authorizationStatusOverrideForTesting = .notDetermined
        XCTAssertTrue(lm.areLocationServicesEnabled)
    }

    // MARK: - Authorization Regression Tests

    func testWhenInUseRequestHasDeadlineAndDoesNotMarkAlways() async {
        let completed = expectation(description: "When In Use request completes")
        let lm = LocationManager.shared
        let expectedStatus = lm.currentAuthorizationStatus
        lm.beginAuthorizationRequest(level: .whenInUse, completion: { status in
            XCTAssertEqual(status, expectedStatus)
            completed.fulfill()
        }, timeout: 0.01)
        XCTAssertFalse(lm.hasRequestedAlwaysAuthorization)
        await fulfillment(of: [completed], timeout: 1)
    }

    func testAuthorizationUpdateNeeded() {
        let lm = LocationManager.shared
        lm.infoDictionaryValue = { _ in nil }
        lm.authorizationStatusOverrideForTesting = .authorizedWhenInUse
        XCTAssertEqual(lm.authorizationUpdateNeeded(for: .whenInUse), .blocked(.authorizedWhenInUse))

        let info: [String: Any] = [
            "NSLocationWhenInUseUsageDescription": "Foreground",
            "NSLocationAlwaysAndWhenInUseUsageDescription": "Background"
        ]
        lm.infoDictionaryValue = { info[$0] }
        XCTAssertEqual(lm.authorizationUpdateNeeded(for: .whenInUse), .satisfied)
        XCTAssertEqual(lm.authorizationUpdateNeeded(for: .always), .needsUpgradeToAlways)

        lm.userDefaults.set(true, forKey: "LocationManager.hasRequestedAlwaysAuthorization")
        XCTAssertEqual(lm.authorizationUpdateNeeded(for: .always), .blocked(.authorizedWhenInUse))

        lm.authorizationStatusOverrideForTesting = .notDetermined
        XCTAssertEqual(lm.authorizationUpdateNeeded(for: .always), .needsInitialRequest(.always))
        lm.authorizationStatusOverrideForTesting = .denied
        XCTAssertEqual(lm.authorizationUpdateNeeded(for: .whenInUse), .blocked(.denied))
        lm.authorizationStatusOverrideForTesting = .authorizedAlways
        XCTAssertEqual(lm.authorizationUpdateNeeded(for: .always), .satisfied)
    }

    func testBackgroundLocationModeDetection() {
        let lm = LocationManager.shared
        lm.infoDictionaryValue = { $0 == "UIBackgroundModes" ? ["fetch"] as Any : nil }
        XCTAssertFalse(lm.hasBackgroundLocationMode)
        #if os(iOS)
        XCTAssertFalse(lm.enableBackgroundLocationUpdates())
        #endif
        lm.infoDictionaryValue = { $0 == "UIBackgroundModes" ? ["fetch", "location"] as Any : nil }
        XCTAssertTrue(lm.hasBackgroundLocationMode)
    }

    // MARK: - Delegate & Event Regression Tests

    private final class RecordingDelegate: LocationManagerDelegate {
        var errors: [LocationError] = []
        var regionFailures = 0
        var pauses = 0
        var resumes = 0

        func locationManager(_ manager: LocationManager, didFailWithError error: LocationError) {
            errors.append(error)
        }
        func locationManager(_ manager: LocationManager, monitoringDidFailFor region: CLRegion?, withError error: LocationError) {
            regionFailures += 1
        }
        func locationManagerDidPauseLocationUpdates(_ manager: LocationManager) {
            pauses += 1
        }
        func locationManagerDidResumeLocationUpdates(_ manager: LocationManager) {
            resumes += 1
        }
    }

    func testDelegateReceivesPauseResumeAndRegionFailures() {
        let lm = LocationManager.shared
        let delegate = RecordingDelegate()
        lm.delegate = delegate

        lm.locationManagerDidPauseLocationUpdates(CLLocationManager())
        lm.locationManagerDidResumeLocationUpdates(CLLocationManager())
        lm.locationManager(CLLocationManager(), monitoringDidFailFor: nil, withError: NSError(domain: kCLErrorDomain, code: 0))

        XCTAssertEqual(delegate.pauses, 1)
        XCTAssertEqual(delegate.resumes, 1)
        XCTAssertEqual(delegate.regionFailures, 1)
        XCTAssertEqual(delegate.errors.count, 1)
        guard case .regionMonitoringFailed = delegate.errors.first else {
            return XCTFail("Expected region failure, got \(delegate.errors)")
        }
    }

    func testRegionEventsArePublished() async {
        let entered = expectation(description: "Entry event")
        let exited = expectation(description: "Exit event")
        let lm = LocationManager.shared
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: 37, longitude: -122), radius: 100, identifier: "events")
        lm.regionEventPublisher
            .sink { event in
                XCTAssertEqual(event.region.identifier, "events")
                switch event {
                case .entered: entered.fulfill()
                case .exited: exited.fulfill()
                }
            }
            .store(in: &cancellables)

        lm.locationManager(CLLocationManager(), didEnterRegion: region)
        lm.locationManager(CLLocationManager(), didExitRegion: region)
        await fulfillment(of: [entered, exited], timeout: 1, enforceOrder: true)
    }

    // MARK: - Geocoding Cancellation Tests

    func testGeocodeCancellationCompletesWithCancelled() async {
        let cancelled = expectation(description: "Geocode cancelled")
        let lm = LocationManager.shared
        let id = lm.reverseGeocode(location: CLLocation(latitude: 37, longitude: -122)) { result in
            guard case .failure(.cancelled) = result else { return XCTFail("\(result)") }
            cancelled.fulfill()
        }
        lm.cancelGeocode(id: id)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testAsyncGeocodeCancellationThrowsCancellationError() async {
        let task = Task { @MainActor in
            try await LocationManager.shared.forwardGeocode(address: "1 Apple Park Way, Cupertino, CA")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled geocode returned results")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    #if canImport(MapKit)
    func testStructuredPlacemarkFieldsArePreserved() {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
                                   addressDictionary: ["Street": "1 Infinite Loop", "City": "Cupertino",
                                                       "State": "CA", "ZIP": "95014",
                                                       "Country": "United States", "CountryCode": "US"])
        let info = PlacemarkInfo(from: placemark)
        XCTAssertEqual(info.locality, "Cupertino")
        XCTAssertEqual(info.administrativeArea, "CA")
        XCTAssertEqual(info.postalCode, "95014")
        XCTAssertEqual(info.country, "United States")
        XCTAssertEqual(info.isoCountryCode, "US")
    }
    #endif

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
        await waitUntil { LocationManager.shared.activeLocationStreamCount == initialCount + 1 }
        XCTAssertEqual(LocationManager.shared.activeLocationStreamCount, initialCount + 1)

        // Cancel task to test termination cleanup
        task.cancel()
        _ = await task.result

        // Allow termination handler to execute on MainActor
        await waitUntil { LocationManager.shared.activeLocationStreamCount == initialCount }
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
        if let expectedISOCode = item.addressRepresentations?.region?.identifier {
            XCTAssertEqual(info.isoCountryCode, expectedISOCode)
        }
    }
    #endif
    #endif
}
