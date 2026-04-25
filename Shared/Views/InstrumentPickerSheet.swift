import SwiftUI

struct InstrumentPickerSheet: View {
  @Bindable var store: InstrumentPickerStore
  let label: LocalizedStringResource
  @Binding var selection: Instrument
  @Binding var isPresented: Bool

  var body: some View {
    #if os(macOS)
      macOSContent
    #else
      navigationStack
        .accessibilityIdentifier("instrumentPicker.sheet")
    #endif
  }

  // MARK: - Platform layouts

  #if os(macOS)
    /// macOS: custom VStack layout.
    ///
    /// A NavigationStack inside a popover does not render an accessible
    /// search field on macOS (`.searchable` is suppressed in that context).
    /// Instead we use an explicit `TextField` whose identifier surfaces in the
    /// XCUITest tree, and place `instrumentPicker.sheet` on the Cancel button
    /// so the driver can detect picker open/closed without relying on a
    /// container-level identifier (which SwiftUI propagates to all children,
    /// overriding child identifiers).
    private var macOSContent: some View {
      VStack(spacing: 0) {
        macOSHeader
        Divider()
        macOSSearchField
        Divider()
        listContent
      }
      // Use ObjectIdentifier as task id so the task re-runs whenever the store
      // instance is replaced (e.g. when the picker is reopened via openPicker()).
      .task(id: ObjectIdentifier(store)) { await store.start() }
    }

    private var macOSHeader: some View {
      HStack {
        Text("Choose \(String(localized: label))")
          .font(.headline)
        Spacer()
        Button("Cancel") { isPresented = false }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          // Drives tap() and pickRow() in InstrumentPickerFieldDriver:
          // present ↔ cancel button exists; dismissed ↔ it doesn't.
          .accessibilityIdentifier("instrumentPicker.sheet")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }

    private var macOSSearchField: some View {
      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField(
          "Search",
          text: Binding(
            get: { store.query },
            set: { store.updateQuery($0) }
          )
        )
        .textFieldStyle(.plain)
        .accessibilityIdentifier("instrumentPicker.searchField")
        if !store.query.isEmpty {
          Button {
            store.updateQuery("")
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  #endif

  // MARK: - Shared layouts

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
    .task { await store.start() }
  }

  @ViewBuilder private var listContent: some View {
    if store.results.isEmpty && !store.query.isEmpty {
      ContentUnavailableView(
        "No matches",
        systemImage: "magnifyingglass",
        description: Text(
          "No matching currencies, stocks, or registered tokens for \"\(store.query)\".")
      )
    } else {
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
        if store.kinds.contains(.cryptoToken) {
          Section {
            Text("Add a crypto token in Settings → Crypto Tokens.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func row(for result: InstrumentSearchResult) -> some View {
    Button {
      if result.isRegistered {
        selection = result.instrument
        isPresented = false
      } else {
        Task {
          if let chosen = await store.select(result) {
            selection = chosen
            isPresented = false
          }
        }
      }
    } label: {
      HStack(spacing: 10) {
        glyph(for: result.instrument)
          .accessibilityHidden(true)
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
            .accessibilityHidden(true)
        }
        if result.instrument == selection {
          Image(systemName: "checkmark").foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("instrumentPicker.row.\(result.instrument.id)")
    .accessibilityLabel(
      Text(
        result.isRegistered
          ? "\(result.instrument.id), \(result.instrument.name)"
          : "\(result.instrument.id), \(result.instrument.name), new")
    )
    .accessibilityAddTraits(result.instrument == selection ? .isSelected : [])
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
