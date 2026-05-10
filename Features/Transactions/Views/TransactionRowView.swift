import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmounts: [InstrumentAmount]
  let balance: InstrumentAmount?
  let scopeReferenceInstrument: Instrument
  var hideEarmark: Bool = false
  var viewingAccountId: UUID?

  /// When true, the payee header shows a red `exclamationmark.triangle.fill`
  /// leading icon and the payee text renders in red. Used by the
  /// `.scheduledStatus` grouping for overdue rows.
  var isOverdue: Bool = false

  /// When true, the date in the meta row renders in orange and bold,
  /// indicating the scheduled transaction is due today. Used by the
  /// `.scheduledStatus` grouping.
  var isDueToday: Bool = false

  /// Optional inline Pay button. When non-nil, the row renders a trailing
  /// "Pay" button that invokes the closure. When nil (the default), no
  /// button is rendered. Used by the `.scheduledStatus` grouping.
  var onPay: (() -> Void)?

  /// When non-nil and equal to this row's transaction id, the inline Pay
  /// area is replaced by a small `ProgressView` with a payee-parameterised
  /// `.accessibilityLabel`, and the row is `.disabled(true)`. Used by the
  /// `.scheduledStatus` grouping for the in-progress pay flow.
  var pendingPayId: Transaction.ID?

  #if os(macOS)
    @ScaledMetric private var verticalPadding: CGFloat = 8
  #else
    @ScaledMetric private var verticalPadding: CGFloat = 12
  #endif

  @Environment(\.spamInstruments) private var spamInstruments

  // MARK: - Body & View Builders

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
        .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)
        .accessibilityHidden(true)
      infoColumn
      Spacer()
      amountColumn
      payAffordance
    }
    .padding(.vertical, verticalPadding)
    .disabled(isPaying)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  // MARK: - Title

  private var infoColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      titleRow
      metadataRow
    }
  }

  private var titleRow: some View {
    HStack(spacing: 4) {
      if isOverdue {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      titleTextValue
        .lineLimit(1)
        .foregroundStyle(isOverdue ? Color.red : Color.primary)
    }
  }

  /// Composed title for the row. For trade transactions, builds a `Text`
  /// concatenation that may include inline spam markers (red SF Symbol +
  /// "Spam" substituted for the spam-flagged leg's instrument symbol). For
  /// other transactions, returns the plain payee.
  private var titleTextValue: Text {
    let payee = displayPayee
    if let sentence = transaction.tradeTitleText(
      scopeReference: scopeReferenceInstrument,
      spamInstruments: spamInstruments
    ) {
      if payee.isEmpty {
        return sentence
      }
      return Text("\(payee) (\(sentence))")
    }
    return Text(payee)
  }

  /// Plain-string equivalent of the title used by `accessibilityDescription`.
  /// Reuses `tradeTitleSegments` and joins via `accessibilityString` so spam
  /// magnitudes read as "<magnitude> spam token" instead of triggering the
  /// glyph-as-punctuation announcement that `tradeTitleText` would emit.
  private var titleAccessibilityString: String {
    let payee = displayPayee
    let segments = transaction.tradeTitleSegments(
      scopeReference: scopeReferenceInstrument,
      spamInstruments: spamInstruments)
    guard !segments.isEmpty else { return payee }
    let sentence = segments.map(\.accessibilityString).joined()
    return payee.isEmpty ? sentence : "\(payee) (\(sentence))"
  }

  // MARK: - Metadata Row

  private var metadataRow: some View {
    HStack(spacing: 4) {
      Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
        .foregroundStyle(isDueToday ? Color.orange : Color.secondary)
        .fontWeight(isDueToday ? .semibold : .regular)
        .monospacedDigit()
      if let recurrence = recurrenceDescription {
        Text("·")
        Text(recurrence)
      }
      ForEach(categoryNames, id: \.self) { name in
        Text("·")
        Label(name, systemImage: "tag")
          .labelStyle(.iconOnly)
          .imageScale(.small)
        Text(name)
      }
      if !hideEarmark {
        ForEach(earmarkNames, id: \.self) { name in
          Text("·")
          Label(name, systemImage: "bookmark.fill")
            .labelStyle(.iconOnly)
            .imageScale(.small)
          Text(name)
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private var payAffordance: some View {
    if isPaying {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Paying \(displayPayee), please wait")
    } else if let onPay {
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
  }

  // MARK: - Computed Display Properties

  private var isPaying: Bool {
    pendingPayId != nil && pendingPayId == transaction.id
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

  // MARK: - Amount Column

  private var amountColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if displayAmounts.isEmpty {
        Text("—")
          .font(.body)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        TransactionAmountFlow(
          amounts: displayAmounts,
          spamInstruments: spamInstruments)
      }
      if let balance {
        SpamAwareAmountView(
          amount: balance,
          spamInstruments: spamInstruments,
          font: .caption)
      }
    }
  }

  // MARK: - Accessibility

  private var accessibilityDescription: String {
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    let amountStr =
      displayAmounts.isEmpty
      ? "amount unavailable"
      : displayAmounts
        .map { $0.accessibilityString(isSpam: spamInstruments.contains($0.instrument)) }
        .joined(separator: " and ")
    let typeStr: String
    if transaction.isTrade {
      typeStr = TransactionType.trade.displayName
    } else if transaction.isSimple, let type = transaction.legs.first?.type {
      typeStr = type.displayName
    } else {
      typeStr = "Custom transaction"
    }
    var parts: [String] = []
    if isOverdue {
      parts.append("Overdue")
    }
    parts.append(typeStr)
    parts.append(titleAccessibilityString)
    parts.append(amountStr)
    if isDueToday {
      parts.append("due today, \(dateStr)")
    } else {
      parts.append(dateStr)
    }
    if let balance {
      parts.append(
        "balance \(balance.accessibilityString(isSpam: spamInstruments.contains(balance.instrument)))"
      )
    }
    if let recurrence = recurrenceDescription {
      parts.append("repeats \(recurrence)")
    }
    return parts.joined(separator: ", ")
  }

  // MARK: - Icon

  private var iconName: String {
    if transaction.isTrade { return "arrow.up.arrow.down" }
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return "arrow.trianglehead.branch"
    }
    switch type {
    case .income: return "arrow.up"
    case .expense: return "arrow.down"
    case .transfer: return "arrow.left.arrow.right"
    case .openingBalance: return "flag.fill"
    case .trade: return "arrow.up.arrow.down"
    }
  }

  private var iconColor: Color {
    if transaction.isTrade { return .indigo }
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return .purple
    }
    switch type {
    case .income: return .green
    case .expense: return .red
    case .transfer: return .blue
    case .openingBalance: return .orange
    case .trade: return .indigo
    }
  }

  private var categoryNames: [String] {
    let applicable =
      viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
      } ?? transaction.legs
    let uniqueIds = applicable.compactMap(\.categoryId).uniqued()
    return uniqueIds.compactMap { id in categories.by(id: id).map { categories.path(for: $0) } }
  }

  private var earmarkNames: [String] {
    let applicable =
      viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
      } ?? transaction.legs
    let uniqueIds = applicable.compactMap(\.earmarkId).uniqued()
    return uniqueIds.compactMap { earmarks.by(id: $0)?.name }
  }

  private var displayPayee: String {
    transaction.displayPayee(
      viewingAccountId: viewingAccountId, accounts: accounts, earmarks: earmarks)
  }

}
