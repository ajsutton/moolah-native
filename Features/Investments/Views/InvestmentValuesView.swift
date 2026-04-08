import Charts
import SwiftUI

struct InvestmentValuesView: View {
  let account: Account
  let store: InvestmentStore
  @State private var showingAddValue = false

  var body: some View {
    VStack(spacing: 0) {
      if store.values.isEmpty && !store.isLoading {
        ContentUnavailableView(
          "No Values Recorded",
          systemImage: "chart.line.uptrend.xyaxis",
          description: Text("Tap + to record your first investment value")
        )
      } else {
        if store.values.count > 1 {
          investmentChart
            .frame(height: 200)
            .padding()

          Divider()
        }

        List {
          ForEach(store.values) { value in
            InvestmentValueRow(value: value) {
              Task {
                await store.removeValue(accountId: account.id, date: value.date)
              }
            }
          }

          if store.hasMore {
            ProgressView()
              .frame(maxWidth: .infinity)
              .task {
                await store.loadValues(accountId: account.id)
              }
          }
        }
        .listStyle(.inset)
      }
    }
    .navigationTitle(account.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingAddValue = true
        } label: {
          Label("Add Value", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $showingAddValue) {
      AddInvestmentValueView(accountId: account.id, store: store)
    }
    .task {
      await store.loadValues(accountId: account.id, reset: true)
    }
    .refreshable {
      await store.loadValues(accountId: account.id, reset: true)
    }
  }

  @ViewBuilder
  private var investmentChart: some View {
    let chartValues = store.values.reversed()
    Chart {
      ForEach(chartValues) { value in
        LineMark(
          x: .value("Date", value.date),
          y: .value("Value", value.value.decimalValue)
        )
        .foregroundStyle(Color.blue)
        .interpolationMethod(.catmullRom)

        AreaMark(
          x: .value("Date", value.date),
          y: .value("Value", value.value.decimalValue)
        )
        .foregroundStyle(Color.blue.opacity(0.1))
        .interpolationMethod(.catmullRom)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { axisValue in
        if let decimal = axisValue.as(Decimal.self) {
          AxisValueLabel {
            Text(decimal, format: .currency(code: Currency.defaultCurrency.code))
              .font(.caption)
              .monospacedDigit()
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks { axisValue in
        if let date = axisValue.as(Date.self) {
          AxisValueLabel {
            Text(date, format: .dateTime.month(.abbreviated).year())
              .font(.caption)
          }
        }
      }
    }
    .accessibilityLabel("Investment value over time")
  }
}
