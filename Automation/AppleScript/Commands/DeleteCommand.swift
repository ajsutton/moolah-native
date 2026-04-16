#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "DeleteCommand")

  /// Handles: `delete account "Checking" of profile "X"`
  /// Works for accounts, transactions, earmarks, and categories.
  class DeleteCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing object specifier for delete"
        return nil
      }

      // Walk up the specifier chain to find the profile name
      let profileName: String
      let objectKey = specifier.key
      let container = specifier.container

      // The specifier should be: object of profile "X"
      if let nameSpec = container as? NSNameSpecifier {
        profileName = nameSpec.name
      } else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot determine profile for delete operation"
        return nil
      }

      // Determine what we're deleting based on the key
      let objectName: String?
      let objectID: String?

      if let nameSpec = specifier as? NSNameSpecifier {
        objectName = nameSpec.name
        objectID = nil
      } else if let idSpec = specifier as? NSUniqueIDSpecifier {
        objectName = nil
        objectID = idSpec.uniqueID as? String
      } else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot identify object to delete"
        return nil
      }

      let result: Bool? = runBlockingWithError { @MainActor () async throws -> Bool in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }

        switch objectKey {
        case "scriptableAccounts":
          let account: Account
          if let objectName {
            account = try service.resolveAccount(named: objectName, profileIdentifier: profileName)
          } else if let objectID, let uuid = UUID(uuidString: objectID) {
            account = try service.resolveAccount(id: uuid, profileIdentifier: profileName)
          } else {
            throw AutomationError.accountNotFound("unknown")
          }
          try await service.deleteAccount(profileIdentifier: profileName, accountId: account.id)

        case "scriptableTransactions":
          guard let objectID, let uuid = UUID(uuidString: objectID) else {
            throw AutomationError.transactionNotFound("unknown")
          }
          try await service.deleteTransaction(profileIdentifier: profileName, transactionId: uuid)

        case "scriptableEarmarks":
          let earmark: Earmark
          if let objectName {
            earmark = try service.resolveEarmark(named: objectName, profileIdentifier: profileName)
          } else {
            throw AutomationError.earmarkNotFound("unknown")
          }
          try await service.deleteEarmark(profileIdentifier: profileName, earmarkId: earmark.id)

        case "scriptableCategories":
          let category: Category
          if let objectName {
            category = try service.resolveCategory(
              named: objectName, profileIdentifier: profileName)
          } else {
            throw AutomationError.categoryNotFound("unknown")
          }
          try await service.deleteCategory(profileIdentifier: profileName, categoryId: category.id)

        default:
          throw AutomationError.operationFailed("Cannot delete objects of type '\(objectKey)'")
        }

        return true
      }
      return result
    }
  }
#endif
