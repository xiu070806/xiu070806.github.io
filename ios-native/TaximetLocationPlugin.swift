import Foundation
import CoreLocation
import Capacitor

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let ioQueue = DispatchQueue(label: "com.taximet.pro.location-queue", qos: .utility)

    private let tripKey = "TaximetLocation.tripActive"
    private let nextSeqKey = "TaximetLocation.nextSequence"
    private let ackSeqKey = "TaximetLocation.ackSequence"
    private var tripActive = false
    // Stored as NSObject to keep this plugin source compatible with the iOS 14 deployment target.
    // The iOS 17+ CLBackgroundActivitySession is created dynamically at runtime.
    private var backgroundActivitySession: NSObject?
    private var lastPersistedTimestamp: TimeInterval = 0
    private var lastPersistedLat: CLLocationDegrees = 0
    private var lastPersistedLon: CLLocationDegrees = 0

    private lazy var queueURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TAXIMETPRO", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("location-queue.jsonl")
    }()

    public override func load() {
        super.load()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        if #available(iOS 11.0, *) { manager.showsBackgroundLocationIndicator = true }
        tripActive = UserDefaults.standard.bool(forKey: tripKey)
        if tripActive { startServicesIfPossible() }
    }

    @objc public func start(_ call: CAPPluginCall) {
        tripActive = true
        UserDefaults.standard.set(true, forKey: tripKey)
        startServicesIfPossible()
        call.resolve(["status": "STARTED", "tripActive": true])
    }

    @objc public func stop(_ call: CAPPluginCall) {
        tripActive = false
        UserDefaults.standard.set(false, forKey: tripKey)
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        endBackgroundSession()
        call.resolve(["status": "STOPPED", "tripActive": false])
    }

    @objc public func setTripActive(_ call: CAPPluginCall) {
        let active = call.getBool("active") ?? false
        tripActive = active
        UserDefaults.standard.set(active, forKey: tripKey)
        if active {
            startServicesIfPossible()
        } else {
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
            endBackgroundSession()
        }
        call.resolve(["tripActive": active])
    }

    @objc public func getLastLocation(_ call: CAPPluginCall) {
        let location = manager.location
        guard let location else { call.resolve([:]); return }
        call.resolve(payload(location, seq: 0))
    }

    @objc public func getBackgroundLocations(_ call: CAPPluginCall) {
        let result = ioQueue.sync { readQueue() }
        call.resolve(["locations": result])
    }

    @objc public func ackBackgroundLocations(_ call: CAPPluginCall) {
        let sequence = call.getInt("sequence") ?? 0
        guard sequence > 0 else { call.resolve(["ackSequence": currentAck()]); return }
        let acked = ioQueue.sync { compactQueue(upTo: sequence) }
        call.resolve(["ackSequence": acked])
    }

    @objc public func clearBackgroundLocations(_ call: CAPPluginCall) {
        let cleared = ioQueue.sync { clearQueue() }
        call.resolve(["cleared": cleared])
    }

    @objc public func status(_ call: CAPPluginCall) {
        let auth = CLLocationManager.authorizationStatus()
        let queueCount = ioQueue.sync { readQueue().count }
        call.resolve([
            "tripActive": tripActive,
            "authorization": auth.rawValue,
            "queueCount": queueCount,
            "ackSequence": currentAck()
        ])
    }

    private func configureLocationManager() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        if #available(iOS 11.0, *) { manager.showsBackgroundLocationIndicator = true }
    }

    private func startServicesIfPossible() {
        configureLocationManager()
        let status = CLLocationManager.authorizationStatus()
        switch status {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginBackgroundSessionIfAvailable()
            manager.startUpdatingLocation()
            if #available(iOS 8.0, *) {
                manager.startMonitoringSignificantLocationChanges()
            }
        default:
            NotificationCenter.default.post(name: Notification.Name("TaximetLocation.authorizationError"), object: nil)
        }
    }

    private func beginBackgroundSessionIfAvailable() {
        guard #available(iOS 17.0, *) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.backgroundActivitySession == nil else { return }
            guard let cls = NSClassFromString("CLBackgroundActivitySession") as? NSObject.Type else { return }
            // Initializing the session starts the iOS background activity session.
            self.backgroundActivitySession = cls.init()
        }
    }

    private func endBackgroundSession() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let session = self.backgroundActivitySession {
                let selector = NSSelectorFromString("invalidate")
                if session.responds(to: selector) {
                    _ = session.perform(selector)
                }
            }
            self.backgroundActivitySession = nil
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard tripActive else { return }
        startServicesIfPossible()
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard tripActive else { return }
        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= 100,
                  location.timestamp.timeIntervalSince1970 > 0 else { continue }
            if shouldPersist(location) {
                let seq = ioQueue.sync { append(location) }
                notifyListeners("locationUpdate", data: payload(location, seq: seq))
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notifyListeners("locationError", data: ["code": 2, "message": error.localizedDescription])
    }

    private func shouldPersist(_ location: CLLocation) -> Bool {
        let t = location.timestamp.timeIntervalSince1970
        if t < lastPersistedTimestamp { return false }
        if t == lastPersistedTimestamp && location.coordinate.latitude == lastPersistedLat && location.coordinate.longitude == lastPersistedLon { return false }
        lastPersistedTimestamp = t
        lastPersistedLat = location.coordinate.latitude
        lastPersistedLon = location.coordinate.longitude
        return true
    }

    private func payload(_ location: CLLocation, seq: Int) -> [String: Any] {
        [
            "seq": seq,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "speed": location.speed >= 0 ? location.speed : NSNull(),
            "heading": location.course >= 0 ? location.course : NSNull(),
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]
    }

    private func nextSequence() -> Int {
        let n = UserDefaults.standard.integer(forKey: nextSeqKey) + 1
        UserDefaults.standard.set(n, forKey: nextSeqKey)
        return n
    }

    private func currentAck() -> Int {
        UserDefaults.standard.integer(forKey: ackSeqKey)
    }

    private func append(_ location: CLLocation) -> Int {
        let seq = nextSequence()
        let obj = payload(location, seq: seq)
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return 0 }
        var line = data
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: queueURL.path) {
            FileManager.default.createFile(atPath: queueURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: queueURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try handle.close()
            return seq
        } catch { return 0 }
    }

    private func readQueue() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: queueURL), !data.isEmpty else { return [] }
        var out: [[String: Any]] = []
        for line in data.split(separator: 0x0A) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line), options: []), let dict = obj as? [String: Any] {
                out.append(dict)
            }
        }
        return out
    }

    private func compactQueue(upTo sequence: Int) -> Int {
        let items = readQueue()
        guard !items.isEmpty else {
            UserDefaults.standard.set(max(currentAck(), sequence), forKey: ackSeqKey)
            return max(currentAck(), sequence)
        }
        let remaining = items.filter { seqValue($0) > sequence }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
        } else {
            let lines = remaining.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: []) }
            var data = Data()
            for var line in lines { line.append(0x0A); data.append(line) }
            try? data.write(to: queueURL, options: .atomic)
        }
        let newAck = max(currentAck(), sequence)
        UserDefaults.standard.set(newAck, forKey: ackSeqKey)
        return newAck
    }

    private func seqValue(_ item: [String: Any]) -> Int {
        if let n = item["seq"] as? NSNumber { return n.intValue }
        if let s = item["seq"] as? String { return Int(s) ?? 0 }
        return 0
    }

    private func clearQueue() -> Int {
        let count = readQueue().count
        try? FileManager.default.removeItem(at: queueURL)
        return count
    }
}
