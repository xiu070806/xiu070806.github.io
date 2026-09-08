import Foundation
import UIKit
import Capacitor
import CoreLocation

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()
    private let queue = DispatchQueue(label: "com.taximet.pro.location", qos: .userInitiated)

    private var started = false
    private var tripActive = false

    private struct StoredLocation: Codable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double
        let altitude: Double
        let course: Double
        let speedMps: Double
        let timestamp: Double
    }

    private let fileName = "taximet-background-locations.json"

    override public func load() {
        super.load()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appEnteredBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appEnteredBackground() {
        guard tripActive else { return }
        // Reassert the native background configuration when the app enters
        // background. No JavaScript/WebView timer is required.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        if !started {
            locationManager.startUpdatingLocation()
            started = true
        }
    }

    @objc private func appBecameActive() {
        guard tripActive else { return }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        if !started {
            locationManager.startUpdatingLocation()
            started = true
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.tripActive = true

            let status = CLLocationManager.authorizationStatus()
            if status == .notDetermined {
                self.locationManager.requestAlwaysAuthorization()
            }

            self.locationManager.allowsBackgroundLocationUpdates = true
            self.locationManager.pausesLocationUpdatesAutomatically = false
            self.locationManager.activityType = .automotiveNavigation
            self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            self.locationManager.distanceFilter = kCLDistanceFilterNone

            self.locationManager.startUpdatingLocation()
            self.started = true

            call.resolve(["status": "STARTED"])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.tripActive = false
            self.locationManager.stopUpdatingLocation()
            self.started = false
            call.resolve(["status": "STOPPED"])
        }
    }

    @objc func setTripActive(_ call: CAPPluginCall) {
        let active = call.getBool("active") ?? false
        DispatchQueue.main.async {
            self.tripActive = active

            if active {
                self.locationManager.allowsBackgroundLocationUpdates = true
                self.locationManager.pausesLocationUpdatesAutomatically = false
                self.locationManager.activityType = .automotiveNavigation
                self.locationManager.startUpdatingLocation()
                self.started = true
            }

            call.resolve(["active": active])
        }
    }

    @objc func getLastLocation(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let loc = self.locationManager.location else {
                call.resolve(["available": false])
                return
            }
            call.resolve(self.payload(loc))
        }
    }

    @objc func getBackgroundLocations(_ call: CAPPluginCall) {
        queue.async {
            let values = self.loadStored()
            call.resolve([
                "count": values.count,
                "locations": values.map { self.payload($0) }
            ])
        }
    }

    @objc func clearBackgroundLocations(_ call: CAPPluginCall) {
        queue.async {
            self.saveStored([])
            call.resolve(["status": "CLEARED"])
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let auth = CLLocationManager.authorizationStatus()
            call.resolve([
                "started": self.started,
                "tripActive": self.tripActive,
                "authorization": auth.rawValue,
                "background": UIApplication.shared.applicationState != .active
            ])
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard tripActive else { return }

        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= 100 else { continue }

            // Native persistence happens for every valid update while the trip
            // is active. It does not depend on WebView state.
            queue.async {
                self.append(location)
            }

            notifyListeners("locationUpdate", data: payloadForLocation(location))
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if CLLocationManager.authorizationStatus() == .authorizedAlways && tripActive {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.startUpdatingLocation()
            started = true
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notifyListeners("locationError", data: [
            "message": error.localizedDescription
        ])
    }

    private func storageURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func loadStored() -> [StoredLocation] {
        guard let data = try? Data(contentsOf: storageURL()) else {
            return []
        }
        return (try? JSONDecoder().decode([StoredLocation].self, from: data)) ?? []
    }

    private func saveStored(_ values: [StoredLocation]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: storageURL(), options: [.atomic])
    }

    private func append(_ location: CLLocation) {
        var values = loadStored()

        let point = StoredLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.altitude,
            course: location.course >= 0 ? location.course : -1,
            speedMps: location.speed >= 0 ? location.speed : -1,
            timestamp: location.timestamp.timeIntervalSince1970 * 1000
        )

        if let last = values.last {
            if point.timestamp <= last.timestamp {
                return
            }
            if abs(point.latitude - last.latitude) < 0.0000001 &&
               abs(point.longitude - last.longitude) < 0.0000001 {
                return
            }
        }

        values.append(point)

        // Approx. 8 hours at one update/sec.
        if values.count > 30000 {
            values.removeFirst(values.count - 30000)
        }

        saveStored(values)
    }

    private func payload(_ p: StoredLocation) -> [String: Any] {
        [
            "coords": [
                "latitude": p.latitude,
                "longitude": p.longitude,
                "accuracy": p.accuracy,
                "altitude": p.altitude,
                "heading": p.course,
                "speed": p.speedMps
            ],
            "timestamp": p.timestamp
        ]
    }

    private func payload(_ location: CLLocation) -> [String: Any] {
        payload(StoredLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.altitude,
            course: location.course >= 0 ? location.course : -1,
            speedMps: location.speed >= 0 ? location.speed : -1,
            timestamp: location.timestamp.timeIntervalSince1970 * 1000
        ))
    }
}

private func payloadForLocation(_ location: CLLocation) -> [String: Any] {
    [
        "coords": [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.altitude,
            "heading": location.course >= 0 ? location.course : -1,
            "speed": location.speed >= 0 ? location.speed : -1
        ],
        "timestamp": location.timestamp.timeIntervalSince1970 * 1000
    ]
}
