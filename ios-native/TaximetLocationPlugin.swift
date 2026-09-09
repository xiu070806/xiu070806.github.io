import Foundation
import CoreLocation
import Capacitor

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let queue = DispatchQueue(label: "com.taximet.pro.location.queue", qos: .utility)
    private let tripKey = "TaximetLocation.tripActive"
    private let nextKey = "TaximetLocation.nextSequence"
    private let ackKey = "TaximetLocation.ackSequence"
    private var tripActive = false

    private lazy var queueURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TAXIMETPRO", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("location-queue.jsonl")
    }()

    public override func load() {
        super.load()
        manager.delegate = self
        configure()
        tripActive = UserDefaults.standard.bool(forKey: tripKey)
        if tripActive {
            startServices()
        }
    }

    @objc public func start(_ call: CAPPluginCall) {
        tripActive = true
        UserDefaults.standard.set(true, forKey: tripKey)
        startServices()
        call.resolve(["status": "STARTED", "tripActive": true])
    }

    @objc public func stop(_ call: CAPPluginCall) {
        tripActive = false
        UserDefaults.standard.set(false, forKey: tripKey)
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        call.resolve(["status": "STOPPED", "tripActive": false])
    }

    @objc public func setTripActive(_ call: CAPPluginCall) {
        let active = call.getBool("active") ?? false
        tripActive = active
        UserDefaults.standard.set(active, forKey: tripKey)

        if active {
            startServices()
        } else {
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
        }

        call.resolve(["tripActive": active])
    }

    @objc public func getLastLocation(_ call: CAPPluginCall) {
        if let location = manager.location {
            call.resolve(payload(location, sequence: 0))
        } else {
            call.resolve([:])
        }
    }

    @objc public func getBackgroundLocations(_ call: CAPPluginCall) {
        call.resolve(["locations": queue.sync { readQueue() }])
    }

    @objc public func ackBackgroundLocations(_ call: CAPPluginCall) {
        let requested = call.getInt("sequence") ?? 0
        let acknowledged = queue.sync { compact(upTo: requested) }
        call.resolve(["ackSequence": acknowledged])
    }

    @objc public func clearBackgroundLocations(_ call: CAPPluginCall) {
        let count = queue.sync { () -> Int in
            let count = readQueue().count
            try? FileManager.default.removeItem(at: queueURL)
            return count
        }
        let next = UserDefaults.standard.integer(forKey: nextKey)
        UserDefaults.standard.set(max(0, next - 1), forKey: ackKey)
        call.resolve(["cleared": count])
    }

    @objc public func status(_ call: CAPPluginCall) {
        let count = queue.sync { readQueue().count }
        call.resolve([
            "tripActive": tripActive,
            "authorization": manager.authorizationStatus.rawValue,
            "queueCount": count,
            "ackSequence": UserDefaults.standard.integer(forKey: ackKey)
        ])
    }

    private func configure() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLLocationDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        if #available(iOS 11.0, *) {
            manager.showsBackgroundLocationIndicator = true
        }
    }

    private func startServices() {
        configure()

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        default:
            notifyListeners(
                "locationError",
                data: [
                    "code": 1,
                    "message": "Location permission is not Always authorized"
                ]
            )
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard tripActive else { return }
        startServices()
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard tripActive else { return }

        for location in locations {
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= 100 else {
                continue
            }

            let sequence = queue.sync { append(location) }
            if sequence > 0 {
                notifyListeners("locationUpdate", data: payload(location, sequence: sequence))
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notifyListeners(
            "locationError",
            data: ["code": 2, "message": error.localizedDescription]
        )
    }

    private func append(_ location: CLLocation) -> Int {
        let sequence = UserDefaults.standard.integer(forKey: nextKey) + 1
        UserDefaults.standard.set(sequence, forKey: nextKey)

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload(location, sequence: sequence),
            options: []
        ) else {
            return 0
        }

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
            return sequence
        } catch {
            return 0
        }
    }

    private func readQueue() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: queueURL), !data.isEmpty else {
            return []
        }

        let acknowledged = UserDefaults.standard.integer(forKey: ackKey)

        return data.split(separator: 0x0A).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dictionary = object as? [String: Any] else {
                return nil
            }

            let sequence = (dictionary["seq"] as? NSNumber)?.intValue ?? 0
            return sequence > acknowledged ? dictionary : nil
        }
    }

    private func compact(upTo requested: Int) -> Int {
        let acknowledged = UserDefaults.standard.integer(forKey: ackKey)
        guard requested > acknowledged else { return acknowledged }

        let items = readQueue()
        let maximum = items
            .map { ($0["seq"] as? NSNumber)?.intValue ?? 0 }
            .max() ?? acknowledged
        let target = min(requested, maximum)
        guard target > acknowledged else { return acknowledged }

        let remaining = items.filter {
            (($0["seq"] as? NSNumber)?.intValue ?? 0) > target
        }

        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
        } else {
            var data = Data()
            for item in remaining {
                if var line = try? JSONSerialization.data(withJSONObject: item, options: []) {
                    line.append(0x0A)
                    data.append(line)
                }
            }
            try? data.write(to: queueURL, options: .atomic)
        }

        UserDefaults.standard.set(target, forKey: ackKey)
        return target
    }

    private func payload(_ location: CLLocation, sequence: Int) -> [String: Any] {
        [
            "seq": sequence,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "speed": location.speed >= 0 ? location.speed : NSNull(),
            "heading": location.course >= 0 ? location.course : NSNull(),
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]
    }
}
