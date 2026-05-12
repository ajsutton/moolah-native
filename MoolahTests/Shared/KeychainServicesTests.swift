import Foundation
import Testing

@testable import Moolah

@Suite("KeychainServices")
struct KeychainServicesTests {
  @Test("makeApiKeysService(for: .development) returns dotted lowercase env suffix")
  func testDevelopmentServiceStringFormat() {
    #expect(
      KeychainServices.makeApiKeysService(for: .development)
        == "com.moolah.api-keys.development")
  }

  @Test("makeApiKeysService(for: .production) returns dotted lowercase env suffix")
  func testProductionServiceStringFormat() {
    #expect(
      KeychainServices.makeApiKeysService(for: .production)
        == "com.moolah.api-keys.production")
  }

  @Test("apiKeys uses the resolved environment")
  func testApiKeysUsesResolvedEnvironment() {
    let resolved = CloudKitEnvironment.resolved()
    #expect(
      KeychainServices.apiKeys
        == KeychainServices.makeApiKeysService(for: resolved))
  }
}
