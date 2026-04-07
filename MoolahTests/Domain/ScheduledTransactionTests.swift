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
      recurPeriod: "MONTH",
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
      recurPeriod: "MONTH",
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
      recurPeriod: "MONTH",
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
      recurPeriod: "MONTH",
      recurEvery: 1
    )

    let upcoming = Transaction(
      type: .expense,
      date: calendar.date(byAdding: .day, value: 5, to: today)!,
      amount: MonetaryAmount.zero,
      recurPeriod: "MONTH",
      recurEvery: 1
    )

    #expect(overdue.date < today)
    #expect(upcoming.date > today)
  }

  @Test("Recurrence periods")
  func testRecurrencePeriods() {
    let daily = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: "DAY", recurEvery: 1
    )
    let weekly = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: "WEEK", recurEvery: 2
    )
    let monthly = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: "MONTH", recurEvery: 1
    )
    let yearly = Transaction(
      type: .expense, date: Date(), amount: MonetaryAmount.zero,
      recurPeriod: "YEAR", recurEvery: 1
    )

    #expect(daily.recurPeriod == "DAY")
    #expect(daily.recurEvery == 1)
    #expect(weekly.recurPeriod == "WEEK")
    #expect(weekly.recurEvery == 2)
    #expect(monthly.recurPeriod == "MONTH")
    #expect(yearly.recurPeriod == "YEAR")
  }
}
