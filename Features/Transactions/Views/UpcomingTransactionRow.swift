import SwiftUI

struct UpcomingTransactionRow: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmount: InstrumentAmount?
  let isOverdue: Bool
  var isDueToday: Bool = false
  let onPay: () -> Void

  var body: some View {
    HStack {
      rowSummary
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
      payButton
    }
    .contentShape(Rectangle())
  }

  private var rowSummary: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        payeeHeader
        metaRow
      }
      Spacer()
      amountView
    }
  }

  private var payeeHeader: some View {
    HStack(spacing: 4) {
      if isOverdue {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      Text(displayPayee)
        .font(.headline)
        .foregroundStyle(isOverdue ? .red : .primary)
    }
  }

  private var metaRow: some View {
    HStack(spacing: 4) {
      Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
        .font(.caption)
        .foregroundStyle(isDueToday ? .orange : .secondary)
        .fontWeight(isDueToday ? .semibold : .regular)
        .monospacedDigit()

      if let recurrence = recurrenceDescription {
        metaSeparator
        Text(recurrence).font(.caption).foregroundStyle(.secondary)
      }

      ForEach(transaction.legs.compactMap(\.categoryId).uniqued(), id: \.self) { catId in
        if let category = categories.by(id: catId) {
          metaSeparator
          Text(category.name).font(.caption).foregroundStyle(.secondary)
        }
      }

      ForEach(transaction.legs.compactMap(\.earmarkId).uniqued(), id: \.self) { eid in
        if let earmark = earmarks.by(id: eid) {
          metaSeparator
          Text(earmark.name).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var metaSeparator: some View {
    Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
  }

  @ViewBuilder private var amountView: some View {
    if let displayAmount {
      InstrumentAmountView(amount: displayAmount, font: .body)
    } else {
      Text("—").font(.body).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  private var payButton: some View {
    Button("Pay") { onPay() }
      #if os(iOS)
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
      #else
        .buttonStyle(.bordered)
        .controlSize(.small)
      #endif
      .accessibilityLabel("Pay \(displayPayee)")
  }

  private var accessibilityDescription: String {
    var parts: [String] = []
    if isOverdue {
      parts.append("Overdue")
    }
    parts.append(displayPayee)
    let amountStr = displayAmount?.formatted ?? "amount unavailable"
    parts.append(amountStr)
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    if isDueToday {
      parts.append("due today, \(dateStr)")
    } else {
      parts.append(dateStr)
    }
    if let recurrence = recurrenceDescription {
      parts.append("repeats \(recurrence)")
    }
    let categoryNames = transaction.legs.compactMap(\.categoryId).uniqued()
      .compactMap { categories.by(id: $0)?.name }
    parts.append(contentsOf: categoryNames)
    let earmarkNames = transaction.legs.compactMap(\.earmarkId).uniqued()
      .compactMap { earmarks.by(id: $0)?.name }
    parts.append(contentsOf: earmarkNames)
    return parts.joined(separator: ", ")
  }

  private var displayPayee: String {
    let label = transaction.displayPayee(
      viewingAccountId: nil, accounts: accounts, earmarks: earmarks)
    return label.isEmpty ? "Untitled" : label
  }

  private var recurrenceDescription: String? {
    guard let period = transaction.recurPeriod,
      let every = transaction.recurEvery,
      period != .once
    else {
      return nil
    }
    return period.recurrenceDescription(every: every)
  }
}
