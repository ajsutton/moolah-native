import Foundation
import Testing

@testable import Moolah

struct TransactionDraftTests {
  private let instrument = Instrument.defaultTestInstrument
  private let accountA = UUID()
  private let accountB = UUID()

  // MARK: - Helpers

  /// Build a simple one-leg draft for testing.
  private func makeExpenseDraft(
    amountText: String = "10.00",
    accountId: UUID? = nil,
    instrumentId: String? = Instrument.defaultTestInstrument.id
  ) -> TransactionDraft {
    TransactionDraft(
      payee: "Test",
      date: Date(),
      notes: "",
      isRepeating: false,
      recurPeriod: nil,
      recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: accountId ?? accountA,
          amountText: amountText, categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: instrumentId)
      ],
      relevantLegIndex: 0,
      viewingAccountId: nil
    )
  }

  /// Build Accounts collection from a list of accounts.
  private func makeAccounts(_ accounts: [Account]) -> Accounts {
    Accounts(from: accounts)
  }

  /// Build a simple Account with given id and instrument.
  private func makeAccount(id: UUID, instrument: Instrument = .defaultTestInstrument) -> Account {
    Account(
      id: id, name: "Test Account", type: .bank, instrument: instrument)
  }

  // MARK: - Init from Transaction: Simple Expense

  @Test func initFromSimpleExpense() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let tx = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      payee: "Coffee",
      notes: "Latte",
      recurPeriod: .week,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "-42.50")!, type: .expense,
          categoryId: categoryId, earmarkId: earmarkId)
      ]
    )

    let draft = TransactionDraft(from: tx)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.payee == "Coffee")
    #expect(draft.notes == "Latte")
    #expect(draft.date == tx.date)
    #expect(draft.isRepeating == true)
    #expect(draft.recurPeriod == .week)
    #expect(draft.recurEvery == 2)

    // Leg data: amount is negated for display (expense -42.50 → display "42.50")
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "42.50")
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
  }

  @Test func initFromSimpleIncome() {
    let tx = Transaction(
      date: Date(),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "3000.00")!, type: .income)
      ]
    )

    let draft = TransactionDraft(from: tx)

    // Income: display = quantity as-is (positive stays positive)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].amountText == "3000.00")
  }

  @Test func initFromRefundExpense() {
    // Refund: expense with positive quantity
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "10.00")!, type: .expense)
      ]
    )

    let draft = TransactionDraft(from: tx)

    // Expense display is negated: -(+10) = -10
    #expect(draft.legDrafts[0].amountText == "-10.00")
  }

  @Test func initFromZeroAmount() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal.zero, type: .expense)
      ]
    )

    let draft = TransactionDraft(from: tx)
    #expect(draft.legDrafts[0].amountText == "0")
  }

  // MARK: - Init from Transaction: Simple Transfer

  @Test func initFromSimpleTransferNoContext() {
    let tx = Transaction(
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: tx)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 2)
    // No context: relevant leg is index 0 (the primary leg)
    #expect(draft.relevantLegIndex == 0)
    // Both legs populated
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "100.00")  // -(-100) = 100
    #expect(draft.legDrafts[1].accountId == accountB)
    #expect(draft.legDrafts[1].amountText == "-100.00")  // -(+100) = -100
  }

  @Test func initFromSimpleTransferViewingFromSource() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: tx, viewingAccountId: accountA)

    // Source account is at index 0, so relevant leg = 0
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts[0].amountText == "100.00")
  }

  @Test func initFromSimpleTransferViewingFromDestination() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: tx, viewingAccountId: accountB)

    // Destination account is at index 1, so relevant leg = 1
    #expect(draft.relevantLegIndex == 1)
    // Display: -(+100) = -100
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "-100.00")
  }

  @Test func initFromSimpleTransferWithCategoryOnFirstLeg() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer,
          categoryId: categoryId, earmarkId: earmarkId),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    #expect(tx.isSimple == true)
    let draft = TransactionDraft(from: tx)
    #expect(draft.isCustom == false)
    // Category/earmark on primary leg (index 0)
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
    // Counterpart has nil
    #expect(draft.legDrafts[1].categoryId == nil)
    #expect(draft.legDrafts[1].earmarkId == nil)
  }

  // MARK: - Init from Transaction: Complex

  @Test func initFromComplexTransaction() {
    let catId = UUID()
    let tx = Transaction(
      date: Date(),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense,
          categoryId: catId),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: -50, type: .expense),
        TransactionLeg(accountId: UUID(), instrument: instrument, quantity: 150, type: .income),
      ]
    )
    #expect(!tx.isSimple)

    let draft = TransactionDraft(from: tx)
    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    // Expense legs: display is negated
    #expect(draft.legDrafts[0].amountText == "100.00")
    #expect(draft.legDrafts[0].categoryId == catId)
    #expect(draft.legDrafts[1].amountText == "50.00")
    // Income leg: display is as-is
    #expect(draft.legDrafts[2].amountText == "150.00")
  }

  // MARK: - Init Blank

  @Test func initBlankTransaction() {
    let draft = TransactionDraft(accountId: accountA)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "0")
    #expect(draft.payee == "")
    #expect(draft.notes == "")
    #expect(draft.isRepeating == false)
  }

  // MARK: - Init with Instrument Precision

  @Test func initPreservesCryptoPrecision() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: btc,
          quantity: Decimal(string: "-0.00123456")!, type: .expense)
      ]
    )
    let draft = TransactionDraft(from: tx)
    #expect(draft.legDrafts[0].amountText.contains("0.00123456"))
  }

  // MARK: - setType

  @Test func setTypeExpenseToIncome() {
    var draft = makeExpenseDraft(amountText: "50.00")
    draft.setType(.income, accounts: makeAccounts([makeAccount(id: accountA)]))

    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].type == .income)
    // Display text stays the same
    #expect(draft.legDrafts[0].amountText == "50.00")
  }

  @Test func setTypeExpenseToTransfer() {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)

    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts[0].type == .transfer)
    #expect(draft.legDrafts[0].amountText == "50.00")
    // Counterpart added with negated display amount and default account
    #expect(draft.legDrafts[1].type == .transfer)
    #expect(draft.legDrafts[1].amountText == "-50.00")
    #expect(draft.legDrafts[1].accountId == accountB)
  }

  @Test func setTypeTransferToExpense() {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)
    // Now switch back to expense
    draft.setType(.expense, accounts: accounts)

    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].amountText == "50.00")
  }

  @Test func setTypeIncomeToTransfer() {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = TransactionDraft(
      payee: "Test", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: accountA, amountText: "50.00",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    draft.setType(.transfer, accounts: accounts)

    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts[0].type == .transfer)
    #expect(draft.legDrafts[0].amountText == "50.00")
    #expect(draft.legDrafts[1].amountText == "-50.00")
  }

  @Test func setTypeTransferDefaultAccountExcludesCurrentAccount() {
    let accountC = UUID()
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
      makeAccount(id: accountC),
    ])
    var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)

    // Counterpart should not be accountA
    #expect(draft.legDrafts[1].accountId != accountA)
  }

  @Test func setTypeClearsCounterpartCategoryAndEarmark() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = TransactionDraft(
      payee: "Test", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: accountA, amountText: "50.00",
          categoryId: categoryId, categoryText: "Food", earmarkId: earmarkId)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    draft.setType(.transfer, accounts: accounts)

    // Primary leg (0) keeps category/earmark
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
    // Counterpart has nil
    #expect(draft.legDrafts[1].categoryId == nil)
    #expect(draft.legDrafts[1].earmarkId == nil)
  }

  // MARK: - setAmount

  @Test func setAmountSimpleExpense() {
    var draft = makeExpenseDraft(amountText: "10.00")
    draft.setAmount("75.00")
    #expect(draft.legDrafts[0].amountText == "75.00")
  }

  @Test func setAmountSimpleTransferMirrorsToCounterpart() {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)

    draft.setAmount("75.00")
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "75.00")
    // Counterpart gets parse-negate-format
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "-75.00")
  }

  @Test func setAmountNegativeDisplayMirrorsPositiveToCounterpart() {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)

    // Negative display value (reversed transfer)
    draft.setAmount("-10.00")
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "-10.00")
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "10.00")
  }

  @Test func setAmountUnparseableCascadesToInvalidCounterpart() {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)

    draft.setAmount("abc")
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "abc")
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "")
  }

  @Test func setAmountZeroIsValid() {
    var draft = makeExpenseDraft(amountText: "10.00")
    draft.setAmount("0")
    #expect(draft.legDrafts[0].amountText == "0")
  }

  @Test func setAmountFromDestinationPerspectiveMirrorsCorrectly() {
    // Transfer where relevant leg is index 1 (viewing from destination)
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: tx, viewingAccountId: accountB)
    #expect(draft.relevantLegIndex == 1)

    // User changes amount to 200 (from their perspective)
    draft.setAmount("200.00")
    #expect(draft.legDrafts[1].amountText == "200.00")
    // Primary leg (index 0) gets negated
    #expect(draft.legDrafts[0].amountText == "-200.00")
  }

  // MARK: - Relevant Leg Stability

  @Test func relevantLegStableWhenAmountSignChanges() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: tx, viewingAccountId: accountA)
    let originalIndex = draft.relevantLegIndex

    // Change amount to negative (would flip which leg is "outflow")
    draft.setAmount("-50.00")

    // Relevant leg index must NOT change
    #expect(draft.relevantLegIndex == originalIndex)
    #expect(draft.legDrafts[originalIndex].accountId == accountA)
  }

  // MARK: - Mode Switching

  @Test func switchToCustomPreservesLegs() {
    var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
    draft.isCustom = true
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].amountText == "50.00")
  }

  @Test func switchToSimpleRepinsRelevantLeg() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: tx, viewingAccountId: accountB)
    draft.isCustom = true
    // Switch back to simple
    draft.switchToSimple()
    #expect(draft.isCustom == false)
    #expect(draft.relevantLegIndex == 1)  // re-pinned to accountB
  }

  @Test func switchToSimpleNoContextPinsToZero() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: tx)
    draft.isCustom = true
    draft.switchToSimple()
    #expect(draft.relevantLegIndex == 0)
  }

  @Test func canSwitchToSimpleWhenLegsAreSimple() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    #expect(draft.canSwitchToSimple == true)
  }

  @Test func cannotSwitchToSimpleWithThreeLegs() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts.append(
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountB, amountText: "5.00",
        categoryId: nil, categoryText: "", earmarkId: nil))
    draft.legDrafts.append(
      TransactionDraft.LegDraft(
        type: .income, accountId: UUID(), amountText: "15.00",
        categoryId: nil, categoryText: "", earmarkId: nil))
    #expect(draft.canSwitchToSimple == false)
  }

  // MARK: - Validation

  @Test func validSimpleExpense() {
    let draft = makeExpenseDraft(amountText: "10.00", accountId: accountA)
    #expect(draft.isValid == true)
  }

  @Test func invalidEmptyAmount() {
    let draft = makeExpenseDraft(amountText: "")
    #expect(draft.isValid == false)
  }

  @Test func validZeroAmount() {
    let draft = makeExpenseDraft(amountText: "0")
    #expect(draft.isValid == true)
  }

  @Test func validNegativeDisplayAmount() {
    // Refund: user types -10 for an expense
    let draft = makeExpenseDraft(amountText: "-10.00")
    #expect(draft.isValid == true)
  }

  @Test func invalidMissingAccount() {
    let draft = TransactionDraft(
      payee: "Test", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: nil, amountText: "10.00",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == false)
  }

  @Test func invalidRecurrenceWithoutPeriod() {
    var draft = makeExpenseDraft(amountText: "10.00")
    draft.isRepeating = true
    draft.recurPeriod = nil
    #expect(draft.isValid == false)
  }

  @Test func validRecurrence() {
    var draft = makeExpenseDraft(amountText: "10.00")
    draft.isRepeating = true
    draft.recurPeriod = .month
    draft.recurEvery = 1
    #expect(draft.isValid == true)
  }

  @Test func invalidCustomEmptyLegs() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = []
    #expect(draft.isValid == false)
  }

  @Test func invalidCustomLegMissingAccount() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: nil, amountText: "10.00",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ]
    #expect(draft.isValid == false)
  }

  @Test func invalidCustomLegEmptyAmount() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ]
    #expect(draft.isValid == false)
  }

  @Test func validCustomLegs() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "10.00",
        categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: accountB, amountText: "5.00",
        categoryId: nil, categoryText: "", earmarkId: nil),
    ]
    #expect(draft.isValid == true)
  }

  // MARK: - Conversion: toTransaction

  @Test func toTransactionSimpleExpense() {
    let draft = makeExpenseDraft(amountText: "25.00", accountId: accountA)
    let accounts = makeAccounts([makeAccount(id: accountA)])
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [instrument])

    #expect(tx != nil)
    #expect(tx!.legs.count == 1)
    #expect(tx!.legs[0].quantity == Decimal(string: "-25.00"))  // expense: negated back
    #expect(tx!.legs[0].type == .expense)
    #expect(tx!.legs[0].accountId == accountA)
  }

  @Test func toTransactionSimpleIncome() {
    let draft = TransactionDraft(
      payee: "Salary", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: accountA, amountText: "3000.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: instrument.id)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let accounts = makeAccounts([makeAccount(id: accountA)])
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [instrument])

    #expect(tx != nil)
    #expect(tx!.legs[0].quantity == Decimal(string: "3000.00"))  // income: as-is
  }

  @Test func toTransactionRefundExpense() {
    // Display value "-10" for expense → quantity = -(-10) = +10
    let draft = makeExpenseDraft(amountText: "-10.00", accountId: accountA)
    let accounts = makeAccounts([makeAccount(id: accountA)])
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [instrument])

    #expect(tx != nil)
    #expect(tx!.legs[0].quantity == Decimal(string: "10.00"))
  }

  @Test func toTransactionSimpleTransfer() {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)

    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [instrument])
    #expect(tx != nil)
    #expect(tx!.legs.count == 2)
    #expect(tx!.legs[0].quantity == Decimal(string: "-100.00"))
    #expect(tx!.legs[1].quantity == Decimal(string: "100.00"))
  }

  @Test func toTransactionRoundTripsExpense() {
    let id = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let original = Transaction(
      id: id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      payee: "Coffee",
      notes: "Latte",
      recurPeriod: .week,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "-42.50")!, type: .expense,
          categoryId: categoryId, earmarkId: earmarkId)
      ]
    )

    let draft = TransactionDraft(from: original)
    let accounts = makeAccounts([makeAccount(id: accountA)])
    let roundTripped = draft.toTransaction(
      id: id, accounts: accounts, availableInstruments: [instrument])

    #expect(roundTripped != nil)
    #expect(roundTripped!.id == original.id)
    #expect(roundTripped!.date == original.date)
    #expect(roundTripped!.payee == original.payee)
    #expect(roundTripped!.notes == original.notes)
    #expect(roundTripped!.recurPeriod == original.recurPeriod)
    #expect(roundTripped!.recurEvery == original.recurEvery)
    #expect(roundTripped!.legs.count == original.legs.count)
    #expect(roundTripped!.legs[0].quantity == original.legs[0].quantity)
    #expect(roundTripped!.legs[0].type == original.legs[0].type)
    #expect(roundTripped!.legs[0].categoryId == original.legs[0].categoryId)
    #expect(roundTripped!.legs[0].earmarkId == original.legs[0].earmarkId)
  }

  @Test func toTransactionRoundTripsTransfer() {
    let id = UUID()
    let categoryId = UUID()
    let original = Transaction(
      id: id,
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer,
          categoryId: categoryId),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: original)
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    let roundTripped = draft.toTransaction(
      id: id, accounts: accounts, availableInstruments: [instrument])

    #expect(roundTripped != nil)
    #expect(roundTripped!.legs.count == 2)
    #expect(roundTripped!.legs[0].quantity == original.legs[0].quantity)
    #expect(roundTripped!.legs[1].quantity == original.legs[1].quantity)
    #expect(roundTripped!.legs[0].categoryId == categoryId)
    #expect(roundTripped!.legs[1].categoryId == nil)
  }

  @Test func toTransactionRoundTripsTransferFromDestination() {
    let id = UUID()
    let original = Transaction(
      id: id,
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    // Edit from destination perspective
    let draft = TransactionDraft(from: original, viewingAccountId: accountB)
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    let roundTripped = draft.toTransaction(
      id: id, accounts: accounts, availableInstruments: [instrument])

    #expect(roundTripped != nil)
    // Quantities must be preserved regardless of which leg is "relevant"
    #expect(roundTripped!.legs[0].quantity == Decimal(string: "-100"))
    #expect(roundTripped!.legs[1].quantity == Decimal(string: "100"))
  }

  @Test func toTransactionCustomModeMultiLeg() {
    let catId = UUID()
    let earmarkId = UUID()
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    let draft = TransactionDraft(
      payee: "Split", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: accountA, amountText: "100.00",
          categoryId: catId, categoryText: "", earmarkId: nil,
          instrumentId: instrument.id),
        TransactionDraft.LegDraft(
          type: .income, accountId: accountB, amountText: "50.00",
          categoryId: nil, categoryText: "", earmarkId: earmarkId,
          instrumentId: instrument.id),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [instrument])
    #expect(tx != nil)
    #expect(tx!.legs.count == 2)
    #expect(tx!.legs[0].quantity == Decimal(string: "-100.00"))  // expense negated
    #expect(tx!.legs[0].categoryId == catId)
    #expect(tx!.legs[1].quantity == Decimal(string: "50.00"))  // income as-is
    #expect(tx!.legs[1].earmarkId == earmarkId)
  }

  @Test func toTransactionReturnsNilWhenInvalid() {
    let draft = makeExpenseDraft(amountText: "")
    let accounts = makeAccounts([makeAccount(id: accountA)])
    #expect(draft.toTransaction(id: UUID(), accounts: accounts) == nil)
  }

  @Test func toTransactionClearsRecurrenceWhenNotRepeating() {
    var draft = makeExpenseDraft(amountText: "10.00", accountId: accountA)
    draft.recurPeriod = .month
    draft.recurEvery = 2
    draft.isRepeating = false

    let accounts = makeAccounts([makeAccount(id: accountA)])
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [instrument])
    #expect(tx != nil)
    #expect(tx!.recurPeriod == nil)
    #expect(tx!.recurEvery == nil)
  }

  // MARK: - Autofill

  @Test func autofillCopiesEverythingExceptDate() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let matchDate = Date(timeIntervalSince1970: 999_999)
    let matchTx = Transaction(
      date: matchDate,
      payee: "Coffee",
      notes: "Morning",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "-5.50")!, type: .expense,
          categoryId: categoryId, earmarkId: earmarkId)
      ]
    )

    let originalDate = Date()
    var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
    draft.date = originalDate

    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    #expect(draft.payee == "Coffee")
    #expect(draft.notes == "Morning")
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].amountText == "5.50")
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
    // Date preserved from original draft
    #expect(draft.date == originalDate)
    #expect(draft.date != matchDate)
  }

  @Test func autofillFromComplexTransactionSetsCustomMode() {
    let matchTx = Transaction(
      date: Date(),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: -50, type: .expense),
        TransactionLeg(accountId: UUID(), instrument: instrument, quantity: 150, type: .income),
      ]
    )

    var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    #expect(draft.payee == "Split")
  }

  @Test func autofillPopulatesCategoryText() {
    let categoryId = UUID()
    let matchTx = Transaction(
      date: Date(),
      payee: "Shop",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: -10, type: .expense, categoryId: categoryId)
      ]
    )
    let categories = Categories(from: [Category(id: categoryId, name: "Groceries")])

    var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
    draft.applyAutofill(from: matchTx, categories: categories)

    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].categoryText == "Groceries")
  }

  @Test func autofillPreservesViewingAccountForSimpleMatch() {
    // Match was recorded against accountB, but the user is viewing accountA.
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountB, instrument: instrument,
          quantity: -5, type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    // The leg's account must remain the viewed account; only the other
    // fields (amount, type, category, etc.) should be copied from the match.
    #expect(draft.legDrafts[0].accountId == accountA)
  }

  @Test func autofillRemapsInstrumentToViewingAccount() {
    let usd = Instrument.fiat(code: "USD")
    let eur = Instrument.fiat(code: "EUR")
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: usd),
      makeAccount(id: accountB, instrument: eur),
    ])
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountB, instrument: eur,
          quantity: -5, type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []), accounts: accounts)

    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].instrumentId == usd.id)
  }

  @Test func autofillWithoutViewingContextUsesMatchAccount() {
    // When there's no viewing account (e.g. "All Transactions"), autofill
    // should adopt the match's account as before.
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountB, instrument: instrument,
          quantity: -5, type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: accountA, viewingAccountId: nil)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    #expect(draft.legDrafts[0].accountId == accountB)
  }

  @Test func autofillPreservesViewingAccountForTransferMatch() {
    // Transfer match is A→B, but user is viewing accountC; the viewed-account
    // leg should be remapped to C while the counterpart leg is preserved.
    let accountC = UUID()
    let matchTx = Transaction(
      date: Date(),
      payee: "Savings",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    var draft = TransactionDraft(accountId: accountC, viewingAccountId: accountC)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    // pinRelevantLeg falls through to index 0 since C isn't in the match, so
    // leg 0 is the "viewed" leg and must be remapped to accountC.
    #expect(draft.legDrafts[0].accountId == accountC)
    #expect(draft.legDrafts[1].accountId == accountB)
  }

  // MARK: - showFromAccount

  @Test func showFromAccountFalseWhenViewingPrimaryLeg() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )
    let draft = TransactionDraft(from: tx, viewingAccountId: accountA)
    // accountA is at index 0 (primary), so "To Account" label
    #expect(draft.showFromAccount == false)
  }

  @Test func showFromAccountTrueWhenViewingCounterpartLeg() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )
    let draft = TransactionDraft(from: tx, viewingAccountId: accountB)
    // accountB is at index 1, so relevantLegIndex = 1, not primary → "From Account"
    #expect(draft.showFromAccount == true)
  }

  @Test func showFromAccountFalseWhenNoContext() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )
    let draft = TransactionDraft(from: tx)
    // No context: relevantLegIndex = 0 → "To Account"
    #expect(draft.showFromAccount == false)
  }

  // MARK: - Multi-instrument toTransaction

  @Test func toTransactionExpenseUsesAccountInstrument() throws {
    let usdAccount = makeAccount(id: accountA, instrument: .USD)
    let accounts = makeAccounts([usdAccount])
    let draft = TransactionDraft(
      payee: "Coffee", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1, isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: accountA, amountText: "4.50",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: Instrument.USD.id)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let tx = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts, availableInstruments: [.USD]))
    #expect(tx.legs.count == 1)
    #expect(tx.legs[0].instrument == .USD)
    #expect(tx.legs[0].quantity == Decimal(string: "-4.50")!)
  }

  @Test func toTransactionCrossCurrencyTransferProducesMixedInstrumentLegs() throws {
    // Transfer from AUD account to USD account — leg 0 is AUD, leg 1 is USD.
    // Display convention negates transfer legs, so amountText is the negated quantity.
    let audAccount = makeAccount(id: accountA, instrument: .AUD)
    let usdAccount = makeAccount(id: accountB, instrument: .USD)
    let accounts = makeAccounts([audAccount, usdAccount])
    let draft = TransactionDraft(
      payee: "FX", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1, isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .transfer, accountId: accountA, amountText: "1000.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: Instrument.AUD.id),
        TransactionDraft.LegDraft(
          type: .transfer, accountId: accountB, amountText: "-650.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: Instrument.USD.id),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let tx = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts, availableInstruments: [.AUD, .USD]))
    #expect(tx.legs.count == 2)
    #expect(tx.legs[0].instrument == .AUD)
    #expect(tx.legs[0].quantity == Decimal(string: "-1000.00")!)
    #expect(tx.legs[1].instrument == .USD)
    #expect(tx.legs[1].quantity == Decimal(string: "650.00")!)
    #expect(tx.isTransfer)
    // Cross-currency transfer quantities don't negate, so NOT isSimple.
    #expect(!tx.isSimple)
  }

  @Test func toTransactionStockTradeLegHasStockInstrument() throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let audAccount = makeAccount(id: accountA, instrument: .AUD)
    let stockAccount = makeAccount(id: accountB, instrument: bhp)
    let accounts = makeAccounts([audAccount, stockAccount])
    let draft = TransactionDraft(
      payee: "Buy BHP", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1, isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .transfer, accountId: accountA, amountText: "6345.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: Instrument.AUD.id),
        TransactionDraft.LegDraft(
          type: .transfer, accountId: accountB, amountText: "-150",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: bhp.id),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let tx = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts, availableInstruments: [.AUD, bhp]))
    #expect(tx.legs.count == 2)
    #expect(tx.legs[0].instrument == .AUD)
    #expect(tx.legs[0].quantity == Decimal(string: "-6345.00")!)
    #expect(tx.legs[1].instrument == bhp)
    #expect(tx.legs[1].quantity == Decimal(150))
  }

  // MARK: - eligibleToAccounts

  @Test func eligibleToAccountsFiltersByCurrency() {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let audAccount1 = makeAccount(id: accountA, instrument: aud)
    let audAccount2 = makeAccount(id: accountB, instrument: aud)
    let usdAccount = makeAccount(id: UUID(), instrument: usd)
    let accounts = makeAccounts([audAccount1, audAccount2, usdAccount])

    let eligible = TransactionDraftHelpers.eligibleToAccounts(from: accounts, currency: aud)
    let eligibleIds = eligible.map(\.id)
    #expect(eligibleIds.contains(accountA))
    #expect(eligibleIds.contains(accountB))
    #expect(!eligibleIds.contains(usdAccount.id))
  }

  // MARK: - Custom Mode Operations

  @Test func addLegAppendsBlankLeg() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    let initialCount = draft.legDrafts.count
    draft.addLeg()
    #expect(draft.legDrafts.count == initialCount + 1)
    let newLeg = draft.legDrafts.last!
    #expect(newLeg.type == .expense)
    #expect(newLeg.accountId == nil)
    #expect(newLeg.amountText == "0")
    #expect(newLeg.categoryId == nil)
    #expect(newLeg.earmarkId == nil)
  }

  @Test func removeLegRemovesCorrectIndex() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts.append(
      TransactionDraft.LegDraft(
        type: .income, accountId: accountB, amountText: "20.00",
        categoryId: nil, categoryText: "", earmarkId: nil))
    #expect(draft.legDrafts.count == 2)

    draft.removeLeg(at: 0)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].accountId == accountB)
  }

  // MARK: - Edge Cases

  @Test func displayTextForZeroQuantity() {
    let text = TransactionDraft.displayText(quantity: .zero, type: .expense, decimals: 2)
    #expect(text == "0")
  }

  @Test func displayTextForNegativeExpense() {
    // Normal expense: quantity -50, display = -(-50) = 50
    let text = TransactionDraft.displayText(
      quantity: Decimal(string: "-50")!, type: .expense, decimals: 2)
    #expect(text == "50.00")
  }

  @Test func displayTextForRefundExpense() {
    // Refund: quantity +10, display = -(+10) = -10
    let text = TransactionDraft.displayText(
      quantity: Decimal(string: "10")!, type: .expense, decimals: 2)
    #expect(text == "-10.00")
  }

  @Test func displayTextForIncome() {
    let text = TransactionDraft.displayText(
      quantity: Decimal(string: "100")!, type: .income, decimals: 2)
    #expect(text == "100.00")
  }

  @Test func parseDisplayTextRoundTrips() {
    let original: Decimal = Decimal(string: "-42.50")!
    let display = TransactionDraft.displayText(quantity: original, type: .expense, decimals: 2)
    let parsed = TransactionDraft.parseDisplayText(display, type: .expense, decimals: 2)
    #expect(parsed == original)
  }

  @Test func parseDisplayTextRefundRoundTrips() {
    let original: Decimal = Decimal(string: "10.00")!  // refund expense
    let display = TransactionDraft.displayText(quantity: original, type: .expense, decimals: 2)
    #expect(display == "-10.00")
    let parsed = TransactionDraft.parseDisplayText(display, type: .expense, decimals: 2)
    #expect(parsed == original)
  }

  @Test func parseDisplayTextIncomeRoundTrips() {
    let original: Decimal = Decimal(string: "3000.00")!
    let display = TransactionDraft.displayText(quantity: original, type: .income, decimals: 2)
    let parsed = TransactionDraft.parseDisplayText(display, type: .income, decimals: 2)
    #expect(parsed == original)
  }

  @Test func customModeLegTypeChangePreservesDisplayAmount() {
    var draft = makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts[0].amountText = "50.00"
    draft.legDrafts[0].type = .income
    // Display text unchanged
    #expect(draft.legDrafts[0].amountText == "50.00")
    // But conversion would produce different quantity
    let accounts = makeAccounts([makeAccount(id: accountA)])
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [instrument])
    #expect(tx!.legs[0].quantity == Decimal(string: "50.00"))  // income: as-is
  }

  // MARK: - Earmark-Only Legs

  @Test func isEarmarkOnlyWithEarmarkAndNoAccount() {
    let leg = TransactionDraft.LegDraft(
      type: .income, accountId: nil, amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: UUID())
    #expect(leg.isEarmarkOnly == true)
  }

  @Test func isEarmarkOnlyWithAccountAndEarmark() {
    let leg = TransactionDraft.LegDraft(
      type: .income, accountId: UUID(), amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: UUID())
    #expect(leg.isEarmarkOnly == false)
  }

  @Test func isEarmarkOnlyWithAccountNoEarmark() {
    let leg = TransactionDraft.LegDraft(
      type: .expense, accountId: UUID(), amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: nil)
    #expect(leg.isEarmarkOnly == false)
  }

  @Test func isEarmarkOnlyWithNeitherAccountNorEarmark() {
    let leg = TransactionDraft.LegDraft(
      type: .expense, accountId: nil, amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: nil)
    #expect(leg.isEarmarkOnly == false)
  }

  @Test func validEarmarkOnlyLeg() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "100",
          categoryId: nil, categoryText: "", earmarkId: UUID())
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == true)
  }

  @Test func invalidLegWithNeitherAccountNorEarmark() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: nil, amountText: "100",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == false)
  }

  @Test func validCustomWithMixedAccountAndEarmarkOnlyLegs() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: UUID(), amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: nil),
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: UUID()),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == true)
  }

  @Test func toTransactionEarmarkOnlyLeg() {
    let emId = UUID()
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "500",
          categoryId: nil, categoryText: "", earmarkId: emId,
          instrumentId: Instrument.defaultTestInstrument.id)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let earmarks = Earmarks(from: [
      Earmark(
        id: emId, name: "Holiday",
        instrument: .defaultTestInstrument)
    ])
    let tx = draft.toTransaction(
      id: UUID(), accounts: Accounts(from: []), earmarks: earmarks,
      availableInstruments: [instrument])
    #expect(tx != nil)
    #expect(tx!.legs.count == 1)
    #expect(tx!.legs[0].accountId == nil)
    #expect(tx!.legs[0].earmarkId == emId)
    #expect(tx!.legs[0].quantity == Decimal(string: "500"))
    #expect(tx!.legs[0].type == .income)
    #expect(tx!.legs[0].instrument == .defaultTestInstrument)
  }

  @Test func toTransactionMixedAccountAndEarmarkOnlyLegs() {
    let emId = UUID()
    let acctId = UUID()
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: Instrument.defaultTestInstrument.id),
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: emId,
          instrumentId: Instrument.defaultTestInstrument.id),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let accounts = Accounts(from: [
      Account(
        id: acctId, name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    ])
    let earmarks = Earmarks(from: [
      Earmark(
        id: emId, name: "Holiday",
        instrument: .defaultTestInstrument)
    ])
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, earmarks: earmarks,
      availableInstruments: [instrument])
    #expect(tx != nil)
    #expect(tx!.legs.count == 2)
    #expect(tx!.legs[0].accountId == acctId)
    #expect(tx!.legs[1].accountId == nil)
    #expect(tx!.legs[1].earmarkId == emId)
  }

  @Test func earmarkOnlyLegEnforcesIncomeType() {
    var draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: UUID(), amountText: "100",
          categoryId: UUID(), categoryText: "Food", earmarkId: UUID())
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    // Clear the account — should enforce earmark-only invariants
    draft.legDrafts[0].accountId = nil
    draft.enforceEarmarkOnlyInvariants(at: 0)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].categoryId == nil)
    #expect(draft.legDrafts[0].categoryText == "")
  }

  @Test func earmarkOnlyInvariantsNoOpWhenNotEarmarkOnly() {
    var draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: UUID(), amountText: "100",
          categoryId: UUID(), categoryText: "Food", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let originalCategoryId = draft.legDrafts[0].categoryId
    draft.enforceEarmarkOnlyInvariants(at: 0)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].categoryId == originalCategoryId)
  }

  @Test func initBlankEarmarkOnlyDraft() {
    let emId = UUID()
    let draft = TransactionDraft(earmarkId: emId)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].earmarkId == emId)
    #expect(draft.legDrafts[0].accountId == nil)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].amountText == "0")
    #expect(draft.legDrafts[0].categoryId == nil)
  }

  // MARK: - Cross-Currency Transfers

  @Test func initFromCrossCurrencyTransferUsesSimpleMode() {
    let tx = Transaction(
      date: Date(),
      payee: "FX",
      legs: [
        TransactionLeg(accountId: accountA, instrument: .AUD, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: .USD, quantity: 65, type: .transfer),
      ]
    )
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
    ])
    let draft = TransactionDraft(from: tx, viewingAccountId: accountA, accounts: accounts)
    #expect(draft.isCustom == false)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts[0].amountText == "100.00")
    #expect(draft.legDrafts[1].amountText == "-65.00")
  }

  @Test func initFromCrossCurrencyTransferFallsToCustomWhenInstrumentMismatchesAccount() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountA, instrument: .USD, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: .AUD, quantity: 155, type: .transfer),
      ]
    )
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .AUD),
    ])
    let draft = TransactionDraft(from: tx, viewingAccountId: accountA, accounts: accounts)
    #expect(draft.isCustom == true)
  }

  @Test func isCrossCurrencyTransferTrueWhenDifferentCurrencies() {
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
    ])
    var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = accountB
    #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == true)
  }

  @Test func isCrossCurrencyTransferFalseWhenSameCurrency() {
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .AUD),
    ])
    var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = accountB
    #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == false)
  }

  @Test func isCrossCurrencyTransferFalseWhenNotTransfer() {
    let accounts = makeAccounts([makeAccount(id: accountA, instrument: .AUD)])
    let draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == false)
  }

  @Test func setCounterpartAmountSetsCounterpartLeg() {
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
    ])
    var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = accountB
    draft.setCounterpartAmount("65.00")
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "65.00")
  }

  @Test func setAmountDoesNotMirrorWhenCrossCurrency() {
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
    ])
    var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = accountB
    draft.setCounterpartAmount("65.00")
    draft.setAmount("200.00", accounts: accounts)
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "65.00")  // unchanged
  }

  @Test func setAmountStillMirrorsWhenSameCurrency() {
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .AUD),
    ])
    var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = accountB
    draft.setAmount("200.00", accounts: accounts)
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "-200.00")
  }

  @Test func canSwitchToSimpleAllowsCrossCurrencyAmounts() {
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

  @Test func switchToAccountFromCrossCurrencyToSameCurrencySnapsMirror() {
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
    ])
    var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
    draft.setType(.transfer, accounts: accounts)
    draft.toAccountId = accountB
    draft.setCounterpartAmount("65.00")

    // Create a third AUD account and switch to it
    let acctC = UUID()
    let updatedAccounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
      makeAccount(id: acctC, instrument: .AUD),
    ])
    draft.toAccountId = acctC
    draft.snapToSameCurrencyIfNeeded(accounts: updatedAccounts)

    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "-100.00")
  }

  // MARK: - LegDraft instrumentId

  @Test func legDraftInstrumentIdOverridesToTransaction() {
    let acctId = UUID()
    let accounts = makeAccounts([makeAccount(id: acctId, instrument: .AUD)])
    let availableInstruments = ["AUD", "USD", "EUR", "GBP"].map { Instrument.fiat(code: $0) }
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: "USD")
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: availableInstruments)
    #expect(tx != nil)
    #expect(tx!.legs[0].instrument.id == "USD")
  }

  @Test func legDraftNilInstrumentIdReturnsNil() {
    // instrumentId is the canonical source of truth; a leg without one can't
    // resolve to an instrument and the draft is considered invalid-to-save.
    let acctId = UUID()
    let accounts = makeAccounts([makeAccount(id: acctId, instrument: .AUD)])
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [.AUD])
    #expect(tx == nil)
  }

  @Test func legDraftInvalidInstrumentIdReturnsNil() {
    let acctId = UUID()
    let accounts = makeAccounts([makeAccount(id: acctId, instrument: .AUD)])
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: "FAKE_CURRENCY")
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let tx = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [Instrument.fiat(code: "AUD")])
    #expect(tx == nil)
  }

  // MARK: - Cross-Currency Round-Trip

  @Test func toTransactionRoundTripsCrossCurrencyTransfer() {
    let id = UUID()
    let original = Transaction(
      id: id,
      date: Date(),
      payee: "FX",
      legs: [
        TransactionLeg(accountId: accountA, instrument: .AUD, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: .USD, quantity: 65, type: .transfer),
      ]
    )
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
    ])
    let draft = TransactionDraft(from: original, viewingAccountId: accountA, accounts: accounts)
    let roundTripped = draft.toTransaction(
      id: id, accounts: accounts, availableInstruments: [.AUD, .USD])
    #expect(roundTripped != nil)
    #expect(roundTripped!.legs.count == 2)
    #expect(roundTripped!.legs[0].quantity == Decimal(string: "-100"))
    #expect(roundTripped!.legs[0].instrument == .AUD)
    #expect(roundTripped!.legs[1].quantity == Decimal(string: "65"))
    #expect(roundTripped!.legs[1].instrument == .USD)
  }

  @Test func crossCurrencyTransferFromDestinationPerspective() {
    let accounts = makeAccounts([
      makeAccount(id: accountA, instrument: .AUD),
      makeAccount(id: accountB, instrument: .USD),
    ])
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountA, instrument: .AUD, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: .USD, quantity: 65, type: .transfer),
      ]
    )
    let draft = TransactionDraft(from: tx, viewingAccountId: accountB, accounts: accounts)
    #expect(draft.relevantLegIndex == 1)
    #expect(draft.showFromAccount == true)
    #expect(draft.legDrafts[1].amountText == "-65.00")
  }

  @Test func cannotSwitchToSimpleWhenTransferHasEarmarkOnlyLeg() {
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

  // MARK: - Complex Round-Trip

  /// Build a draft from `original`, convert back to a transaction, and return the result.
  /// Fails the calling test if either step yields nil.
  private func roundTrip(
    _ original: Transaction,
    accounts: Accounts,
    earmarks: Earmarks = Earmarks(from: []),
    availableInstruments: [Instrument]
  ) -> Transaction? {
    let draft = TransactionDraft(from: original, accounts: accounts)
    return draft.toTransaction(
      id: original.id,
      accounts: accounts,
      earmarks: earmarks,
      availableInstruments: availableInstruments
    )
  }

  /// The user's reported scenario: a custom transaction where two legs reference
  /// the same account but carry different instruments (an AUD↔NZD trade booked
  /// against a single AUD investment account). The round-trip must preserve each
  /// leg's instrument rather than silently re-deriving it from the account.
  @Test func customTransactionMixedInstrumentsSameAccountRoundTrips() throws {
    let accountId = UUID()
    let accounts = makeAccounts([makeAccount(id: accountId, instrument: .AUD)])
    let availableInstruments = [Instrument.AUD, Instrument.fiat(code: "NZD")]
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "AUD/NZD trade",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: accountId, instrument: .fiat(code: "NZD"), quantity: 650, type: .transfer),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts, availableInstruments: availableInstruments))

    #expect(roundTripped.legs.count == 2)
    #expect(roundTripped.legs[0].instrument == .AUD)
    #expect(roundTripped.legs[0].quantity == Decimal(-500))
    #expect(roundTripped.legs[0].accountId == accountId)
    #expect(roundTripped.legs[1].instrument == .fiat(code: "NZD"))
    #expect(roundTripped.legs[1].quantity == Decimal(650))
    #expect(roundTripped.legs[1].accountId == accountId)
  }

  @Test func customTransactionPreservesLegOrder() throws {
    let accountIds = [UUID(), UUID(), UUID()]
    let accounts = makeAccounts(accountIds.map { makeAccount(id: $0) })
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Three-way split",
      legs: [
        TransactionLeg(
          accountId: accountIds[0], instrument: instrument, quantity: -100, type: .expense),
        TransactionLeg(
          accountId: accountIds[1], instrument: instrument, quantity: -200, type: .expense),
        TransactionLeg(
          accountId: accountIds[2], instrument: instrument, quantity: 300, type: .income),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts, availableInstruments: [instrument]))

    #expect(roundTripped.legs.count == 3)
    #expect(roundTripped.legs[0].accountId == accountIds[0])
    #expect(roundTripped.legs[0].quantity == Decimal(-100))
    #expect(roundTripped.legs[1].accountId == accountIds[1])
    #expect(roundTripped.legs[1].quantity == Decimal(-200))
    #expect(roundTripped.legs[2].accountId == accountIds[2])
    #expect(roundTripped.legs[2].quantity == Decimal(300))
  }

  @Test func customTransactionPreservesPerLegFields() throws {
    let categoryIdA = UUID()
    let categoryIdB = UUID()
    let earmarkIdA = UUID()
    let earmarkIdB = UUID()
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
    ])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Mixed",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -75, type: .expense,
          categoryId: categoryIdA, earmarkId: earmarkIdA),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 25, type: .income,
          categoryId: categoryIdB, earmarkId: earmarkIdB),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts, availableInstruments: [instrument]))

    #expect(roundTripped.legs[0].type == .expense)
    #expect(roundTripped.legs[0].categoryId == categoryIdA)
    #expect(roundTripped.legs[0].earmarkId == earmarkIdA)
    #expect(roundTripped.legs[1].type == .income)
    #expect(roundTripped.legs[1].categoryId == categoryIdB)
    #expect(roundTripped.legs[1].earmarkId == earmarkIdB)
  }

  @Test func customTransactionPreservesDecimalPrecision() throws {
    let jpy = Instrument.fiat(code: "JPY")  // 0 decimals
    #expect(jpy.decimals == 0)
    let accountJpy = UUID()
    let accountAud = UUID()
    let accounts = makeAccounts([
      makeAccount(id: accountJpy, instrument: jpy),
      makeAccount(id: accountAud, instrument: .AUD),
    ])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountJpy, instrument: jpy, quantity: Decimal(-12_345), type: .transfer),
        TransactionLeg(
          accountId: accountAud, instrument: .AUD,
          quantity: Decimal(string: "123.45")!, type: .transfer),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts, availableInstruments: [jpy, .AUD]))

    #expect(roundTripped.legs[0].quantity == Decimal(-12_345))
    #expect(roundTripped.legs[0].instrument == jpy)
    #expect(roundTripped.legs[1].quantity == Decimal(string: "123.45"))
    #expect(roundTripped.legs[1].instrument == .AUD)
  }

  @Test func customTransactionPreservesTransactionLevelFields() throws {
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
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
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: -200, type: .expense),
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: 300, type: .income),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts, availableInstruments: [instrument]))

    #expect(roundTripped.id == id)
    #expect(roundTripped.date == date)
    #expect(roundTripped.payee == "Complex")
    #expect(roundTripped.notes == "multi-leg notes")
    #expect(roundTripped.recurPeriod == .month)
    #expect(roundTripped.recurEvery == 3)
  }

  @Test func customTransactionEarmarkOnlyLegRoundTrips() throws {
    let earmarkId = UUID()
    let accounts = makeAccounts([makeAccount(id: accountA, instrument: instrument)])
    let earmark = Earmark(
      id: earmarkId, name: "Travel", instrument: instrument)
    let earmarks = Earmarks(from: [earmark])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Allocate",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -50, type: .expense),
        TransactionLeg(
          accountId: nil, instrument: instrument, quantity: 50, type: .income,
          earmarkId: earmarkId),
      ]
    )

    let roundTripped = try #require(
      roundTrip(
        original, accounts: accounts, earmarks: earmarks,
        availableInstruments: [instrument]))

    #expect(roundTripped.legs.count == 2)
    #expect(roundTripped.legs[0].accountId == accountA)
    #expect(roundTripped.legs[0].earmarkId == nil)
    #expect(roundTripped.legs[1].accountId == nil)
    #expect(roundTripped.legs[1].earmarkId == earmarkId)
    #expect(roundTripped.legs[1].instrument == instrument)
  }

  @Test func customTransactionMixedLegTypesRoundTrip() throws {
    let accountC = UUID()
    let accounts = makeAccounts([
      makeAccount(id: accountA),
      makeAccount(id: accountB),
      makeAccount(id: accountC),
    ])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Mixed types",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: 50, type: .income),
        TransactionLeg(
          accountId: accountC, instrument: instrument, quantity: 50, type: .transfer),
      ]
    )

    let roundTripped = try #require(
      roundTrip(original, accounts: accounts, availableInstruments: [instrument]))

    #expect(roundTripped.legs[0].type == .expense)
    #expect(roundTripped.legs[0].quantity == Decimal(-100))
    #expect(roundTripped.legs[1].type == .income)
    #expect(roundTripped.legs[1].quantity == Decimal(50))
    #expect(roundTripped.legs[2].type == .transfer)
    #expect(roundTripped.legs[2].quantity == Decimal(50))
  }
}
