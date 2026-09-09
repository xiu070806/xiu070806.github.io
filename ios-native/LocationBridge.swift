import Foundation
import CoreLocation

final class LocationBridge: NSObject, CLLocationManagerDelegate {
    // Reserved native helper. The active CLLocationManager is owned by
    // TaximetLocationPlugin so Capacitor has one authoritative location
    // pipeline and no duplicate CLLocation streams.
}
