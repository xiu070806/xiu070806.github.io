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

    // iOS 17+ background activity session. Kept alongside CLLocationManager so the
    // proven v16 GPS delivery path remains unchanged.
    @available(iOS 17.0, *)
    private var backgroundActivitySession: CLBackgroundActivitySession?

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

        // iOS 17+: keep an explicit Core Location background activity session
        // alive while the app process is alive. This is additive to the v16
        // CLLocationManager path; it does not replace the existing GPS bridge.
        if #available(iOS 17.0, *) {
            prepareBackgroundActivitySessionIfAuthorized()
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

        DispatchQueue.main.async {
            self.autoStartIfAuthorized()
        }
    }

    @objc private func appDidBecomeActive() {
        autoStartIfAuthorized()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func autoStartIfAuthorized() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            if #available(iOS 17.0, *) { prepareBackgroundActivitySession() }
            if #available(iOS 18.0, *) { prepareServiceSession() }
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
            // Kept for native API compatibility. The web trip engine must not
            // call this method when a trip pauses/finishes: GPS is a persistent
            // app-level service and remains active until the app process ends.
            self.locationManager.stopUpdatingLocation()
            if #available(iOS 17.0, *) {
                self.backgroundActivitySession?.invalidate()
                self.backgroundActivitySession = nil
            }
            self.started = false
            call.resolve(["status": "STOPPED"])
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
            var result: [String: Any] = [
                "started": self.started,
                "servicesEnabled": CLLocationManager.locationServicesEnabled(),
                "authorization": auth
            ]
            if #available(iOS 17.0, *) {
                result["backgroundActivitySession"] = (self.backgroundActivitySession != nil)
            } else {
                result["backgroundActivitySession"] = false
            }
            call.resolve(result)
        }
    }

    @available(iOS 17.0, *)
    private func prepareBackgroundActivitySessionIfAuthorized() {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        prepareBackgroundActivitySession()
    }

    @available(iOS 17.0, *)
    private func prepareBackgroundActivitySession() {
        if backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
        }
    }
    }

    private func beginUpdates() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        if #available(iOS 17.0, *) {
            prepareBackgroundActivitySessionIfAuthorized()
        }
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
        }
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0
        locationManager.activityType = .automotiveNavigation
        locationManager.startUpdatingLocation()
        if #available(iOS 9.0, *) {
            locationManager.requestLocation()
        }
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
            if #available(iOS 17.0, *) { prepareBackgroundActivitySessionIfAuthorized() }
            if #available(iOS 18.0, *) { prepareServiceSessionIfAuthorized() }
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
