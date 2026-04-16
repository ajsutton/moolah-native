#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CreateCategoryCommand")

  /// Handles: `create category profile "X" name "Groceries" parent "Food"`
  class CreateCategoryCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }
      guard let args = evaluatedArguments,
        let name = args["name"] as? String
      else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing required parameter: name"
        return nil
      }

      let parentName = args["parent"] as? String
      let profName = profileName

      return runBlockingWithError { @MainActor in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let category = try await service.createCategory(
          profileIdentifier: profName,
          name: name,
          parentName: parentName
        )
        let session = try service.resolveSession(for: profName)
        let parentDisplay: String
        if let parentId = category.parentId,
          let parent = session.categoryStore.categories.by(id: parentId)
        {
          parentDisplay = parent.name
        } else {
          parentDisplay = ""
        }
        return ScriptableCategory(
          category: category, parentName: parentDisplay, profileName: profName)
      }
    }
  }
#endif
