import Foundation
import UIKit
import Capacitor
import CoreLocation
import SQLite3

// MARK: - App-level GPS engine
//
// This engine is deliberately independent from the WebView and from the
// taxi-trip state. AppDelegate starts it at application launch, so GPS does
// not depend on JavaScript, registerPlugin(), or pressing BẮT ĐẦU.
//
// The Capacitor plugin below only exposes this same engine to JavaScript.

public final class TaximetLocationEngine: NSObject, CLLocationManagerDelegate {
    public static let shared = TaximetLocationEngine()

    public static let locationUpdateNotification =
        Notification.Name("TaximetLocationEngine.locationUpdate")
    public static let locationErrorNotification =
        Notification.Name("TaximetLocationEngine.locationError")
    public static let gpsStatusNotification =
        Notification.Name("TaximetLocationEngine.gpsStatus")

    private let locationManager = CLLocationManager()
    private var started = false
    private var heartbeatTimer: Timer?

    // V50.3: native trip-distance state survives WebView suspension and app
    // process relaunch. JS remains a UI consumer; Core Location is authoritative.
    private let tripDefaultsPrefix = "TAXIMET_NATIVE_TRIP_"
    private var nativeTripRunning = false
    private var nativeTripPaused = false
    private var nativeTripId = ""
    private var nativeDistanceM: Double = 0
    private var nativeLastLocation: CLLocation?
    // Accumulates sub-2m valid movement so real slow/creeping motion is not lost
    // by a per-fix threshold, while the distance is only committed once the
    // accumulated motion has enough evidence to count.
    private var nativeSmallMovementM: Double = 0
    private var nativeSmallMovementStart: Date?

    // GPS distance filter: one authoritative rule set for iOS native distance.
    // Invalid/noisy fixes never become the next distance baseline.
    private let maxTripAccuracyM: CLLocationAccuracy = 100.0
    private let minTripDeltaM: CLLocationDistance = 2.0
    private let minConfidentMovementSpeedMps: CLLocationSpeed = 1.2
    private let stationarySpeedMps: CLLocationSpeed = 0.75
    private let stationaryDriftFloorM: CLLocationDistance = 6.0
    private let stationaryDriftMaxM: CLLocationDistance = 25.0
    private let maxTripDeltaM: CLLocationDistance = 10_000.0
    private let maxTripDerivedSpeedMps: CLLocationSpeed = 50.0 // 180 km/h
    private let sparseGapThresholdSeconds: TimeInterval = 30.0

    private var tripRunningKey: String { tripDefaultsPrefix + "RUNNING" }
    private var tripPausedKey: String { tripDefaultsPrefix + "PAUSED" }
    private var tripIdKey: String { tripDefaultsPrefix + "ID" }
    private var tripDistanceKey: String { tripDefaultsPrefix + "DISTANCE_M" }
    private var tripLatKey: String { tripDefaultsPrefix + "LAT" }
    private var tripLonKey: String { tripDefaultsPrefix + "LON" }
    private var tripTimestampKey: String { tripDefaultsPrefix + "TIMESTAMP" }
    private var tripSpeedKey: String { tripDefaultsPrefix + "SPEED_MPS" }
    private var tripAccuracyKey: String { tripDefaultsPrefix + "ACCURACY_M" }

    private override init() {
        super.init()

        // CLLocationManager must be configured/used from the main thread.
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 0.5
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        // CLLocationManager does not guarantee a location callback every second,
        // especially when the device is stationary. The separate heartbeat below
        // is therefore used for GPS STATUS only; it never creates a fake location.

        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        restoreNativeTripState()
        if nativeTripRunning {
            ensureTripBackgroundRecoveryMonitoring()
        }
    }

    deinit {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Native trip distance persistence
    //
    // This layer intentionally does not invent distance when no CLLocation
    // callback arrives. It accumulates only accepted Core Location fixes.
    // UserDefaults is used for the small recovery state so a terminated/relaunched
    // WebView can recover the last authoritative distance immediately.
    private func restoreNativeTripState() {
        let d = UserDefaults.standard
        nativeTripRunning = d.bool(forKey: tripRunningKey)
        nativeTripPaused = d.bool(forKey: tripPausedKey)
        nativeTripId = d.string(forKey: tripIdKey) ?? ""
        nativeDistanceM = max(0, d.double(forKey: tripDistanceKey))
        nativeSmallMovementM = 0
        nativeSmallMovementStart = nil
        if d.object(forKey: tripLatKey) != nil && d.object(forKey: tripLonKey) != nil {
            let lat = d.double(forKey: tripLatKey)
            let lon = d.double(forKey: tripLonKey)
            let ts = d.double(forKey: tripTimestampKey)
            let speed = d.object(forKey: tripSpeedKey) != nil ? d.double(forKey: tripSpeedKey) : -1
            let accuracy = d.object(forKey: tripAccuracyKey) != nil ? d.double(forKey: tripAccuracyKey) : 0
            if abs(lat) <= 90, abs(lon) <= 180 {
                nativeLastLocation = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: 0,
                    horizontalAccuracy: max(0, accuracy),
                    verticalAccuracy: -1,
                    course: -1,
                    speed: speed >= 0 ? speed : -1,
                    timestamp: Date(timeIntervalSince1970: ts > 0 ? ts : Date().timeIntervalSince1970)
                )
            }
        }
    }

    private func persistNativeTripState() {
        let d = UserDefaults.standard
        d.set(nativeTripRunning, forKey: tripRunningKey)
        d.set(nativeTripPaused, forKey: tripPausedKey)
        d.set(nativeTripId, forKey: tripIdKey)
        d.set(nativeDistanceM, forKey: tripDistanceKey)
        if let last = nativeLastLocation {
            d.set(last.coordinate.latitude, forKey: tripLatKey)
            d.set(last.coordinate.longitude, forKey: tripLonKey)
            d.set(last.timestamp.timeIntervalSince1970, forKey: tripTimestampKey)
            d.set(last.speed, forKey: tripSpeedKey)
            d.set(last.horizontalAccuracy, forKey: tripAccuracyKey)
        }
        d.synchronize()
    }

    private func clearNativeTripState() {
        nativeTripRunning = false
        nativeTripPaused = false
        nativeTripId = ""
        nativeDistanceM = 0
        nativeLastLocation = nil
        nativeSmallMovementM = 0
        nativeSmallMovementStart = nil
        let d = UserDefaults.standard
        [tripRunningKey, tripPausedKey, tripIdKey, tripDistanceKey,
         tripLatKey, tripLonKey, tripTimestampKey, tripSpeedKey, tripAccuracyKey].forEach { d.removeObject(forKey: $0) }
        d.synchronize()
    }

    private func ensureTripBackgroundRecoveryMonitoring() {
        if #available(iOS 4.0, *) {
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    private func stopTripBackgroundRecoveryMonitoring() {
        if #available(iOS 4.0, *) {
            locationManager.stopMonitoringSignificantLocationChanges()
        }
    }

    public func startTripTracking(tripId: String) {
        dispatchPrecondition(condition: .onQueue(.main))

        // A different trip MUST start from zero. Never inherit an old trip's
        // distance or location anchor, even if stale UserDefaults survived.
        if nativeTripId != tripId {
            nativeDistanceM = 0
            nativeLastLocation = nil
            nativeSmallMovementM = 0
            nativeSmallMovementStart = nil
        }

        nativeTripId = tripId
        nativeTripRunning = true
        nativeTripPaused = false
        nativeDistanceM = max(0, nativeDistanceM)
        // Deliberately do not use CLLocationManager.location as the first trip
        // anchor: it can be an old/stale fix and would create a false jump.
        nativeLastLocation = nil
        nativeSmallMovementM = 0
        nativeSmallMovementStart = nil
        persistNativeTripState()
        ensureTripBackgroundRecoveryMonitoring()
        setKeepAwake(true)
        startAtLaunch()
        emitStatusHeartbeat()
    }

    public func pauseTripTracking() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard nativeTripRunning else { return }
        nativeTripPaused = true
        // Do not let fixes received while paused become the resume anchor.
        // The first valid post-resume fix will establish a fresh baseline.
        nativeLastLocation = nil
        nativeSmallMovementM = 0
        nativeSmallMovementStart = nil
        setKeepAwake(false)
        persistNativeTripState()
    }

    public func resumeTripTracking() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard nativeTripRunning else { return }
        nativeTripPaused = false
        // First valid post-resume fix is a baseline; no distance is added across pause.
        nativeLastLocation = nil
        nativeSmallMovementM = 0
        nativeSmallMovementStart = nil
        persistNativeTripState()
        ensureTripBackgroundRecoveryMonitoring()
        setKeepAwake(true)
        startAtLaunch()
    }

    public func finishTripTracking() -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(.main))
        // Freeze the authoritative native distance BEFORE clearing the trip state.
        // The WebView uses this exact snapshot to calculate the final fare.
        let finalStats: [String: Any] = [
            "tripRunning": nativeTripRunning,
            "tripPaused": nativeTripPaused,
            "tripId": nativeTripId,
            "distanceM": nativeDistanceM,
            "speedMps": nativeLastLocation?.speed ?? -1,
            "accuracyM": nativeLastLocation?.horizontalAccuracy ?? 0
        ]
        setKeepAwake(false)
        stopTripBackgroundRecoveryMonitoring()
        clearNativeTripState()
        emitStatusHeartbeat()
        return finalStats
    }

    public func nativeTripPayload() -> [String: Any] {
        [
            "tripRunning": nativeTripRunning,
            "tripPaused": nativeTripPaused,
            "tripId": nativeTripId,
            "distanceM": nativeDistanceM
        ]
    }

    // Called directly by the native AppDelegate during app launch.
    public func startAtLaunch() {
        if Thread.isMainThread {
            startInternal()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.startInternal()
            }
        }
    }

    public func start() {
        startAtLaunch()
    }

    public func stop() {
        // Intentionally a no-op.
        //
        // GPS is an app-level service. Trip pause/finish/cancel must never
        // stop Core Location. The only normal way this engine ends is when
        // iOS terminates the application process.
        startAtLaunch()
    }

    public var isStarted: Bool {
        started
    }

    public var authorization: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    public var servicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    // Keep the iPhone display awake only while the trip flow requests it.
    // This is the native fallback for Capacitor/WKWebView Wake Lock, which is
    // not equally reliable across iOS versions and WebView lifecycle states.
    public func setKeepAwake(_ enabled: Bool) {
        let apply = { UIApplication.shared.isIdleTimerDisabled = enabled }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    public var lastLocation: CLLocation? {
        locationManager.location
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.emitStatusHeartbeat()
        }
        RunLoop.main.add(heartbeatTimer!, forMode: .common)
        emitStatusHeartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func emitStatusHeartbeat() {
        dispatchPrecondition(condition: .onQueue(.main))
        let payload = currentStatusPayload()
        NotificationCenter.default.post(
            name: TaximetLocationEngine.gpsStatusNotification,
            object: self,
            userInfo: payload
        )
    }

    // Authoritative state: an old CLLocation is not a current GPS fix.
    public func currentStatusPayload() -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(.main))
        let auth: String
        switch locationManager.authorizationStatus {
        case .authorizedAlways: auth = "AUTHORIZED_ALWAYS"
        case .authorizedWhenInUse: auth = "AUTHORIZED_WHEN_IN_USE"
        case .denied: auth = "DENIED"
        case .restricted: auth = "RESTRICTED"
        case .notDetermined: auth = "NOT_DETERMINED"
        @unknown default: auth = "UNKNOWN"
        }

        let services = CLLocationManager.locationServicesEnabled()
        let now = Date()
        let freshnessLimit: TimeInterval = 15.0

        var data: [String: Any] = [
            "started": started,
            "servicesEnabled": services,
            "authorization": auth,
            "backgroundUpdates": true,
            "pausesAutomatically": false,
            "heartbeatAt": now.timeIntervalSince1970 * 1000.0
        ]

        if let location = locationManager.location, location.horizontalAccuracy >= 0 {
            let age = max(0.0, now.timeIntervalSince(location.timestamp))
            let fresh = age <= freshnessLimit && services &&
                (auth == "AUTHORIZED_ALWAYS" || auth == "AUTHORIZED_WHEN_IN_USE") &&
                started
            data["hasFix"] = fresh
            data["hasLocation"] = true
            data["latitude"] = location.coordinate.latitude
            data["longitude"] = location.coordinate.longitude
            data["accuracy"] = location.horizontalAccuracy
            data["speed"] = location.speed
            data["course"] = location.course
            data["timestamp"] = location.timestamp.timeIntervalSince1970 * 1000.0
            data["fixAgeMs"] = age * 1000.0
        } else {
            data["hasFix"] = false
            data["hasLocation"] = false
            data["fixAgeMs"] = NSNull()
        }
        return data
    }

    private func configureLocationManager() {
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }

        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 0.5
        locationManager.activityType = .automotiveNavigation
    }

    private func startInternal() {
        dispatchPrecondition(condition: .onQueue(.main))
        configureLocationManager()
        if heartbeatTimer == nil { startHeartbeat() }

        guard CLLocationManager.locationServicesEnabled() else {
            started = false
            locationManager.stopUpdatingLocation()
            postError(code: 2, message: "Dịch vụ định vị đang tắt")
            emitStatusHeartbeat()
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            started = false
            locationManager.stopUpdatingLocation()
            // This app's core function needs background location. Ask Core Location
            // for Always directly; iOS controls the actual system permission UI and
            // may present its authorization flow in more than one step.
            if #available(iOS 13.4, *) {
                locationManager.requestAlwaysAuthorization()
            } else {
                locationManager.requestAlwaysAuthorization()
            }
            emitStatusHeartbeat()

        case .authorizedWhenInUse:
            // If the user previously granted When In Use, immediately request the
            // upgrade to Always. We never use WebView geolocation as a fallback.
            if #available(iOS 13.4, *) {
                locationManager.requestAlwaysAuthorization()
            } else {
                locationManager.requestAlwaysAuthorization()
            }
            startUpdating()

        case .authorizedAlways:
            startUpdating()

        case .denied, .restricted:
            started = false
            locationManager.stopUpdatingLocation()
            postError(code: 1, message: "Quyền GPS bị từ chối")
            emitStatusHeartbeat()

        @unknown default:
            started = false
            locationManager.stopUpdatingLocation()
            postError(code: 2, message: "Trạng thái quyền GPS không xác định")
            emitStatusHeartbeat()
        }
    }

    private func startUpdating() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard CLLocationManager.locationServicesEnabled() else {
            started = false
            locationManager.stopUpdatingLocation()
            emitStatusHeartbeat()
            return
        }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default:
            started = false
            locationManager.stopUpdatingLocation()
            emitStatusHeartbeat()
            return
        }
        configureLocationManager()
        locationManager.startUpdatingLocation()
        started = true
        startHeartbeat()
        emitStatusHeartbeat()
    }

    private func reassert() {
        if Thread.isMainThread {
            reassertInternal()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.reassertInternal()
            }
        }
    }

    private func reassertInternal() {
        configureLocationManager()
        if !CLLocationManager.locationServicesEnabled() {
            started = false
            locationManager.stopUpdatingLocation()
            startHeartbeat()
            emitStatusHeartbeat()
            return
        }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdating()
        case .notDetermined, .denied, .restricted:
            started = false
            locationManager.stopUpdatingLocation()
            startHeartbeat()
            emitStatusHeartbeat()
        @unknown default:
            started = false
            locationManager.stopUpdatingLocation()
            startHeartbeat()
            emitStatusHeartbeat()
        }
    }

    @objc private func appDidBecomeActive() {
        if nativeTripRunning && !nativeTripPaused { setKeepAwake(true) }
        reassert()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.nativeTripRunning && !self.nativeTripPaused { self.setKeepAwake(true) }
            self.reassertInternal()
        }
    }

    @objc private func appWillResignActive() {
        // Do not stop location. Reassert the background-capable configuration.
        reassert()
    }

    @objc private func appDidEnterBackground() {
        // Do not stop location. Core Location was started natively while
        // foreground and UIBackgroundModes=location is present.
        reassert()
    }

    @objc private func appWillEnterForeground() {
        if nativeTripRunning && !nativeTripPaused { setKeepAwake(true) }
        reassert()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.nativeTripRunning && !self.nativeTripPaused { self.setKeepAwake(true) }
            self.reassertInternal()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Authorization changes made in Settings must be able to recover an
        // already-running app-level GPS engine without requiring BẮT ĐẦU.
        // Publish the new state first, then reassert the engine several times
        // because iOS may deliver the authorization callback while the app is
        // transitioning between foreground/background states.
        emitStatusHeartbeat()
        if nativeTripRunning && !nativeTripPaused && locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
        reassertInternal()
        scheduleAuthorizationRecovery()
    }

    private func scheduleAuthorizationRecovery() {
        let delays: [TimeInterval] = [0.15, 0.5, 1.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.reassertInternal()
                self.emitStatusHeartbeat()
            }
        }
    }

    // Called by the Capacitor bridge when JS polls the authoritative status.
    // If permission is already authorized but Core Location is not running,
    // recover it immediately. This is intentionally app-level and does not
    // depend on whether a taxi trip is active.
    public func recoverIfAuthorized() {
        dispatchPrecondition(condition: .onQueue(.main))
        reassertInternal()
    }

    private func emitLocation(_ location: CLLocation) {
        NotificationCenter.default.post(
            name: TaximetLocationEngine.locationUpdateNotification,
            object: self,
            userInfo: payload(for: location)
        )
        emitStatusHeartbeat()
    }

    private func processTripDistance(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= maxTripAccuracyM else {
            return
        }

        guard nativeTripRunning && !nativeTripPaused else { return }

        guard let previous = nativeLastLocation else {
            // First valid fix of a new/resumed trip: baseline only.
            nativeLastLocation = location
            nativeSmallMovementM = 0
            nativeSmallMovementStart = nil
            persistNativeTripState()
            return
        }

        let dt = location.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return }

        let delta = location.distance(from: previous)
        let derivedSpeedMps = delta / dt

        // Any long callback gap is a hard re-anchor. Never estimate distance from
        // endpoint speed and never draw a straight line across an interruption.
        // Core Location batch callbacks are processed one-by-one above, so genuine
        // movement represented by intermediate fixes is still counted.
        if dt > sparseGapThresholdSeconds {
            nativeLastLocation = location
            nativeSmallMovementM = 0
            nativeSmallMovementStart = nil
            persistNativeTripState()
            return
        }

        // Hard safety gates: never accept impossible jumps.
        guard delta < maxTripDeltaM, derivedSpeedMps <= maxTripDerivedSpeedMps else {
            // Reject the point completely. Keep the previous good baseline.
            return
        }

        // Stationary GPS drift must not slowly turn into paid distance. When both
        // fixes report near-zero speed, treat small coordinate wander as noise and
        // keep the last real movement anchor. The accuracy-aware gate is capped so
        // a poor fix cannot suppress legitimate vehicle motion indefinitely.
        let v0 = previous.speed
        let v1 = location.speed
        if v0 >= 0, v1 >= 0, v0 <= stationarySpeedMps, v1 <= stationarySpeedMps {
            let accuracyGate = max(stationaryDriftFloorM,
                                   min(stationaryDriftMaxM,
                                       (max(0, previous.horizontalAccuracy) +
                                        max(0, location.horizontalAccuracy)) * 0.75))
            if delta <= accuracyGate {
                nativeSmallMovementM = 0
                nativeSmallMovementStart = nil
                // Do not move the anchor while stationary; otherwise repeated GPS
                // drift would accumulate into a false trip distance.
                persistNativeTripState()
                return
            }
            // A large low-speed relocation is still not trustworthy enough to bill.
            // Re-anchor it instead of charging the displacement.
            nativeLastLocation = location
            nativeSmallMovementM = 0
            nativeSmallMovementStart = nil
            persistNativeTripState()
            return
        }

        if delta >= minTripDeltaM {
            // A normal segment is committed directly. Any previously buffered
            // sub-2m motion is committed with it, so creeping movement is not lost.
            nativeDistanceM += nativeSmallMovementM + delta
            nativeSmallMovementM = 0
            nativeSmallMovementStart = nil
            nativeLastLocation = location
            persistNativeTripState()
        } else {
            // Do not throw away every sub-2m fix. Accumulate it while the
            // observed motion has credible movement speed. This prevents the
            // old per-fix 2m cutoff from under-counting slow/background travel.
            if nativeSmallMovementStart == nil { nativeSmallMovementStart = previous.timestamp }
            let windowStart = nativeSmallMovementStart ?? previous.timestamp
            let windowDt = max(0.001, location.timestamp.timeIntervalSince(windowStart))
            nativeSmallMovementM += delta

            let avgSpeed = nativeSmallMovementM / windowDt
            if nativeSmallMovementM >= minTripDeltaM && avgSpeed >= minConfidentMovementSpeedMps {
                nativeDistanceM += nativeSmallMovementM
                nativeSmallMovementM = 0
                nativeSmallMovementStart = nil
            }
            nativeLastLocation = location
            persistNativeTripState()
        }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        // Core Location may deliver a batch of fixes after background execution.
        // Processing only locations.last would discard the entire path represented
        // by earlier fixes and can materially under-count a taxi trip. Process every
        // chronologically ordered fix; invalid/rejected fixes never become baseline.
        let ordered = locations.sorted { $0.timestamp < $1.timestamp }
        for location in ordered {
            processTripDistance(location)
        }

        if let last = ordered.last {
            emitLocation(last)
        } else {
            emitStatusHeartbeat()
        }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let ns = error as NSError
        postError(
            code: ns.code == 1 ? 1 : 2,
            message: error.localizedDescription
        )
        emitStatusHeartbeat()
    }

    // Request background-capable permission only from the trip flow.
    public func requestAlwaysAuthorization() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard CLLocationManager.locationServicesEnabled() else {
            emitStatusHeartbeat()
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            // The HTML launch bridge calls this method so the Always request is
            // part of the same startup flow. iOS remains authoritative over the
            // actual permission prompt and may require the user to confirm in
            // Settings depending on the current authorization state.
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways, .denied, .restricted:
            break
        @unknown default:
            break
        }
        emitStatusHeartbeat()
    }

    private func postError(code: Int, message: String) {
        NotificationCenter.default.post(
            name: TaximetLocationEngine.locationErrorNotification,
            object: self,
            userInfo: [
                "code": code,
                "message": message
            ]
        )
    }

    public func nativeTripStats() -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(.main))
        return [
            "tripRunning": nativeTripRunning,
            "tripPaused": nativeTripPaused,
            "tripId": nativeTripId,
            "distanceM": nativeDistanceM,
            "speedMps": nativeLastLocation?.speed ?? -1,
            "accuracyM": nativeLastLocation?.horizontalAccuracy ?? 0
        ]
    }

    public func payload(for location: CLLocation) -> [String: Any] {
        var data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": max(0, location.horizontalAccuracy),
            "altitude": location.altitude,
            "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000)
        ]

        data["heading"] = location.course >= 0
            ? location.course
            : NSNull()

        data["speedMps"] = location.speed >= 0
            ? location.speed
            : NSNull()
        data["speedKmh"] = location.speed >= 0 ? location.speed * 3.6 : NSNull()
        data["distanceM"] = nativeDistanceM
        data["tripRunning"] = nativeTripRunning
        data["tripPaused"] = nativeTripPaused
        data["tripId"] = nativeTripId

        return data
    }
}

// MARK: - Capacitor bridge

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "TaximetLocationPlugin"
    public let jsName = "TaximetLocation"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLastLocation", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestAlways", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setKeepAwake", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startTrip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pauseTrip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resumeTrip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finishTrip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getTripStats", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reverseAddress", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "beginShareBase64", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "appendShareBase64", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finishShareBase64", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelShareBase64", returnType: CAPPluginReturnPromise)
    ]

    private var updateObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var statusObserver: NSObjectProtocol?

    // Native iOS invoice/image sharing. The WebView creates the PNG/PDF bytes;
    // Capacitor transfers them in bounded base64 chunks and UIKit presents the
    // native share sheet. This is isolated from the GPS engine.
    private var shareBuffer = Data()
    private var shareFileName = "invoice"
    private var shareMimeType = "application/octet-stream"
    private var shareTitle = "CabCalc"
    private var shareText = "Hóa đơn CabCalc"

    public override func load() {
        super.load()

        updateObserver = NotificationCenter.default.addObserver(
            forName: TaximetLocationEngine.locationUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let data = notification.userInfo as? [String: Any] else { return }
            self.notifyListeners("locationUpdate", data: data)
        }

        errorObserver = NotificationCenter.default.addObserver(
            forName: TaximetLocationEngine.locationErrorNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let data = notification.userInfo as? [String: Any] else { return }
            self.notifyListeners("locationError", data: data)
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: TaximetLocationEngine.gpsStatusNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let data = notification.userInfo as? [String: Any] else { return }
            self.notifyListeners("gpsStatus", data: data)
        }

        // Safe even if AppDelegate has already started the engine.
        TaximetLocationEngine.shared.startAtLaunch()
    }

    deinit {
        if let updateObserver {
            NotificationCenter.default.removeObserver(updateObserver)
        }
        if let errorObserver {
            NotificationCenter.default.removeObserver(errorObserver)
        }
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.start()

            switch TaximetLocationEngine.shared.authorization {
            case .notDetermined:
                call.resolve(["status": "REQUESTING_PERMISSION"])
            case .denied, .restricted:
                // Permission denied is a normal GPS state, not a bridge failure.
                // Do NOT reject the JS promise here: startGps() treats a rejected
                // native.start() as a fatal engine error and removes its persistent
                // status/location listeners. If the user later re-enables Location
                // in Settings, those listeners would then be gone and REAL GPS UI
                // could never recover. The authoritative status() call handles the
                // denied state and later authorization recovery.
                call.resolve(["status": "DENIED"])
            default:
                call.resolve(["status": "STARTED"])
            }
        }
    }

    @objc func requestAlways(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.requestAlwaysAuthorization()
            call.resolve(["status": "REQUESTING_ALWAYS_PERMISSION"])
        }
    }

    @objc func setKeepAwake(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled") ?? false
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.setKeepAwake(enabled)
            call.resolve(["enabled": enabled])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        // Compatibility only. Never stop the app-level GPS engine.
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.stop()
            call.resolve(["status": "RUNNING"])
        }
    }

    @objc func startTrip(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let tripId = call.getString("tripId") ?? ""
            TaximetLocationEngine.shared.startTripTracking(tripId: tripId)
            call.resolve(TaximetLocationEngine.shared.nativeTripPayload())
        }
    }

    @objc func pauseTrip(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.pauseTripTracking()
            call.resolve(TaximetLocationEngine.shared.nativeTripPayload())
        }
    }

    @objc func resumeTrip(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.resumeTripTracking()
            call.resolve(TaximetLocationEngine.shared.nativeTripPayload())
        }
    }

    @objc func finishTrip(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let finalStats = TaximetLocationEngine.shared.finishTripTracking()
            call.resolve(finalStats)
        }
    }

    @objc func getTripStats(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve(TaximetLocationEngine.shared.nativeTripStats())
        }
    }

    @objc func getLastLocation(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let location = TaximetLocationEngine.shared.lastLocation {
                call.resolve(TaximetLocationEngine.shared.payload(for: location))
            } else {
                call.resolve(["available": false])
            }
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.recoverIfAuthorized()
            let payload = TaximetLocationEngine.shared.currentStatusPayload()
            call.resolve(payload)
        }
    }

    @objc func reverseAddress(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .userInitiated).async {
            let lat = call.getDouble("lat") ?? 0
            let lon = call.getDouble("lon") ?? 0
            guard abs(lat) <= 90, abs(lon) <= 180 else {
                call.resolve(["source": "OSM_OFFLINE", "display": "", "parts": [:]])
                return
            }
            // Capacitor can package web assets under `public/`, while Xcode's
            // resource lookup can expose the same file either through the resource
            // subdirectory or directly from the bundle path. Try both forms so the
            // offline geocoder does not silently fall back to coordinates when the
            // SQLite file is present in the final IPA.
            let resourceURL =
                Bundle.main.url(forResource: "osm_vietnam_full_offline", withExtension: "sqlite", subdirectory: "public")
                ?? Bundle.main.url(forResource: "osm_vietnam_full_offline", withExtension: "sqlite")
                ?? Bundle.main.bundleURL.appendingPathComponent("public/osm_vietnam_full_offline.sqlite", isDirectory: false)

            guard FileManager.default.fileExists(atPath: resourceURL.path) else {
                call.resolve(["source": "OSM_OFFLINE", "display": "", "parts": [:], "error": "LOCAL_OSM_DB_MISSING"])
                return
            }

            var db: OpaquePointer?
            let openResult = sqlite3_open_v2(resourceURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            guard openResult == SQLITE_OK, let db else {
                if db != nil { sqlite3_close(db) }
                call.resolve(["source": "OSM_OFFLINE", "display": "", "parts": [:], "error": "LOCAL_OSM_DB_OPEN_FAILED", "sqliteCode": openResult])
                return
            }
            defer { sqlite3_close(db) }

            // The offline database is a local OSM reverse-geocoder. It contains
            // address-tagged OSM objects, named roads, and named place/admin
            // anchors with RTree spatial indexes. No HTTP request is made here.
            let radiusKm = 2.0
            let dLat = radiusKm / 111.32
            let cosLat = max(0.2, cos(lat * .pi / 180.0))
            let dLon = radiusKm / (111.32 * cosLat)
            let minLat = lat - dLat, maxLat = lat + dLat
            let minLon = lon - dLon, maxLon = lon + dLon

            func distanceMeters(_ aLat: Double, _ aLon: Double) -> Double {
                let dy = (aLat - lat) * 111_320.0
                let dx = (aLon - lon) * 111_320.0 * cosLat
                return sqrt(dx * dx + dy * dy)
            }

            func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
                guard let stmt, let p = sqlite3_column_text(stmt, column) else { return "" }
                return String(cString: p)
            }

            func query(_ sql: String, binds: [Double], row: (OpaquePointer) -> Void) {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
                defer { sqlite3_finalize(stmt) }
                for (i, value) in binds.enumerated() { sqlite3_bind_double(stmt, Int32(i + 1), value) }
                while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
            }

            struct Candidate {
                let distance: Double
                let lat: Double
                let lon: Double
                let house: String
                let road: String
                let ward: String
                let district: String
                let city: String
                let province: String
                let postcode: String
                let country: String
                let name: String
            }

            var bestAddress: Candidate?
            let addressSQL = """
                SELECT a.lat,a.lon,a.house_number,a.road,a.ward,a.district,a.city,
                       a.province,a.postcode,a.country,a.name
                FROM address_rtree r
                JOIN addresses a ON a.id=r.id
                WHERE r.minLat<=? AND r.maxLat>=? AND r.minLon<=? AND r.maxLon>=?
                ORDER BY ((a.lat-?)*(a.lat-?)+((a.lon-?)*(a.lon-?))*?)
                LIMIT 80
                """
            query(addressSQL, binds: [maxLat,minLat,maxLon,minLon,lat,lat,lon,lon,cosLat*cosLat]) { stmt in
                let aLat = sqlite3_column_double(stmt, 0)
                let aLon = sqlite3_column_double(stmt, 1)
                let d = distanceMeters(aLat, aLon)
                let c = Candidate(
                    distance: d, lat: aLat, lon: aLon,
                    house: text(stmt,2), road: text(stmt,3), ward: text(stmt,4),
                    district: text(stmt,5), city: text(stmt,6), province: text(stmt,7),
                    postcode: text(stmt,8), country: text(stmt,9), name: text(stmt,10)
                )
                if bestAddress == nil || d < bestAddress!.distance { bestAddress = c }
            }

            var bestRoadName = ""
            var bestRoadDistance = Double.greatestFiniteMagnitude
            let roadSQL = """
                SELECT r.lat,r.lon,r.name,r.ref
                FROM road_rtree x JOIN roads r ON r.id=x.id
                WHERE x.minLat<=? AND x.maxLat>=? AND x.minLon<=? AND x.maxLon>=?
                ORDER BY ((r.lat-?)*(r.lat-?)+((r.lon-?)*(r.lon-?))*?)
                LIMIT 80
                """
            query(roadSQL, binds: [maxLat,minLat,maxLon,minLon,lat,lat,lon,lon,cosLat*cosLat]) { stmt in
                let d = distanceMeters(sqlite3_column_double(stmt,0), sqlite3_column_double(stmt,1))
                if d < bestRoadDistance {
                    bestRoadDistance = d
                    bestRoadName = text(stmt,2)
                }
            }

            // Address-tagged objects are authoritative for house/street/admin
            // fields. If a point has incomplete admin tags, fill only the missing
            // levels from the nearest OSM place anchors. This keeps the user's
            // existing display customization unchanged while improving offline
            // coverage for road-only locations.
            var ward = bestAddress?.ward ?? ""
            var district = bestAddress?.district ?? ""
            var city = bestAddress?.city ?? ""
            var province = bestAddress?.province ?? ""
            var postcode = bestAddress?.postcode ?? ""
            var country = bestAddress?.country ?? ""

            func nearestPlace(types: [String], maxMeters: Double) -> String {
                if types.isEmpty { return "" }
                let quoted = types.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
                var result = ""
                var best = maxMeters
                let sql = """
                    SELECT p.lat,p.lon,p.name,p.type
                    FROM place_rtree x JOIN places p ON p.id=x.id
                    WHERE x.minLat<=? AND x.maxLat>=? AND x.minLon<=? AND x.maxLon>=?
                      AND p.type IN (\(quoted))
                    ORDER BY ((p.lat-?)*(p.lat-?)+((p.lon-?)*(p.lon-?))*?)
                    LIMIT 40
                    """
                query(sql, binds: [maxLat,minLat,maxLon,minLon,lat,lat,lon,lon,cosLat*cosLat]) { stmt in
                    let d = distanceMeters(sqlite3_column_double(stmt,0), sqlite3_column_double(stmt,1))
                    if d < best { best = d; result = text(stmt,2) }
                }
                return result
            }

            if ward.isEmpty { ward = nearestPlace(types: ["neighbourhood","suburb","quarter","commune","subdistrict"], maxMeters: 8_000) }
            if district.isEmpty { district = nearestPlace(types: ["city_district","district","county"], maxMeters: 20_000) }
            if city.isEmpty { city = nearestPlace(types: ["city","town","municipality"], maxMeters: 50_000) }
            if province.isEmpty { province = nearestPlace(types: ["province","state","region"], maxMeters: 120_000) }
            if country.isEmpty { country = "Việt Nam" }

            let road = !(bestAddress?.road ?? "").isEmpty ? bestAddress!.road : bestRoadName
            let house = bestAddress?.house ?? ""
            let parts: [String: Any] = [
                "houseNumber": house,
                "road": road,
                "ward": ward,
                "district": district,
                "city": city,
                "province": province,
                "postcode": postcode,
                "country": country
            ]

            // Only return a point-address house number when it is genuinely close.
            // A distant address point must not create a false street number.
            let usableHouse = (bestAddress != nil && bestAddress!.distance <= 120.0) ? house : ""
            var finalParts = parts
            finalParts["houseNumber"] = usableHouse

            let display = [usableHouse,road,ward,district,city,province,postcode,country]
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { out,value in if !out.contains(value) { out.append(value) } }
                .joined(separator: ", ")

            call.resolve([
                "source": "OSM_OFFLINE",
                "display": display,
                "parts": finalParts,
                "distanceToAddressM": bestAddress?.distance ?? NSNull(),
                "distanceToRoadM": bestRoadDistance.isFinite ? bestRoadDistance : NSNull()
            ])
        }
    }

    @objc func beginShareBase64(_ call: CAPPluginCall) {
        shareBuffer.removeAll(keepingCapacity: true)
        shareFileName = call.getString("fileName") ?? "invoice"
        shareMimeType = call.getString("mime") ?? "application/octet-stream"
        shareTitle = call.getString("title") ?? "CabCalc"
        shareText = call.getString("text") ?? "Hóa đơn CabCalc"
        call.resolve(["status": "READY"])
    }

    @objc func appendShareBase64(_ call: CAPPluginCall) {
        guard let chunk = call.getString("data"), !chunk.isEmpty else {
            call.reject("Thiếu dữ liệu chia sẻ")
            return
        }
        guard let data = Data(base64Encoded: chunk) else {
            call.reject("Dữ liệu base64 không hợp lệ")
            return
        }
        shareBuffer.append(data)
        call.resolve(["bytes": shareBuffer.count])
    }

    @objc func cancelShareBase64(_ call: CAPPluginCall) {
        shareBuffer.removeAll(keepingCapacity: false)
        shareFileName = "invoice"
        shareMimeType = "application/octet-stream"
        shareTitle = "CabCalc"
        shareText = "Hóa đơn CabCalc"
        call.resolve(["status": "CANCELLED"])
    }

    @objc func finishShareBase64(_ call: CAPPluginCall) {
        let data = shareBuffer
        let fileName = shareFileName
        let mimeType = shareMimeType
        let title = shareTitle
        let text = shareText
        shareBuffer.removeAll(keepingCapacity: false)

        guard !data.isEmpty else {
            call.reject("Không có dữ liệu hóa đơn để chia sẻ")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let ext = (fileName as NSString).pathExtension
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext.isEmpty ? "dat" : ext)
                try data.write(to: url, options: .atomic)
                self.presentShareSheet(url: url, fileName: fileName, mimeType: mimeType, title: title, text: text) { completed in
                    try? FileManager.default.removeItem(at: url)
                    call.resolve(["status": completed ? "COMPLETED" : "CANCELLED"])
                }
            } catch {
                call.reject("Không thể tạo file chia sẻ: \(error.localizedDescription)")
            }
        }
    }

    private func presentShareSheet(url: URL, fileName: String, mimeType: String, title: String, text: String, completion: @escaping (Bool) -> Void) {
        let presenter = bridge?.viewController ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.rootViewController
        guard let presenter else { completion(false); return }

        var top = presenter
        while let presented = top.presentedViewController { top = presented }

        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.setValue(title, forKey: "subject")
        activity.completionWithItemsHandler = { _, completed, _, _ in completion(completed) }

        if let popover = activity.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(activity, animated: true)
    }
}
