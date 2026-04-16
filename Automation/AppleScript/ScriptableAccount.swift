#if os(macOS)
  import AppKit
  import Foundation

  /// AppleScript wrapper for an Account domain model.
  /// Data captured at construction time; all properties are nonisolated.
  @objc(ScriptableAccount)
  class ScriptableAccount: NSObject {
    private let _uniqueID: String
    private let _name: String
    private let _accountType: String
    private let _balance: Double
    private let _investmentValue: Double
    private let _isHidden: Bool
    private let _profileName: String

    @MainActor
    init(account: Account, profileName: String) {
      _uniqueID = account.id.uuidString
      _name = account.name
      _accountType = account.type.rawValue
      _balance = account.balance.doubleValue
      _investmentValue = account.investmentValue?.doubleValue ?? 0
      _isHidden = account.isHidden
      _profileName = profileName
      super.init()
    }

    @objc var uniqueID: String { _uniqueID }
    @objc var name: String { _name }
    @objc var accountType: String { _accountType }
    @objc var balance: Double { _balance }
    @objc var investmentValue: Double { _investmentValue }
    @objc var isHidden: Bool { _isHidden }

    // MARK: - Object Specifier

    override var objectSpecifier: NSScriptObjectSpecifier? {
      guard
        let appDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x6361_7070  // 'capp'
        )
      else {
        return nil
      }
      let profileSpecifier = NSNameSpecifier(
        containerClassDescription: appDescription,
        containerSpecifier: nil,
        key: "scriptableProfiles",
        name: _profileName
      )
      guard
        let profileDescription = NSScriptSuiteRegistry.shared().classDescription(
          withAppleEventCode: 0x5072_6F66  // 'Prof'
        )
      else {
        return nil
      }
      return NSNameSpecifier(
        containerClassDescription: profileDescription,
        containerSpecifier: profileSpecifier,
        key: "scriptableAccounts",
        name: _name
      )
    }
  }
#endif
