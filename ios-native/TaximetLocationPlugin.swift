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

    private let locationManager = CLLocationManager()
    private var started = false

    private override init() {
        super.init()

        // CLLocationManager must be configured/used from the main thread.
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false

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

        guard CLLocationManager.locationServicesEnabled() else {
            postError(code: 2, message: "Dịch vụ định vị đang tắt")
            return
        }

        configureLocationManager()

        switch locationManager.authorizationStatus {
        case .notDetermined:
            // iOS requires When-In-Use authorization before Always can be
            // requested. The authorization delegate will continue the engine.
            locationManager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse:
            if #available(iOS 13.4, *) {
                locationManager.requestAlwaysAuthorization()
            }
            startUpdating()

        case .authorizedAlways:
            startUpdating()

        case .denied, .restricted:
            postError(code: 1, message: "Quyền GPS bị từ chối")

        @unknown default:
            postError(code: 2, message: "Trạng thái quyền GPS không xác định")
        }
    }

    private func startUpdating() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard CLLocationManager.locationServicesEnabled() else { return }

        configureLocationManager()
        locationManager.startUpdatingLocation()
        started = true
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
        guard CLLocationManager.locationServicesEnabled() else { return }

        configureLocationManager()

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            startUpdating()

        case .authorizedWhenInUse:
            if #available(iOS 13.4, *) {
                locationManager.requestAlwaysAuthorization()
            }
            startUpdating()

        default:
            break
        }
    }

    @objc private func appDidBecomeActive() {
        reassert()
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
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        dispatchPrecondition(condition: .onQueue(.main))

        switch manager.authorizationStatus {
        case .authorizedAlways:
            startUpdating()

        case .authorizedWhenInUse:
            if #available(iOS 13.4, *) {
                manager.requestAlwaysAuthorization()
            }
            startUpdating()

        case .denied, .restricted:
            postError(code: 1, message: "Quyền GPS bị từ chối")

        default:
            break
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
public class TaximetLocationPlugin: CAPPlugin {

    private var updateObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?

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
            let engine = TaximetLocationEngine.shared
            let auth: String

            switch engine.authorization {
            case .authorizedAlways: auth = "AUTHORIZED_ALWAYS"
            case .authorizedWhenInUse: auth = "AUTHORIZED_WHEN_IN_USE"
            case .denied: auth = "DENIED"
            case .restricted: auth = "RESTRICTED"
            case .notDetermined: auth = "NOT_DETERMINED"
            @unknown default: auth = "UNKNOWN"
            }

            call.resolve([
                "started": engine.isStarted,
                "servicesEnabled": engine.servicesEnabled,
                "authorization": auth
            ])
        }
    }
}
