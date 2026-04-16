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
  let tradeStore: TradeStore

  @Environment(ProfileSession.self) private var session
  @State private var showingAddValue = false
  @State private var showingRecordTrade = false
  @State private var selectedTransaction: Transaction?

  /// The profile's fiat currency instrument, derived from the account's balance.
  private var profileCurrencyInstrument: Instrument {
    account.instrument
  }

  var body: some View {
    VStack(spacing: 0) {
      if account.usesPositionTracking {
        // Position-tracked: show positions and trade button
        StockPositionsView(
          valuedPositions: investmentStore.valuedPositions,
          totalValue: investmentStore.totalPortfolioValue,
          profileCurrency: profileCurrencyInstrument
        )
      } else {
        // Legacy: show manual valuations
        if account.investmentValue != nil {
          InvestmentSummaryView(account: account, store: investmentStore)
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
      }

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
    .sheet(isPresented: $showingRecordTrade) {
      RecordTradeView(
        accountId: account.id,
        profileCurrency: profileCurrencyInstrument,
        categories: categories,
        tradeStore: tradeStore
      )
    }
    .toolbar {
      if account.usesPositionTracking {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showingRecordTrade = true
          } label: {
            Label("Record Trade", systemImage: "arrow.left.arrow.right")
          }
          .help("Record Trade")
        }
      }
    }
    .task(id: account.id) {
      if account.usesPositionTracking {
        await investmentStore.loadPositions(accountId: account.id)
        await investmentStore.valuatePositions(
          profileCurrency: profileCurrencyInstrument, on: Date())
      } else {
        await investmentStore.loadAll(accountId: account.id)
      }
    }
    .onChange(of: showingRecordTrade) { _, showing in
      if !showing && account.usesPositionTracking {
        Task {
          await investmentStore.loadPositions(accountId: account.id)
          await investmentStore.valuatePositions(
            profileCurrency: profileCurrencyInstrument, on: Date())
        }
      }
    }
    .refreshable {
      if account.usesPositionTracking {
        await investmentStore.loadPositions(accountId: account.id)
        await investmentStore.valuatePositions(
          profileCurrency: profileCurrencyInstrument, on: Date())
      } else {
        await investmentStore.loadAll(accountId: account.id)
      }
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
          description: Text("Tap + to record a value")
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
