// MoolahTests/Backends/GRDB/GRDBCategorySyncCascadeTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBCategoryRepository sync delete cascades")
struct GRDBCategorySyncCascadeTests {
  private struct CategoryFixture {
    let categoryId: UUID
    let childCategoryId: UUID
    let earmarkId: UUID
    let budgetId: UUID
    let txId: UUID
    let legId: UUID
  }

  /// `applyRemoteChangesSync(saved: [], deleted: [categoryId])` must null
  /// `transaction_leg.category_id` references, delete
  /// `earmark_budget_item` rows for that category, and orphan child
  /// categories (set their `parent_id` to NULL) — replacing the v3 FKs
  /// dropped in v5.
  @Test
  func categorySyncDeleteNullsLegAndBudgetReferences() async throws {
    let database = try ProfileDatabase.openInMemory()
    let categoryRepo = GRDBCategoryRepository(database: database)
    let fixture = CategoryFixture(
      categoryId: UUID(),
      childCategoryId: UUID(),
      earmarkId: UUID(),
      budgetId: UUID(),
      txId: UUID(),
      legId: UUID())

    try await seedCategoryFixture(fixture, in: database)

    try categoryRepo.applyRemoteChangesSync(saved: [], deleted: [fixture.categoryId])

    try await database.read { database in
      let nulledLeg =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND category_id IS NULL",
          arguments: [fixture.legId]) ?? -1
      #expect(nulledLeg == 1)

      let remainingBudgets =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM earmark_budget_item WHERE category_id = ?",
          arguments: [fixture.categoryId]) ?? -1
      #expect(remainingBudgets == 0)

      let orphanedChild =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM category WHERE id = ? AND parent_id IS NULL",
          arguments: [fixture.childCategoryId]) ?? -1
      #expect(orphanedChild == 1)
    }
  }

  // MARK: - Helpers

  private func seedCategoryFixture(
    _ fixture: CategoryFixture,
    in database: any DatabaseWriter
  ) async throws {
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO instrument (id, record_name, kind, name, decimals)
            VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
          INSERT INTO category (id, record_name, name) VALUES (?, 'cat-1', 'Food');
          INSERT INTO category (id, record_name, name, parent_id)
            VALUES (?, 'cat-2', 'Restaurants', ?);
          INSERT INTO earmark (id, record_name, name, position, is_hidden)
            VALUES (?, 'earmark-1', 'Holiday', 0, 0);
          INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id)
            VALUES (?, 'budget-1', ?, ?, 5000, 'USD');
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, category_id, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', ?, 0);
          """,
        arguments: [
          fixture.categoryId,
          fixture.childCategoryId, fixture.categoryId,
          fixture.earmarkId,
          fixture.budgetId, fixture.earmarkId, fixture.categoryId,
          fixture.txId,
          fixture.legId, fixture.txId, fixture.categoryId,
        ])
    }
  }
}
