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
      recurEvery: recurEvery
    )
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
      recurEvery: 2
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
    #expect(roundTripped!.type == original.type)
    #expect(roundTripped!.date == original.date)
    #expect(roundTripped!.primaryAccountId == original.primaryAccountId)
    #expect(roundTripped!.legs.first?.quantity == original.legs.first?.quantity)
    #expect(roundTripped!.payee == original.payee)
    #expect(roundTripped!.notes == original.notes)
    #expect(roundTripped!.categoryId == original.categoryId)
    #expect(roundTripped!.earmarkId == original.earmarkId)
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
}
