import Foundation
import Capacitor

@objc(TaximetLocationPlugin)
public final class TaximetLocationPlugin: CAPPlugin {

    private let locationBridge = LocationBridge.shared

    public override func load() {
        super.load()
        if let webView = bridge?.webView {
            locationBridge.attachWebView(webView)
        }
        locationBridge.requestPermission()
    }

    @objc func start(_ call: CAPPluginCall) {
        if let webView = bridge?.webView {
            locationBridge.attachWebView(webView)
        }
        locationBridge.start()
        call.resolve(["started": true])
    }

    @objc func stop(_ call: CAPPluginCall) {
        locationBridge.stop()
        call.resolve(["stopped": true])
    }

    @objc func requestPermission(_ call: CAPPluginCall) {
        locationBridge.requestPermission()
        call.resolve(["requested": true])
    }
}
