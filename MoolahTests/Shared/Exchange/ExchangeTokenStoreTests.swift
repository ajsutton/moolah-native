import Foundation
import Testing

@testable import Moolah

#if os(macOS)  // Keychain tests require code signing (macOS only)

  @Suite("ExchangeTokenStore")
  struct ExchangeTokenStoreTests {
    @Test
    func savedTokenIsReadableForSameAccount() throws {
      let id = UUID()
      let store = ExchangeTokenStore(synchronizable: false)
      defer { store.delete(for: id) }
      try store.save(token: "TOKEN123", for: id)
      #expect(try store.token(for: id) == "TOKEN123")
    }

    @Test
    func deleteRemovesTheStoredToken() throws {
      let id = UUID()
      let store = ExchangeTokenStore(synchronizable: false)
      defer { store.delete(for: id) }
      try store.save(token: "TOKEN123", for: id)
      store.delete(for: id)
      #expect(try store.token(for: id) == nil)
    }

    @Test
    func tokenIsNilForUnknownAccount() throws {
      let store = ExchangeTokenStore(synchronizable: false)
      #expect(try store.token(for: UUID()) == nil)
    }

    @Test
    func tokensAreIsolatedPerAccount() throws {
      let store = ExchangeTokenStore(synchronizable: false)
      let accountA = UUID()
      let accountB = UUID()
      try store.save(token: "A", for: accountA)
      try store.save(token: "B", for: accountB)
      defer {
        store.delete(for: accountA)
        store.delete(for: accountB)
      }
      #expect(try store.token(for: accountA) == "A")
      #expect(try store.token(for: accountB) == "B")
    }
  }

#endif
