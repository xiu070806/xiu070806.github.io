import Foundation
import UIKit
import Capacitor
import CoreLocation

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()
    private let queue = DispatchQueue(label: "com.taximet.pro.location", qos: .userInitiated)
    private let defaults = UserDefaults.standard

    private let tripActiveKey = "TaximetLocation.tripActive"
    private let fileName = "taximet-background-locations.json"

    private var started = false
    private var tripActive = false

    private var backgroundActivitySession: AnyObject?

    @available(iOS 17.0, *)
    private func startBackgroundActivitySessionIfNeeded() {
        if backgroundActivitySession == nil {
            let session = CLBackgroundActivitySession()
            // Instantiating CLBackgroundActivitySession starts the session.
            // There is no session.start() API.
            backgroundActivitySession = session
        }
    }

    private func invalidateBackgroundActivitySession() {
        if #available(iOS 17.0, *) {
            (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
            backgroundActivitySession = nil
        }
    }

    private struct StoredLocation: Codable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double
        let altitude: Double
        let course: Double
        let speedMps: Double
        let timestamp: Double
    }

    override public func load() {
        super.load()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true

        tripActive = defaults.bool(forKey: tripActiveKey)

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

        // If iOS relaunches the process because of a location event, restore
        // the native service immediately. The JS/WebView is not required.
        if tripActive {
            DispatchQueue.main.async {
                self.startNativeServicesIfAuthorized()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appEnteredBackground() {
        guard tripActive else { return }
        startNativeServicesIfAuthorized()
    }

    @objc private func appBecameActive() {
        guard tripActive else { return }
        startNativeServicesIfAuthorized()
    }

    private func startNativeServicesIfAuthorized() {
        DispatchQueue.main.async {
            let status = CLLocationManager.authorizationStatus()

            if status == .notDetermined {
                // Must be requested while foregrounded. The authorization
                // callback below starts services after the user's choice.
                if UIApplication.shared.applicationState == .active {
                    self.locationManager.requestAlwaysAuthorization()
                }
                return
            }

            if status == .authorizedAlways {
                self.configureAndStartServices()
            } else if status == .authorizedWhenInUse {
                // Ask for Always while the app is visible. This is important
                // for a trip that must continue after the screen is locked.
                if UIApplication.shared.applicationState == .active {
                    self.locationManager.requestAlwaysAuthorization()
                }
            }
        }
    }

    private func configureAndStartServices() {
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.activityType = .automotiveNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone

        if #available(iOS 17.0, *) {
            startBackgroundActivitySessionIfNeeded()
        }

        locationManager.startUpdatingLocation()
        locationManager.startMonitoringSignificantLocationChanges()
        started = true
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.tripActive = true
            self.defaults.set(true, forKey: self.tripActiveKey)
            self.defaults.synchronize()

            let status = CLLocationManager.authorizationStatus()
            if status == .notDetermined {
                self.locationManager.requestAlwaysAuthorization()
            } else if status == .authorizedWhenInUse {
                self.locationManager.requestAlwaysAuthorization()
            } else if status == .authorizedAlways {
                self.configureAndStartServices()
            }

            call.resolve(["status": "STARTED"])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.tripActive = false
            self.defaults.set(false, forKey: self.tripActiveKey)
            self.defaults.synchronize()
            self.locationManager.stopUpdatingLocation()
            self.locationManager.stopMonitoringSignificantLocationChanges()
            self.invalidateBackgroundActivitySession()
            self.started = false
            call.resolve(["status": "STOPPED"])
        }
    }

    @objc func setTripActive(_ call: CAPPluginCall) {
        let active = call.getBool("active") ?? false
        DispatchQueue.main.async {
            self.tripActive = active
            self.defaults.set(active, forKey: self.tripActiveKey)
            self.defaults.synchronize()

            if active {
                self.startNativeServicesIfAuthorized()
            } else {
                self.locationManager.stopUpdatingLocation()
                self.locationManager.stopMonitoringSignificantLocationChanges()
                self.invalidateBackgroundActivitySession()
                self.started = false
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
                "background": UIApplication.shared.applicationState != .active,
                "storedCount": self.loadStored().count
            ])
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard tripActive else { return }

        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= 100 else { continue }

            queue.async {
                self.append(location)
            }

            notifyListeners("locationUpdate", data: payloadForLocation(location))
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = CLLocationManager.authorizationStatus()

        if status == .authorizedWhenInUse && tripActive && UIApplication.shared.applicationState == .active {
            manager.requestAlwaysAuthorization()
        }

        if status == .authorizedAlways && tripActive {
            configureAndStartServices()
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
            if point.timestamp <= last.timestamp { return }
            if abs(point.latitude - last.latitude) < 0.0000001 &&
               abs(point.longitude - last.longitude) < 0.0000001 {
                return
            }
        }

        values.append(point)

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
