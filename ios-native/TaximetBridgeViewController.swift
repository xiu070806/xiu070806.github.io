import UIKit
import Capacitor

/// Registers the in-app native GPS plugin with the Capacitor bridge.
/// The GPS engine itself remains independent and is started by AppDelegate.
@objc(TaximetBridgeViewController)
public final class TaximetBridgeViewController: CAPBridgeViewController {
    private var didRegisterTaximetPlugin = false

    override public func capacitorDidLoad() {
        super.capacitorDidLoad()

        guard !didRegisterTaximetPlugin, let bridge else { return }
        bridge.registerPluginInstance(TaximetLocationPlugin())
        didRegisterTaximetPlugin = true
    }
}
