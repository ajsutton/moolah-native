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
    TransactionListView(
      title: account.name,
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      positions: positions,
      positionsHostCurrency: account.instrument,
      positionsTitle: account.name,
      conversionService: conversionService)
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
