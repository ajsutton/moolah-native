import SwiftUI

struct InstrumentPickerSheet: View {
  @Bindable var store: InstrumentPickerStore
  let label: LocalizedStringResource
  @Binding var selection: Instrument
  @Binding var isPresented: Bool

  var body: some View {
    navigationStack
      .accessibilityIdentifier("instrumentPicker.sheet")
      #if os(macOS)
        .frame(minWidth: 400, minHeight: 480)
      #endif
      .task { await store.start() }
  }

  private var navigationStack: some View {
    NavigationStack {
      listContent
        .searchable(
          text: Binding(
            get: { store.query },
            set: { store.updateQuery($0) }
          )
        )
        .navigationTitle("Choose \(String(localized: label))")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { isPresented = false }
          }
        }
    }
  }

  @ViewBuilder private var listContent: some View {
    List {
      if let error = store.error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }
      ForEach(store.results) { result in
        row(for: result)
      }
      if store.results.isEmpty && !store.query.isEmpty {
        ContentUnavailableView(
          "No matches",
          systemImage: "magnifyingglass",
          description: Text(
            "No matching currencies, stocks, or registered tokens for \"\(store.query)\".")
        )
      }
      if store.kinds.contains(.cryptoToken) {
        Section {
          Text("Add a crypto token in Settings → Crypto Tokens.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func row(for result: InstrumentSearchResult) -> some View {
    Button {
      Task {
        if let chosen = await store.select(result) {
          selection = chosen
          isPresented = false
        }
      }
    } label: {
      HStack(spacing: 10) {
        glyph(for: result.instrument)
        VStack(alignment: .leading, spacing: 1) {
          Text(result.instrument.id).fontWeight(.medium)
          Text(result.instrument.name)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !result.isRegistered {
          Text("Add")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
        }
        if result.instrument == selection {
          Image(systemName: "checkmark").foregroundStyle(.tint)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("instrumentPicker.row.\(result.instrument.id)")
  }

  private func glyph(for instrument: Instrument) -> some View {
    let label: String =
      instrument.kind == .fiatCurrency
      ? (Instrument.preferredCurrencySymbol(for: instrument.id) ?? instrument.id)
      : (instrument.ticker ?? instrument.id)
    return Text(label)
      .font(.system(size: 12, weight: .semibold))
      .frame(width: 28, height: 28)
      .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }
}
