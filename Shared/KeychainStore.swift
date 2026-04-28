import Foundation
import Security

enum KeychainError: Error {
  case saveFailed(OSStatus)
  case readFailed(OSStatus)
}

/// Generic Keychain wrapper supporting Data and String values, with optional iCloud sync.
///
/// Used for API keys (String, synced) and cookies (Data, device-local).
struct KeychainStore: Sendable {
  let service: String
  let account: String
  let synchronizable: Bool

  init(service: String, account: String, synchronizable: Bool = false) {
    self.service = service
    self.account = account
    self.synchronizable = synchronizable
  }

  // MARK: - Data

  func saveData(_ data: Data) throws {
    let query = baseQuery()
    SecItemDelete(query as CFDictionary)

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.saveFailed(status)
    }
  }

  func restoreData() throws -> Data? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
      return result as? Data
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError.readFailed(status)
    }
  }

  // MARK: - String

  func saveString(_ value: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainError.saveFailed(errSecParam)
    }
    try saveData(data)
  }

  func restoreString() throws -> String? {
    guard let data = try restoreData() else { return nil }
    return String(data: data, encoding: .utf8)
  }

  // MARK: - Clear

  func clear() {
    let query = baseQuery()
    SecItemDelete(query as CFDictionary)
  }

  // MARK: - Private

  private func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if synchronizable {
      query[kSecAttrSynchronizable as String] = true
    }
    return query
  }
}
