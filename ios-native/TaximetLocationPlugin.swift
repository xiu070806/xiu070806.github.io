import Foundation
import UIKit
import Capacitor
import CoreLocation

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

    private override init() {
        super.init()

        // CLLocationManager must be configured/used from the main thread.
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0
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
    }

    deinit {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        NotificationCenter.default.removeObserver(self)
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
        locationManager.distanceFilter = 1.0
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
            // iOS shows the permission prompt; the user must explicitly allow it.
            // Do not request Always permission automatically at launch.
            locationManager.requestWhenInUseAuthorization()
            emitStatusHeartbeat()

        case .authorizedWhenInUse, .authorizedAlways:
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
        reassert()
        DispatchQueue.main.async { [weak self] in self?.reassertInternal() }
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
        reassert()
        DispatchQueue.main.async { [weak self] in self?.reassertInternal() }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Permission/service changes from iOS Settings are authoritative.
        // Push the new state immediately so JS cannot retain the old GPS UI.
        emitStatusHeartbeat()
        if !CLLocationManager.locationServicesEnabled() {
            started = false
            manager.stopUpdatingLocation()
            startHeartbeat()
            postError(code: 2, message: "Dịch vụ định vị đang tắt")
            emitStatusHeartbeat()
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdating()
        case .denied, .restricted:
            started = false
            manager.stopUpdatingLocation()
            startHeartbeat()
            postError(code: 1, message: "Quyền GPS bị từ chối")
            emitStatusHeartbeat()
        case .notDetermined:
            started = false
            manager.stopUpdatingLocation()
            startHeartbeat()
            emitStatusHeartbeat()
        @unknown default:
            started = false
            manager.stopUpdatingLocation()
            startHeartbeat()
            emitStatusHeartbeat()
        }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        guard location.horizontalAccuracy >= 0 else { return }

        NotificationCenter.default.post(
            name: TaximetLocationEngine.locationUpdateNotification,
            object: self,
            userInfo: payload(for: location)
        )
        emitStatusHeartbeat()
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
        guard locationManager.authorizationStatus == .authorizedWhenInUse else {
            emitStatusHeartbeat()
            return
        }
        if #available(iOS 13.4, *) {
            locationManager.requestAlwaysAuthorization()
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
        CAPPluginMethod(name: "requestAlways", returnType: CAPPluginReturnPromise)
    ]

    private var updateObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var statusObserver: NSObjectProtocol?

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
                call.reject("Location permission denied")
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

    @objc func stop(_ call: CAPPluginCall) {
        // Compatibility only. Never stop the app-level GPS engine.
        DispatchQueue.main.async {
            TaximetLocationEngine.shared.stop()
            call.resolve(["status": "RUNNING"])
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
            call.resolve(TaximetLocationEngine.shared.currentStatusPayload())
        }
    }
}
