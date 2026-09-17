import Foundation
import Capacitor

/// The single native bridge registration point for the local TAXIMET PRO GPS plugin.
/// This class is installed as the Capacitor root view controller by build-ios.yml.
/// Keeping registration here avoids depending on generated packageClassList entries.
public final class TaximetBridgeViewController: CAPBridgeViewController {
    public override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(TaximetLocationPlugin())
    }
}
