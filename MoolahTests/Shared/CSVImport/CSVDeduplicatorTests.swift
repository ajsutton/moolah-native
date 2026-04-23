import Foundation
import Testing

@testable import Moolah

@Suite("CSVDeduplicator")
struct CSVDeduplicatorTests {

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

  // MARK: - Layer 1

  @Test("layer 1 — bank reference match skips regardless of date")
  func layer1BankRefMatchesAcrossDates() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "COFFEE", amount: -5, bankRef: "REF-1")
    ]
    let incoming = candidate(
      date: date(2024, 4, 15),  // different date
      description: "completely different",
      amount: -5,
      bankRef: "REF-1")
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.isEmpty)
    #expect(result.skipped.count == 1)
    #expect(result.skipped[0].layer == .bankReference)
  }

  @Test("layer 1 — empty bank reference falls through to other layers")
  func layer1EmptyReferenceIgnored() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "COFFEE", amount: -5, bankRef: "")
    ]
    let incoming = candidate(
      date: date(2024, 4, 2), description: "DIFFERENT", amount: -5, bankRef: "")
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.count == 1)
  }

  @Test("layer 1 — multiple existing rows share a bank ref; first one wins")
  func layer1MultipleMatchesFirstWins() {
    let first = existingTransaction(
      accountId: accountId, date: date(2024, 4, 2),
      description: "A", amount: -5, bankRef: "REF-1")
    let second = existingTransaction(
      accountId: accountId, date: date(2024, 4, 3),
      description: "B", amount: -5, bankRef: "REF-1")
    let existing = [first, second]
    let incoming = candidate(
      date: date(2024, 4, 10), description: "X", amount: -5, bankRef: "REF-1")
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.skipped.count == 1)
    #expect(result.skipped[0].matchedExistingId == first.id)
  }

  // MARK: - Layer 2

  @Test("layer 2 — same calendar day + normalised description + amount → skip")
  func layer2SameDateExactMatch() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "COFFEE HUT", amount: Decimal(string: "-5.50")!)
    ]
    let incoming = candidate(
      date: date(2024, 4, 2),
      description: "  coffee hut  ",
      amount: Decimal(string: "-5.50")!)
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.isEmpty)
    #expect(result.skipped.count == 1)
    #expect(result.skipped[0].layer == .sameDateExactMatch)
  }

  @Test("layer 2 — different dates don't match even with same description + amount")
  func layer2DifferentDateKept() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "COFFEE", amount: Decimal(string: "-5.50")!)
    ]
    let incoming = candidate(
      date: date(2024, 4, 3), description: "COFFEE", amount: Decimal(string: "-5.50")!)
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.count == 1)
  }

  @Test("layer 2 — same UTC calendar day at different times still matches")
  func layer2SameDayDifferentTimeOfDay() {
    var morning = DateComponents()
    morning.year = 2024
    morning.month = 4
    morning.day = 2
    morning.hour = 0
    morning.minute = 0
    morning.second = 1
    var evening = morning
    evening.hour = 23
    evening.minute = 59
    evening.second = 59
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let existing = [
      existingTransaction(
        accountId: accountId, date: cal.date(from: morning)!,
        description: "COFFEE", amount: Decimal(string: "-5.50")!)
    ]
    let incoming = candidate(
      date: cal.date(from: evening)!,
      description: "COFFEE",
      amount: Decimal(string: "-5.50")!)
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.isEmpty)
  }

  @Test("layer 2 — different amounts don't match")
  func layer2DifferentAmountKept() {
    let existing = [
      existingTransaction(
        accountId: accountId, date: date(2024, 4, 2),
        description: "COFFEE", amount: Decimal(string: "-5.50")!)
    ]
    let incoming = candidate(
      date: date(2024, 4, 2), description: "COFFEE", amount: Decimal(string: "-5.51")!)
    let result = CSVDeduplicator.filter([incoming], against: existing, accountId: accountId)
    #expect(result.kept.count == 1)
  }
}
