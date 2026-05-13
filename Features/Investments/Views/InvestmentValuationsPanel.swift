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
        "No Values",
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
