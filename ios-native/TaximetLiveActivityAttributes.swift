import ActivityKit
import Foundation

public struct TaximetLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var status: String
        public var distanceM: Double
        public var fare: Int
        public var tripCode: String
        public var updatedAt: Date

        public init(status: String, distanceM: Double, fare: Int, tripCode: String, updatedAt: Date = Date()) {
            self.status = status
            self.distanceM = distanceM
            self.fare = fare
            self.tripCode = tripCode
            self.updatedAt = updatedAt
        }
    }

    public var tripId: String

    public init(tripId: String) {
        self.tripId = tripId
    }
}
