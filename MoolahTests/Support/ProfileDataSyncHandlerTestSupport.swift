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

  /// `@Sendable` factory closure suitable for
  /// `SyncCoordinator.init(... fallbackGRDBRepositoriesFactory:)`. Each
  /// invocation builds a fresh in-memory `ProfileGRDBRepositories` so
  /// `SyncCoordinator` tests that drive `handlerForProfileZone` (directly
  /// or via `queueAllRecordsAfterImport` etc.) don't have to register a
  /// bundle for every profile they touch.
  static let inMemoryFallbackFactory: @Sendable (UUID) throws -> ProfileGRDBRepositories = { _ in
    let database = try ProfileDatabase.openInMemory()
    return Self.makeBundle(database: database, instrument: .defaultTestInstrument)
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
    let bundle = Self.makeBundle(database: database, instrument: .defaultTestInstrument)
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      modelContainer: container,
      grdbRepositories: bundle)
    return HandlerHarness(handler: handler, container: container, database: database)
  }

  /// Constructs a fully-populated `ProfileGRDBRepositories` bundle backed
  /// by the supplied `database`. All hooks are no-ops; tests that need
  /// to observe sync queueing should build their own bundle via the
  /// concrete repo constructors.
  static func makeBundle(
    database: any DatabaseWriter,
    instrument: Instrument
  ) -> ProfileGRDBRepositories {
    let conversionService = FixedConversionService(rates: [:])
    return ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database),
      instruments: GRDBInstrumentRegistryRepository(database: database),
      categories: GRDBCategoryRepository(database: database),
      accounts: GRDBAccountRepository(database: database),
      earmarks: GRDBEarmarkRepository(
        database: database, defaultInstrument: instrument),
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(database: database),
      investmentValues: GRDBInvestmentRepository(
        database: database, defaultInstrument: instrument),
      transactions: GRDBTransactionRepository(
        database: database,
        defaultInstrument: instrument,
        conversionService: conversionService),
      transactionLegs: GRDBTransactionLegRepository(database: database))
  }
}
