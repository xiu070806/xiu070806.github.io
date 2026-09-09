import Foundation
import CoreLocation
import WebKit

final class TaximetLocationBridge: NSObject, CLLocationManagerDelegate, WKScriptMessageHandler {
    static let shared = TaximetLocationBridge()

    private let manager = CLLocationManager()
    private var webView: WKWebView?
    private let queueKey = "taximet.native.location.queue.v1"
    private var pending: [[String: Any]] = []
    private var running = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        if #available(iOS 11.0, *) {
            manager.showsBackgroundLocationIndicator = true
        }
        loadQueue()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "taximetLocation")
        webView.configuration.userContentController.add(self, name: "taximetLocation")
        flushQueue()
    }

    func start() {
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
        if #available(iOS 9.0, *) {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        if #available(iOS 9.0, *) {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "taximetLocation" else { return }
        if let command = message.body as? String, command == "start" {
            start()
        } else if let command = message.body as? String, command == "stop" {
            stop()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if running { manager.startUpdatingLocation() }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            guard location.horizontalAccuracy >= 0 else { continue }
            let point: [String: Any] = [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "accuracy": location.horizontalAccuracy,
                "speed": location.speed >= 0 ? location.speed : NSNull(),
                "heading": location.course >= 0 ? location.course : NSNull(),
                "timestamp": location.timestamp.timeIntervalSince1970 * 1000
            ]
            enqueue(point)
        }
        flushQueue()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        sendEvent("nativeLocationError", ["message": error.localizedDescription])
    }

    private func enqueue(_ point: [String: Any]) {
        pending.append(point)
        if pending.count > 500 {
            pending.removeFirst(pending.count - 500)
        }
        saveQueue()
    }

    private func flushQueue() {
        guard let webView else { return }
        guard !pending.isEmpty else { return }

        let batch = pending
        pending.removeAll(keepingCapacity: true)
        saveQueue()

        guard let data = try? JSONSerialization.data(withJSONObject: batch),
              let json = String(data: data, encoding: .utf8) else {
            pending.insert(contentsOf: batch, at: 0)
            saveQueue()
            return
        }

        let js = """
        (function(){
          var a=\(json);
          if(window.TAXIMET_NATIVE_LOCATION_EVENT){
            a.forEach(function(p){window.TAXIMET_NATIVE_LOCATION_EVENT(p);});
          }
        })();
        """
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { [weak self] _, error in
                if error != nil {
                    self?.pending.insert(contentsOf: batch, at: 0)
                    self?.saveQueue()
                }
            }
        }
    }

    private func sendEvent(_ name: String, _ payload: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.\(name) && window.\(name)(\(json));"
        DispatchQueue.main.async { webView.evaluateJavaScript(js) }
    }

    private func saveQueue() {
        UserDefaults.standard.set(pending, forKey: queueKey)
    }

    private func loadQueue() {
        pending = UserDefaults.standard.array(forKey: queueKey) as? [[String: Any]] ?? []
    }
}