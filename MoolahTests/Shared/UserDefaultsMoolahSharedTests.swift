import Foundation
import Testing

@testable import Moolah

@Suite("UserDefaults+MoolahShared")
struct UserDefaultsMoolahSharedTests {
  @Test("makeSharedSuite(for: .development) is not UserDefaults.standard")
  func testMakeSharedSuiteDevelopmentIsNotStandard() {
    #expect(UserDefaults.makeSharedSuite(for: .development) !== UserDefaults.standard)
  }

  @Test("makeSharedSuite(for: .development) uses dotted lowercase env suffix")
  func testMakeSharedSuiteDevelopmentSuiteName() {
    let suite = UserDefaults.makeSharedSuite(for: .development)
    let key = "moolah.test.\(UUID().uuidString)"
    defer { suite.removeObject(forKey: key) }
    suite.set("dev", forKey: key)
    let mirror = UserDefaults(suiteName: "rocks.moolah.app.development")
    #expect(mirror?.string(forKey: key) == "dev")
  }

  @Test("makeSharedSuite(for: .production) is not UserDefaults.standard")
  func testMakeSharedSuiteProductionIsNotStandard() {
    #expect(UserDefaults.makeSharedSuite(for: .production) !== UserDefaults.standard)
  }

  @Test("makeSharedSuite(for: .production) uses dotted lowercase env suffix")
  func testMakeSharedSuiteProductionSuiteName() {
    let suite = UserDefaults.makeSharedSuite(for: .production)
    let key = "moolah.test.\(UUID().uuidString)"
    defer { suite.removeObject(forKey: key) }
    suite.set("prod", forKey: key)
    let mirror = UserDefaults(suiteName: "rocks.moolah.app.production")
    #expect(mirror?.string(forKey: key) == "prod")
  }

  @Test("dev and prod suites are isolated from each other")
  func testDevAndProdAreIsolated() {
    let dev = UserDefaults.makeSharedSuite(for: .development)
    let prod = UserDefaults.makeSharedSuite(for: .production)
    let key = "moolah.test.\(UUID().uuidString)"
    defer {
      dev.removeObject(forKey: key)
      prod.removeObject(forKey: key)
    }
    dev.set("dev-value", forKey: key)
    #expect(prod.string(forKey: key) == nil)
  }

  @Test("moolahShared resolves to a suite, never .standard")
  func testMoolahSharedIsNotStandard() {
    #expect(UserDefaults.moolahShared !== UserDefaults.standard)
  }
}
