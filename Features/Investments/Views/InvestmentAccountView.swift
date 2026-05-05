import OSLog
import SwiftUI

/// Combined investment account view showing summary panels, chart with valuations list,
/// and an embedded transaction list.
struct InvestmentAccountView: View {
  /// Composite identity used to drive `.task(id:)`. Re-fires when either the
  /// account changes (navigation) or the valuation mode changes (sync push
  /// from another device, or the user-facing Picker once it ships) so
  /// `loadAllData` always runs against the active mode.
  private struct LoadKey: Equatable {
    let id: UUID
    let mode: ValuationMode
  }

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "InvestmentAccountView")

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
      PositionsTransactionsSplit(
        defaultTab: .positions,
        // Distinct autosave key from the chartless multi-currency split so
        // the saved divider position from each layout doesn't bleed into
        // the other; the chart pushes the table off-screen at the
        // chartless 180pt default.
        autosaveName: "positions-transactions-split.with-chart",
        // Header (~50pt) + chart (~250pt with padding) + a few table rows
        // need ~530pt to render comfortably without the user dragging.
        initialTopHeight: 540
      ) {
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
          .accessibilityLabel("Loading account data")
      } else {
        switch account.valuationMode {
        case .recordedValue:
          legacyValuationsLayout
            .id(ValuationMode.recordedValue)
        case .calculatedFromTrades:
          positionTrackedLayout
            .id(ValuationMode.calculatedFromTrades)
        }
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
    .task(id: LoadKey(id: account.id, mode: account.valuationMode)) {
      initialLoadComplete = false
      isLoadingPositions = true
      defer { isLoadingPositions = false }
      do {
        positionsInput = try await investmentStore.loadAndBuildPositionsInput(
          account: account,
          profileCurrency: profileCurrencyInstrument,
          range: positionsRange)
      } catch is CancellationError {
        return
      } catch {
        Self.logger.error(
          "Unexpected error from positionsViewInput: \(error.localizedDescription, privacy: .public)"
        )
      }
      initialLoadComplete = true
    }
    .task(id: positionsRange) {
      // Skip until loadAllData has populated the store; the .task(id:) keyed
      // on (account.id, valuationMode) runs the first build. We only fire
      // re-builds for subsequent range changes.
      guard investmentStore.loadedAccountId != nil else { return }
      do {
        positionsInput = try await investmentStore.positionsViewInput(
          title: account.name, range: positionsRange)
      } catch is CancellationError {
        return
      } catch {
        Self.logger.error(
          "Unexpected error from positionsViewInput: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    .refreshable {
      isLoadingPositions = true
      defer { isLoadingPositions = false }
      do {
        positionsInput = try await investmentStore.loadAndBuildPositionsInput(
          account: account,
          profileCurrency: profileCurrencyInstrument,
          range: positionsRange)
      } catch is CancellationError {
        return
      } catch {
        Self.logger.error(
          "Unexpected error from positionsViewInput: \(error.localizedDescription, privacy: .public)"
        )
      }
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

// Preview seeds and `#Preview` blocks live in InvestmentAccountView+Previews.swift
