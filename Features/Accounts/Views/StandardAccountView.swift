// Features/Accounts/Views/StandardAccountView.swift
//
// Two thin per-leaf wrappers around `TransactionListView` for the
// non-investment, non-crypto cases of `ContentView`'s detail column.
// Both types collocate in this file deliberately: each is a one-line
// composition with no behaviour, and pairing them keeps the
// "one canonical transaction list, dispatched per leaf" pattern visible
// at a glance. Explicit exception to the one-primary-type-per-file
// convention — both are one-line wrappers around `TransactionListView`
// with no behaviour of their own. See `guides/UI_GUIDE.md` §3 for the
// per-leaf-leaf-view pattern these implement.

// Reason: SwiftUI declarative chains and the Transaction-leg seeding
// helpers at the bottom wrap arguments across multiple lines for
// readability; enforcing the rule would fight the formatter and the
// SwiftUI idiom without improving clarity.
// swiftlint:disable multiline_arguments

import SwiftUI

/// Detail view for bank, asset, and other non-investment, non-crypto
/// accounts. A `TransactionListView` filtered to the account's id, with
/// the account's positions threaded through so the multi-instrument
/// positions split renders for accounts that hold foreign-currency
/// positions (e.g., a multi-currency CommBank account holding USD).
struct StandardAccountView: View {
  let account: Account
  let positions: [Position]
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let conversionService: any InstrumentConversionService

  var body: some View {
    #if os(macOS)
      MultiInstrumentPositionsTopAccessoryHost(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService,
        // Standard accounts are not crypto wallets, so the registry-
        // version bump trigger (issue #790 spam flip) is inert here.
        // Crypto callers pass `session.cryptoTokenStore?.registrationsVersion ?? 0`
        // instead.
        registrationsVersion: 0
      ) { panel in
        TransactionListView(
          title: account.name,
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          topAccessory: {
            // Switch on the host's enum — module-scope `PositionsPanel`
            // (see its declaration in
            // `MultiInstrumentPositionsTopAccessoryHost.swift`) breaks
            // the inference cycle, so the switch resolves without
            // coupling to the host's `Content` generic parameter.
            switch panel {
            case let .panel(input, range):
              PositionsView(input: input, range: range)
            case .loading:
              ProgressView().frame(maxWidth: .infinity).padding()
            case .absent:
              EmptyView()
            }
          }
        )
      }
    #else
      TransactionListView(
        title: account.name,
        filter: TransactionFilter(accountId: account.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
      .multiInstrumentPositionsSplit(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService)
    #endif
  }
}

/// Detail view for the All Transactions sidebar selection. A bare
/// `TransactionListView` with an empty filter.
struct AllTransactionsView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  var body: some View {
    TransactionListView(
      title: "All Transactions",
      filter: TransactionFilter(),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore)
  }
}

// MARK: - Preview

// Preview covers `StandardAccountView` only — `AllTransactionsView` is
// structurally identical (a bare `TransactionListView` with an empty
// filter), so one preview demonstrates the per-leaf wrapper pattern
// for both.
@MainActor
private func seedStandardAccountPreview(
  backend: any BackendProvider,
  accountId: UUID,
  store: TransactionStore
) async {
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date(), payee: "Woolworths",
      legs: [
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50.23, type: .expense)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86400), payee: "Employer",
      legs: [
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 3500, type: .income)
      ]))
  await store.load(filter: TransactionFilter(accountId: accountId))
}

#Preview {
  let accountId = UUID()
  let account = Account(
    id: accountId, name: "Checking", type: .bank, instrument: .AUD,
    positions: [Position(instrument: .AUD, quantity: 3449.77)])
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  return NavigationStack {
    StandardAccountView(
      account: account,
      positions: account.positions,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store,
      conversionService: backend.conversionService)
  }
  .previewProfileEnvironment()
  .task {
    await seedStandardAccountPreview(backend: backend, accountId: accountId, store: store)
  }
}
