import Foundation
import Testing

@testable import Moolah

@Suite("CSVDeduplicator — Part 2")
struct CSVDeduplicatorTestsMore {

  private let accountId = UUID()

  private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: components)!
  }

  private func existingTransaction(
    accountId: UUID,
    date: Date,
    description: String,
    amount: Decimal,
    bankRef: String? = nil,
    balance: Decimal? = nil
  ) -> Transaction {
    Transaction(
      date: date,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: amount,
          type: amount >= 0 ? .income : .expense,
          categoryId: nil,
          earmarkId: nil)
      ],
      importOrigin: ImportOrigin(
        rawDescription: description,
        bankReference: bankRef,
        rawAmount: amount,
        rawBalance: balance,
        importedAt: Date(),
        importSessionId: UUID(),
        sourceFilename: nil,
        parserIdentifier: "generic-bank"))
  }

  private func candidate(
    date: Date,
    description: String,
    amount: Decimal,
    bankRef: String? = nil,
    balance: Decimal? = nil,
    legs: [ParsedLeg]? = nil
  ) -> ParsedTransaction {
    ParsedTransaction(
      date: date,
      legs: legs
        ?? [
          ParsedLeg(
            accountId: nil,
            instrument: .AUD,
            quantity: amount,
            type: amount >= 0 ? .income : .expense)
        ],
      rawRow: [],
      rawDescription: description,
      rawAmount: amount,
      rawBalance: balance,
      bankReference: bankRef)
  }

  @Test("layer 2 — normalisation collapses whitespace and case")
  func layer2NormalisationCollapsesWhitespaceAndCase() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "coffee  hut", amount: -5)
    ]
    let incoming = candidate(
      date: date(2024, 4, 2), description: "COFFEE HUT", amount: -5)
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.isEmpty)
  }

  // MARK: - Layer 3

  @Test("layer 3 — balance alignment skips a candidate whose triple matches existing")
  func layer3BalanceAlignmentCatchesOverlap() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "COFFEE HUT SYDNEY", amount: Decimal(string: "-5.50")!,
        balance: Decimal(string: "994.50")!)
    ]
    let incoming = candidate(
      date: date(2024, 4, 2),
      description: "different wording",  // defeats layer 2
      amount: Decimal(string: "-5.50")!,
      balance: Decimal(string: "994.50")!)
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.isEmpty)
    #expect(result.skipped[0].layer == .balanceAlignment)
  }

  @Test("layer 3 — disabled when any candidate is multi-leg")
  func layer3DisabledWhenMultiLeg() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "MATCHING", amount: Decimal(string: "-5.50")!,
        balance: Decimal(string: "994.50")!)
    ]
    let multiLeg = candidate(
      date: date(2024, 4, 2),
      description: "something else",  // defeats layer 2
      amount: Decimal(string: "-5.50")!,
      balance: Decimal(string: "994.50")!,
      legs: [
        ParsedLeg(accountId: nil, instrument: .AUD, quantity: -10, type: .expense),
        ParsedLeg(accountId: nil, instrument: .AUD, quantity: 10, type: .income),
      ])
    let result = CSVDeduplicator.filter(
      [multiLeg], against: existing, accountId: accountId)
    // Layer 3 is off because candidate is multi-leg; layers 1+2 don't match →
    // the row is kept.
    #expect(result.kept.count == 1)
  }

  @Test("layer 3 — disabled when any candidate lacks rawBalance")
  func layer3DisabledWhenBalanceMissing() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "MATCHING", amount: Decimal(string: "-5.50")!,
        balance: Decimal(string: "994.50")!)
    ]
    let withBalance = candidate(
      date: date(2024, 4, 2), description: "other", amount: Decimal(string: "-5.50")!,
      balance: Decimal(string: "994.50")!)
    let noBalance = candidate(
      date: date(2024, 4, 3), description: "x", amount: Decimal(string: "-1.00")!)
    let result = CSVDeduplicator.filter(
      [withBalance, noBalance], against: existing, accountId: accountId)
    // Layer 3 is off because one candidate has no balance; layer 2 won't
    // match withBalance because descriptions differ.
    #expect(result.kept.count == 2)
  }

  // MARK: - Cross-layer

  @Test("unrelated existing transactions keep the incoming row")
  func noMatchKeepsTheRow() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "COFFEE", amount: -5)
    ]
    let incoming = candidate(
      date: date(2024, 4, 3), description: "SALARY", amount: 3000)
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.count == 1)
    #expect(result.skipped.isEmpty)
  }

  @Test("existing transactions on a different account are ignored")
  func existingOnDifferentAccountIgnored() {
    let otherAccount = UUID()
    let existing = [
      existingTransaction(
        accountId: otherAccount, date: date(2024, 4, 2),
        description: "COFFEE", amount: -5, bankRef: "REF-1")
    ]
    let incoming = candidate(
      date: date(2024, 4, 2), description: "COFFEE", amount: -5, bankRef: "REF-1")
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.count == 1)
  }

  @Test("normalise collapses case, internal whitespace, and strips punctuation")
  func normaliseBehaviour() {
    #expect(CSVDeduplicator.normalise("  COFFEE,  Hut!  ") == "COFFEE HUT")
    #expect(CSVDeduplicator.normalise("coffee\thut") == "COFFEE HUT")
    #expect(CSVDeduplicator.normalise("EFTPOS 123456") == "EFTPOS 123456")
  }
}
