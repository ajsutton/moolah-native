import Foundation
import Testing

@testable import Moolah

struct ExchangeTokenStoreTests {
  @Test
  func saveReadDeleteRoundTrip() throws {
    let id = UUID()
    let store = ExchangeTokenStore(synchronizable: false)
    try store.save(token: "TOKEN123", for: id)
    #expect(try store.token(for: id) == "TOKEN123")
    store.delete(for: id)
    #expect(try store.token(for: id) == nil)
  }

  @Test
  func tokensAreIsolatedPerAccount() throws {
    let store = ExchangeTokenStore(synchronizable: false)
    let accountA = UUID()
    let accountB = UUID()
    try store.save(token: "A", for: accountA)
    try store.save(token: "B", for: accountB)
    #expect(try store.token(for: accountA) == "A")
    #expect(try store.token(for: accountB) == "B")
    store.delete(for: accountA)
    store.delete(for: accountB)
  }
}
