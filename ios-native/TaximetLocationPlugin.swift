import Foundation
import UIKit
import Capacitor
import CoreLocation

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var startCall: CAPPluginCall?
    private var started = false
    private var permissionRequestInFlight = false

    public override func load() {
        super.load()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }

        // GPS engine is independent from the taxi-trip state.
        // If permission was already granted, start immediately when the
        // Capacitor plugin is loaded. The JavaScript layer also calls start()
        // on first launch so iOS can present the permission prompt when needed.
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

        DispatchQueue.main.async {
            self.autoStartIfAuthorized()
        }
    }

    @objc private func appDidBecomeActive() {
        autoStartIfAuthorized()
    }

    @objc private func appWillResignActive() {
        // Reassert continuous native location when leaving the foreground.
        reassertBackgroundLocation()
    }

    @objc private func appDidEnterBackground() {
        // Keep CLLocationManager actively updating on Home/lock screen.
        reassertBackgroundLocation()
    }

    @objc private func appWillEnterForeground() {
        autoStartIfAuthorized()
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Once the user upgrades from "While Using" to "Always", immediately
        // restart the continuous engine with the background capability enabled.
        autoStartIfAuthorized()
    }

    private func reassertBackgroundLocation() {
        // These properties must remain enabled every time the app transitions
        // out of the foreground.
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }
        locationManager.pausesLocationUpdatesAutomatically = false
        guard CLLocationManager.locationServicesEnabled() else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            beginUpdates()
        case .authorizedWhenInUse:
            if #available(iOS 13.4, *) {
                locationManager.requestAlwaysAuthorization()
            }
            beginUpdates()
        default:
            break
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func autoStartIfAuthorized() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            beginUpdates()
        case .authorizedWhenInUse:
            if #available(iOS 13.4, *) {
                locationManager.requestAlwaysAuthorization()
            }
            beginUpdates()
        default:
            break
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.startCall = call

            guard CLLocationManager.locationServicesEnabled() else {
                self.emitError(code: 2, message: "Dịch vụ định vị đang tắt")
                call.reject("Location services are disabled")
                return
            }

            let status = self.locationManager.authorizationStatus

            switch status {
            case .notDetermined:
                self.permissionRequestInFlight = true
                self.locationManager.requestWhenInUseAuthorization()
                call.resolve(["status": "REQUESTING_PERMISSION"])

            case .authorizedWhenInUse:
                if #available(iOS 13.4, *) {
                    self.permissionRequestInFlight = true
                    self.locationManager.requestAlwaysAuthorization()
                }
                self.beginUpdates()
                call.resolve(["status": "STARTED"])

            case .authorizedAlways:
                self.beginUpdates()
                call.resolve(["status": "STARTED"])

            case .denied, .restricted:
                self.emitError(code: 1, message: "Quyền GPS bị từ chối")
                call.reject("Location permission denied")

            @unknown default:
                self.emitError(code: 2, message: "Trạng thái quyền GPS không xác định")
                call.reject("Unknown location authorization state")
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            // IMPORTANT:
            // GPS is an app-level service, not a trip-level service.
            // The web trip engine's pause/finish/cancel paths must never be
            // able to stop Core Location. Normal continuous updates end only
            // when iOS terminates the app process.
            //
            // Keep this method for Capacitor API compatibility, but do not
            // call stopUpdatingLocation() here.
            if self.locationManager.authorizationStatus == .authorizedAlways ||
               self.locationManager.authorizationStatus == .authorizedWhenInUse {
                self.beginUpdates()
                call.resolve(["status": "RUNNING"])
            } else {
                call.resolve(["status": "NOT_AUTHORIZED"])
            }
        }
    }

    @objc func getLastLocation(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let location = self.locationManager.location {
                call.resolve(self.payload(for: location))
            } else {
                call.resolve(["available": false])
            }
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let auth: String
            switch self.locationManager.authorizationStatus {
            case .authorizedAlways: auth = "AUTHORIZED_ALWAYS"
            case .authorizedWhenInUse: auth = "AUTHORIZED_WHEN_IN_USE"
            case .denied: auth = "DENIED"
            case .restricted: auth = "RESTRICTED"
            case .notDetermined: auth = "NOT_DETERMINED"
            @unknown default: auth = "UNKNOWN"
            }
            call.resolve([
                "started": self.started,
                "servicesEnabled": CLLocationManager.locationServicesEnabled(),
                "authorization": auth
            ])
        }
    }

    private func beginUpdates() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
        }
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0
        locationManager.activityType = .automotiveNavigation
        locationManager.startUpdatingLocation()
        started = true
    }

    private func payload(for location: CLLocation) -> [String: Any] {
        var data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": max(0, location.horizontalAccuracy),
            "altitude": location.altitude,
            "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000)
        ]

        if location.horizontalAccuracy >= 0 {
            data["accuracy"] = location.horizontalAccuracy
        }
        if location.course >= 0 {
            data["heading"] = location.course
        } else {
            data["heading"] = NSNull()
        }
        if location.speed >= 0 {
            data["speedMps"] = location.speed
        } else {
            data["speedMps"] = NSNull()
        }
        return data
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        switch status {
        case .authorizedAlways:
            permissionRequestInFlight = false
            beginUpdates()
            startCall?.resolve(["status": "STARTED"])
            startCall = nil

        case .authorizedWhenInUse:
            // Ask for Always so the same GPS engine can continue in background.
            if #available(iOS 13.4, *) {
                permissionRequestInFlight = true
                manager.requestAlwaysAuthorization()
            }
            beginUpdates()
            startCall?.resolve(["status": "STARTED"])
            startCall = nil

        case .denied, .restricted:
            emitError(code: 1, message: "Quyền GPS bị từ chối")
            startCall?.reject("Location permission denied")
            startCall = nil

        default:
            break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        guard location.horizontalAccuracy >= 0 else { return }
        notifyListeners("locationUpdate", data: payload(for: location))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let ns = error as NSError
        emitError(code: ns.code == 1 ? 1 : 2, message: error.localizedDescription)
    }

    private func emitError(code: Int, message: String) {
        notifyListeners("locationError", data: [
            "code": code,
            "message": message
        ])
    }
}
