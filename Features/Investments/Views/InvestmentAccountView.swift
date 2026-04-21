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
  @State private var positionsInput: PositionsViewInput = PositionsViewInput(
    title: "", hostCurrency: .AUD, positions: [], historicalValue: nil)
  @State private var positionsRange: PositionsTimeRange = .threeMonths
  @State private var isLoadingPositions = false

  /// The profile's reporting currency — used for valuing positions and the
  /// chart series. NOT the account's own instrument: an investment account
  /// can be denominated in a non-fiat instrument (e.g., a crypto wallet),
  /// but valuations should always roll up into the user's fiat currency.
  private var profileCurrencyInstrument: Instrument {
    session.profile.instrument
  }

  /// The invested amount (balance from positions in the account's primary instrument).
  private var investedAmount: InstrumentAmount {
    let primaryPosition = account.positions.first(where: { $0.instrument == account.instrument })
    return primaryPosition?.amount ?? .zero(instrument: account.instrument)
  }

  /// The latest investment value, or nil if no values have been recorded.
  private var latestInvestmentValue: InstrumentAmount? {
    investmentStore.values.first?.value
  }

  var body: some View {
    Group {
      if investmentStore.hasLegacyValuations {
        VStack(spacing: 0) {
          // Legacy: show manual valuations
          if !investmentStore.values.isEmpty {
            InvestmentSummaryView(
              investedAmount: investedAmount,
              currentValue: latestInvestmentValue,
              store: investmentStore
            )
            .padding(.horizontal)
            .padding(.top)
          }

          // Chart + valuations: side by side on macOS, stacked on iOS
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

          Divider()

          // Transaction list fills remaining space
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
      }
    }
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      viewingAccountId: account.id,
      supportsComplexTransactions: session.profile.supportsComplexTransactions
    )
    .profileNavigationTitle(account.name)
    .sheet(isPresented: $showingAddValue) {
      AddInvestmentValueView(
        accountId: account.id, instrument: account.instrument, store: investmentStore)
    }
    .task(id: account.id) {
      isLoadingPositions = true
      defer { isLoadingPositions = false }
      await investmentStore.loadAllData(
        accountId: account.id, profileCurrency: profileCurrencyInstrument)
      positionsInput = await investmentStore.positionsViewInput(
        title: account.name, range: positionsRange)
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
      HStack {
        Text("Valuations")
          .font(.headline)
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

      Divider()

      if investmentStore.values.isEmpty && !investmentStore.isLoading {
        ContentUnavailableView(
          "No Values",
          systemImage: "chart.line.uptrend.xyaxis",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(buttonLabel: "+", suffix: "to record a value")
          )
        )
      } else {
        List {
          ForEach(investmentStore.values) { value in
            InvestmentValueRow(value: value) {
              Task {
                await investmentStore.removeValue(accountId: account.id, date: value.date)
              }
            }
          }
        }
        .listStyle(.inset)
      }
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

#Preview {
  let (backend, _) = PreviewBackend.create()
  let investmentStore = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService
  )
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )
  let session = ProfileSession(profile: Profile(label: "Preview", backendType: .moolah))
  let account = Account(
    name: "Brokerage",
    type: .investment,
    instrument: .AUD
  )

  NavigationStack {
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
  .task {
    _ = try? await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: .AUD))
    let calendar = Calendar.current
    for monthsAgo in (0..<6).reversed() {
      let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date())!
      let quantity: Decimal = 9_500 + Decimal(6 - monthsAgo) * 400
      await investmentStore.setValue(
        accountId: account.id,
        date: date,
        value: InstrumentAmount(quantity: quantity, instrument: .AUD)
      )
    }
  }
}

#Preview("Position-tracked") {
  let (backend, _) = PreviewBackend.create()
  let investmentStore = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService
  )
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )
  let session = ProfileSession(profile: Profile(label: "Preview", backendType: .moolah))
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
  .task {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    _ = try? await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: .AUD))
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date().addingTimeInterval(-86_400 * 30),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .income),
          TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .expense),
        ]
      )
    )
  }
}
