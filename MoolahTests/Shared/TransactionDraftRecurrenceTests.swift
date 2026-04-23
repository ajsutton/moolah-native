import Foundation
import Testing

@testable import Moolah

/// Behaviour of the "Repeat" toggle in the transaction inspector.
///
/// A transaction is *scheduled* when `recurPeriod != nil` — including the
/// `.once` case (scheduled but non-recurring). The inspector's Repeat toggle
/// must preserve scheduled-ness: turning off Repeat on a draft that started
/// scheduled demotes the period to `.once`, not to `nil`. Turning off Repeat
/// on a draft that started non-scheduled continues to produce `nil`.
@Suite("TransactionDraft recurrence toggle")
struct TransactionDraftRecurrenceTests {
  private let support = TransactionDraftTestSupport()

  // MARK: - Draft loaded from a scheduled Transaction

  @Test
  func turningOffRepeatOnScheduledDraftPreservesScheduledAsOnce() {
    let original = Transaction(
      date: Date(),
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -1000, type: .expense)
      ]
    )

    var draft = TransactionDraft(from: original)
    draft.isRepeating = false

    #expect(draft.isRepeating == false)
    #expect(draft.recurPeriod == .once)
  }

  @Test
  func toTransactionFromScheduledDraftWithRepeatOffProducesOnce() throws {
    let original = Transaction(
      date: Date(),
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -1000, type: .expense)
      ]
    )

    var draft = TransactionDraft(from: original)
    draft.isRepeating = false

    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))

    #expect(transaction.recurPeriod == .once)
    #expect(transaction.isScheduled == true)
    #expect(transaction.isRecurring == false)
  }

  @Test
  func turningOnRepeatOnScheduledOneOffRestoresMonthly() {
    let original = Transaction(
      date: Date(),
      recurPeriod: .once,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -1000, type: .expense)
      ]
    )

    var draft = TransactionDraft(from: original)
    #expect(draft.isRepeating == false)

    draft.isRepeating = true

    #expect(draft.isRepeating == true)
    #expect(draft.recurPeriod == .month)
  }

  @Test
  func toggleOffThenOnOnScheduledDraftReturnsToMonthly() {
    let original = Transaction(
      date: Date(),
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -1000, type: .expense)
      ]
    )

    var draft = TransactionDraft(from: original)
    draft.isRepeating = false
    #expect(draft.recurPeriod == .once)

    draft.isRepeating = true
    #expect(draft.recurPeriod == .month)
  }

  @Test
  func onceRecurPeriodRoundTripsThroughDraft() throws {
    let id = UUID()
    let original = Transaction(
      id: id,
      date: Date(),
      recurPeriod: .once,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -1000, type: .expense)
      ]
    )

    let draft = TransactionDraft(from: original)
    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let roundTripped = try #require(
      draft.toTransaction(
        id: id, accounts: accounts, availableInstruments: [support.instrument]))

    #expect(roundTripped.recurPeriod == .once)
    #expect(roundTripped.isScheduled == true)
    #expect(roundTripped.isRecurring == false)
  }

  // MARK: - Draft loaded from a non-scheduled Transaction

  @Test
  func toggleOnThenOffOnRegularDraftReturnsToNil() {
    let original = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -50, type: .expense)
      ]
    )

    var draft = TransactionDraft(from: original)
    #expect(draft.isRepeating == false)
    #expect(draft.recurPeriod == nil)

    draft.isRepeating = true
    #expect(draft.recurPeriod == .month)

    draft.isRepeating = false
    #expect(draft.recurPeriod == nil)
  }

  @Test
  func turningOffRepeatOnBlankDraftLeavesRecurPeriodNil() {
    var draft = TransactionDraft(accountId: support.accountA)
    draft.isRepeating = false
    #expect(draft.recurPeriod == nil)
  }

  @Test
  func turningOnRepeatOnBlankDraftSetsMonthly() {
    var draft = TransactionDraft(accountId: support.accountA)
    draft.isRepeating = true
    #expect(draft.isRepeating == true)
    #expect(draft.recurPeriod == .month)
    #expect(draft.recurEvery == 1)
  }
}
