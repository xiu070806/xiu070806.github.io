
import Foundation
import CoreLocation
import WebKit

final class NativeLocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private weak var webView: WKWebView?

    private var running = false
    private var backgroundMeters: CLLocationDistance = 0
    private var backgroundAnchor: CLLocation?
    private var lastLocation: CLLocation?
    private var lastWasBackground = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1.0
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        if #available(iOS 9.0, *) {
            manager.allowsBackgroundLocationUpdates = true
        }
        if #available(iOS 11.0, *) {
            manager.showsBackgroundLocationIndicator = true
        }
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        webView.configuration.userContentController.add(self, name: "taximetLocation")
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("""
            window.dispatchEvent(new CustomEvent('taximet-native-ready'));
            """)
        }
    }

    func appDidEnterBackground() {
        guard running else { return }
        lastWasBackground = true
        backgroundMeters = 0
        backgroundAnchor = lastLocation
    }

    func appWillEnterForeground() {
        guard running else { return }
        let meters = backgroundMeters
        backgroundMeters = 0
        backgroundAnchor = lastLocation
        lastWasBackground = false
        if meters > 0 {
            sendBackgroundDistance(meters)
        }
        sendCurrentLocation()
    }

    private func requestAuthorizationAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .restricted, .denied:
            sendError("LOCATION_PERMISSION_DENIED")
        @unknown default:
            break
        }
    }

    private func start() {
        running = true
        requestAuthorizationAndStart()
    }

    private func stop() {
        running = false
        manager.stopUpdatingLocation()
        backgroundMeters = 0
        backgroundAnchor = nil
        lastWasBackground = false
    }

    private func pause() {
        running = false
        manager.stopUpdatingLocation()
        backgroundMeters = 0
        backgroundAnchor = nil
        lastWasBackground = false
    }

    private func sendCurrentLocation() {
        guard let loc = lastLocation else { return }
        sendLocation(loc)
    }

    private func sendLocation(_ location: CLLocation) {
        let speed = location.speed >= 0 ? location.speed : nil
        let heading = location.course >= 0 ? location.course : nil
        let payload: [String: Any] = [
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "speedMps": speed as Any,
            "heading": heading as Any,
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let js = "window.dispatchEvent(new CustomEvent('taximet-native-location',{detail:\(json)}));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func sendBackgroundDistance(_ meters: CLLocationDistance) {
        let js = "window.dispatchEvent(new CustomEvent('taximet-native-background-distance',{detail:{meters:\(meters)}}));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func sendError(_ code: String) {
        let safe = code.replacingOccurrences(of: "'", with: "\\'")
        let js = "window.dispatchEvent(new CustomEvent('taximet-native-error',{detail:{code:'\(safe)'}}));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if running { manager.startUpdatingLocation() }
        case .denied, .restricted:
            sendError("LOCATION_PERMISSION_DENIED")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        guard loc.horizontalAccuracy >= 0 else { return }

        if let previous = lastLocation {
            let d = loc.distance(from: previous)
            if lastWasBackground && d.isFinite && d >= 0 && d < 1000 {
                backgroundMeters += d
            }
        }
        lastLocation = loc

        // Foreground: feed the web app so its existing fare/GPS engine remains authoritative.
        // Background: Core Location continues collecting points; distance is reconciled on resume.
        if !lastWasBackground {
            sendLocation(loc)
        }
    }
}

extension NativeLocationService: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "taximetLocation",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "start", "sync":
            start()
            if action == "sync" { sendCurrentLocation() }
        case "pause", "stop":
            pause()
            if action == "stop" { stop() }
        default:
            break
        }
    }
}
