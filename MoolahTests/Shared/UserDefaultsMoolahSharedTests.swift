import Foundation
import Testing

@testable import Moolah

@Suite("UserDefaults+MoolahShared")
struct UserDefaultsMoolahSharedTests {
  @Test("sharedSuite(for: .development) uses dotted lowercase env suffix")
  func testDevelopmentSuiteName() {
    let suite = UserDefaults.sharedSuite(for: .development)
    #expect(suite !== UserDefaults.standard)
    let key = "moolah.test.\(UUID().uuidString)"
    suite.set("dev", forKey: key)
    defer { suite.removeObject(forKey: key) }
    let mirror = UserDefaults(suiteName: "rocks.moolah.app.development")
    #expect(mirror?.string(forKey: key) == "dev")
  }

  @Test("sharedSuite(for: .production) uses dotted lowercase env suffix")
  func testProductionSuiteName() {
    let suite = UserDefaults.sharedSuite(for: .production)
    #expect(suite !== UserDefaults.standard)
    let key = "moolah.test.\(UUID().uuidString)"
    suite.set("prod", forKey: key)
    defer { suite.removeObject(forKey: key) }
    let mirror = UserDefaults(suiteName: "rocks.moolah.app.production")
    #expect(mirror?.string(forKey: key) == "prod")
  }

  @Test("dev and prod suites are isolated from each other")
  func testDevAndProdAreIsolated() {
    let dev = UserDefaults.sharedSuite(for: .development)
    let prod = UserDefaults.sharedSuite(for: .production)
    let key = "moolah.test.\(UUID().uuidString)"
    dev.set("dev-value", forKey: key)
    defer {
      dev.removeObject(forKey: key)
      prod.removeObject(forKey: key)
    }
    #expect(prod.string(forKey: key) == nil)
  }

  @Test("moolahShared resolves to a suite, never .standard")
  func testMoolahSharedIsNotStandard() {
    #expect(UserDefaults.moolahShared !== UserDefaults.standard)
  }
}
