import SwiftUI

/// Combined investment account view showing summary panels, chart with valuations list,
/// and an embedded transaction list.
struct InvestmentAccountView: View {
  let account: Account
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let investmentStore: InvestmentStore
  let transactionStore: TransactionStore

  @Environment(ProfileSession.self) private var session
  @State private var showingAddValue = false
  @State private var selectedTransaction: Transaction?
  @State private var positionsInput = PositionsViewInput(
    title: "", hostCurrency: .AUD, positions: [], historicalValue: nil)
  @State private var positionsRange: PositionsTimeRange = .threeMonths
  @State private var isLoadingPositions = false
  /// Tracks whether `loadAllData` has run at least once for this account.
  /// Gates the body so `legacyValuationsLayout` vs `positionTrackedLayout`
  /// is chosen *after* `investmentStore.values` is known — otherwise the
  /// branch flips from position-tracked to legacy mid-layout, tearing down
  /// and re-mounting the embedded `TransactionListView` with its `.toolbar`,
  /// which double-registers items in SwiftUI's AppKit toolbar bridge and
  /// crashes Release builds on accounts that have legacy investment values
  /// (e.g. Test Profile → Crypto).
  @State private var initialLoadComplete = false

  /// The profile's reporting currency — used for valuing positions and the
  /// chart series. NOT the account's own instrument: an investment account
  /// can be denominated in a non-fiat instrument (e.g., a crypto wallet),
  /// but valuations should always roll up into the user's fiat currency.
  private var profileCurrencyInstrument: Instrument {
    session.profile.instrument
  }

  /// Embedded transaction list for this account. Factored out because three
  /// layout branches reuse it verbatim.
  @ViewBuilder private var accountTransactionList: some View {
    TransactionListView(
      title: "",
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      selectedTransaction: $selectedTransaction
    )
  }

  /// The positions/transactions composition for non-legacy accounts. Collapses
  /// to a bare transaction list when `PositionsView` would be redundant with
  /// the host's already-visible account balance (see `shouldHide`).
  @ViewBuilder private var positionTrackedLayout: some View {
    if positionsInput.shouldHide && !isLoadingPositions {
      accountTransactionList
    } else {
      PositionsTransactionsSplit(defaultTab: .positions) {
        if isLoadingPositions && positionsInput.positions.isEmpty {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
        } else {
          PositionsView(input: positionsInput, range: $positionsRange)
        }
      } transactions: {
        accountTransactionList
      }
    }
  }

  @ViewBuilder private var legacyValuationsLayout: some View {
    VStack(spacing: 0) {
      legacySummary
      legacyChartAndValuations
      Divider()
      accountTransactionList
    }
  }

  @ViewBuilder private var legacySummary: some View {
    if !investmentStore.values.isEmpty,
      let performance = investmentStore.accountPerformance
    {
      AccountPerformanceTiles(title: account.name, performance: performance)
        .padding(.horizontal)
        .padding(.top)
    }
  }

  /// Chart + valuations layout: side-by-side on macOS, stacked on iOS.
  @ViewBuilder private var legacyChartAndValuations: some View {
    #if os(macOS)
      HStack(alignment: .top, spacing: 0) {
        VStack(spacing: 16) {
          timePeriodPicker
          InvestmentChartView(
            dataPoints: investmentStore.chartDataPoints,
            instrument: account.instrument)
        }
        .padding()

        Divider()

        valuationsList
          .frame(width: 240)
      }
    #else
      VStack(spacing: 0) {
        VStack(spacing: 16) {
          timePeriodPicker
          InvestmentChartView(
            dataPoints: investmentStore.chartDataPoints,
            instrument: account.instrument)
        }
        .padding()

        Divider()

        valuationsList
          .frame(maxHeight: 300)
      }
    #endif
  }

  var body: some View {
    Group {
      if !initialLoadComplete {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if investmentStore.hasLegacyValuations {
        legacyValuationsLayout
      } else {
        positionTrackedLayout
      }
    }
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      viewingAccountId: account.id
    )
    .profileNavigationTitle(account.name)
    .sheet(isPresented: $showingAddValue) {
      AddInvestmentValueView(
        accountId: account.id, instrument: account.instrument, store: investmentStore)
    }
    .task(id: account.id) {
      initialLoadComplete = false
      isLoadingPositions = true
      defer { isLoadingPositions = false }
      await investmentStore.loadAllData(
        accountId: account.id, profileCurrency: profileCurrencyInstrument)
      positionsInput = await investmentStore.positionsViewInput(
        title: account.name, range: positionsRange)
      initialLoadComplete = true
    }
    .task(id: positionsRange) {
      // Skip until loadAllData has populated the store; the .task(id: account.id)
      // block runs the first build. We only fire re-builds for subsequent
      // range changes.
      guard investmentStore.loadedAccountId != nil else { return }
      positionsInput = await investmentStore.positionsViewInput(
        title: account.name, range: positionsRange)
    }
    .refreshable {
      isLoadingPositions = true
      defer { isLoadingPositions = false }
      await investmentStore.loadAllData(
        accountId: account.id, profileCurrency: profileCurrencyInstrument)
      positionsInput = await investmentStore.positionsViewInput(
        title: account.name, range: positionsRange)
    }
  }

  // MARK: - Valuations List

  private var valuationsList: some View {
    VStack(spacing: 0) {
      valuationsHeader
      Divider()
      valuationsBody
    }
  }

  private var valuationsHeader: some View {
    HStack {
      Text("Valuations").font(.headline)
      Spacer()
      Button {
        showingAddValue = true
      } label: {
        Label("Record Value", systemImage: "plus")
          .labelStyle(.iconOnly)
      }
      .help("Record Value")
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  @ViewBuilder private var valuationsBody: some View {
    if investmentStore.values.isEmpty && !investmentStore.isLoading {
      ContentUnavailableView(
        "No Values",
        systemImage: "chart.line.uptrend.xyaxis",
        description: Text(
          PlatformActionVerb.emptyStatePrompt(buttonLabel: "+", suffix: "to record a value"))
      )
    } else {
      List {
        ForEach(investmentStore.values) { value in
          InvestmentValueListRow(value: value) {
            Task {
              await investmentStore.removeValue(accountId: account.id, date: value.date)
            }
          }
        }
      }
      .listStyle(.inset)
    }
  }

  // MARK: - Time Period Picker

  private var timePeriodPicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(TimePeriod.allCases) { period in
          Button {
            investmentStore.selectedPeriod = period
          } label: {
            Text(period.label)
              .font(.caption)
              .fontWeight(investmentStore.selectedPeriod == period ? .bold : .regular)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(
                investmentStore.selectedPeriod == period
                  ? Color.accentColor.opacity(0.15)
                  : Color.clear
              )
              .cornerRadius(8)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Show \(period.label) history")
          .accessibilityAddTraits(
            investmentStore.selectedPeriod == period ? .isSelected : [])
        }
      }
    }
  }
}

@MainActor
private func seedLegacyValuations(
  backend: CloudKitBackend, account: Account, store: InvestmentStore
) async {
  _ = try? await backend.accounts.create(
    account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: .AUD))
  let calendar = Calendar.current
  for monthsAgo in (0..<6).reversed() {
    let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
    let quantity: Decimal = 9_500 + Decimal(6 - monthsAgo) * 400
    await store.setValue(
      accountId: account.id, date: date,
      value: InstrumentAmount(quantity: quantity, instrument: .AUD))
  }
}

@MainActor
private func seedPositionValuations(backend: CloudKitBackend, account: Account) async {
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
  let (backend, _) = PreviewBackend.create()
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
    .environment(session)
  }
  .frame(width: 720, height: 560)
  .task { await seedLegacyValuations(backend: backend, account: account, store: investmentStore) }
}

#Preview("Position-tracked") {
  let (backend, _) = PreviewBackend.create()
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
    .environment(session)
  }
  .frame(width: 720, height: 600)
  .task { await seedPositionValuations(backend: backend, account: account) }
}
