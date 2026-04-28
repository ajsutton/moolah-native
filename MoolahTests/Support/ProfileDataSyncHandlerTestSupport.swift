import CloudKit
import Foundation
import GRDB
import SwiftData

@testable import Moolah

enum ProfileDataSyncHandlerTestSupport {
  /// Bundle of references the tests need to retain so the in-memory
  /// resources (model container, GRDB queue) outlive the handler's use
  /// during the test.
  struct HandlerHarness {
    let handler: ProfileDataSyncHandler
    let container: ModelContainer
    let database: DatabaseQueue
  }

  @MainActor
  static func makeHandler() throws -> (ProfileDataSyncHandler, ModelContainer) {
    let result = try makeHandlerWithDatabase()
    return (result.handler, result.container)
  }

  /// Three-value variant for tests that need to verify GRDB-side state.
  /// The caller retains a reference to `database` so the in-memory queue
  /// outlives the test's repos.
  @MainActor
  static func makeHandlerWithDatabase() throws -> HandlerHarness {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let bundle = ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database))
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      modelContainer: container,
      grdbRepositories: bundle)
    return HandlerHarness(handler: handler, container: container, database: database)
  }
}
