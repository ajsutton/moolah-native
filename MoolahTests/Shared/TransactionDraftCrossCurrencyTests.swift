import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft cross-currency transfers")
struct TransactionDraftCrossCurrencyTests {
  private let support = TransactionDraftTestSupport()

  // MARK: - Cross-Currency Transfers

  @Test
  func initFromCrossCurrencyTransferUsesSimpleMode() {
    let transaction = Transaction(
      date: Date(),
      payee: "FX",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: .AUD,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: .USD,
          quantity: 65, type: .transfer),
      ]
    )
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
    ])
    let draft = TransactionDraft(
      from: transaction, viewingAccountId: support.accountA, accounts: accounts)
    #expect(draft.isCustom == false)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts[0].amountText == "100.00")
    #expect(draft.legDrafts[1].amountText == "-65.00")
  }

  @Test
  func initFromCrossCurrencyTransferFallsToCustomWhenInstrumentMismatchesAccount() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: .USD,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: .AUD,
          quantity: 155, type: .transfer),
      ]
    )
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .AUD),
    ])
    let draft = TransactionDraft(
      from: transaction, viewingAccountId: support.accountA, accounts: accounts)
    #expect(draft.isCustom == true)
  }

  @Test
  func isCrossCurrencyTransferTrueWhenDifferentCurrencies() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
    ])
    var draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = support.accountB
    #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == true)
  }

  @Test
  func isCrossCurrencyTransferFalseWhenSameCurrency() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .AUD),
    ])
    var draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = support.accountB
    #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == false)
  }

  @Test
  func isCrossCurrencyTransferFalseWhenNotTransfer() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD)
    ])
    let draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == false)
  }

  @Test
  func setCounterpartAmountSetsCounterpartLeg() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
    ])
    var draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = support.accountB
    draft.setCounterpartAmount("65.00")
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "65.00")
  }

  @Test
  func setAmountDoesNotMirrorWhenCrossCurrency() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
    ])
    var draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = support.accountB
    draft.setCounterpartAmount("65.00")
    draft.setAmount("200.00", accounts: accounts)
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "65.00")  // unchanged
  }

  @Test
  func setAmountStillMirrorsWhenSameCurrency() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .AUD),
    ])
    var draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = support.accountB
    draft.setAmount("200.00", accounts: accounts)
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "-200.00")
  }

  @Test
  func canSwitchToSimpleAllowsCrossCurrencyAmounts() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .transfer, accountId: UUID(), amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil),
        TransactionDraft.LegDraft(
          type: .transfer, accountId: UUID(), amountText: "-65.00",
          categoryId: nil, categoryText: "", earmarkId: nil),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.canSwitchToSimple == true)
  }

  @Test
  func switchToAccountFromCrossCurrencyToSameCurrencySnapsMirror() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
    ])
    var draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = support.accountB
    draft.setCounterpartAmount("65.00")

    // Create a third AUD account and switch to it
    let acctC = UUID()
    let updatedAccounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
      support.makeAccount(id: acctC, instrument: .AUD),
    ])
    draft.toAccountId = acctC
    draft.snapToSameCurrencyIfNeeded(accounts: updatedAccounts)

    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "-100.00")
  }

  // MARK: - Cross-Currency Round-Trip

  @Test
  func toTransactionRoundTripsCrossCurrencyTransfer() throws {
    let id = UUID()
    let original = Transaction(
      id: id,
      date: Date(),
      payee: "FX",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: .AUD,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: .USD,
          quantity: 65, type: .transfer),
      ]
    )
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
    ])
    let draft = TransactionDraft(
      from: original, viewingAccountId: support.accountA, accounts: accounts)
    let roundTripped = try #require(
      draft.toTransaction(
        id: id, accounts: accounts, availableInstruments: [.AUD, .USD]))
    #expect(roundTripped.legs.count == 2)
    #expect(roundTripped.legs[0].quantity == Decimal(string: "-100"))
    #expect(roundTripped.legs[0].instrument == .AUD)
    #expect(roundTripped.legs[1].quantity == Decimal(string: "65"))
    #expect(roundTripped.legs[1].instrument == .USD)
  }

  @Test
  func crossCurrencyTransferFromDestinationPerspective() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: .AUD),
      support.makeAccount(id: support.accountB, instrument: .USD),
    ])
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: .AUD,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: .USD,
          quantity: 65, type: .transfer),
      ]
    )
    let draft = TransactionDraft(
      from: transaction, viewingAccountId: support.accountB, accounts: accounts)
    #expect(draft.relevantLegIndex == 1)
    #expect(draft.showFromAccount == true)
    #expect(draft.legDrafts[1].amountText == "-65.00")
  }

  @Test
  func cannotSwitchToSimpleWhenTransferHasEarmarkOnlyLeg() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .transfer, accountId: UUID(), amountText: "100",
          categoryId: nil, categoryText: "", earmarkId: nil),
        TransactionDraft.LegDraft(
          type: .transfer, accountId: nil, amountText: "-100",
          categoryId: nil, categoryText: "", earmarkId: UUID()),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.canSwitchToSimple == false)
  }
}
