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
}

extension ProfileGRDBRepositories {
  /// Builds a bundle suitable for the sync apply path: every per-type
  /// repository targets `database`, hooks are no-ops, and the read-side
  /// `defaultInstrument` / `conversionService` parameters carry inert
  /// placeholders. The apply path writes Row objects via
  /// `applyRemoteChangesSync` and never invokes either placeholder; the
  /// session-side bundle owned by `CloudKitBackend` continues to carry
  /// real values for user-mutation paths.
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
      accounts: GRDBAccountRepository(database: database),
      earmarks: GRDBEarmarkRepository(
        database: database, defaultInstrument: placeholderInstrument),
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(database: database),
      investmentValues: GRDBInvestmentRepository(
        database: database, defaultInstrument: placeholderInstrument),
      transactions: GRDBTransactionRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        conversionService: ApplyPathConversionService()),
      transactionLegs: GRDBTransactionLegRepository(database: database))
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
}
