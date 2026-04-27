// swiftlint:disable multiline_arguments

import Foundation

extension Transaction {
  /// A blank expense with zero quantity, today's date, attached to `accountId`.
  /// Intended for the "create new transaction" entry point where the user
  /// refines the fields in the inspector.
  static func defaultExpense(accountId: UUID, instrument: Instrument) -> Transaction {
    Transaction(
      date: Date(),
      payee: "",
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: 0, type: .expense)
      ]
    )
  }

  /// A blank monthly-recurring expense. Shows up in the Upcoming view
  /// immediately; the user sets payee, amount, and recurrence in the inspector.
  static func defaultMonthlyScheduled(accountId: UUID, instrument: Instrument) -> Transaction {
    Transaction(
      date: Date(),
      payee: "",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: 0, type: .expense)
      ]
    )
  }

  /// A blank earmark-only income transaction (no account leg).
  static func defaultEarmarkIncome(earmarkId: UUID, instrument: Instrument) -> Transaction {
    Transaction(
      date: Date(),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: nil, instrument: instrument, quantity: 0, type: .income,
          earmarkId: earmarkId)
      ]
    )
  }

  /// A non-scheduled copy of `scheduled` dated as of its scheduled date.
  /// Used by `TransactionStore.payScheduledTransaction` to record the actual
  /// payment without altering the scheduled template. Keeping the scheduled
  /// date — not the click time — means a batch of bills paid in one sitting
  /// lands on the dates the user budgeted for, so reports and running
  /// balances reflect the schedule rather than when the user happened to
  /// click pay.
  static func paidCopy(of scheduled: Transaction) -> Transaction {
    Transaction(
      id: UUID(),
      date: scheduled.date,
      payee: scheduled.payee,
      notes: scheduled.notes,
      legs: scheduled.legs
    )
  }

  /// Returns this transaction with its date advanced to the next recurrence
  /// instance, or `nil` if the transaction is non-recurring or has no
  /// computable next due date.
  func advancingToNextDueDate() -> Transaction? {
    guard isRecurring, let nextDate = nextDueDate() else { return nil }
    var advanced = self
    advanced.date = nextDate
    return advanced
  }
}
