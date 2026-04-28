// swift-format wraps `TransactionLeg(...)` calls with one argument per line
// inside these previews; SwiftLint's multiline_arguments rule (which
// expects "all on one line OR one per line including the first") then
// trips on the formatter's chosen style. The formatter wins per project
// policy (.swift-format is the layout source of truth), so suppress here.
// swiftlint:disable multiline_arguments

import SwiftUI

@MainActor
private func previewStore() -> TransactionStore {
  let (backend, _) = PreviewBackend.create()
  return TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )
}

#Preview {
  let accountId = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Woolworths",
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50.23, type: .expense)
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Checking", type: .bank, instrument: .AUD),
        Account(name: "Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: [
        Category(name: "Groceries"),
        Category(name: "Transport"),
      ]),
      earmarks: Earmarks(from: [Earmark(name: "Holiday Fund", instrument: .AUD)]),
      transactionStore: previewStore(),
      viewingAccountId: accountId,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Custom Transaction") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Split Purchase",
        legs: [
          TransactionLeg(
            accountId: accountId1, instrument: .AUD, quantity: -30.00, type: .expense,
            categoryId: nil),
          TransactionLeg(
            accountId: accountId2, instrument: .AUD, quantity: -20.00, type: .expense,
            categoryId: nil),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "Checking", type: .bank, instrument: .AUD),
        Account(id: accountId2, name: "Credit Card", type: .creditCard, instrument: .AUD),
      ]),
      categories: Categories(from: [
        Category(name: "Groceries"), Category(name: "Transport"),
      ]),
      earmarks: Earmarks(from: [Earmark(name: "Holiday Fund", instrument: .AUD)]),
      transactionStore: previewStore(),

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Earmark-Only Transaction") {
  let earmarkId = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .AUD, quantity: 500, type: .income,
            earmarkId: earmarkId)
        ]
      ),
      accounts: Accounts(from: [
        Account(name: "Checking", type: .bank, instrument: .AUD),
        Account(name: "Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: [
        Earmark(id: earmarkId, name: "Income Tax FY2025", instrument: .AUD),
        Earmark(name: "Holiday Fund", instrument: .AUD),
      ]),
      transactionStore: previewStore(),

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Cross-Currency Transfer") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Currency Exchange",
        legs: [
          TransactionLeg(accountId: accountId1, instrument: .USD, quantity: -100, type: .transfer),
          TransactionLeg(accountId: accountId2, instrument: .AUD, quantity: 155, type: .transfer),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "US Checking", type: .bank, instrument: .USD),
        Account(id: accountId2, name: "AU Savings", type: .bank, instrument: .AUD),
        Account(name: "Credit Card", type: .creditCard, instrument: .USD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId1,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Cross-Currency Transfer (Sent)") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Currency Exchange",
        legs: [
          TransactionLeg(accountId: accountId1, instrument: .USD, quantity: -100, type: .transfer),
          TransactionLeg(accountId: accountId2, instrument: .AUD, quantity: 155, type: .transfer),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "US Checking", type: .bank, instrument: .USD),
        Account(id: accountId2, name: "AU Savings", type: .bank, instrument: .AUD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      viewingAccountId: accountId2,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Scheduled (Recurring)") {
  let accountId = UUID()
  return NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date().addingTimeInterval(60 * 60 * 24 * 3),
        payee: "Rent",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -1800, type: .expense)
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId, name: "Checking", type: .bank, instrument: .AUD)
      ]),
      categories: Categories(from: [Category(name: "Housing")]),
      earmarks: Earmarks(from: []),
      transactionStore: previewStore(),
      showRecurrence: true,
      viewingAccountId: accountId,

      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
