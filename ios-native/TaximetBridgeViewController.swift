import Foundation
import Capacitor

/// Deterministic Capacitor registration point for the single native GPS plugin.
public final class TaximetBridgeViewController: CAPBridgeViewController {
    public override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(TaximetLocationPlugin())
    }
}
