import Foundation
import CoreLocation
import WebKit

final class LocationBridge: NSObject, CLLocationManagerDelegate {

    static let shared = LocationBridge()

    private let locationManager = CLLocationManager()
    private var webView: WKWebView?

    private var isRunning = false

    private override init() {
        super.init()

        locationManager.delegate = self

        // GPS độ chính xác cao
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation

        // Không tự động dừng khi iOS thấy thiết bị đứng yên
        locationManager.pausesLocationUpdatesAutomatically = false

        // Phù hợp ứng dụng tính cước khi xe di chuyển
        locationManager.activityType = .automotiveNavigation

        // Cho phép cập nhật vị trí khi app chạy nền
        locationManager.allowsBackgroundLocationUpdates = true
    }

    // MARK: - WebView

    func attachWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Authorization

    func requestPermission() {
        let status = locationManager.authorizationStatus

        switch status {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()

        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()

        case .authorizedAlways:
            start()

        default:
            break
        }
    }

    // MARK: - Start GPS

    func start() {
        guard !isRunning else { return }

        isRunning = true

        locationManager.startUpdatingLocation()
    }

    // MARK: - Stop GPS

    func stop() {
        isRunning = false

        locationManager.stopUpdatingLocation()
    }

    // MARK: - GPS callback

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {

        guard let location = locations.last else {
            return
        }

        guard location.horizontalAccuracy >= 0 else {
            return
        }

        let data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.altitude,
            "speed": max(location.speed, 0),
            "course": location.course,
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ]

        sendToJavaScript(data)
    }

    // MARK: - Send GPS to WebView

    private func sendToJavaScript(_ data: [String: Any]) {

        guard let webView = webView else {
            return
        }

        guard
            let jsonData = try? JSONSerialization.data(
                withJSONObject: data,
                options: []
            ),
            let json = String(data: jsonData, encoding: .utf8)
        else {
            return
        }

        let script = """
        window.dispatchEvent(
            new CustomEvent('nativeLocationUpdate', {
                detail: \(json)
            })
        );
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(script)
        }
    }

    // MARK: - Authorization changed

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {

        switch manager.authorizationStatus {

        case .authorizedAlways:
            start()

        case .authorizedWhenInUse:
            // Yêu cầu Always nếu iOS chưa cấp
            manager.requestAlwaysAuthorization()

        default:
            break
        }
    }

    // MARK: - Error

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {

        let message: [String: Any] = [
            "error": error.localizedDescription
        ]

        sendErrorToJavaScript(message)
    }

    private func sendErrorToJavaScript(
        _ data: [String: Any]
    ) {

        guard let webView = webView else {
            return
        }

        guard
            let jsonData = try? JSONSerialization.data(
                withJSONObject: data,
                options: []
            ),
            let json = String(data: jsonData, encoding: .utf8)
        else {
            return
        }

        let script = """
        window.dispatchEvent(
            new CustomEvent('nativeLocationError', {
                detail: \(json)
            })
        );
        """

        DispatchQueue.main.async {
            webView.evaluateJavaScript(script)
        }
    }
}
