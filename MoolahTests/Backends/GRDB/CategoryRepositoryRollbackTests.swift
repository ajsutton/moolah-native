// MoolahTests/Backends/GRDB/CategoryRepositoryRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract tests for `GRDBCategoryRepository.delete(id:withReplacement:)`
/// — split out of `CoreFinancialGraphRollbackTests` so each file stays
/// under SwiftLint's `file_length` ceiling. The repository's delete path
/// touches three tables (categories, transaction legs, budget items)
/// inside a single write transaction; these tests force a mid-write
/// failure and assert the prior state survives byte-equal.
@Suite("Category repository rollback contracts")
@MainActor
struct CategoryRepositoryRollbackTests {

  // MARK: - GRDBCategoryRepository.delete(id:withReplacement:)

  /// Identifiers seeded ahead of `categoryDeleteRollsBackOnFailure` and
  /// re-checked after the failed delete to assert nothing torn through.
  private struct CategoryDeleteFixtureIds {
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let txnId = UUID()
    let legId = UUID()
    let budgetItemId = UUID()
  }

  /// Seeds the parent rows + leg + budget item that reference the
  /// category, then installs the BEFORE-DELETE trigger on
  /// `earmark_budget_item` so the production delete path's
  /// budget-item DELETE step throws.
  ///
  /// The category's delete path UPDATEs the leg (category_id → NULL),
  /// DELETEs the budget item, then DELETEs the category. A failing
  /// trigger on the budget-item DELETE must unwind the leg UPDATE along
  /// with the row removal.
  private func seedCategoryDeleteFixture(
    in database: any DatabaseWriter,
    ids: CategoryDeleteFixtureIds
  ) async throws {
    let category = Moolah.Category(id: ids.categoryId, name: "Food")
    try await database.write { database in
      try Self.insertCategoryDeleteParents(database: database, ids: ids, category: category)
      try Self.insertCategoryDeleteTransaction(database: database, ids: ids)
      try database.execute(
        sql: """
          CREATE TRIGGER fail_category_delete_budget
          BEFORE DELETE ON earmark_budget_item
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }
  }

  nonisolated private static func insertCategoryDeleteParents(
    database: Database,
    ids: CategoryDeleteFixtureIds,
    category: Moolah.Category
  ) throws {
    try AccountRow(
      domain: Account(
        id: ids.accountId, name: "stub", type: .bank, instrument: .AUD)
    ).insert(database)
    try CategoryRow(domain: category).insert(database)
    try EarmarkRow(
      domain: Earmark(id: ids.earmarkId, name: "Trip", instrument: .AUD)
    ).insert(database)
    try EarmarkBudgetItemRow(
      domain: EarmarkBudgetItem(
        id: ids.budgetItemId, categoryId: ids.categoryId,
        amount: InstrumentAmount(quantity: 100, instrument: .AUD)),
      earmarkId: ids.earmarkId
    ).insert(database)
  }

  nonisolated private static func insertCategoryDeleteTransaction(
    database: Database,
    ids: CategoryDeleteFixtureIds
  ) throws {
    try TransactionRow(
      id: ids.txnId,
      recordName: TransactionRow.recordName(for: ids.txnId),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil
    ).insert(database)
    try TransactionLegRow(
      id: ids.legId,
      recordName: TransactionLegRow.recordName(for: ids.legId),
      transactionId: ids.txnId,
      accountId: ids.accountId,
      instrumentId: Instrument.AUD.id,
      quantity: -1000,
      type: TransactionType.expense.rawValue,
      categoryId: ids.categoryId,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil
    ).insert(database)
  }

  @Test
  func categoryDeleteRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let categoryRepo = GRDBCategoryRepository(database: database)
    let ids = CategoryDeleteFixtureIds()
    try await seedCategoryDeleteFixture(in: database, ids: ids)

    do {
      try await categoryRepo.delete(id: ids.categoryId, withReplacement: nil)
      Issue.record("delete should have thrown but did not")
    } catch {
      // Expected.
    }

    // Category survives, leg keeps its category_id, budget item still
    // references the category — the entire transaction rolled back.
    try await database.read { database in
      let surviving = try CategoryRow.filter(CategoryRow.Columns.id == ids.categoryId)
        .fetchOne(database)
      #expect(surviving != nil)
      let leg = try #require(
        try TransactionLegRow.filter(TransactionLegRow.Columns.id == ids.legId)
          .fetchOne(database))
      #expect(leg.categoryId == ids.categoryId)
      let budgetItem =
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.id == ids.budgetItemId)
        .fetchOne(database)
      #expect(budgetItem != nil)
    }
  }

  @Test
  func categoryDeleteWithReplacementRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let categoryRepo = GRDBCategoryRepository(database: database)
    let ids = CategoryDeleteFixtureIds()
    try await seedCategoryDeleteFixture(in: database, ids: ids)

    // The shared fixture installs a BEFORE-DELETE trigger which fires
    // for the no-replacement path. The replacement path UPDATEs the
    // budget row instead, so we need a BEFORE-UPDATE trigger to force a
    // mid-write failure here.
    try await database.write { database in
      try database.execute(sql: "DROP TRIGGER fail_category_delete_budget")
      try database.execute(
        sql: """
          CREATE TRIGGER fail_category_delete_budget_update
          BEFORE UPDATE ON earmark_budget_item
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Seed a replacement category that the failing delete would reroute
    // legs/budgets to. The replacement must still exist after the
    // rollback, and the leg/budget rows must still reference the
    // pre-delete category (not the replacement).
    let replacementId = UUID()
    try await database.write { database in
      try CategoryRow(
        domain: Moolah.Category(id: replacementId, name: "Travel")
      ).insert(database)
    }

    do {
      try await categoryRepo.delete(id: ids.categoryId, withReplacement: replacementId)
      Issue.record("delete should have thrown but did not")
    } catch {
      // Expected.
    }

    // Category, replacement, leg, and budget item all survive byte-equal:
    // the failing transaction rolled back the leg-reassign and any
    // partial budget mutation.
    try await database.read { database in
      let surviving = try CategoryRow.filter(CategoryRow.Columns.id == ids.categoryId)
        .fetchOne(database)
      #expect(surviving != nil)
      let replacement = try CategoryRow.filter(CategoryRow.Columns.id == replacementId)
        .fetchOne(database)
      #expect(replacement != nil)
      let leg = try #require(
        try TransactionLegRow.filter(TransactionLegRow.Columns.id == ids.legId)
          .fetchOne(database))
      #expect(leg.categoryId == ids.categoryId)
      let budgetItem = try #require(
        try EarmarkBudgetItemRow
          .filter(EarmarkBudgetItemRow.Columns.id == ids.budgetItemId)
          .fetchOne(database))
      #expect(budgetItem.categoryId == ids.categoryId)
    }
  }
}
