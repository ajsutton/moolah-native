import Foundation
import Testing

@testable import Moolah

@Suite("Scheduled Transactions")
struct ScheduledTransactionTests {
  @Test("isScheduled returns true when recurPeriod is set")
  func testIsScheduledWithRecurrence() {
    let transaction = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: 1
    )

    #expect(transaction.isScheduled == true)
  }

  @Test("isScheduled returns false when recurPeriod is nil")
  func testIsScheduledWithoutRecurrence() {
    let transaction = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero
    )

    #expect(transaction.isScheduled == false)
  }

  @Test("Creating paid copy removes recurrence fields")
  func testPayingScheduledTransactionCreatesNonScheduledCopy() {
    let scheduled = Transaction(
      type: .expense,
      date: Calendar.current.date(byAdding: .day, value: -5, to: Date())!,
      accountId: UUID(),
      amount: MonetaryAmount(cents: -100000, currency: Currency.defaultCurrency),
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1
    )

    // Simulate the "Pay" action
    let paid = Transaction(
      id: UUID(),
      type: scheduled.type,
      date: Date(),
      accountId: scheduled.accountId,
      toAccountId: scheduled.toAccountId,
      amount: scheduled.amount,
      payee: scheduled.payee,
      notes: scheduled.notes,
      categoryId: scheduled.categoryId,
      earmarkId: scheduled.earmarkId,
      recurPeriod: nil,
      recurEvery: nil
    )

    #expect(paid.id != scheduled.id)
    #expect(paid.recurPeriod == nil)
    #expect(paid.recurEvery == nil)
    #expect(paid.isScheduled == false)
    #expect(paid.payee == scheduled.payee)
    #expect(paid.amount == scheduled.amount)
  }

  @Test("Filter returns only scheduled transactions")
  func testFilterScheduledTransactions() async throws {
    let scheduled = Transaction(
      type: .expense,
      date: Date(),
      accountId: UUID(),
      amount: MonetaryAmount(cents: -100000, currency: Currency.defaultCurrency),
      recurPeriod: .month,
      recurEvery: 1
    )

    let oneTime = Transaction(
      type: .expense,
      date: Date(),
      accountId: UUID(),
      amount: MonetaryAmount(cents: -50000, currency: Currency.defaultCurrency)
    )

    let repository = InMemoryTransactionRepository(initialTransactions: [scheduled, oneTime])

    let page = try await repository.fetch(
      filter: TransactionFilter(scheduled: true),
      page: 0,
      pageSize: 50
    )

    #expect(page.transactions.count == 1)
    #expect(page.transactions[0].isScheduled == true)
  }

  @Test("Overdue classification")
  func testOverdueClassification() {
    let calendar = Calendar.current
    let today = Date()

    let overdue = Transaction(
      type: .expense,
      date: calendar.date(byAdding: .day, value: -5, to: today)!,
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: 1
    )

    let upcoming = Transaction(
      type: .expense,
      date: calendar.date(byAdding: .day, value: 5, to: today)!,
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: 1
    )

    #expect(overdue.date < today)
    #expect(upcoming.date > today)
  }

  @Test("Recurrence periods")
  func testRecurrencePeriods() {
    let daily = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: .day, recurEvery: 1
    )
    let weekly = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: .week, recurEvery: 2
    )
    let monthly = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: .month, recurEvery: 1
    )
    let yearly = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: .year, recurEvery: 1
    )

    #expect(daily.recurPeriod == .day)
    #expect(daily.recurEvery == 1)
    #expect(weekly.recurPeriod == .week)
    #expect(weekly.recurEvery == 2)
    #expect(monthly.recurPeriod == .month)
    #expect(yearly.recurPeriod == .year)
  }

  @Test("nextDueDate returns nil for non-recurring transactions")
  func testNextDueDateNonRecurring() {
    let oneTime = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero
    )

    #expect(oneTime.nextDueDate() == nil)

    let once = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: .once,
      recurEvery: 1
    )

    #expect(once.nextDueDate() == nil)
  }

  @Test("nextDueDate calculates daily recurrence")
  func testNextDueDateDaily() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!

    let transaction = Transaction(
      type: .expense,
      date: startDate,
      amount: MonetaryAmount.zero,
      recurPeriod: .day,
      recurEvery: 1
    )

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 16))!

    #expect(calendar.isDate(nextDate, inSameDayAs: expectedDate))
  }

  @Test("nextDueDate calculates weekly recurrence")
  func testNextDueDateWeekly() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!

    let transaction = Transaction(
      type: .expense,
      date: startDate,
      amount: MonetaryAmount.zero,
      recurPeriod: .week,
      recurEvery: 2
    )

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 29))!

    #expect(calendar.isDate(nextDate, inSameDayAs: expectedDate))
  }

  @Test("nextDueDate calculates monthly recurrence")
  func testNextDueDateMonthly() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!

    let transaction = Transaction(
      type: .expense,
      date: startDate,
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: 1
    )

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 15))!

    #expect(calendar.isDate(nextDate, inSameDayAs: expectedDate))
  }

  @Test("nextDueDate calculates yearly recurrence")
  func testNextDueDateYearly() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!

    let transaction = Transaction(
      type: .expense,
      date: startDate,
      amount: MonetaryAmount.zero,
      recurPeriod: .year,
      recurEvery: 1
    )

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15))!

    #expect(calendar.isDate(nextDate, inSameDayAs: expectedDate))
  }

  @Test("isRecurring distinguishes between once and recurring")
  func testIsRecurring() {
    let once = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: .once,
      recurEvery: 1
    )

    let recurring = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: 1
    )

    let notScheduled = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero
    )

    #expect(once.isRecurring == false)
    #expect(recurring.isRecurring == true)
    #expect(notScheduled.isRecurring == false)
  }

  @Test("Pay action for one-time scheduled transaction")
  func testPayOneTimeScheduled() async throws {
    let calendar = Calendar.current
    let futureDate = calendar.date(byAdding: .day, value: 7, to: Date())!

    let scheduled = Transaction(
      id: UUID(),
      type: .expense,
      date: futureDate,
      accountId: UUID(),
      amount: MonetaryAmount(cents: -50000, currency: Currency.defaultCurrency),
      payee: "One-time payment",
      recurPeriod: .once,
      recurEvery: 1
    )

    let repository = InMemoryTransactionRepository(initialTransactions: [scheduled])

    // Verify it exists and is scheduled
    let page1 = try await repository.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(page1.transactions.count == 1)

    // Create paid transaction (simulating the pay action)
    let paid = Transaction(
      id: UUID(),
      type: scheduled.type,
      date: Date(),
      accountId: scheduled.accountId,
      amount: scheduled.amount,
      payee: scheduled.payee,
      recurPeriod: nil,
      recurEvery: nil
    )
    _ = try await repository.create(paid)

    // For .once, the scheduled transaction should be deleted
    try await repository.delete(id: scheduled.id)

    // Verify the scheduled transaction is gone
    let page2 = try await repository.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(page2.transactions.count == 0)

    // Verify the paid transaction exists
    let page3 = try await repository.fetch(
      filter: TransactionFilter(scheduled: false), page: 0, pageSize: 50)
    #expect(page3.transactions.count == 1)
    #expect(page3.transactions[0].isScheduled == false)
  }

  @Test("Pay action for recurring scheduled transaction")
  func testPayRecurringScheduled() async throws {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!

    let scheduled = Transaction(
      id: UUID(),
      type: .expense,
      date: startDate,
      accountId: UUID(),
      amount: MonetaryAmount(cents: -150000, currency: Currency.defaultCurrency),
      payee: "Monthly rent",
      recurPeriod: .month,
      recurEvery: 1
    )

    let repository = InMemoryTransactionRepository(initialTransactions: [scheduled])

    // Create paid transaction
    let paid = Transaction(
      id: UUID(),
      type: scheduled.type,
      date: Date(),
      accountId: scheduled.accountId,
      amount: scheduled.amount,
      payee: scheduled.payee,
      recurPeriod: nil,
      recurEvery: nil
    )
    _ = try await repository.create(paid)

    // For recurring, update the scheduled transaction's date to next occurrence
    guard let nextDate = scheduled.nextDueDate() else {
      fatalError("nextDueDate should not be nil for recurring transaction")
    }

    var updated = scheduled
    updated.date = nextDate
    _ = try await repository.update(updated)

    // Verify the scheduled transaction still exists with updated date
    let page = try await repository.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(page.transactions.count == 1)
    #expect(page.transactions[0].isScheduled == true)

    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
    #expect(calendar.isDate(page.transactions[0].date, inSameDayAs: expectedDate))
  }

  @Test("Validation passes for valid transactions")
  func testValidationPassesForValid() throws {
    // Non-scheduled transaction
    let normal = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero
    )
    try normal.validate()

    // Scheduled transaction with both period and every
    let scheduled = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: 1
    )
    try scheduled.validate()
  }

  @Test("Validation fails when only period is set")
  func testValidationFailsWithOnlyPeriod() {
    let transaction = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: nil
    )

    #expect(throws: Transaction.ValidationError.incompleteRecurrence) {
      try transaction.validate()
    }
  }

  @Test("Validation fails when only every is set")
  func testValidationFailsWithOnlyEvery() {
    let transaction = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: nil,
      recurEvery: 1
    )

    #expect(throws: Transaction.ValidationError.incompleteRecurrence) {
      try transaction.validate()
    }
  }

  @Test("Validation fails when recurEvery is less than 1")
  func testValidationFailsWithInvalidEvery() {
    let transaction = Transaction(
      type: .expense,
      date: Date(),
      amount: MonetaryAmount.zero,
      recurPeriod: .month,
      recurEvery: 0
    )

    #expect(throws: Transaction.ValidationError.invalidRecurEvery) {
      try transaction.validate()
    }
  }
}
