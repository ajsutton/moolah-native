import Foundation
import Security

/// Persists HTTP cookies in the system Keychain so sessions survive app relaunch.
///
/// Cookies are archived as a single Data blob keyed by a fixed service + account pair.
/// Thread-safe: all `SecItem*` functions are safe to call from any thread.
struct CookieKeychain: Sendable {
  private let service: String
  private let account: String

  init(
    service: String = Bundle.main.bundleIdentifier.map { $0 + ".cookies" } ?? "com.moolah.cookies",
    account: String = "session"
  ) {
    self.service = service
    self.account = account
  }

  /// Archives cookies and stores them in the Keychain. Overwrites any previous entry.
  func save(cookies: [HTTPCookie]) throws {
    let properties = cookies.compactMap(\.properties)
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: properties,
      requiringSecureCoding: true
    )

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    // Remove any existing item first — simpler than conditional update.
    SecItemDelete(query as CFDictionary)

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.saveFailed(status)
    }
  }

  /// Restores previously saved cookies, or returns `nil` if none are stored.
  func restore() throws -> [HTTPCookie]? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return nil }
      guard
        let propertyList = try NSKeyedUnarchiver.unarchivedObject(
          ofClasses: [
            NSArray.self, NSDictionary.self, NSString.self,
            NSNumber.self, NSDate.self,
          ],
          from: data
        ) as? [[HTTPCookiePropertyKey: Any]]
      else {
        return nil
      }
      return propertyList.compactMap { HTTPCookie(properties: $0) }
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError.readFailed(status)
    }
  }

  /// Removes stored cookies from the Keychain.
  func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

enum KeychainError: Error, Sendable {
  case saveFailed(OSStatus)
  case readFailed(OSStatus)
}
