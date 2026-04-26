import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Regression tests for the bug introduced in PR #416 where every CloudKit
/// repository's `onRecordChanged` / `onRecordDeleted` closure forced a single
/// `recordType` regardless of which kind of record the repository was
/// actually mutating. Repositories that mutate more than one record type
/// (legs, budget items, child categories, the txn+leg pair built from an
/// opening balance) emitted IDs that the wiring then mis-prefixed, so the
/// server-side `nextRecordZoneChangeBatch` lookup missed them and converted
/// the upload into a phantom delete.
///
/// The fix threads the `recordType` through the hook signature so each
/// emit names its own type. These tests pin that contract per repo so a
/// future signature regression breaks the build (and the wiring stays
/// honest about which type each id belongs to).
@Suite("Repository hooks emit (recordType, id) pairs")
@MainActor
struct RepositoryHookRecordTypeTests {

  // MARK: - Capture Helper

  /// Confined to `@MainActor` so the (non-Sendable) closures wired to the
  /// repository can append into the buffers without crossing actors.
  @MainActor
  final class HookCapture {
    var changed: [(recordType: String, id: UUID)] = []
    var deleted: [(recordType: String, id: UUID)] = []
  }

  // MARK: - TransactionRepository

  @Test("create(_:) emits one TransactionRecord and one TransactionLegRecord per leg")
  func transactionCreateEmitsLegRecordType() async throws {
    let repo = try makeContractCloudKitTransactionRepository()
    let capture = HookCapture()
    repo.onRecordChanged = { recordType, id in capture.changed.append((recordType, id)) }
    repo.onRecordDeleted = { recordType, id in capture.deleted.append((recordType, id)) }

    let accountId = UUID()
    let txn = Transaction(
      date: Date(), payee: "Trade",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
        makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
      ]
    )

    _ = try await repo.create(txn)

    let txnEmits = capture.changed.filter { $0.recordType == TransactionRecord.recordType }
    let legEmits = capture.changed.filter { $0.recordType == TransactionLegRecord.recordType }
    #expect(txnEmits.map(\.id) == [txn.id])
    #expect(legEmits.count == 2)
    #expect(capture.deleted.isEmpty)
    // Catch any future drift that emits a leg under the wrong type prefix.
    #expect(capture.changed.count == 3)
  }

  @Test("update(_:) emits leg-create and leg-delete events tagged with TransactionLegRecord")
  func transactionUpdateEmitsLegRecordType() async throws {
    let initialLeg = makeContractTestLeg(accountId: UUID(), quantity: -50, type: .expense)
    let original = Transaction(date: Date(), payee: "Coffee", legs: [initialLeg])
    let repo = try makeContractCloudKitTransactionRepository(initialTransactions: [original])

    let capture = HookCapture()
    repo.onRecordChanged = { recordType, id in capture.changed.append((recordType, id)) }
    repo.onRecordDeleted = { recordType, id in capture.deleted.append((recordType, id)) }

    var updated = original
    updated.legs = [makeContractTestLeg(accountId: UUID(), quantity: -75, type: .expense)]
    _ = try await repo.update(updated)

    let txnChanges = capture.changed.filter { $0.recordType == TransactionRecord.recordType }
    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRecord.recordType }
    let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRecord.recordType }
    #expect(txnChanges.map(\.id) == [original.id])
    #expect(legChanges.count == 1)
    #expect(legDeletes.count == 1)
  }

  @Test("delete(id:) emits TransactionRecord delete and TransactionLegRecord delete per leg")
  func transactionDeleteEmitsLegRecordType() async throws {
    let leg = makeContractTestLeg(accountId: UUID(), quantity: -50, type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    let repo = try makeContractCloudKitTransactionRepository(initialTransactions: [txn])

    let capture = HookCapture()
    repo.onRecordChanged = { recordType, id in capture.changed.append((recordType, id)) }
    repo.onRecordDeleted = { recordType, id in capture.deleted.append((recordType, id)) }

    try await repo.delete(id: txn.id)

    let txnDeletes = capture.deleted.filter { $0.recordType == TransactionRecord.recordType }
    let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRecord.recordType }
    #expect(txnDeletes.map(\.id) == [txn.id])
    #expect(legDeletes.count == 1)
    #expect(capture.changed.isEmpty)
  }

  // MARK: - AccountRepository

  @Test("create with opening balance tags account, txn, and leg with their own record types")
  func accountCreateOpeningBalanceTagsRecordTypes() async throws {
    let container = try TestModelContainer.create()
    let repo = CloudKitAccountRepository(modelContainer: container)
    let capture = HookCapture()
    repo.onRecordChanged = { recordType, id in capture.changed.append((recordType, id)) }
    repo.onRecordDeleted = { recordType, id in capture.deleted.append((recordType, id)) }

    let account = Account(name: "Cash", type: .bank, instrument: .defaultTestInstrument)
    _ = try await repo.create(
      account,
      openingBalance: InstrumentAmount(quantity: 100, instrument: .defaultTestInstrument))

    let accountEmits = capture.changed.filter { $0.recordType == AccountRecord.recordType }
    let txnEmits = capture.changed.filter { $0.recordType == TransactionRecord.recordType }
    let legEmits = capture.changed.filter { $0.recordType == TransactionLegRecord.recordType }
    #expect(accountEmits.map(\.id) == [account.id])
    #expect(txnEmits.count == 1)
    #expect(legEmits.count == 1)
    #expect(capture.changed.count == 3)
  }

  // MARK: - CategoryRepository

  @Test(
    "delete cascade tags legs as TransactionLegRecord and budget items as EarmarkBudgetItemRecord")
  func categoryDeleteCascadeTagsRecordTypes() async throws {
    let container = try TestModelContainer.create()

    let parentCategoryId = UUID()
    let childCategoryId = UUID()
    let earmarkId = UUID()
    let txnId = UUID()
    let legId = UUID()
    let budgetItemId = UUID()
    let instrumentId = "AUD"

    let context = ModelContext(container)
    context.insert(
      InstrumentRecord(
        id: instrumentId, kind: "fiatCurrency", name: "AUD", decimals: 2))
    context.insert(CategoryRecord(id: parentCategoryId, name: "Food", parentId: nil))
    context.insert(
      CategoryRecord(id: childCategoryId, name: "Groceries", parentId: parentCategoryId))
    context.insert(EarmarkRecord(id: earmarkId, name: "Holiday", instrumentId: instrumentId))
    context.insert(
      EarmarkBudgetItemRecord(
        id: budgetItemId, earmarkId: earmarkId, categoryId: parentCategoryId,
        amount: 100, instrumentId: instrumentId))
    context.insert(TransactionRecord(id: txnId, date: Date(), payee: "Lunch"))
    context.insert(
      TransactionLegRecord(
        id: legId, transactionId: txnId, accountId: UUID(),
        instrumentId: instrumentId, quantity: -10, type: "expense",
        categoryId: parentCategoryId, sortOrder: 0))
    try context.save()

    let repo = CloudKitCategoryRepository(modelContainer: container)
    let capture = HookCapture()
    repo.onRecordChanged = { recordType, id in capture.changed.append((recordType, id)) }
    repo.onRecordDeleted = { recordType, id in capture.deleted.append((recordType, id)) }

    // No replacement: legs lose their categoryId, budget item is deleted, child is orphaned.
    try await repo.delete(id: parentCategoryId, withReplacement: nil)

    let categoryDeletes = capture.deleted.filter { $0.recordType == CategoryRecord.recordType }
    let budgetDeletes = capture.deleted.filter {
      $0.recordType == EarmarkBudgetItemRecord.recordType
    }
    let categoryChanges = capture.changed.filter { $0.recordType == CategoryRecord.recordType }
    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRecord.recordType }

    #expect(categoryDeletes.map(\.id) == [parentCategoryId])
    #expect(budgetDeletes.map(\.id) == [budgetItemId])
    #expect(categoryChanges.map(\.id) == [childCategoryId])
    #expect(legChanges.map(\.id) == [legId])
  }

  // MARK: - EarmarkRepository

  @Test("setBudget tags emits with EarmarkBudgetItemRecord, not EarmarkRecord")
  func earmarkSetBudgetTagsBudgetItemRecord() async throws {
    let container = try TestModelContainer.create()
    let repo = CloudKitEarmarkRepository(
      modelContainer: container, instrument: .defaultTestInstrument)
    let earmark = try await repo.create(
      Earmark(name: "Holiday", instrument: .defaultTestInstrument))
    let capture = HookCapture()
    repo.onRecordChanged = { recordType, id in capture.changed.append((recordType, id)) }
    repo.onRecordDeleted = { recordType, id in capture.deleted.append((recordType, id)) }

    try await repo.setBudget(
      earmarkId: earmark.id,
      categoryId: UUID(),
      amount: InstrumentAmount(quantity: 50, instrument: .defaultTestInstrument))

    let earmarkEmits = capture.changed.filter { $0.recordType == EarmarkRecord.recordType }
    let budgetEmits = capture.changed.filter {
      $0.recordType == EarmarkBudgetItemRecord.recordType
    }
    #expect(earmarkEmits.isEmpty)
    #expect(budgetEmits.count == 1)
  }
}
