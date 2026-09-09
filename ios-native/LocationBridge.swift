import Foundation
import CoreLocation
import WebKit

final class LocationBridge: NSObject, CLLocationManagerDelegate {
    static let shared = LocationBridge()

    private let manager = CLLocationManager()
    private weak var webView: WKWebView?
    private var running = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    func attachWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            start()
        default:
            break
        }
    }

    func start() {
        guard !running else { return }
        running = true
        manager.startUpdatingLocation()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            start()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }

        let payload: [String: Any] = [
            "latitude": l.coordinate.latitude,
            "longitude": l.coordinate.longitude,
            "accuracy": l.horizontalAccuracy,
            "altitude": l.altitude,
            "speed": max(l.speed, 0),
            "course": l.course,
            "timestamp": l.timestamp.timeIntervalSince1970 * 1000
        ]
        emit("nativeLocationUpdate", payload)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        emit("nativeLocationError", ["error": error.localizedDescription])
    }

    private func emit(_ name: String, _ payload: [String: Any]) {
        guard let webView else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let script = """
        window.dispatchEvent(new CustomEvent(\(jsonString(name)), { detail: \(json) }));
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8)!
    }
}
