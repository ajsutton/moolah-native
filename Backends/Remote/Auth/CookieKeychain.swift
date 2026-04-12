import Foundation
import Security

/// Persists HTTP cookies in the system Keychain so sessions survive app relaunch.
///
/// Thin wrapper around `KeychainStore` that handles cookie archiving/unarchiving.
struct CookieKeychain: Sendable {
  private let store: KeychainStore

  init(
    service: String = Bundle.main.bundleIdentifier.map { $0 + ".cookies" } ?? "com.moolah.cookies",
    account: String = "session"
  ) {
    self.store = KeychainStore(service: service, account: account, synchronizable: false)
  }

  func save(cookies: [HTTPCookie]) throws {
    let properties = cookies.compactMap(\.properties)
    let data = try NSKeyedArchiver.archivedData(
      withRootObject: properties,
      requiringSecureCoding: true
    )
    try store.saveData(data)
  }

  func restore() throws -> [HTTPCookie]? {
    guard let data = try store.restoreData() else { return nil }
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
  }

  func clear() {
    store.clear()
  }
}

enum KeychainError: Error, Sendable {
  case saveFailed(OSStatus)
  case readFailed(OSStatus)
}
