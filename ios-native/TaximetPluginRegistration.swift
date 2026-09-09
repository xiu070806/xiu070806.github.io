import Foundation
import Capacitor

@objc(TaximetPluginRegistration)
public final class TaximetPluginRegistration: NSObject {

    public static func register(with bridge: CAPBridgeProtocol) {
        bridge.registerPluginInstance(TaximetLocationPlugin())
    }
}
