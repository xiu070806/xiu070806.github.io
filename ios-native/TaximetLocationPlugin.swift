import Foundation
import CoreLocation
import Capacitor

public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let tripActiveKey = "TaximetLocation.tripActive"
    private let locationsFileName = "taximet-background-locations.json"
    private let persistenceQueue = DispatchQueue(label: "com.taximet.pro.location.persistence")

    private var tripActive = false
    private var latestLocation: CLLocation?

    private var locationsURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent(locationsFileName)
    }

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
        setTripState(true)
        startLocationServices()
        call.resolve(["ok": true])
    }

    @objc public func stop(_ call: CAPPluginCall) {
        setTripState(false)
        locationManager.stopUpdatingLocation()
        call.resolve(["ok": true])
    }

    @objc public func setTripActive(_ call: CAPPluginCall) {
        let active = call.getBool("active", false)
        setTripState(active)

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
        call.resolve([
            "ok": true,
            "locations": readStoredLocations()
        ])
    }

    @objc public func clearBackgroundLocations(_ call: CAPPluginCall) {
        persistenceQueue.sync {
            try? FileManager.default.removeItem(at: locationsURL)
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

    private func setTripState(_ active: Bool) {
        tripActive = active
        defaults.set(active, forKey: tripActiveKey)
    }

    private var isAuthorized: Bool {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = locationManager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
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
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            configureAndStartUpdates()
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
            switch manager.authorizationStatus {
            case .authorizedAlways:
                configureAndStartUpdates()
            case .authorizedWhenInUse:
                manager.requestAlwaysAuthorization()
            default:
                break
            }
        } else {
            if CLLocationManager.authorizationStatus() == .authorizedAlways {
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
        return [
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

        persistenceQueue.async { [weak self] in
            guard let self else { return }

            var items = self.readStoredLocations()
            items.append(item)

            if items.count > 30000 {
                items.removeFirst(items.count - 30000)
            }

            do {
                let directory = self.locationsURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )

                let data = try JSONSerialization.data(
                    withJSONObject: items,
                    options: []
                )
                try data.write(to: self.locationsURL, options: .atomic)
            } catch {
                // GPS delivery must continue even if persistence temporarily fails.
            }
        }
    }

    private func readStoredLocations() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: locationsURL) else {
            return []
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let items = object as? [[String: Any]] else {
            return []
        }

        return items
    }
}
