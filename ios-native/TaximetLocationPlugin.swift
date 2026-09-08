import Foundation
import UIKit
import Capacitor
import CoreLocation

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()
    private let queue = DispatchQueue(label: "com.taximet.pro.location", qos: .userInitiated)
    private let tripActiveKey = "TaximetLocation.tripActive"
    private let ackKey = "TaximetLocation.ackedSequence"
    private let sequenceKey = "TaximetLocation.nextSequence"
    private let fileName = "taximet-location-queue.jsonl"

    private var started = false
    private var tripActive = false

    // iOS 17+: keeps a declared background activity session alive while a
    // trip is active. CLLocationManager remains the actual location source.
    @available(iOS 17.0, *)
    private var backgroundActivitySession: CLBackgroundActivitySession?

    private struct StoredLocation: Codable {
        let seq: Int64
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
        configureLocationManager()

        tripActive = UserDefaults.standard.bool(forKey: tripActiveKey)

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

        if tripActive {
            DispatchQueue.main.async {
                self.startNativeServicesIfAuthorized(requestPermission: false)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureLocationManager() {
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .automotiveNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        if #available(iOS 11.0, *) {
            locationManager.showsBackgroundLocationIndicator = true
        }
    }

    private func startBackgroundSessionIfAvailable() {
        if #available(iOS 17.0, *) {
            if backgroundActivitySession == nil {
                backgroundActivitySession = CLBackgroundActivitySession()
            }
        }
    }

    private func invalidateBackgroundSession() {
        if #available(iOS 17.0, *) {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
        }
    }

    private func startNativeServicesIfAuthorized(requestPermission: Bool) {
        configureLocationManager()
        let status = CLLocationManager.authorizationStatus()

        switch status {
        case .notDetermined:
            if requestPermission {
                locationManager.requestAlwaysAuthorization()
            }
        case .authorizedWhenInUse:
            if requestPermission {
                locationManager.requestAlwaysAuthorization()
            }
            // Foreground updates may start while the Always prompt is pending.
            locationManager.startUpdatingLocation()
            started = true
        case .authorizedAlways:
            startBackgroundSessionIfAvailable()
            locationManager.startUpdatingLocation()
            started = true
        case .denied, .restricted:
            started = false
        @unknown default:
            started = false
        }
    }

    @objc private func appEnteredBackground() {
        guard tripActive else { return }
        configureLocationManager()
        if CLLocationManager.authorizationStatus() == .authorizedAlways {
            startBackgroundSessionIfAvailable()
            if !started {
                locationManager.startUpdatingLocation()
                started = true
            }
        }
    }

    @objc private func appBecameActive() {
        guard tripActive else { return }
        configureLocationManager()
        if CLLocationManager.authorizationStatus() == .authorizedAlways {
            startBackgroundSessionIfAvailable()
        }
        if !started {
            startNativeServicesIfAuthorized(requestPermission: false)
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.tripActive = true
            UserDefaults.standard.set(true, forKey: self.tripActiveKey)
            self.startNativeServicesIfAuthorized(requestPermission: true)
            call.resolve([
                "status": self.started ? "STARTED" : "WAITING_AUTHORIZATION",
                "authorization": CLLocationManager.authorizationStatus().rawValue,
                "tripActive": true
            ])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.tripActive = false
            UserDefaults.standard.set(false, forKey: self.tripActiveKey)
            self.locationManager.stopUpdatingLocation()
            self.started = false
            self.invalidateBackgroundSession()
            call.resolve(["status": "STOPPED"])
        }
    }

    @objc func setTripActive(_ call: CAPPluginCall) {
        let active = call.getBool("active") ?? false
        DispatchQueue.main.async {
            self.tripActive = active
            UserDefaults.standard.set(active, forKey: self.tripActiveKey)
            if active {
                self.startNativeServicesIfAuthorized(requestPermission: true)
            } else {
                self.locationManager.stopUpdatingLocation()
                self.started = false
                self.invalidateBackgroundSession()
            }
            call.resolve([
                "active": active,
                "started": self.started,
                "authorization": CLLocationManager.authorizationStatus().rawValue
            ])
        }
    }

    @objc func getLastLocation(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let loc = self.locationManager.location else {
                call.resolve(["available": false])
                return
            }
            var p = self.payloadForLocation(loc, seq: 0)
            p["available"] = true
            call.resolve(p)
        }
    }

    @objc func getBackgroundLocations(_ call: CAPPluginCall) {
        queue.async {
            let values = self.readQueue()
            call.resolve([
                "count": values.count,
                "ackedSequence": UserDefaults.standard.integer(forKey: self.ackKey),
                "locations": values.map { self.payload($0) }
            ])
        }
    }

    @objc func ackBackgroundLocations(_ call: CAPPluginCall) {
        let requested = call.getInt("sequence") ?? 0
        queue.async {
            let current = UserDefaults.standard.integer(forKey: self.ackKey)
            let next = max(current, requested)
            UserDefaults.standard.set(next, forKey: self.ackKey)
            self.compactQueueIfNeeded(ackedSequence: next)
            call.resolve(["ackedSequence": next])
        }
    }

    @objc func clearBackgroundLocations(_ call: CAPPluginCall) {
        queue.async {
            self.replaceQueue([])
            UserDefaults.standard.set(0, forKey: self.ackKey)
            UserDefaults.standard.set(0, forKey: self.sequenceKey)
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
                "authorizationName": self.authorizationName(auth),
                "background": UIApplication.shared.applicationState != .active,
                "backgroundSession": self.hasBackgroundSession()
            ])
        }
    }

    private func hasBackgroundSession() -> Bool {
        if #available(iOS 17.0, *) {
            return backgroundActivitySession != nil
        }
        return false
    }

    private func authorizationName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "NOT_DETERMINED"
        case .restricted: return "RESTRICTED"
        case .denied: return "DENIED"
        case .authorizedAlways: return "AUTHORIZED_ALWAYS"
        case .authorizedWhenInUse: return "AUTHORIZED_WHEN_IN_USE"
        @unknown default: return "UNKNOWN"
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard tripActive else { return }
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
            manager.startUpdatingLocation()
            started = true
        } else if status == .authorizedAlways {
            configureLocationManager()
            startBackgroundSessionIfAvailable()
            manager.startUpdatingLocation()
            started = true
        } else if status == .denied || status == .restricted {
            started = false
            notifyListeners("locationError", data: [
                "code": 1,
                "message": "Background location authorization is not available"
            ])
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard tripActive else { return }

        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= 100,
                  location.timestamp.timeIntervalSince1970 > 0 else { continue }

            // Append-only persistent queue. The sequence is allocated and the
            // sample is written in the same serial operation that schedules the
            // live callback, so every callback carries the exact sequence of its
            // own persisted sample. The Core Location callback itself never does
            // the disk write synchronously.
            queue.async {
                let seq = self.append(location)

                // Live delivery to JS carries the exact sequence. JS ACKs only
                // after processing; un-ACKed samples remain recoverable.
                DispatchQueue.main.async {
                    self.notifyListeners("locationUpdate", data: self.payloadForLocation(location, seq: seq))
                }
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notifyListeners("locationError", data: [
            "code": (error as NSError).code,
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

    private func nextSequence() -> Int64 {
        let current = Int64(UserDefaults.standard.integer(forKey: sequenceKey))
        let next = current + 1
        UserDefaults.standard.set(Int(next), forKey: sequenceKey)
        return next
    }

    private func append(_ location: CLLocation) -> Int64 {
        let seq = nextSequence()
        let point = StoredLocation(
            seq: seq,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.altitude,
            course: location.course >= 0 ? location.course : -1,
            speedMps: location.speed >= 0 ? location.speed : -1,
            timestamp: location.timestamp.timeIntervalSince1970 * 1000
        )

        guard let data = try? JSONEncoder().encode(point),
              var line = String(data: data, encoding: .utf8) else { return seq }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return seq }

        let url = storageURL()
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(lineData)
            handle.synchronizeFile()
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: lineData)
        }
        return seq
    }

    private func readQueue() -> [StoredLocation] {
        guard let data = try? Data(contentsOf: storageURL()),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let ack = Int64(UserDefaults.standard.integer(forKey: ackKey))
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                  let p = try? JSONDecoder().decode(StoredLocation.self, from: d),
                  p.seq > ack else { return nil }
            return p
        }
    }

    private func compactQueueIfNeeded(ackedSequence: Int) {
        guard ackedSequence > 0 else { return }
        guard let data = try? Data(contentsOf: storageURL()),
              let text = String(data: data, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").compactMap { line -> String? in
            guard let d = line.data(using: .utf8),
                  let p = try? JSONDecoder().decode(StoredLocation.self, from: d) else { return nil }
            return p.seq > Int64(ackedSequence) ? String(line) : nil
        }
        // Compact only after ACK. This preserves any concurrently appended
        // newer sequence because all writes happen on the same serial queue.
        let output = kept.isEmpty ? Data() : Data((kept.joined(separator: "\n") + "\n").utf8)
        try? output.write(to: storageURL(), options: [.atomic])
    }

    private func replaceQueue(_ values: [StoredLocation]) {
        let output = values.map { p -> String in
            guard let d = try? JSONEncoder().encode(p) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }.filter { !$0.isEmpty }
        let data = output.isEmpty ? Data() : Data((output.joined(separator: "\n") + "\n").utf8)
        try? data.write(to: storageURL(), options: [.atomic])
    }

    private func payload(_ p: StoredLocation) -> [String: Any] {
        [
            "seq": p.seq,
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

    private func payloadForLocation(_ location: CLLocation, seq: Int64) -> [String: Any] {
        [
            "seq": seq,
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
}
