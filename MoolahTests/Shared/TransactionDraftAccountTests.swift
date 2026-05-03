import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft account + multi-instrument + custom mode ops")
struct TransactionDraftAccountTests {
  private let support = TransactionDraftTestSupport()

  // MARK: - showFromAccount

  @Test
  func showFromAccountFalseWhenViewingPrimaryLeg() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )
    let draft = TransactionDraft(from: transaction, viewingAccountId: support.accountA)
    // accountA is at index 0 (primary), so "To Account" label
    #expect(draft.showFromAccount == false)
  }

  @Test
  func showFromAccountTrueWhenViewingCounterpartLeg() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )
    let draft = TransactionDraft(from: transaction, viewingAccountId: support.accountB)
    // accountB is at index 1, so relevantLegIndex = 1, not primary -> "From Account"
    #expect(draft.showFromAccount == true)
  }

  @Test
  func showFromAccountFalseWhenNoContext() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )
    let draft = TransactionDraft(from: transaction)
    // No context: relevantLegIndex = 0 -> "To Account"
    #expect(draft.showFromAccount == false)
  }

  // MARK: - Multi-instrument toTransaction

  @Test
  func toTransactionExpenseUsesAccountInstrument() throws {
    let usdAccount = support.makeAccount(id: support.accountA, instrument: .USD)
    let accounts = support.makeAccounts([usdAccount])
    let draft = TransactionDraft(
      payee: "Coffee", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1, isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: support.accountA, amountText: "4.50",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrument: Instrument.USD)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let transaction = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts))
    let expectedQuantity = try #require(Decimal(string: "-4.50"))
    #expect(transaction.legs.count == 1)
    #expect(transaction.legs[0].instrument == .USD)
    #expect(transaction.legs[0].quantity == expectedQuantity)
  }

  @Test
  func toTransactionCrossCurrencyTransferProducesMixedInstrumentLegs() throws {
    // Transfer from AUD account to USD account — leg 0 is AUD, leg 1 is USD.
    // Display convention negates transfer legs, so amountText is the negated quantity.
    let audAccount = support.makeAccount(id: support.accountA, instrument: .AUD)
    let usdAccount = support.makeAccount(id: support.accountB, instrument: .USD)
    let accounts = support.makeAccounts([audAccount, usdAccount])
    let draft = TransactionDraft(
      payee: "FX", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1, isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .transfer, accountId: support.accountA, amountText: "1000.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrument: Instrument.AUD),
        TransactionDraft.LegDraft(
          type: .transfer, accountId: support.accountB, amountText: "-650.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrument: Instrument.USD),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let transaction = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts))
    let audQuantity = try #require(Decimal(string: "-1000.00"))
    let usdQuantity = try #require(Decimal(string: "650.00"))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].instrument == .AUD)
    #expect(transaction.legs[0].quantity == audQuantity)
    #expect(transaction.legs[1].instrument == .USD)
    #expect(transaction.legs[1].quantity == usdQuantity)
    #expect(transaction.isTransfer)
    // Cross-currency transfer quantities don't negate, so NOT isSimple.
    #expect(!transaction.isSimple)
  }

  @Test
  func toTransactionStockTradeLegHasStockInstrument() throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let audAccount = support.makeAccount(id: support.accountA, instrument: .AUD)
    let stockAccount = support.makeAccount(id: support.accountB, instrument: bhp)
    let accounts = support.makeAccounts([audAccount, stockAccount])
    let draft = TransactionDraft(
      payee: "Buy BHP", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1, isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .transfer, accountId: support.accountA, amountText: "6345.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrument: Instrument.AUD),
        TransactionDraft.LegDraft(
          type: .transfer, accountId: support.accountB, amountText: "-150",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrument: bhp),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let transaction = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts))
    let audQuantity = try #require(Decimal(string: "-6345.00"))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].instrument == .AUD)
    #expect(transaction.legs[0].quantity == audQuantity)
    #expect(transaction.legs[1].instrument == bhp)
    #expect(transaction.legs[1].quantity == Decimal(150))
  }

  // MARK: - eligibleToAccounts

  @Test
  func eligibleToAccountsFiltersByCurrency() {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let audAccount1 = support.makeAccount(id: support.accountA, instrument: aud)
    let audAccount2 = support.makeAccount(id: support.accountB, instrument: aud)
    let usdAccount = support.makeAccount(id: UUID(), instrument: usd)
    let accounts = support.makeAccounts([audAccount1, audAccount2, usdAccount])

    let eligible = TransactionDraft.eligibleToAccounts(from: accounts, currency: aud)
    let eligibleIds = eligible.map(\.id)
    #expect(eligibleIds.contains(support.accountA))
    #expect(eligibleIds.contains(support.accountB))
    #expect(!eligibleIds.contains(usdAccount.id))
  }

  // MARK: - Custom Mode Operations

  @Test
  func addLegAppendsBlankLeg() throws {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    let initialCount = draft.legDrafts.count
    draft.addLeg()
    #expect(draft.legDrafts.count == initialCount + 1)
    let newLeg = try #require(draft.legDrafts.last)
    #expect(newLeg.type == .expense)
    #expect(newLeg.accountId == nil)
    #expect(newLeg.amountText == "0")
    #expect(newLeg.categoryId == nil)
    #expect(newLeg.earmarkId == nil)
  }

  @Test
  func removeLegRemovesCorrectIndex() {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts.append(
      TransactionDraft.LegDraft(
        type: .income, accountId: support.accountB, amountText: "20.00",
        categoryId: nil, categoryText: "", earmarkId: nil))
    #expect(draft.legDrafts.count == 2)

    draft.removeLeg(at: 0)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].accountId == support.accountB)
  }
}
