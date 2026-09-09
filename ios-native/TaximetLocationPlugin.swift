import Foundation
import Capacitor
import WebKit

@objc(TaximetLocationPlugin)
public class TaximetLocationPlugin: CAPPlugin {

    private let locationBridge = LocationBridge.shared

    public override func load() {
        super.load()

        DispatchQueue.main.async {
            if let webView = self.bridge?.webView {
                self.locationBridge.attachWebView(webView)
            }

            self.locationBridge.requestPermission()
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let webView = self.bridge?.webView {
                self.locationBridge.attachWebView(webView)
            }

            self.locationBridge.start()

            call.resolve([
                "started": true
            ])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.locationBridge.stop()

            call.resolve([
                "stopped": true
            ])
        }
    }

    @objc func requestPermission(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.locationBridge.requestPermission()

            call.resolve([
                "requested": true
            ])
        }
    }
}
