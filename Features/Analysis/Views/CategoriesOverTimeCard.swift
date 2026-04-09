import Charts
import SwiftUI

struct CategoriesOverTimeCard: View {
  let entries: [CategoryOverTimeEntry]
  let categories: Categories
  @Binding var showActualValues: Bool

  @State private var selectedDate: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Expenses by Category Over Time")
          .font(.title2)
          .fontWeight(.semibold)

        Spacer()

        Picker("Values", selection: $showActualValues) {
          Text("Percentage").tag(false)
          Text("Actual").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
        .accessibilityLabel("Toggle between percentage and actual values")
      }

      if entries.isEmpty {
        emptyState
      } else {
        chart
        legend
      }
    }
    .padding()
    #if os(macOS)
      .background(Color(nsColor: .controlBackgroundColor))
    #else
      .background(Color(uiColor: .systemBackground))
    #endif
    .cornerRadius(12)
  }

  private var emptyState: some View {
    Text("No expense data available")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 300)
  }

  private var chart: some View {
    Chart {
      ForEach(entries) { entry in
        let name = categoryName(for: entry.categoryId)
        ForEach(entry.points) { point in
          AreaMark(
            x: .value("Month", point.monthDate),
            y: .value("Amount", showActualValues ? point.actualCents : Int(point.percentage)),
            stacking: .standard
          )
          .foregroundStyle(by: .value("Category", name))
        }
      }

      if let selectedDate {
        RuleMark(x: .value("Selected", selectedDate))
          .foregroundStyle(.gray.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartForegroundStyleScale(
      domain: entries.map { categoryName(for: $0.categoryId) },
      range: entries.map { categoryColor(for: $0.categoryId) }
    )
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 8)) { _ in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Int.self) {
            if showActualValues {
              Text(MonetaryAmount(cents: amount, currency: .defaultCurrency).formatNoSymbol)
                .monospacedDigit()
            } else {
              Text("\(amount)%")
                .monospacedDigit()
            }
          }
        }
      }
    }
    .chartXSelection(value: $selectedDate)
    .frame(height: 400)
    .accessibilityLabel(
      "Stacked area chart showing expense categories over time in \(showActualValues ? "actual amounts" : "percentages")"
    )
  }

  private var legend: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
      ForEach(entries) { entry in
        HStack(spacing: 4) {
          Circle()
            .fill(categoryColor(for: entry.categoryId))
            .frame(width: 10, height: 10)
          Text(categoryName(for: entry.categoryId))
            .font(.caption)
            .lineLimit(1)
          Spacer()
          Text(MonetaryAmount(cents: entry.totalCents, currency: .defaultCurrency).formatNoSymbol)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(categoryName(for: entry.categoryId)): \(MonetaryAmount(cents: entry.totalCents, currency: .defaultCurrency).formatNoSymbol)"
        )
      }
    }
  }

  private func categoryName(for id: UUID?) -> String {
    guard let id else { return "Uncategorized" }
    return categories.by(id: id)?.name ?? "Unknown"
  }

  private static let chartPalette: [Color] = [
    .blue, .green, .orange, .purple, .red, .teal, .indigo, .pink, .mint, .cyan, .brown, .yellow,
  ]

  private func categoryColor(for id: UUID?) -> Color {
    guard let id else { return .gray }
    let index = abs(id.hashValue) % Self.chartPalette.count
    return Self.chartPalette[index]
  }
}

#Preview {
  let categories = [
    Category(id: UUID(), name: "Groceries"),
    Category(id: UUID(), name: "Transport"),
    Category(id: UUID(), name: "Entertainment"),
  ]

  let entries = categories.enumerated().map { index, category in
    CategoryOverTimeEntry(
      categoryId: category.id,
      points: (0..<6).map { month in
        CategoryOverTimePoint(
          month: "20260\(month + 1)",
          monthDate: Calendar.current.date(
            byAdding: .month, value: -5 + month, to: Date())!,
          actualCents: Int.random(in: 10000...50000),
          percentage: Double.random(in: 10...50)
        )
      },
      totalCents: Int.random(in: 60000...200000)
    )
  }

  CategoriesOverTimeCard(
    entries: entries,
    categories: Categories(from: categories),
    showActualValues: .constant(false)
  )
  .frame(width: 800)
  .padding()
}
