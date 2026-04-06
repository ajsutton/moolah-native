import Foundation
import Testing

@testable import Moolah

// Keychain access requires code signing. The iOS simulator test target uses
// CODE_SIGNING_ALLOWED=NO, so these tests only run on macOS.
#if os(macOS)

  @Suite("CookieKeychain")
  struct CookieKeychainTests {
    /// Use a unique service name to avoid collisions with the real app keychain.
    private let keychain = CookieKeychain(service: "com.moolah.tests.cookies", account: "test")

    private func makeCookie(name: String = "session_id", value: String = "abc123") -> HTTPCookie {
      HTTPCookie(properties: [
        .name: name,
        .value: value,
        .domain: "localhost",
        .path: "/",
      ])!
    }

    @Test("save and restore round-trips cookies")
    func roundTrip() throws {
      let cookie = makeCookie()
      try keychain.save(cookies: [cookie])
      let restored = try keychain.restore()

      #expect(restored?.count == 1)
      #expect(restored?.first?.name == "session_id")
      #expect(restored?.first?.value == "abc123")

      keychain.clear()
    }

    @Test("restore returns nil when nothing stored")
    func restoreEmpty() throws {
      keychain.clear()
      let result = try keychain.restore()
      #expect(result == nil)
    }

    @Test("clear removes stored cookies")
    func clearRemoves() throws {
      try keychain.save(cookies: [makeCookie()])
      keychain.clear()
      let result = try keychain.restore()
      #expect(result == nil)
    }

    @Test("save overwrites previous entry")
    func overwrite() throws {
      try keychain.save(cookies: [makeCookie(name: "a", value: "1")])
      try keychain.save(cookies: [makeCookie(name: "b", value: "2")])

      let restored = try keychain.restore()
      #expect(restored?.count == 1)
      #expect(restored?.first?.name == "b")

      keychain.clear()
    }
  }

#endif
