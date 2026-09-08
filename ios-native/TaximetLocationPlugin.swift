import Foundation
import Capacitor
import CoreLocation

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var startCall: CAPPluginCall?
    private var started = false
    private var permissionRequested = false

    public override func load() {
        super.load()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1.0
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        print("[TAXIMET][GPS] CLLocationManager loaded")
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
            print("[TAXIMET][GPS] start authorization=\(status.rawValue)")

            switch status {
            case .notDetermined:
                self.permissionRequested = true
                self.locationManager.requestWhenInUseAuthorization()
                call.resolve(["status": "REQUESTING_PERMISSION"])

            case .authorizedWhenInUse:
                // iOS may show the Always prompt only after When-In-Use has
                // been granted. Start immediately so foreground GPS works.
                self.beginUpdates()
                if #available(iOS 13.4, *) {
                    self.permissionRequested = true
                    self.locationManager.requestAlwaysAuthorization()
                }
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
            self.locationManager.stopUpdatingLocation()
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
            call.resolve([
                "started": self.started,
                "servicesEnabled": CLLocationManager.locationServicesEnabled(),
                "authorization": auth
            ])
        }
    }

    private func beginUpdates() {
        guard CLLocationManager.locationServicesEnabled() else {
            emitError(code: 2, message: "Dịch vụ định vị đang tắt")
            return
        }
        started = true
        print("[TAXIMET][GPS] startUpdatingLocation")
        locationManager.startUpdatingLocation()
        // Ask Core Location for a one-shot fix too; continuous updates remain
        // the primary source.
        if #available(iOS 9.0, *) {
            locationManager.requestLocation()
        }
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
        case .authorizedAlways, .authorizedWhenInUse:
            permissionRequested = false
            if started || startCall != nil {
                beginUpdates()
                startCall = nil
            }
        case .denied, .restricted:
            permissionRequested = false
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
        started = true
        let data = payload(for: location)
        print("[TAXIMET][GPS] didUpdateLocations lat=\(location.coordinate.latitude) lon=\(location.coordinate.longitude) acc=\(location.horizontalAccuracy)")
        notifyListeners("locationUpdate", data: data)
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
