// Backends/CloudKit/Sync/ProfileGRDBRepositories.swift

import Foundation
import GRDB

/// Bundle of the GRDB-backed repositories for the per-profile data
/// handler.
///
/// The dispatch tables in `ProfileDataSyncHandler+ApplyRemoteChanges` /
/// `+SystemFields` consult this bundle for record types that have moved
/// to GRDB and fall through to the SwiftData paths for everything else.
/// Every field is non-optional because in-memory tests, previews, and
/// production all build the GRDB repos eagerly during backend
/// construction.
///
/// **Sendable.** Plain `Sendable` synthesis. Every stored property is
/// `let` and itself `Sendable` — the GRDB repositories are
/// `final class … : @unchecked Sendable`, which satisfies the
/// `Sendable` protocol requirement. The struct has no escape hatches,
/// so the compiler derives `Sendable` automatically and no
/// `@unchecked` waiver is needed.
struct ProfileGRDBRepositories: Sendable {
  let csvImportProfiles: GRDBCSVImportProfileRepository
  let importRules: GRDBImportRuleRepository
  let instruments: GRDBInstrumentRegistryRepository
  let categories: GRDBCategoryRepository
  let accounts: GRDBAccountRepository
  let earmarks: GRDBEarmarkRepository
  let earmarkBudgetItems: GRDBEarmarkBudgetItemRepository
  let investmentValues: GRDBInvestmentRepository
  let transactions: GRDBTransactionRepository
  let transactionLegs: GRDBTransactionLegRepository
  /// Shared writer used by `ProfileDataSyncHandler.applyRemoteChanges` to
  /// open one outer `database.write { ... }` for the whole fetched-changes
  /// batch — saves + deletions across every per-record-type repo land in a
  /// single commit, so `databaseDidCommit` (and the UI `ValueObservation`
  /// re-fetches it drives) fires once. Every repository in this bundle
  /// must already be backed by this same writer; the apply path relies on
  /// that invariant to avoid nested or cross-queue writes. Issue #872.
  let database: any GRDB.DatabaseWriter
}

extension ProfileGRDBRepositories {
  /// Builds a bundle suitable for the sync apply path: every per-type
  /// repository targets `database`, hooks are no-ops, and the read-side
  /// `defaultInstrument` / `conversionService` parameters carry inert
  /// placeholders. The apply path writes Row objects via
  /// `applyRemoteChangesSync` and never invokes either placeholder; the
  /// session-side bundle owned by `CloudKitBackend` continues to carry
  /// real values for user-mutation paths.
  ///
  /// The `instrumentResolver` injected into each repository here is a fresh
  /// `PerProfileInstrumentMapResolver` that is likewise never invoked by the
  /// apply path: `applyRemoteChangesSync` writes raw Rows directly and never
  /// calls `instrumentMap()`. Do NOT rewire these resolvers to the shared
  /// registry without first auditing every apply-path caller — the apply path
  /// currently carries no observation and assumes the resolver is a no-op.
  static func makeForApply(database: any GRDB.DatabaseWriter) -> ProfileGRDBRepositories {
    // USD is a stable, locale-independent fiat that satisfies
    // `Instrument.fiat(code:)`'s `isoCurrencies` lookup. The choice is
    // arbitrary — only the type matters for the apply path.
    let placeholderInstrument = Instrument.fiat(code: "USD")
    return ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database),
      instruments: GRDBInstrumentRegistryRepository(database: database),
      categories: GRDBCategoryRepository(database: database),
      accounts: GRDBAccountRepository(
        database: database,
        instrumentResolver: PerProfileInstrumentMapResolver(database: database)),
      earmarks: GRDBEarmarkRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        instrumentResolver: PerProfileInstrumentMapResolver(database: database)),
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(database: database),
      investmentValues: GRDBInvestmentRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        instrumentResolver: PerProfileInstrumentMapResolver(database: database)),
      transactions: GRDBTransactionRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        conversionService: ApplyPathConversionService(),
        instrumentResolver: PerProfileInstrumentMapResolver(database: database)),
      transactionLegs: GRDBTransactionLegRepository(database: database),
      database: database)
  }
}

/// Placeholder `InstrumentConversionService` for the apply-path bundle.
/// Reachable only from `ProfileGRDBRepositories.makeForApply(database:)`;
/// every method throws `ConversionError.unsupportedConversion` because
/// the apply path never reads through the conversion service. If a
/// future code change starts invoking it from the apply path, the
/// error surfaces as a saveFailed result and the offending call site
/// is identifiable from the logs — preferable to silent zero-conversion.
private struct ApplyPathConversionService: InstrumentConversionService {
  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal {
    throw ConversionError.unsupportedConversion(from: from.id, to: to.id)
  }

  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount {
    throw ConversionError.unsupportedConversion(
      from: amount.instrument.id, to: instrument.id)
  }

  func convertResult(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> ConversionResult {
    throw ConversionError.unsupportedConversion(
      from: amount.instrument.id, to: instrument.id)
  }

  func invalidateCache(for instrument: Instrument) async {}

  // No-op observation stubs — the apply-path conversion service is
  // never observed (the apply path doesn't drive a UI store), so a
  // single tick on subscription and an empty error stream keep the
  // protocol satisfied without standing up a real GRDB observation.
  func observeRates() -> AsyncStream<Void> {
    AsyncStream { continuation in
      continuation.yield(())
      continuation.finish()
    }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
}
