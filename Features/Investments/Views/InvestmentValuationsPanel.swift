import SwiftUI

/// Side-of-chart valuations panel rendered on the legacy
/// (`recordedValue`) investment layout. Composes a "Valuations"
/// header (with a "+ Record Value" action) above either a
/// `ContentUnavailableView` (when no snapshots exist and the store
/// isn't loading) or a list of `InvestmentValueListRow`s with per-row
/// delete.
///
/// macOS body uses a `VStack(Divider-separated)` rather than `List` so
/// the panel grows to its content height when embedded inside an outer
/// transaction-list scroll surface — no nested scroll, no wasted blank
/// rows. iOS keeps `List` for native swipe / refresh affordances.
struct InvestmentValuationsPanel: View {
  let store: InvestmentStore
  let accountId: UUID
  @Binding var showingAddValue: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      bodyContent
    }
  }

  private var header: some View {
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
      // `.iconOnly` style hides the title from screen readers on iOS,
      // which then announce the SF Symbol name ("plus") instead of
      // the action. Pin the action label explicitly so VoiceOver reads
      // "Record Value".
      .accessibilityLabel("Record Value")
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  @ViewBuilder private var bodyContent: some View {
    if store.values.isEmpty && !store.isLoading {
      ContentUnavailableView(
        "No recorded valuations yet",
        systemImage: "chart.line.uptrend.xyaxis",
        description: Text(
          PlatformActionVerb.emptyStatePrompt(
            buttonLabel: "+",
            suffix: "to record a value"))
      )
    } else {
      #if os(macOS)
        VStack(spacing: 0) {
          ForEach(store.values) { value in
            InvestmentValueListRow(value: value) {
              deleteValue(value)
            }
            Divider()
          }
        }
      #else
        List {
          ForEach(store.values) { value in
            InvestmentValueListRow(value: value) {
              deleteValue(value)
            }
          }
        }
        .listStyle(.inset)
      #endif
    }
  }

  private func deleteValue(_ value: InvestmentValue) {
    Task {
      await store.removeValue(accountId: accountId, date: value.date)
    }
  }
}

#Preview("Empty state") {
  let backend = PreviewBackend.create()
  let store = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService)
  return InvestmentValuationsPanel(
    store: store,
    accountId: UUID(),
    showingAddValue: .constant(false)
  )
  .frame(width: 240, height: 320)
}

#Preview("With values") {
  let backend = PreviewBackend.create()
  let store = InvestmentStore(
    repository: backend.investments,
    transactionRepository: backend.transactions,
    conversionService: backend.conversionService)
  let account = Account(name: "Brokerage", type: .investment, instrument: .AUD)
  return InvestmentValuationsPanel(
    store: store,
    accountId: account.id,
    showingAddValue: .constant(false)
  )
  .frame(width: 240, height: 480)
  .task {
    _ = try? await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: .AUD))
    let calendar = Calendar.current
    for monthsAgo in (0..<6).reversed() {
      let date = calendar.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
      let quantity: Decimal = 9_500 + Decimal(6 - monthsAgo) * 400
      await store.setValue(
        accountId: account.id,
        date: date,
        value: InstrumentAmount(quantity: quantity, instrument: .AUD))
    }
    await store.loadValues(accountId: account.id)
  }
}
