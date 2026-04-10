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

  @State private var showingAddValue = false

  var body: some View {
    VStack(spacing: 0) {
      // Summary panels at top
      if account.investmentValue != nil {
        InvestmentSummaryView(account: account, store: investmentStore)
          .padding(.horizontal)
          .padding(.top)
      }

      // Chart + valuations side by side
      HStack(alignment: .top, spacing: 0) {
        // Chart with time period picker
        VStack(spacing: 16) {
          timePeriodPicker
          InvestmentChartView(
            dataPoints: investmentStore.chartDataPoints, currency: account.balance.currency)
        }
        .padding()

        Divider()

        // Valuations list
        valuationsList
          .frame(width: 240)
      }

      Divider()

      // Transaction list fills remaining space
      TransactionListView(
        title: "",
        filter: TransactionFilter(accountId: account.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
    }
    .profileNavigationTitle(account.name)
    .sheet(isPresented: $showingAddValue) {
      AddInvestmentValueView(
        accountId: account.id, currency: account.balance.currency, store: investmentStore)
    }
    .task(id: account.id) {
      await investmentStore.loadAll(accountId: account.id)
    }
    .refreshable {
      await investmentStore.loadAll(accountId: account.id)
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
