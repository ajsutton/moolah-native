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
    // Cache the harness on the container's user info so tests that
    // call `try saveAndMirror(context:)` can find the matching GRDB
    // queue without changing every test's signature. This is the
    // smallest mechanical change that lets the legacy SwiftData-seed
    // tests round-trip through the handler's GRDB-backed lookups.
    Self.harnessByContainer[ObjectIdentifier(result.container)] = result
    return (result.handler, result.container)
  }

  /// Returns the full handler harness (handler, container, GRDB queue).
  /// Use when the test needs to verify the GRDB-side state directly —
  /// the runtime now reads exclusively from `data.sqlite`, so any
  /// "after applyRemoteChanges" assertion against SwiftData is wrong.
  @MainActor
  static func makeHandlerAndDatabase() throws -> HandlerHarness {
    let result = try makeHandlerWithDatabase()
    Self.harnessByContainer[ObjectIdentifier(result.container)] = result
    return result
  }

  /// Tracks the GRDB queue paired with each `ModelContainer` returned
  /// from `makeHandler()`. Lookup runs on `@MainActor` because every
  /// caller (the test bodies) is `@MainActor`-isolated; no
  /// cross-thread access.
  @MainActor private static var harnessByContainer: [ObjectIdentifier: HandlerHarness] = [:]

  /// Saves the SwiftData context and mirrors every recently-inserted
  /// row into the paired GRDB queue. Tests built before the GRDB
  /// migration seed via the SwiftData context; the mirror keeps those
  /// seeds visible to the handler's GRDB-backed lookup paths.
  @MainActor
  static func saveAndMirror(context: ModelContext) throws {
    try context.save()
    let container = context.container
    guard let harness = harnessByContainer[ObjectIdentifier(container)] else { return }
    try mirrorContainerToDatabase(
      container: container, database: harness.database)
  }

  /// One-shot copy of every synced record type from the SwiftData
  /// container into the GRDB queue. Used by `saveAndMirror`. Mirrors
  /// the same record-type ordering the migrator uses (parents before
  /// children) so FK references resolve as the single transaction
  /// commits.
  @MainActor
  static func mirrorContainerToDatabase(
    container: ModelContainer, database: any DatabaseWriter
  ) throws {
    let context = ModelContext(container)
    let instruments = try context.fetch(FetchDescriptor<InstrumentRecord>())
    let categories = try context.fetch(FetchDescriptor<CategoryRecord>())
    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    let earmarks = try context.fetch(FetchDescriptor<EarmarkRecord>())
    let budgetItems = try context.fetch(FetchDescriptor<EarmarkBudgetItemRecord>())
    let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
    let legs = try context.fetch(FetchDescriptor<TransactionLegRecord>())
    let investmentValues = try context.fetch(FetchDescriptor<InvestmentValueRecord>())

    try database.write { database in
      for record in instruments {
        try Self.instrumentRow(from: record).upsert(database)
      }
      for record in categories {
        try CategoryRow(domain: record.toDomain()).upsert(database)
      }
      for record in accounts {
        try Self.accountRow(from: record).upsert(database)
      }
      for record in earmarks {
        try Self.earmarkRow(from: record).upsert(database)
      }
      for record in budgetItems {
        try Self.budgetItemRow(from: record).upsert(database)
      }
      for record in transactions {
        try Self.transactionRow(from: record).upsert(database)
      }
      for record in legs {
        try Self.legRow(from: record).upsert(database)
      }
      for record in investmentValues {
        try Self.investmentValueRow(from: record).upsert(database)
      }
    }
  }

  // MARK: - Per-record Row builders
  //
  // The CloudKit `*Record.toDomain()` shapes don't all line up exactly
  // with the GRDB `Row.init(domain:)` initialisers. These shims read
  // raw fields off the SwiftData record and build the corresponding
  // row directly so the mirror doesn't need to invent legs / position
  // lists / instruments to round-trip through the domain.

  private static func instrumentRow(from record: InstrumentRecord) -> InstrumentRow {
    InstrumentRow(
      id: record.id,
      recordName: InstrumentRow.recordName(for: record.id),
      kind: record.kind,
      name: record.name,
      decimals: record.decimals,
      ticker: record.ticker,
      exchange: record.exchange,
      chainId: record.chainId,
      contractAddress: record.contractAddress,
      coingeckoId: record.coingeckoId,
      cryptocompareSymbol: record.cryptocompareSymbol,
      binanceSymbol: record.binanceSymbol,
      encodedSystemFields: record.encodedSystemFields)
  }

  private static func accountRow(from record: AccountRecord) -> AccountRow {
    AccountRow(
      id: record.id,
      recordName: AccountRow.recordName(for: record.id),
      name: record.name,
      type: record.type,
      instrumentId: record.instrumentId,
      position: record.position,
      isHidden: record.isHidden,
      encodedSystemFields: record.encodedSystemFields)
  }

  private static func earmarkRow(from record: EarmarkRecord) -> EarmarkRow {
    EarmarkRow(
      id: record.id,
      recordName: EarmarkRow.recordName(for: record.id),
      name: record.name,
      position: record.position,
      isHidden: record.isHidden,
      instrumentId: record.instrumentId,
      savingsTarget: record.savingsTarget,
      savingsTargetInstrumentId: record.savingsTargetInstrumentId,
      savingsStartDate: record.savingsStartDate,
      savingsEndDate: record.savingsEndDate,
      encodedSystemFields: record.encodedSystemFields)
  }

  private static func budgetItemRow(
    from record: EarmarkBudgetItemRecord
  ) -> EarmarkBudgetItemRow {
    EarmarkBudgetItemRow(
      id: record.id,
      recordName: EarmarkBudgetItemRow.recordName(for: record.id),
      earmarkId: record.earmarkId,
      categoryId: record.categoryId,
      amount: record.amount,
      instrumentId: record.instrumentId,
      encodedSystemFields: record.encodedSystemFields)
  }

  private static func transactionRow(from record: TransactionRecord) -> TransactionRow {
    TransactionRow(
      id: record.id,
      recordName: TransactionRow.recordName(for: record.id),
      date: record.date,
      payee: record.payee,
      notes: record.notes,
      recurPeriod: record.recurPeriod,
      recurEvery: record.recurEvery,
      importOriginRawDescription: record.importOriginRawDescription,
      importOriginBankReference: record.importOriginBankReference,
      importOriginRawAmount: record.importOriginRawAmount,
      importOriginRawBalance: record.importOriginRawBalance,
      importOriginImportedAt: record.importOriginImportedAt,
      importOriginImportSessionId: record.importOriginImportSessionId,
      importOriginSourceFilename: record.importOriginSourceFilename,
      importOriginParserIdentifier: record.importOriginParserIdentifier,
      encodedSystemFields: record.encodedSystemFields)
  }

  private static func legRow(from record: TransactionLegRecord) -> TransactionLegRow {
    TransactionLegRow(
      id: record.id,
      recordName: TransactionLegRow.recordName(for: record.id),
      transactionId: record.transactionId,
      accountId: record.accountId,
      instrumentId: record.instrumentId,
      quantity: record.quantity,
      type: record.type,
      categoryId: record.categoryId,
      earmarkId: record.earmarkId,
      sortOrder: record.sortOrder,
      encodedSystemFields: record.encodedSystemFields)
  }

  private static func investmentValueRow(
    from record: InvestmentValueRecord
  ) -> InvestmentValueRow {
    InvestmentValueRow(
      id: record.id,
      recordName: InvestmentValueRow.recordName(for: record.id),
      accountId: record.accountId,
      date: record.date,
      value: record.value,
      instrumentId: record.instrumentId,
      encodedSystemFields: record.encodedSystemFields)
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

  /// Builds a fallback factory that resolves each profile's GRDB
  /// repositories against the queue cached on the supplied
  /// `ProfileContainerManager`. Use this from `SyncCoordinator` tests
  /// that seed the manager's per-profile container and expect those
  /// rows to surface through the coordinator's handler. Pairs with
  /// `mirrorContainerToDatabase` so legacy SwiftData seeds round-trip
  /// to GRDB.
  @MainActor
  static func managerBackedFallbackFactory(
    manager: ProfileContainerManager
  ) -> @Sendable (UUID) throws -> ProfileGRDBRepositories {
    // The manager itself is `@MainActor`-isolated, so the closure must
    // re-enter the main actor to ask for the queue. `MainActor.assumeIsolated`
    // is safe here because tests that drive the factory route through
    // SyncCoordinator methods that themselves run on the main actor.
    { profileId in
      try MainActor.assumeIsolated {
        let database = try manager.database(for: profileId)
        let container = try manager.container(for: profileId)
        try Self.mirrorContainerToDatabase(
          container: container, database: database)
        return Self.makeBundle(database: database, instrument: .defaultTestInstrument)
      }
    }
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
