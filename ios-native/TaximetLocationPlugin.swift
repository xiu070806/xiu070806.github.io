import Foundation
import CoreLocation
import Capacitor
import WebKit

@objc(TaximetLocationPlugin)
public final class TaximetLocationPlugin: CAPPlugin, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private let queueKey = "taximet.native.location.queue"
    private let queueLock = NSLock()

    private var isTracking = false
    private weak var webView: WKWebView?

    public override func load() {
        super.load()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true

        if let webView = bridge?.webView {
            self.webView = webView
        }
    }

    @objc func requestPermission(_ call: CAPPluginCall) {
        manager.requestAlwaysAuthorization()
        call.resolve()
    }

    @objc func start(_ call: CAPPluginCall) {
        if let webView = bridge?.webView {
            self.webView = webView
        }

        isTracking = true
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()

        call.resolve(["started": true])
        replayQueuedLocations()
    }

    @objc func stop(_ call: CAPPluginCall) {
        isTracking = false
        manager.stopUpdatingLocation()
        call.resolve(["stopped": true])
    }

    @objc func replay(_ call: CAPPluginCall) {
        replayQueuedLocations()
        call.resolve(["replayed": true])
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways && isTracking {
            manager.startUpdatingLocation()
        }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        for location in locations {
            guard location.horizontalAccuracy >= 0 else { continue }

            let payload: [String: Any] = [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "accuracy": location.horizontalAccuracy,
                "altitude": location.altitude,
                "speed": max(0, location.speed),
                "course": location.course >= 0 ? location.course : -1,
                "timestamp": location.timestamp.timeIntervalSince1970 * 1000
            ]

            enqueue(payload)
        }

        replayQueuedLocations()
    }

    private func enqueue(_ payload: [String: Any]) {
        queueLock.lock()
        defer { queueLock.unlock() }

        var items = loadQueueLocked()
        items.append(payload)

        // Keep a bounded native queue so a long background period cannot
        // grow storage without limit.
        if items.count > 2000 {
            items.removeFirst(items.count - 2000)
        }

        saveQueueLocked(items)
    }

    private func replayQueuedLocations() {
        guard let webView = bridge?.webView else { return }
        self.webView = webView

        queueLock.lock()
        let items = loadQueueLocked()
        queueLock.unlock()

        guard !items.isEmpty else { return }

        for item in items {
            sendToWebView(item)
        }

        queueLock.lock()
        saveQueueLocked([])
        queueLock.unlock()
    }

    private func sendToWebView(_ payload: [String: Any]) {
        guard let webView = webView else { return }

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { return }

        let js = """
        window.dispatchEvent(new CustomEvent('nativeLocationUpdate', {
            detail: \(json)
        }));
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func loadQueueLocked() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: queueKey),
              let value = try? JSONSerialization.jsonObject(with: data),
              let array = value as? [[String: Any]]
        else {
            return []
        }
        return array
    }

    private func saveQueueLocked(_ array: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return }
        UserDefaults.standard.set(data, forKey: queueKey)
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let payload = ["error": error.localizedDescription]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8),
            let webView = webView
        else { return }

        let js = """
        window.dispatchEvent(new CustomEvent('nativeLocationError', {
            detail: \(json)
        }));
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
