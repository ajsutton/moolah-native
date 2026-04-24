import Testing

@testable import Moolah

@Suite("ICloudAvailability")
struct ICloudAvailabilityTests {
  @Test("reasons are equatable")
  func reasonsEquatable() {
    #expect(ICloudAvailability.UnavailableReason.notSignedIn == .notSignedIn)
    #expect(ICloudAvailability.UnavailableReason.notSignedIn != .restricted)
  }

  @Test("cases are equatable")
  func casesEquatable() {
    #expect(ICloudAvailability.available == .available)
    #expect(ICloudAvailability.unknown == .unknown)
    #expect(
      ICloudAvailability.unavailable(reason: .notSignedIn)
        == .unavailable(reason: .notSignedIn))
    #expect(
      ICloudAvailability.unavailable(reason: .notSignedIn)
        != .unavailable(reason: .restricted))
    #expect(ICloudAvailability.available != .unknown)
  }
}
