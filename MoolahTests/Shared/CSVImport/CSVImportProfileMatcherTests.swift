import Foundation
import Testing

@testable import Moolah

@Suite("CSVImportProfileMatcher")
struct CSVImportProfileMatcherTests {

  private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents()
    c.year = y
    c.month = m
    c.day = d
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
  }

  private func profile(
    accountId: UUID,
    parser: String = "generic-bank",
    signature: [String] = ["date", "amount", "description", "balance"],
    filenamePattern: String? = nil
  ) -> CSVImportProfile {
    CSVImportProfile(
      accountId: accountId,
      parserIdentifier: parser,
      headerSignature: signature,
      filenamePattern: filenamePattern)
  }

  private func candidate(
    date: Date,
    description: String,
    amount: Decimal,
    bankRef: String? = nil,
    balance: Decimal? = nil
  ) -> ParsedTransaction {
    ParsedTransaction(
      date: date,
      legs: [
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

  private func existing(
    accountId: UUID,
    date: Date,
    description: String,
    amount: Decimal,
    bankRef: String? = nil
  ) -> Transaction {
    Transaction(
      date: date,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: amount,
          type: amount >= 0 ? .income : .expense, categoryId: nil, earmarkId: nil)
      ],
      importOrigin: ImportOrigin(
        rawDescription: description,
        bankReference: bankRef,
        rawAmount: amount,
        rawBalance: nil,
        importedAt: Date(),
        importSessionId: UUID(),
        sourceFilename: nil,
        parserIdentifier: "generic-bank"))
  }

  // MARK: - Cases

  @Test("zero matching profiles → needsSetup with noMatchingProfile")
  func noProfilesNeedsSetup() {
    let input = MatcherInput(
      filename: "cba.csv",
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      candidates: [],
      existingByAccountId: [:],
      profiles: [])
    #expect(CSVImportProfileMatcher.match(input) == .needsSetup(reason: .noMatchingProfile))
  }

  @Test("exactly one matching profile → routed")
  func oneProfileRouted() {
    let account = UUID()
    let p = profile(accountId: account)
    let input = MatcherInput(
      filename: "cba.csv",
      parserIdentifier: "generic-bank",
      headerSignature: ["Date", "Amount", "Description", "Balance"],
      candidates: [],
      existingByAccountId: [:],
      profiles: [p])
    #expect(CSVImportProfileMatcher.match(input) == .routed(p))
  }

  @Test("multi-match — profile with more duplicate overlap wins")
  func duplicateOverlapWins() {
    let accountA = UUID()
    let accountB = UUID()
    let pA = profile(accountId: accountA)
    let pB = profile(accountId: accountB)
    let candidates = [
      candidate(date: date(2024, 4, 2), description: "COFFEE", amount: -5),
      candidate(date: date(2024, 4, 3), description: "SALARY", amount: 3000),
    ]
    // A overlaps on the coffee row only; B overlaps on neither.
    let existingA = [
      existing(
        accountId: accountA, date: date(2024, 4, 2), description: "COFFEE", amount: -5)
    ]
    let input = MatcherInput(
      filename: nil,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      candidates: candidates,
      existingByAccountId: [accountA: existingA, accountB: []],
      profiles: [pA, pB])
    #expect(CSVImportProfileMatcher.match(input) == .routed(pA))
  }

  @Test("tie on overlap — filename pattern tiebreaks")
  func filenamePatternTiebreak() {
    let accountA = UUID()
    let accountB = UUID()
    let pA = profile(accountId: accountA, filenamePattern: "cba-*.csv")
    let pB = profile(accountId: accountB, filenamePattern: "anz-*.csv")
    // Both profiles see the coffee candidate and both have a matching
    // existing row — overlap tied at 1.
    let shared = candidate(
      date: date(2024, 4, 2), description: "COFFEE", amount: -5)
    let existingA = [
      existing(accountId: accountA, date: date(2024, 4, 2), description: "COFFEE", amount: -5)
    ]
    let existingB = [
      existing(accountId: accountB, date: date(2024, 4, 2), description: "COFFEE", amount: -5)
    ]
    let input = MatcherInput(
      filename: "cba-april.csv",
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      candidates: [shared],
      existingByAccountId: [accountA: existingA, accountB: existingB],
      profiles: [pA, pB])
    #expect(CSVImportProfileMatcher.match(input) == .routed(pA))
  }

  @Test("score=0 tie — filename pattern still tiebreaks across all candidates")
  func scoreZeroFilenameTiebreak() {
    // Two profiles, no overlap on either (both score 0), but only one has a
    // filename pattern that matches. The tiebreak pool includes both
    // profiles (not just the overlap-winning ones), so the filename check
    // fires and picks the single pattern-matching profile.
    let accountA = UUID()
    let accountB = UUID()
    let pA = profile(accountId: accountA, filenamePattern: "cba-*.csv")
    let pB = profile(accountId: accountB, filenamePattern: "anz-*.csv")
    let input = MatcherInput(
      filename: "cba-april.csv",
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      candidates: [],
      existingByAccountId: [accountA: [], accountB: []],
      profiles: [pA, pB])
    #expect(CSVImportProfileMatcher.match(input) == .routed(pA))
  }

  @Test("tie on overlap with no filename hint → needsSetup(.ambiguousMatch)")
  func tieWithoutFilenameHint() {
    let accountA = UUID()
    let accountB = UUID()
    let pA = profile(accountId: accountA)
    let pB = profile(accountId: accountB)
    let input = MatcherInput(
      filename: nil,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      candidates: [],
      existingByAccountId: [accountA: [], accountB: []],
      profiles: [pA, pB])
    if case .needsSetup(let reason) = CSVImportProfileMatcher.match(input),
      case .ambiguousMatch(let ids) = reason
    {
      #expect(Set(ids) == Set([pA.id, pB.id]))
    } else {
      Issue.record("expected .needsSetup(.ambiguousMatch)")
    }
  }

  @Test("profiles with different header signature are ignored")
  func differentHeadersIgnored() {
    let accountA = UUID()
    let wrongSignature = profile(
      accountId: accountA,
      signature: ["date", "amount"])  // missing description/balance
    let input = MatcherInput(
      filename: nil,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      candidates: [],
      existingByAccountId: [:],
      profiles: [wrongSignature])
    #expect(CSVImportProfileMatcher.match(input) == .needsSetup(reason: .noMatchingProfile))
  }

  @Test("profiles with different parser identifier are ignored")
  func differentParserIgnored() {
    let accountA = UUID()
    let swProfile = profile(accountId: accountA, parser: "selfwealth")
    let input = MatcherInput(
      filename: nil,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      candidates: [],
      existingByAccountId: [:],
      profiles: [swProfile])
    #expect(CSVImportProfileMatcher.match(input) == .needsSetup(reason: .noMatchingProfile))
  }

  @Test("incoming headers are normalised before matching (case + trim)")
  func headerSignatureNormalisedBeforeMatch() {
    let accountA = UUID()
    let p = profile(accountId: accountA)
    let input = MatcherInput(
      filename: nil,
      parserIdentifier: "generic-bank",
      headerSignature: [" DATE ", " AMOUNT ", " DESCRIPTION ", " BALANCE "],
      candidates: [],
      existingByAccountId: [:],
      profiles: [p])
    #expect(CSVImportProfileMatcher.match(input) == .routed(p))
  }
}
