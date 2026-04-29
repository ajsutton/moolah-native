// Backends/CloudKit/Sync/ProfileGRDBRepositories.swift

import Foundation

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
