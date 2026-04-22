import Foundation
import Testing

@testable import Moolah

#if os(macOS)  // Keychain tests require code signing (macOS only)

  @Suite("KeychainStore")
  struct KeychainStoreTests {
    private func makeStore(
      service: String = "com.moolah.test.\(UUID().uuidString)",
      account: String = "test",
      synchronizable: Bool = false
    ) -> KeychainStore {
      KeychainStore(service: service, account: account, synchronizable: synchronizable)
    }

    // MARK: - String values

    @Test func saveAndRestoreString() throws {
      let store = makeStore()
      defer { store.clear() }

      try store.saveString("my-api-key-123")
      let restored = try store.restoreString()
      #expect(restored == "my-api-key-123")
    }

    @Test func restoreStringWhenEmpty() throws {
      let store = makeStore()
      let restored = try store.restoreString()
      #expect(restored == nil)
    }

    @Test func saveStringOverwritesPrevious() throws {
      let store = makeStore()
      defer { store.clear() }

      try store.saveString("key-1")
      try store.saveString("key-2")
      let restored = try store.restoreString()
      #expect(restored == "key-2")
    }

    @Test func clearRemovesString() throws {
      let store = makeStore()
      try store.saveString("key")
      store.clear()
      let restored = try store.restoreString()
      #expect(restored == nil)
    }

    // MARK: - Data values

    @Test func saveAndRestoreData() throws {
      let store = makeStore()
      defer { store.clear() }

      let data = Data("hello".utf8)
      try store.saveData(data)
      let restored = try store.restoreData()
      #expect(restored == data)
    }

    @Test func restoreDataWhenEmpty() throws {
      let store = makeStore()
      let restored = try store.restoreData()
      #expect(restored == nil)
    }
  }

#endif
