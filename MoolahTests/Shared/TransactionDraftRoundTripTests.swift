import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft complex round-trips")
struct TransactionDraftRoundTripTests {
  private let support = TransactionDraftTestSupport()

  /// Build a draft from `original`, convert back to a transaction, and return the result.
  /// Returns nil if either step yields nil so callers can assert via `#require`.
  private func roundTrip(
    _ original: Transaction,
    accounts: Accounts,
    earmarks: Earmarks = Earmarks(from: [])
  ) -> Transaction? {
    let draft = TransactionDraft(from: original, accounts: accounts)
    return draft.toTransaction(
      id: original.id,
      accounts: accounts,
      earmarks: earmarks
    )
  }

  /// The user's reported scenario: a custom transaction where two legs reference
  /// the same account but carry different instruments (an AUD<->NZD trade booked
  /// against a single AUD investment account). The round-trip must preserve each
  /// leg's instrument rather than silently re-deriving it from the account.
  @Test
  func customTransactionMixedInstrumentsSameAccountRoundTrips() throws {
    let accountId = UUID()
    let accounts = support.makeAccounts([support.makeAccount(id: accountId, instrument: .AUD)])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "AUD/NZD trade",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: accountId, instrument: .fiat(code: "NZD"),
          quantity: 650, type: .transfer),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts))

    #expect(roundTripped.legs.count == 2)
    #expect(roundTripped.legs[0].instrument == .AUD)
    #expect(roundTripped.legs[0].quantity == Decimal(-500))
    #expect(roundTripped.legs[0].accountId == accountId)
    #expect(roundTripped.legs[1].instrument == .fiat(code: "NZD"))
    #expect(roundTripped.legs[1].quantity == Decimal(650))
    #expect(roundTripped.legs[1].accountId == accountId)
  }

  @Test
  func customTransactionPreservesLegOrder() throws {
    let accountIds = [UUID(), UUID(), UUID()]
    let accounts = support.makeAccounts(accountIds.map { support.makeAccount(id: $0) })
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Three-way split",
      legs: [
        TransactionLeg(
          accountId: accountIds[0], instrument: support.instrument,
          quantity: -100, type: .expense),
        TransactionLeg(
          accountId: accountIds[1], instrument: support.instrument,
          quantity: -200, type: .expense),
        TransactionLeg(
          accountId: accountIds[2], instrument: support.instrument,
          quantity: 300, type: .income),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts))

    #expect(roundTripped.legs.count == 3)
    #expect(roundTripped.legs[0].accountId == accountIds[0])
    #expect(roundTripped.legs[0].quantity == Decimal(-100))
    #expect(roundTripped.legs[1].accountId == accountIds[1])
    #expect(roundTripped.legs[1].quantity == Decimal(-200))
    #expect(roundTripped.legs[2].accountId == accountIds[2])
    #expect(roundTripped.legs[2].quantity == Decimal(300))
  }

  @Test
  func customTransactionPreservesPerLegFields() throws {
    let categoryIdA = UUID()
    let categoryIdB = UUID()
    let earmarkIdA = UUID()
    let earmarkIdB = UUID()
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Mixed",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -75, type: .expense,
          categoryId: categoryIdA, earmarkId: earmarkIdA),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 25, type: .income,
          categoryId: categoryIdB, earmarkId: earmarkIdB),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts))

    #expect(roundTripped.legs[0].type == .expense)
    #expect(roundTripped.legs[0].categoryId == categoryIdA)
    #expect(roundTripped.legs[0].earmarkId == earmarkIdA)
    #expect(roundTripped.legs[1].type == .income)
    #expect(roundTripped.legs[1].categoryId == categoryIdB)
    #expect(roundTripped.legs[1].earmarkId == earmarkIdB)
  }

  @Test
  func customTransactionPreservesDecimalPrecision() throws {
    let jpy = Instrument.fiat(code: "JPY")  // 0 decimals
    #expect(jpy.decimals == 0)
    let accountJpy = UUID()
    let accountAud = UUID()
    let accounts = support.makeAccounts([
      support.makeAccount(id: accountJpy, instrument: jpy),
      support.makeAccount(id: accountAud, instrument: .AUD),
    ])
    let audQuantity = try #require(Decimal(string: "123.45"))
    let original = Transaction(
      id: UUID(),
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountJpy, instrument: jpy,
          quantity: Decimal(-12_345), type: .transfer),
        TransactionLeg(
          accountId: accountAud, instrument: .AUD,
          quantity: audQuantity, type: .transfer),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts))

    #expect(roundTripped.legs[0].quantity == Decimal(-12_345))
    #expect(roundTripped.legs[0].instrument == jpy)
    #expect(roundTripped.legs[1].quantity == Decimal(string: "123.45"))
    #expect(roundTripped.legs[1].instrument == .AUD)
  }

  @Test
  func customTransactionPreservesTransactionLevelFields() throws {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let id = UUID()
    let original = Transaction(
      id: id,
      date: date,
      payee: "Complex",
      notes: "multi-leg notes",
      recurPeriod: .month,
      recurEvery: 3,
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .expense),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: -200, type: .expense),
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: 300, type: .income),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts))

    #expect(roundTripped.id == id)
    #expect(roundTripped.date == date)
    #expect(roundTripped.payee == "Complex")
    #expect(roundTripped.notes == "multi-leg notes")
    #expect(roundTripped.recurPeriod == .month)
    #expect(roundTripped.recurEvery == 3)
  }

  @Test
  func customTransactionEarmarkOnlyLegRoundTrips() throws {
    let earmarkId = UUID()
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: support.instrument)
    ])
    let earmark = Earmark(
      id: earmarkId, name: "Travel", instrument: support.instrument)
    let earmarks = Earmarks(from: [earmark])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Allocate",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -50, type: .expense),
        TransactionLeg(
          accountId: nil, instrument: support.instrument,
          quantity: 50, type: .income, earmarkId: earmarkId),
      ]
    )

    let roundTripped = try #require(
      roundTrip(
        original, accounts: accounts, earmarks: earmarks))

    #expect(roundTripped.legs.count == 2)
    #expect(roundTripped.legs[0].accountId == support.accountA)
    #expect(roundTripped.legs[0].earmarkId == nil)
    #expect(roundTripped.legs[1].accountId == nil)
    #expect(roundTripped.legs[1].earmarkId == earmarkId)
    #expect(roundTripped.legs[1].instrument == support.instrument)
  }

  @Test
  func customTransactionMixedLegTypesRoundTrip() throws {
    let accountC = UUID()
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
      support.makeAccount(id: accountC),
    ])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Mixed types",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .expense),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 50, type: .income),
        TransactionLeg(
          accountId: accountC, instrument: support.instrument,
          quantity: 50, type: .transfer),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts))

    #expect(roundTripped.legs[0].type == .expense)
    #expect(roundTripped.legs[0].quantity == Decimal(-100))
    #expect(roundTripped.legs[1].type == .income)
    #expect(roundTripped.legs[1].quantity == Decimal(50))
    #expect(roundTripped.legs[2].type == .transfer)
    #expect(roundTripped.legs[2].quantity == Decimal(50))
  }

}
