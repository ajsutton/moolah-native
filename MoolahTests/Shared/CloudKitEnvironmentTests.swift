import Foundation
import Testing

@testable import Moolah

@Suite("CloudKitEnvironment")
struct CloudKitEnvironmentTests {
  @Test("resolves Development from raw value")
  func testResolveDevelopment() {
    let env = CloudKitEnvironment.resolve(from: "Development")
    #expect(env == .development)
  }

  @Test("resolves Production from raw value")
  func testResolveProduction() {
    let env = CloudKitEnvironment.resolve(from: "Production")
    #expect(env == .production)
  }

  @Test("storageSubdirectory matches raw value")
  func testStorageSubdirectory() {
    #expect(CloudKitEnvironment.development.storageSubdirectory == "Development")
    #expect(CloudKitEnvironment.production.storageSubdirectory == "Production")
  }
}
