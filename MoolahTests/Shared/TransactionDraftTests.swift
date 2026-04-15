import Foundation
import Testing

@testable import Moolah

struct TransactionDraftTests {
  private let instrument = Instrument.defaultTestInstrument
  private let accountA = UUID()
  private let accountB = UUID()

  /// Helper that builds a minimal valid draft with the given type and amount.
  private func makeDraft(
    type: TransactionType = .expense,
    amountText: String = "10.00",
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    toAmountText: String = "",
    isRepeating: Bool = false,
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int = 1
  ) -> TransactionDraft {
    TransactionDraft(
      type: type,
      payee: "Test Payee",
      amountText: amountText,
      date: Date(),
      accountId: accountId,
      toAccountId: toAccountId,
      categoryId: nil,
      earmarkId: nil,
      notes: "",
      categoryText: "",
      toAmountText: toAmountText,
      isRepeating: isRepeating,
      recurPeriod: recurPeriod,
      recurEvery: recurEvery,
      isCustom: false,
      legDrafts: []
    )
  }

  /// Helper: builds an `Accounts` collection containing the given accounts.
  private func makeAccounts(_ accounts: [Account]) -> Accounts {
    Accounts(from: accounts)
  }

  /// Helper: builds a simple `Account` with the given id and instrument.
  private func makeAccount(id: UUID, instrument: Instrument = .defaultTestInstrument) -> Account {
    Account(id: id, name: "Test Account", type: .bank, balance: .zero(instrument: instrument))
  }

  // MARK: - Amount Signing

  @Test func testExpenseAmountIsNegative() {
    let draft = makeDraft(type: .expense, amountText: "25.00", accountId: accountA)
    let tx = draft.toTransaction(id: UUID(), instrument: instrument)
    #expect(tx != nil)
    #expect(tx!.legs.first?.quantity == Decimal(string: "-25.00")!)
  }

  @Test func testIncomeAmountIsPositive() {
    let draft = makeDraft(type: .income, amountText: "25.00", accountId: accountA)
    let tx = draft.toTransaction(id: UUID(), instrument: instrument)
    #expect(tx != nil)
    #expect(tx!.legs.first?.quantity == Decimal(string: "25.00")!)
  }

  @Test func testTransferAmountIsNegative() {
    let draft = makeDraft(
      type: .transfer, amountText: "25.00",
      accountId: accountA, toAccountId: accountB)
    let tx = draft.toTransaction(id: UUID(), instrument: instrument)
    #expect(tx != nil)
    #expect(tx!.legs.first?.quantity == Decimal(string: "-25.00")!)
  }

  @Test func testOpeningBalanceAmountIsPositive() {
    let draft = makeDraft(type: .openingBalance, amountText: "100.00", accountId: accountA)
    let tx = draft.toTransaction(id: UUID(), instrument: instrument)
    #expect(tx != nil)
    #expect(tx!.legs.first?.quantity == Decimal(string: "100.00")!)
  }

  // MARK: - Parsing

  @Test func testParsedQuantityFromDecimalString() {
    let draft = makeDraft(amountText: "12.50")
    #expect(draft.parsedQuantity == Decimal(string: "12.50")!)
  }

  @Test func testParsedQuantityRejectsZero() {
    let draft = makeDraft(amountText: "0")
    #expect(draft.parsedQuantity == nil)
  }

  @Test func testParsedQuantityRejectsNonNumeric() {
    let draft = makeDraft(amountText: "abc")
    #expect(draft.parsedQuantity == nil)
  }

  // MARK: - Validation

  @Test func testIsValidRequiresAmount() {
    let draft = makeDraft(amountText: "")
    #expect(draft.isValid == false)
  }

  @Test func testIsValidRequiresTransferToAccount() {
    let draft = makeDraft(
      type: .transfer, amountText: "10.00",
      accountId: accountA, toAccountId: nil)
    #expect(draft.isValid == false)
  }

  @Test func testIsValidRejectsTransferToSameAccount() {
    let draft = makeDraft(
      type: .transfer, amountText: "10.00",
      accountId: accountA, toAccountId: accountA)
    #expect(draft.isValid == false)
  }

  @Test func testIsValidRequiresRecurrenceConfig() {
    // Repeating but no period set
    let draft = makeDraft(
      amountText: "10.00",
      isRepeating: true, recurPeriod: nil, recurEvery: 1)
    #expect(draft.isValid == false)

    // Repeating with period set — valid
    let validDraft = makeDraft(
      amountText: "10.00",
      isRepeating: true, recurPeriod: .month, recurEvery: 1)
    #expect(validDraft.isValid == true)
  }

  // MARK: - Conversion Details

  @Test func testToTransactionSetsTransferLegs() {
    let draft = makeDraft(
      type: .transfer, amountText: "10.00",
      accountId: accountA, toAccountId: accountB)
    let tx = draft.toTransaction(id: UUID(), instrument: instrument)
    #expect(tx != nil)
    #expect(tx!.legs.count == 2)
    #expect(tx!.legs[0].accountId == accountA)
    #expect(tx!.legs[1].accountId == accountB)
  }

  @Test func testToTransactionClearsRecurrenceWhenNotRepeating() {
    // Draft has recurPeriod set but isRepeating is false
    let draft = TransactionDraft(
      type: .expense,
      payee: "",
      amountText: "10.00",
      date: Date(),
      accountId: accountA,
      toAccountId: nil,
      categoryId: nil,
      earmarkId: nil,
      notes: "",
      categoryText: "",
      toAmountText: "",
      isRepeating: false,
      recurPeriod: .month,
      recurEvery: 2,
      isCustom: false,
      legDrafts: []
    )
    let tx = draft.toTransaction(id: UUID(), instrument: instrument)
    #expect(tx != nil)
    #expect(tx!.recurPeriod == nil)
    #expect(tx!.recurEvery == nil)
  }

  @Test func testInitFromExistingTransactionRoundTrips() {
    let id = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let original = Transaction(
      id: id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      payee: "Coffee Shop",
      notes: "Morning latte",
      recurPeriod: .week,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "-42.50")!, type: .expense,
          categoryId: categoryId, earmarkId: earmarkId
        )
      ]
    )

    let draft = TransactionDraft(from: original)
    let roundTripped = draft.toTransaction(id: id, instrument: instrument)

    #expect(roundTripped != nil)
    #expect(roundTripped!.id == original.id)
    #expect(roundTripped!.legs.map(\.type) == original.legs.map(\.type))
    #expect(roundTripped!.date == original.date)
    #expect(roundTripped!.legs.map(\.accountId) == original.legs.map(\.accountId))
    #expect(roundTripped!.legs.first?.quantity == original.legs.first?.quantity)
    #expect(roundTripped!.payee == original.payee)
    #expect(roundTripped!.notes == original.notes)
    #expect(roundTripped!.legs.compactMap(\.categoryId) == original.legs.compactMap(\.categoryId))
    #expect(roundTripped!.legs.compactMap(\.earmarkId) == original.legs.compactMap(\.earmarkId))
    #expect(roundTripped!.recurPeriod == original.recurPeriod)
    #expect(roundTripped!.recurEvery == original.recurEvery)
  }

  // MARK: - Viewing Account Perspective

  @Test func roundTripTransferFromDestinationPerspective() {
    let sourceId = UUID()
    let destId = UUID()

    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: sourceId, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(accountId: destId, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    // When viewing from the destination account, the draft should orient to that leg
    let draft = TransactionDraft(from: original, viewingAccountId: destId)
    #expect(draft.accountId == destId)
    #expect(draft.toAccountId == sourceId)
    #expect(draft.amountText == "100.00")
  }

  // MARK: - Instrument Precision

  @Test func initFromTransactionPreservesInstrumentPrecision() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let original = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: btc,
          quantity: Decimal(string: "-0.00123456")!, type: .expense
        )
      ]
    )
    let draft = TransactionDraft(from: original)
    #expect(draft.amountText.contains("0.00123456"))
  }

  @Test func initFromCrossCurrencyTransferPreservesToInstrumentPrecision() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let original = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: Instrument.AUD,
          quantity: Decimal(string: "-100.00")!, type: .transfer
        ),
        TransactionLeg(
          accountId: accountB, instrument: btc,
          quantity: Decimal(string: "0.00456789")!, type: .transfer
        ),
      ]
    )
    let draft = TransactionDraft(from: original)
    #expect(draft.toAmountText.contains("0.00456789"))
  }

  // MARK: - Cross-Currency Transfers

  @Test func sameCurrencyTransferProducesTwoLegsWithSameAmount() {
    let draft = makeDraft(
      type: .transfer, amountText: "100.00",
      accountId: accountA, toAccountId: accountB, toAmountText: "")
    let tx = draft.toTransaction(
      id: UUID(), fromInstrument: .AUD, toInstrument: .AUD)
    #expect(tx != nil)
    #expect(tx!.legs.count == 2)

    let outflow = tx!.legs.first(where: { $0.accountId == accountA })
    #expect(outflow?.quantity == Decimal(string: "-100.00")!)
    #expect(outflow?.instrument == .AUD)

    let inflow = tx!.legs.first(where: { $0.accountId == accountB })
    #expect(inflow?.quantity == Decimal(string: "100.00")!)
    #expect(inflow?.instrument == .AUD)
  }

  @Test func crossCurrencyTransferProducesTwoLegsWithDifferentAmounts() {
    let draft = makeDraft(
      type: .transfer, amountText: "1000.00",
      accountId: accountA, toAccountId: accountB, toAmountText: "650.00")
    let tx = draft.toTransaction(
      id: UUID(), fromInstrument: .AUD, toInstrument: .USD)
    #expect(tx != nil)
    #expect(tx!.legs.count == 2)

    let outflow = tx!.legs.first(where: { $0.accountId == accountA })
    #expect(outflow?.quantity == Decimal(string: "-1000.00")!)
    #expect(outflow?.instrument == .AUD)

    let inflow = tx!.legs.first(where: { $0.accountId == accountB })
    #expect(inflow?.quantity == Decimal(string: "650.00")!)
    #expect(inflow?.instrument == .USD)
  }

  @Test func crossCurrencyTransferDefaultsSameAmount() {
    let draft = makeDraft(
      type: .transfer, amountText: "1000.00",
      accountId: accountA, toAccountId: accountB, toAmountText: "")
    let tx = draft.toTransaction(
      id: UUID(), fromInstrument: .AUD, toInstrument: .USD)
    #expect(tx != nil)

    let inflow = tx!.legs.first(where: { $0.accountId == accountB })
    #expect(inflow?.quantity == Decimal(string: "1000.00")!)
    #expect(inflow?.instrument == .USD)
  }

  // MARK: - LegDraft

  @Test func legDraftConstructionAndEquality() {
    let id = UUID()
    let catId = UUID()
    let earmarkId = UUID()
    let leg = TransactionDraft.LegDraft(
      type: .expense,
      accountId: id,
      amountText: "42.00",
      isOutflow: true,
      categoryId: catId,
      categoryText: "Food",
      earmarkId: earmarkId
    )
    let leg2 = TransactionDraft.LegDraft(
      type: .expense,
      accountId: id,
      amountText: "42.00",
      isOutflow: true,
      categoryId: catId,
      categoryText: "Food",
      earmarkId: earmarkId
    )
    #expect(leg == leg2)

    var leg3 = leg
    leg3.amountText = "99.00"
    #expect(leg != leg3)
  }

  // MARK: - isCustom Round-Trip

  @Test func initFromNonSimpleTransactionSetsIsCustom() {
    // Three-leg transaction: not simple
    let legA = TransactionLeg(
      accountId: accountA, instrument: instrument, quantity: -100, type: .expense,
      categoryId: UUID())
    let legB = TransactionLeg(
      accountId: accountB, instrument: instrument, quantity: -50, type: .expense)
    let legC = TransactionLeg(
      accountId: UUID(), instrument: instrument, quantity: 150, type: .income)
    let tx = Transaction(date: Date(), legs: [legA, legB, legC])
    #expect(!tx.isSimple)

    let draft = TransactionDraft(from: tx)
    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "100.00")
    #expect(draft.legDrafts[0].isOutflow == true)
    #expect(draft.legDrafts[0].categoryId == legA.categoryId)
    #expect(draft.legDrafts[1].accountId == accountB)
    #expect(draft.legDrafts[1].amountText == "50.00")
    #expect(draft.legDrafts[2].isOutflow == false)
  }

  @Test func initFromSimpleTransactionIsNotCustom() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountA, instrument: instrument, quantity: -50, type: .expense)
      ]
    )
    #expect(tx.isSimple)

    let draft = TransactionDraft(from: tx)
    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.isEmpty)
  }

  // MARK: - toTransaction(id:accounts:) Custom Mode

  @Test func toTransactionCustomModeBuildsLegsWithCorrectSigns() {
    let acctIdA = UUID()
    let acctIdB = UUID()
    let acctIdC = UUID()
    let accounts = makeAccounts([
      makeAccount(id: acctIdA),
      makeAccount(id: acctIdB),
      makeAccount(id: acctIdC),
    ])

    let catId = UUID()
    let earmarkId = UUID()
    var draft = TransactionDraft(accountId: acctIdA)
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: acctIdA, amountText: "100.00",
        isOutflow: true, categoryId: catId, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: acctIdB, amountText: "50.00",
        isOutflow: false, categoryId: nil, categoryText: "", earmarkId: earmarkId),
      TransactionDraft.LegDraft(
        type: .transfer, accountId: acctIdC, amountText: "25.00",
        isOutflow: false, categoryId: nil, categoryText: "", earmarkId: nil),
    ]

    let tx = draft.toTransaction(id: UUID(), accounts: accounts)
    #expect(tx != nil)
    #expect(tx!.legs.count == 3)

    let expenseLeg = tx!.legs.first { $0.accountId == acctIdA }
    #expect(expenseLeg?.quantity == Decimal(string: "-100.00")!)
    #expect(expenseLeg?.categoryId == catId)

    let incomeLeg = tx!.legs.first { $0.accountId == acctIdB }
    #expect(incomeLeg?.quantity == Decimal(string: "50.00")!)
    #expect(incomeLeg?.earmarkId == earmarkId)

    let transferLeg = tx!.legs.first { $0.accountId == acctIdC }
    #expect(transferLeg?.quantity == Decimal(string: "25.00")!)  // isOutflow=false → positive
  }

  @Test func toTransactionCustomModeOutflowTransferIsNegative() {
    let acctId = UUID()
    let accounts = makeAccounts([makeAccount(id: acctId)])

    var draft = TransactionDraft(accountId: acctId)
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .transfer, accountId: acctId, amountText: "200.00",
        isOutflow: true, categoryId: nil, categoryText: "", earmarkId: nil)
    ]

    let tx = draft.toTransaction(id: UUID(), accounts: accounts)
    #expect(tx != nil)
    #expect(tx!.legs.first?.quantity == Decimal(string: "-200.00")!)
  }

  @Test func toTransactionCustomModeDelegatesToSimpleWhenNotCustom() {
    let acctId = UUID()
    let accounts = makeAccounts([makeAccount(id: acctId)])

    var draft = TransactionDraft(accountId: acctId)
    draft.isCustom = false
    draft.amountText = "75.00"
    draft.type = .income

    let tx = draft.toTransaction(id: UUID(), accounts: accounts)
    #expect(tx != nil)
    #expect(tx!.legs.count == 1)
    #expect(tx!.legs.first?.quantity == Decimal(string: "75.00")!)
  }

  // MARK: - isValid Custom Mode

  @Test func isValidCustomRequiresAtLeastOneLeg() {
    var draft = TransactionDraft(accountId: accountA)
    draft.isCustom = true
    draft.legDrafts = []
    #expect(draft.isValid == false)
  }

  @Test func isValidCustomRequiresAllLegsHaveAccount() {
    var draft = TransactionDraft(accountId: accountA)
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: nil, amountText: "10.00",
        isOutflow: true, categoryId: nil, categoryText: "", earmarkId: nil)
    ]
    #expect(draft.isValid == false)
  }

  @Test func isValidCustomRequiresAllLegsHavePositiveAmount() {
    var draft = TransactionDraft(accountId: accountA)
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "0",
        isOutflow: true, categoryId: nil, categoryText: "", earmarkId: nil)
    ]
    #expect(draft.isValid == false)
  }

  @Test func isValidCustomPassesWhenAllLegsValid() {
    var draft = TransactionDraft(accountId: accountA)
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "10.00",
        isOutflow: true, categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: accountB, amountText: "5.00",
        isOutflow: false, categoryId: nil, categoryText: "", earmarkId: nil),
    ]
    #expect(draft.isValid == true)
  }

  @Test func isValidCustomPartialLegsAreInvalid() {
    var draft = TransactionDraft(accountId: accountA)
    draft.isCustom = true
    // First leg valid, second has no account
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "10.00",
        isOutflow: true, categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: nil, amountText: "10.00",
        isOutflow: false, categoryId: nil, categoryText: "", earmarkId: nil),
    ]
    #expect(draft.isValid == false)
  }

  // MARK: - applyAutofill

  @Test func applyAutofillSimpleMatchFillsDefaults() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let matchTx = Transaction(
      date: Date(timeIntervalSince1970: 999_999),
      payee: "Coffee",
      notes: "Morning",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: Decimal(string: "-5.50")!,
          type: .expense, categoryId: categoryId, earmarkId: earmarkId)
      ]
    )

    var draft = TransactionDraft(accountId: nil)
    let categories = Categories(from: [Category(id: categoryId, name: "Food")])
    draft.applyAutofill(from: matchTx, categories: categories, supportsComplexTransactions: false)

    #expect(draft.payee == "Coffee")
    #expect(draft.notes == "Morning")
    #expect(draft.type == .expense)
    #expect(draft.amountText == "5.50")
    #expect(draft.accountId == accountA)
    #expect(draft.categoryId == categoryId)
    #expect(draft.earmarkId == earmarkId)
    // Date must NOT be set from the match
    #expect(draft.date != matchTx.date)
  }

  @Test func applyAutofillSimpleMatchPreservesUserEnteredValues() {
    let originalAccountId = UUID()
    let originalCategoryId = UUID()
    let matchCategoryId = UUID()
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      notes: "From match",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: Decimal(string: "-5.50")!,
          type: .expense, categoryId: matchCategoryId, earmarkId: nil)
      ]
    )

    var draft = TransactionDraft(accountId: originalAccountId)
    draft.amountText = "20.00"
    draft.payee = "User Payee"
    draft.notes = "User notes"
    draft.categoryId = originalCategoryId
    draft.type = .income

    let categories = Categories(from: [])
    draft.applyAutofill(from: matchTx, categories: categories, supportsComplexTransactions: false)

    // All user-entered values preserved
    #expect(draft.payee == "User Payee")
    #expect(draft.notes == "User notes")
    #expect(draft.amountText == "20.00")
    #expect(draft.accountId == originalAccountId)
    #expect(draft.categoryId == originalCategoryId)
    #expect(draft.type == .income)
  }

  @Test func applyAutofillComplexMatchWithSupportSetsCustomMode() {
    let catId = UUID()
    let matchTx = Transaction(
      date: Date(),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense,
          categoryId: catId),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: -50, type: .expense),
        TransactionLeg(
          accountId: UUID(), instrument: instrument, quantity: 150, type: .income),
      ]
    )
    #expect(!matchTx.isSimple)

    var draft = TransactionDraft(accountId: nil)
    let categories = Categories(from: [])
    draft.applyAutofill(from: matchTx, categories: categories, supportsComplexTransactions: true)

    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    #expect(draft.payee == "Split")
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "100.00")
    #expect(draft.legDrafts[0].isOutflow == true)
    #expect(draft.legDrafts[0].categoryId == catId)
  }

  @Test func applyAutofillComplexMatchWithoutSupportCopiesOnlyPayeeAndNotes() {
    let matchTx = Transaction(
      date: Date(),
      payee: "Split Bill",
      notes: "Dinner",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: -50, type: .expense),
        TransactionLeg(
          accountId: UUID(), instrument: instrument, quantity: 150, type: .income),
      ]
    )
    #expect(!matchTx.isSimple)

    var draft = TransactionDraft(accountId: nil)
    let categories = Categories(from: [])
    draft.applyAutofill(from: matchTx, categories: categories, supportsComplexTransactions: false)

    #expect(draft.payee == "Split Bill")
    #expect(draft.notes == "Dinner")
    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.isEmpty)
  }

  @Test func applyAutofillPreservesNotesWhenAlreadyFilled() {
    let matchTx = Transaction(
      date: Date(),
      payee: "Shop",
      notes: "Match notes",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -10, type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: nil)
    draft.notes = "My existing notes"
    let categories = Categories(from: [])
    draft.applyAutofill(from: matchTx, categories: categories, supportsComplexTransactions: false)

    #expect(draft.notes == "My existing notes")
  }

  @Test func applyAutofillComplexMatchDoesNotOverrideExistingLegDrafts() {
    let matchTx = Transaction(
      date: Date(),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense),
        TransactionLeg(
          accountId: accountB, instrument: instrument, quantity: -50, type: .expense),
        TransactionLeg(
          accountId: UUID(), instrument: instrument, quantity: 150, type: .income),
      ]
    )
    #expect(!matchTx.isSimple)

    var draft = TransactionDraft(accountId: nil)
    draft.isCustom = true
    // User already has one leg draft
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "999.00",
        isOutflow: true, categoryId: nil, categoryText: "", earmarkId: nil)
    ]
    let categories = Categories(from: [])
    draft.applyAutofill(from: matchTx, categories: categories, supportsComplexTransactions: true)

    // Existing leg drafts preserved
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].amountText == "999.00")
  }
}
