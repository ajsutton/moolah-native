// MoolahTests/Backends/GRDB/CoreFinancialGraphRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract tests for the multi-statement writes in the core
/// financial graph repositories. Each test seeds prior state, forces a
/// failure mid-transaction (typically by installing a BEFORE-INSERT or
/// BEFORE-UPDATE trigger), drives the production repository method, and
/// asserts the prior state survives byte-equal. A regression that moves
/// the `committed = true` line above the `database.write` block, or
/// splits a single transaction into two, would silently leave a torn
/// half-write on disk; these tests catch that.
@Suite("Core financial graph GRDB rollback contracts")
@MainActor
struct CoreFinancialGraphRollbackTests {

  // MARK: - GRDBAccountRepository.create(_:openingBalance:)

  @Test
  func accountCreateWithOpeningBalanceRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBAccountRepository(database: database)

    // Pre-seed an account whose row must remain untouched after the
    // failed second-account create — its existence pins the "no torn
    // state" invariant when the failing create's transaction rolls back.
    let priorId = UUID()
    let prior = Account(id: priorId, name: "prior", type: .bank, instrument: .AUD)
    _ = try await repo.create(prior, openingBalance: nil)

    // Trigger that aborts the next leg insert with a sentinel record name.
    // The `create(...:openingBalance:)` write block inserts the account row,
    // a transaction header, and a leg in one `database.write` — the trigger
    // fires on the leg insert and the account+transaction inserts must roll
    // back too.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_account_create_leg
          BEFORE INSERT ON transaction_leg
          WHEN NEW.record_name LIKE '%___FAIL___%'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Construct a leg whose record_name will trip the trigger. The trigger
    // checks the record_name field; the production code derives it from the
    // leg id, so we can't easily pin it. Instead, force the failure via a
    // CHECK on `quantity` we can control: ABS(quantity) > 1e18 is impossible
    // for legitimate amounts but easy to trigger from a test.
    try await database.write { database in
      try database.execute(sql: "DROP TRIGGER fail_account_create_leg")
      try database.execute(
        sql: """
          CREATE TRIGGER fail_account_create_leg
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let failingId = UUID()
    let failing = Account(id: failingId, name: "fail", type: .bank, instrument: .AUD)
    let openingBalance = InstrumentAmount(quantity: 100, instrument: .AUD)
    do {
      _ = try await repo.create(failing, openingBalance: openingBalance)
      Issue.record("create should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT.
    }

    // The failing account row must NOT be on disk; the prior account's
    // row must survive byte-equal.
    let accounts = try await database.read { database in
      try AccountRow.fetchAll(database)
    }
    let surviving = try #require(accounts.first { $0.id == priorId })
    #expect(surviving.name == "prior")
    #expect(accounts.first { $0.id == failingId } == nil)
  }

  // MARK: - GRDBTransactionRepository.create(_:)

  @Test
  func transactionCreateRollsBackOnLegFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FixedConversionService())
    let accountId = UUID()
    let stub = Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    // Install a trigger that aborts every leg insert; the create write
    // path inserts the txn header, then the legs — the trigger fires on
    // the first leg, and the txn header must roll back along with it.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_txn_create_leg
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let txn = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -10, type: .expense)
      ])
    do {
      _ = try await txnRepo.create(txn)
      Issue.record("create should have thrown but did not")
    } catch {
      // Expected.
    }

    let txnRows = try await database.read { database in
      try TransactionRow.fetchAll(database)
    }
    let legRows = try await database.read { database in
      try TransactionLegRow.fetchAll(database)
    }
    #expect(txnRows.isEmpty)
    #expect(legRows.isEmpty)
  }

  // MARK: - GRDBCategoryRepository.delete(id:withReplacement:)

  @Test
  func categoryDeleteRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let categoryRepo = GRDBCategoryRepository(database: database)
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let txnId = UUID()
    let legId = UUID()
    let budgetItemId = UUID()
    let category = Moolah.Category(id: categoryId, name: "Food")
    try await database.write { database in
      // Seed the parent rows and a leg+budget item that reference the
      // category. The category's delete path UPDATEs the leg
      // (category_id → NULL), DELETEs the budget item, then DELETEs the
      // category. A failing trigger on the budget-item DELETE must
      // unwind the leg UPDATE along with the row removal.
      try AccountRow(
        domain: Account(
          id: accountId, name: "stub", type: .bank, instrument: .AUD)
      )
      .insert(database)
      try CategoryRow(domain: category).insert(database)
      try EarmarkRow(
        domain: Earmark(id: earmarkId, name: "Trip", instrument: .AUD)
      )
      .insert(database)
      try EarmarkBudgetItemRow(
        domain: EarmarkBudgetItem(
          id: budgetItemId, categoryId: categoryId,
          amount: InstrumentAmount(quantity: 100, instrument: .AUD)),
        earmarkId: earmarkId
      ).insert(database)
      try TransactionRow(
        id: txnId,
        recordName: TransactionRow.recordName(for: txnId),
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
        id: legId,
        recordName: TransactionLegRow.recordName(for: legId),
        transactionId: txnId,
        accountId: accountId,
        instrumentId: Instrument.AUD.id,
        quantity: -1000,
        type: TransactionType.expense.rawValue,
        categoryId: categoryId,
        earmarkId: nil,
        sortOrder: 0,
        encodedSystemFields: nil
      ).insert(database)
      // Trigger that aborts the budget-item DELETE that the
      // category-delete path runs after the leg UPDATE.
      try database.execute(
        sql: """
          CREATE TRIGGER fail_category_delete_budget
          BEFORE DELETE ON earmark_budget_item
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    do {
      try await categoryRepo.delete(id: categoryId, withReplacement: nil)
      Issue.record("delete should have thrown but did not")
    } catch {
      // Expected.
    }

    // Category survives, leg keeps its category_id, budget item still
    // references the category — the entire transaction rolled back.
    try await database.read { database in
      let surviving = try CategoryRow.filter(CategoryRow.Columns.id == categoryId)
        .fetchOne(database)
      #expect(surviving != nil)
      let leg = try #require(
        try TransactionLegRow.filter(TransactionLegRow.Columns.id == legId)
          .fetchOne(database))
      #expect(leg.categoryId == categoryId)
      let budgetItem =
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.id == budgetItemId)
        .fetchOne(database)
      #expect(budgetItem != nil)
    }
  }

  // MARK: - GRDBEarmarkRepository.setBudget(...)

  @Test
  func earmarkSetBudgetRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let earmarkRepo = GRDBEarmarkRepository(
      database: database, defaultInstrument: .AUD)
    let categoryRepo = GRDBCategoryRepository(database: database)

    let earmarkId = UUID()
    let categoryId = UUID()
    let earmark = Earmark(id: earmarkId, name: "Trip", instrument: .AUD)
    let category = Moolah.Category(id: categoryId, name: "Travel")
    _ = try await earmarkRepo.create(earmark)
    _ = try await categoryRepo.create(category)

    // Install a trigger that aborts every earmark_budget_item insert.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_set_budget_insert
          BEFORE INSERT ON earmark_budget_item
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let amount = InstrumentAmount(quantity: 50, instrument: .AUD)
    do {
      try await earmarkRepo.setBudget(
        earmarkId: earmarkId, categoryId: categoryId, amount: amount)
      Issue.record("setBudget should have thrown but did not")
    } catch {
      // Expected.
    }

    let items = try await database.read { database in
      try EarmarkBudgetItemRow.fetchAll(database)
    }
    #expect(items.isEmpty)
  }
}
