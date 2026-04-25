import SwiftUI

struct InstrumentPickerField: View {
  let label: LocalizedStringResource
  let kinds: Set<Instrument.Kind>
  @Binding var selection: Instrument

  @Environment(ProfileSession.self) private var session
  @State private var isPresented = false
  @State private var store: InstrumentPickerStore?

  var body: some View {
    Button {
      ensureStore()
      isPresented = true
    } label: {
      LabeledContent(String(localized: label)) {
        HStack(spacing: 6) {
          glyph
          Text(selection.id).fontWeight(.medium)
          Image(systemName: "chevron.right")
            .foregroundStyle(.tertiary)
            .font(.caption)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("instrumentPicker.field.\(selection.id)")
    .sheet(isPresented: $isPresented) {
      if let store {
        InstrumentPickerSheet(
          store: store,
          label: label,
          selection: $selection,
          isPresented: $isPresented)
      }
    }
  }

  private var glyph: some View {
    let labelText: String =
      selection.kind == .fiatCurrency
      ? (Instrument.preferredCurrencySymbol(for: selection.id) ?? selection.id)
      : (selection.ticker ?? selection.id)
    return Text(labelText)
      .font(.system(size: 11, weight: .semibold))
      .frame(width: 22, height: 22)
      .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
  }

  private func ensureStore() {
    guard store == nil,
      let service = session.instrumentSearchService,
      let registry = session.instrumentRegistry
    else { return }
    store = InstrumentPickerStore(
      searchService: service,
      registry: registry,
      kinds: kinds
    )
  }
}
