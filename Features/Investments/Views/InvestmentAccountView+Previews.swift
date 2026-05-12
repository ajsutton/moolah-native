import SwiftUI

@MainActor
private func seedLegacyValuations(
  backend: any BackendProvider, account: Account, store: InvestmentStore
) async {
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: .AUD))
  let calendar = Calendar.current
  for monthsAgo in (0..<6).reversed() {
    let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
    let quantity: Decimal = 9_500 + Decimal(6 - monthsAgo) * 400
    await store.setValue(
      accountId: account.id,
      date: date,
      value: InstrumentAmount(quantity: quantity, instrument: .AUD))
  }
}

@MainActor
private func seedPositionValuations(backend: any BackendProvider, account: Account) async {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 0, instrument: .AUD))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86_400 * 30),
      legs: [
        TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .income),
        TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .expense),
      ]))
}

#Preview {
  let backend = PreviewBackend.create()
  let investmentStore = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let account = Account(name: "Brokerage", type: .investment, instrument: .AUD)
  return NavigationStack {
    InvestmentAccountView(
      account: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      investmentStore: investmentStore,
      transactionStore: transactionStore
    )
  }
  .previewProfileEnvironment(session: session)
  .frame(width: 720, height: 560)
  .task { await seedLegacyValuations(backend: backend, account: account, store: investmentStore) }
}

#Preview("Position-tracked") {
  let backend = PreviewBackend.create()
  let investmentStore = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let account = Account(
    name: "Brokerage",
    type: .investment,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades)
  return NavigationStack {
    InvestmentAccountView(
      account: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      investmentStore: investmentStore,
      transactionStore: transactionStore
    )
  }
  .previewProfileEnvironment(session: session)
  .frame(width: 720, height: 600)
  .task { await seedPositionValuations(backend: backend, account: account) }
}
