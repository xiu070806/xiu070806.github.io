import Foundation
import CoreLocation
import Capacitor

public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let tripActiveKey = "TaximetLocation.tripActive"
    private let locationsKey = "TaximetLocation.backgroundLocations"
    private let queue = DispatchQueue(label: "com.taximet.pro.location.persistence")

    private var tripActive = false
    private var latestLocation: CLLocation?

    public override func load() {
        super.load()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }

        tripActive = defaults.bool(forKey: tripActiveKey)

        if tripActive {
            startLocationServicesIfAuthorized()
        }
    }

    @objc public func start(_ call: CAPPluginCall) {
        tripActive = true
        defaults.set(true, forKey: tripActiveKey)
        defaults.synchronize()

        startLocationServices()
        call.resolve(["ok": true])
    }

    @objc public func stop(_ call: CAPPluginCall) {
        tripActive = false
        defaults.set(false, forKey: tripActiveKey)
        defaults.synchronize()

        locationManager.stopUpdatingLocation()
        call.resolve(["ok": true])
    }

    @objc public func setTripActive(_ call: CAPPluginCall) {
        let active = call.getBool("active", false)
        tripActive = active
        defaults.set(active, forKey: tripActiveKey)
        defaults.synchronize()

        if active {
            startLocationServices()
        } else {
            locationManager.stopUpdatingLocation()
        }

        call.resolve(["ok": true, "active": active])
    }

    @objc public func getLastLocation(_ call: CAPPluginCall) {
        guard let location = latestLocation else {
            call.resolve(["ok": false])
            return
        }

        call.resolve(locationDictionary(location))
    }

    @objc public func getBackgroundLocations(_ call: CAPPluginCall) {
        let result = readStoredLocations()
        call.resolve([
            "ok": true,
            "locations": result
        ])
    }

    @objc public func clearBackgroundLocations(_ call: CAPPluginCall) {
        queue.sync {
            defaults.removeObject(forKey: locationsKey)
            defaults.synchronize()
        }
        call.resolve(["ok": true])
    }

    @objc public func status(_ call: CAPPluginCall) {
        call.resolve([
            "ok": true,
            "authorized": isAuthorized,
            "authorizationStatus": authorizationStatusValue,
            "tripActive": tripActive,
            "storedCount": readStoredLocations().count
        ])
    }

    private var isAuthorized: Bool {
        if #available(iOS 14.0, *) {
            let status = locationManager.authorizationStatus
            return status == .authorizedAlways || status == .authorizedWhenInUse
        }
        let status = CLLocationManager.authorizationStatus()
        return status == .authorizedAlways || status == .authorizedWhenInUse
    }

    private var authorizationStatusValue: Int {
        if #available(iOS 14.0, *) {
            return locationManager.authorizationStatus.rawValue
        }
        return CLLocationManager.authorizationStatus().rawValue
    }

    private func startLocationServices() {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = locationManager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        switch status {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            configureAndStartUpdates()
        case .authorizedWhenInUse:
            // Ask for Always so the trip can continue while the screen is locked
            // or another app is in the foreground.
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    private func startLocationServicesIfAuthorized() {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = locationManager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        if status == .authorizedAlways || status == .authorizedWhenInUse {
            configureAndStartUpdates()
        }
    }

    private func configureAndStartUpdates() {
        if #available(iOS 9.0, *) {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.startUpdatingLocation()
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard tripActive else { return }

        for location in locations {
            guard location.horizontalAccuracy >= 0 else { continue }
            latestLocation = location
            persistLocation(location)

            notifyListeners(
                "location",
                data: locationDictionary(location)
            )
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard tripActive else { return }

        if #available(iOS 14.0, *) {
            if manager.authorizationStatus == .authorizedAlways {
                configureAndStartUpdates()
            } else if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
        } else {
            let status = CLLocationManager.authorizationStatus()
            if status == .authorizedAlways {
                configureAndStartUpdates()
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notifyListeners(
            "locationError",
            data: ["message": error.localizedDescription]
        )
    }

    private func locationDictionary(_ location: CLLocation) -> [String: Any] {
        [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.altitude,
            "speed": location.speed >= 0 ? location.speed : 0,
            "course": location.course >= 0 ? location.course : 0,
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]
    }

    private func persistLocation(_ location: CLLocation) {
        let item = locationDictionary(location)

        queue.async { [weak self] in
            guard let self else { return }

            var items = self.readStoredLocations()
            items.append(item)

            // Keep enough points for long taxi trips without allowing
            // UserDefaults to grow without bounds.
            if items.count > 30000 {
                items.removeFirst(items.count - 30000)
            }

            self.defaults.set(items, forKey: self.locationsKey)
            self.defaults.synchronize()
        }
    }

    private func readStoredLocations() -> [[String: Any]] {
        if let items = defaults.array(forKey: locationsKey) as? [[String: Any]] {
            return items
        }
        return []
    }
}
