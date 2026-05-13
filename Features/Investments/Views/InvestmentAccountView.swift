import OSLog
import SwiftUI

/// Anchor `@AccessibilityFocusState` reads/writes inside
/// `InvestmentAccountView`. File-private so the type's body stays focused
/// on layout; only one case is required because every relayout target is
/// the same logical "content has just (re-)mounted" event.
private enum InvestmentAccountFocusAnchor: Hashable {
  case content
}

/// Enforces Apple's iOS HIG 44×44 pt minimum touch target on the
/// time-period picker buttons. macOS uses pointer precision so the
/// modifier is a no-op there; the wrapping lets the call site stay
/// declarative without `#if` clutter.
private struct TimePeriodHitTarget: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
      content.frame(minHeight: 44).contentShape(Rectangle())
    #else
      content
    #endif
  }
}

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

  /// Anchor VoiceOver moves to whenever the layout changes — initial-load
  /// completion or a switch between `recordedValue` / `calculatedFromTrades`.
  /// Without this, focus lingers on a button or row from the previous layout
  /// and reads back unrelated content.
  @AccessibilityFocusState private var focusAnchor: InvestmentAccountFocusAnchor?

  /// Embedded transaction list for this account. Each call site builds a
  /// fresh `TransactionListView`; this is a method (not a `@ViewBuilder`
  /// computed property) so the per-call instantiation is explicit at the
  /// call site rather than masquerading as a stable view value.
  @ViewBuilder
  private func makeAccountTransactionList() -> some View {
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

  @ViewBuilder
  private func makeAccountTransactionList<TopAccessory: View>(
    @ViewBuilder topAccessory: () -> TopAccessory
  ) -> some View {
    TransactionListView(
      title: "",
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      selectedTransaction: $selectedTransaction,
      topAccessory: topAccessory
    )
  }

  /// The positions/transactions composition for non-legacy accounts. Collapses
  /// to a bare transaction list when `PositionsView` would be redundant with
  /// the host's already-visible account balance (see `shouldHide`).
  @ViewBuilder private var positionTrackedLayout: some View {
    if positionsInput.shouldHide && !isLoadingPositions {
      makeAccountTransactionList()
    } else {
      #if os(macOS)
        makeAccountTransactionList {
          if isLoadingPositions && positionsInput.positions.isEmpty {
            ProgressView()
              .frame(maxWidth: .infinity)
              .padding()
          } else {
            PositionsView(input: positionsInput, range: $positionsRange)
          }
        }
      #else
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
          makeAccountTransactionList()
        }
      #endif
    }
  }

  @ViewBuilder private var legacyValuationsLayout: some View {
    #if os(macOS)
      makeAccountTransactionList {
        VStack(spacing: 0) {
          legacySummary
          legacyChartAndValuations
          Divider()
        }
      }
    #else
      RecordedValueInvestmentLayout {
        legacySummary
      } chartAndValuations: {
        legacyChartAndValuations
      } transactions: {
        makeAccountTransactionList()
      }
    #endif
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

        InvestmentValuationsPanel(
          store: investmentStore,
          accountId: account.id,
          showingAddValue: $showingAddValue
        )
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

        InvestmentValuationsPanel(
          store: investmentStore,
          accountId: account.id,
          showingAddValue: $showingAddValue
        )
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
    .accessibilityFocused($focusAnchor, equals: .content)
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
      await reloadPositions()
      initialLoadComplete = true
      // Move VoiceOver focus to the now-rendered content layout once the
      // initial-load gate flips. Mirrored on layout-mode flips below.
      focusAnchor = .content
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
    .onChange(of: account.valuationMode) {
      // Layout-mode flip: reanchor VoiceOver after the new layout mounts.
      // The `.task(id:)` above also fires (LoadKey carries `mode`), so
      // `focusAnchor = .content` is set there once the data load
      // completes — but the reassignment here additionally guarantees a
      // focus move when the data load is a no-op (already cached).
      focusAnchor = .content
    }
    .refreshable {
      await reloadPositions()
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
              .modifier(TimePeriodHitTarget())
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

// MARK: - Private helpers

extension InvestmentAccountView {
  /// The profile's reporting currency — used for valuing positions and the
  /// chart series. NOT the account's own instrument: an investment account
  /// can be denominated in a non-fiat instrument (e.g., a crypto wallet),
  /// but valuations should always roll up into the user's fiat currency.
  private var profileCurrencyInstrument: Instrument {
    session.profile.instrument
  }

  /// Drives the full `loadAllData → positionsViewInput` rebuild used by
  /// both `.task(id:)` and `.refreshable`. Sets `isLoadingPositions`
  /// across the work so progress UI binds correctly.
  private func reloadPositions() async {
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

// Preview seeds and `#Preview` blocks live in InvestmentAccountView+Previews.swift
