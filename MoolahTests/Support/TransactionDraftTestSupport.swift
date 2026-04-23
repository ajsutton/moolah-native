import Foundation

@testable import Moolah

/// Shared helpers and fixtures for the split `TransactionDraft` test suites.
/// Extracted from the original monolithic `TransactionDraftTests.swift` so the
/// focused suites can share setup without re-declaring the same private helpers
/// across files. Instantiate once per suite as `let support = TransactionDraftTestSupport()`.
struct TransactionDraftTestSupport {
  let instrument = Instrument.defaultTestInstrument
  let accountA = UUID()
  let accountB = UUID()

  /// Build a simple one-leg expense draft for testing.
  func makeExpenseDraft(
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

  /// Build an `Accounts` collection from a list of accounts.
  func makeAccounts(_ accounts: [Account]) -> Accounts {
    Accounts(from: accounts)
  }

  /// Build a simple `Account` with the given id and instrument.
  func makeAccount(id: UUID, instrument: Instrument = .defaultTestInstrument) -> Account {
    Account(
      id: id, name: "Test Account", type: .bank, instrument: instrument)
  }
}
