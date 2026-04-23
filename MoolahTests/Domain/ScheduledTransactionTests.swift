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

@Suite("Scheduled Transactions")
struct ScheduledTransactionTests {
  @Test("isScheduled preserves instrument across recurrence")
  func testIsScheduledWithForeignCurrencyRecurrence() {
    // A monthly USD subscription paid from a USD account.
    let usd = Instrument.USD
    let transaction = Transaction(
      date: Date(),
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: usd,
          quantity: Decimal(string: "-9.99")!, type: .expense)
      ]
    )
    #expect(transaction.isScheduled)
    #expect(transaction.legs[0].instrument == usd)
  }

  @Test("Scheduled cross-currency transfer retains both instruments")
  func testScheduledCrossCurrencyTransferLegsInstruments() {
    // A weekly currency conversion: 1000 AUD becomes 650 USD every week.
    let transaction = Transaction(
      date: Date(),
      payee: "Weekly FX",
      recurPeriod: .week,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .AUD,
          quantity: Decimal(string: "-1000.00")!, type: .transfer),
        TransactionLeg(
          accountId: UUID(), instrument: .USD,
          quantity: Decimal(string: "650.00")!, type: .transfer),
      ]
    )
    #expect(transaction.isScheduled)
    #expect(transaction.isTransfer)
    #expect(transaction.legs[0].instrument == .AUD)
    #expect(transaction.legs[1].instrument == .USD)
  }

  @Test("isScheduled returns true when recurPeriod is set")
  func testIsScheduledWithRecurrence() {
    let transaction = makeTxn(recurPeriod: .month, recurEvery: 1)
    #expect(transaction.isScheduled == true)
  }

  @Test("isScheduled returns false when recurPeriod is nil")
  func testIsScheduledWithoutRecurrence() {
    let transaction = makeTxn()
    #expect(transaction.isScheduled == false)
  }

  @Test("Creating paid copy removes recurrence fields")
  func testPayingScheduledTransactionCreatesNonScheduledCopy() {
    let accountId = UUID()
    let scheduled = makeTxn(
      date: Calendar.current.date(byAdding: .day, value: -5, to: Date())!,
      accountId: accountId,
      quantity: Decimal(string: "-1000.00")!,
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1
    )

    // Simulate the "Pay" action
    let paid = Transaction(
      id: UUID(),
      date: Date(),
      payee: scheduled.payee,
      legs: scheduled.legs
    )

    #expect(paid.id != scheduled.id)
    #expect(paid.recurPeriod == nil)
    #expect(paid.recurEvery == nil)
    #expect(paid.isScheduled == false)
    #expect(paid.payee == scheduled.payee)
    #expect(paid.legs.first?.amount == scheduled.legs.first?.amount)
  }

  @Test("Filter returns only scheduled transactions")
  func testFilterScheduledTransactions() async throws {
    let scheduled = makeTxn(
      quantity: Decimal(string: "-1000.00")!,
      recurPeriod: .month,
      recurEvery: 1
    )

    let oneTime = makeTxn(
      accountId: UUID(),
      quantity: Decimal(string: "-500.00")!
    )

    let (backend, container) = try TestBackend.create()
    _ = TestBackend.seed(transactions: [scheduled, oneTime], in: container)

    let page = try await backend.transactions.fetch(
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

    let overdue = makeTxn(
      date: calendar.date(byAdding: .day, value: -5, to: today)!,
      recurPeriod: .month,
      recurEvery: 1
    )

    let upcoming = makeTxn(
      date: calendar.date(byAdding: .day, value: 5, to: today)!,
      recurPeriod: .month,
      recurEvery: 1
    )

    #expect(overdue.date < today)
    #expect(upcoming.date > today)
  }

  @Test("Recurrence periods")
  func testRecurrencePeriods() {
    let daily = makeTxn(recurPeriod: .day, recurEvery: 1)
    let weekly = makeTxn(recurPeriod: .week, recurEvery: 2)
    let monthly = makeTxn(recurPeriod: .month, recurEvery: 1)
    let yearly = makeTxn(recurPeriod: .year, recurEvery: 1)

    #expect(daily.recurPeriod == .day)
    #expect(daily.recurEvery == 1)
    #expect(weekly.recurPeriod == .week)
    #expect(weekly.recurEvery == 2)
    #expect(monthly.recurPeriod == .month)
    #expect(yearly.recurPeriod == .year)
  }

  @Test("nextDueDate returns nil for non-recurring transactions")
  func testNextDueDateNonRecurring() {
    let oneTime = makeTxn()
    #expect(oneTime.nextDueDate() == nil)

    let once = makeTxn(recurPeriod: .once, recurEvery: 1)
    #expect(once.nextDueDate() == nil)
  }

  @Test("nextDueDate calculates daily recurrence")
  func testNextDueDateDaily() {
    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    let transaction = makeTxn(date: startDate, recurPeriod: .day, recurEvery: 1)

    let nextDate = transaction.nextDueDate()!
    let expectedDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 16))!
    #expect(nextDate.isSameDay(as: expectedDate))
  }
}
