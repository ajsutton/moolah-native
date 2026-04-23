import Foundation
import SwiftData
import Testing

@testable import Moolah

private let testAccountId = UUID()

private func makeTxn(
  id: UUID = UUID(),
  date: Date = Date(),
  accountId: UUID = testAccountId,
  quantity: Decimal = 0,
  type: TransactionType = .expense,
  payee: String? = nil,
  categoryId: UUID? = nil,
  earmarkId: UUID? = nil,
  recurPeriod: RecurPeriod? = nil,
  recurEvery: Int? = nil
) -> Transaction {
  Transaction(
    id: id,
    date: date,
    payee: payee,
    recurPeriod: recurPeriod,
    recurEvery: recurEvery,
    legs: [
      TransactionLeg(
        accountId: accountId, instrument: .defaultTestInstrument,
        quantity: quantity, type: type,
        categoryId: categoryId, earmarkId: earmarkId
      )
    ]
  )
}

@Suite("Scheduled Transactions — Part 2")
struct ScheduledTransactionTestsMore {
  @Test("nextDueDate calculates weekly recurrence")
  func testNextDueDateWeekly() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    let transaction = makeTxn(date: startDate, recurPeriod: .week, recurEvery: 2)

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 29))!
    #expect(nextDate.isSameDay(as: expectedDate))
  }

  @Test("nextDueDate calculates monthly recurrence")
  func testNextDueDateMonthly() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    let transaction = makeTxn(date: startDate, recurPeriod: .month, recurEvery: 1)

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 15))!
    #expect(nextDate.isSameDay(as: expectedDate))
  }

  @Test("nextDueDate calculates yearly recurrence")
  func testNextDueDateYearly() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    let transaction = makeTxn(date: startDate, recurPeriod: .year, recurEvery: 1)

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15))!
    #expect(nextDate.isSameDay(as: expectedDate))
  }

  @Test("isRecurring distinguishes between once and recurring")
  func testIsRecurring() {
    let once = makeTxn(recurPeriod: .once, recurEvery: 1)
    let recurring = makeTxn(recurPeriod: .month, recurEvery: 1)
    let notScheduled = makeTxn()

    #expect(once.isRecurring == false)
    #expect(recurring.isRecurring == true)
    #expect(notScheduled.isRecurring == false)
  }

  @Test("Pay action for one-time scheduled transaction")
  func testPayOneTimeScheduled() async throws {
    let calendar = Calendar.current
    let futureDate = calendar.date(byAdding: .day, value: 7, to: Date())!
    let accountId = UUID()

    let scheduled = makeTxn(
      date: futureDate,
      accountId: accountId,
      quantity: Decimal(string: "-500.00")!,
      payee: "One-time payment",
      recurPeriod: .once,
      recurEvery: 1
    )

    let (backend, container) = try TestBackend.create()
    _ = TestBackend.seed(transactions: [scheduled], in: container)

    // Verify it exists and is scheduled
    let page1 = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(page1.transactions.count == 1)

    // Create paid transaction (simulating the pay action)
    let paid = Transaction(
      date: Date(),
      payee: scheduled.payee,
      legs: scheduled.legs
    )
    _ = try await backend.transactions.create(paid)

    // For .once, the scheduled transaction should be deleted
    try await backend.transactions.delete(id: scheduled.id)

    // Verify the scheduled transaction is gone
    let page2 = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(page2.transactions.isEmpty)

    // Verify the paid transaction exists
    let page3 = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: false), page: 0, pageSize: 50)
    #expect(page3.transactions.count == 1)
    #expect(page3.transactions[0].isScheduled == false)
  }

  @Test("Pay action for recurring scheduled transaction")
  func testPayRecurringScheduled() async throws {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    let accountId = UUID()

    let scheduled = makeTxn(
      date: startDate,
      accountId: accountId,
      quantity: Decimal(string: "-1500.00")!,
      payee: "Monthly rent",
      recurPeriod: .month,
      recurEvery: 1
    )

    let (backend, container) = try TestBackend.create()
    _ = TestBackend.seed(transactions: [scheduled], in: container)

    // Create paid transaction
    let paid = Transaction(
      date: Date(),
      payee: scheduled.payee,
      legs: scheduled.legs
    )
    _ = try await backend.transactions.create(paid)

    // For recurring, update the scheduled transaction's date to next occurrence
    guard let nextDate = scheduled.nextDueDate() else {
      fatalError("nextDueDate should not be nil for recurring transaction")
    }

    var updated = scheduled
    updated.date = nextDate
    _ = try await backend.transactions.update(updated)

    // Verify the scheduled transaction still exists with updated date
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(page.transactions.count == 1)
    #expect(page.transactions[0].isScheduled == true)

    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
    #expect(page.transactions[0].date.isSameDay(as: expectedDate))
  }

  @Test("Validation passes for valid transactions")
  func testValidationPassesForValid() throws {
    let normal = makeTxn()
    try normal.validate()

    let scheduled = makeTxn(recurPeriod: .month, recurEvery: 1)
    try scheduled.validate()
  }

  @Test("Validation fails when only period is set")
  func testValidationFailsWithOnlyPeriod() {
    let transaction = makeTxn(recurPeriod: .month, recurEvery: nil)
    #expect(throws: Transaction.ValidationError.incompleteRecurrence) {
      try transaction.validate()
    }
  }

  @Test("Validation fails when only every is set")
  func testValidationFailsWithOnlyEvery() {
    let transaction = makeTxn(recurPeriod: nil, recurEvery: 1)
    #expect(throws: Transaction.ValidationError.incompleteRecurrence) {
      try transaction.validate()
    }
  }

  @Test("Validation fails when recurEvery is less than 1")
  func testValidationFailsWithInvalidEvery() {
    let transaction = makeTxn(recurPeriod: .month, recurEvery: 0)
    #expect(throws: Transaction.ValidationError.invalidRecurEvery) {
      try transaction.validate()
    }
  }
}
