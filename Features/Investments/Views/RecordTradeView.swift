import SwiftUI

struct RecordTradeView: View {
  let accountId: UUID
  let profileCurrency: Instrument
  let categories: Categories
  let tradeStore: TradeStore

  @State private var draft: TradeDraft
  @State private var showFee = false
  @State private var isSaving = false
  @Environment(\.dismiss) private var dismiss

  init(
    accountId: UUID,
    profileCurrency: Instrument,
    categories: Categories,
    tradeStore: TradeStore
  ) {
    self.accountId = accountId
    self.profileCurrency = profileCurrency
    self.categories = categories
    self.tradeStore = tradeStore
    self._draft = State(initialValue: TradeDraft(accountId: accountId))
  }

  var body: some View {
    NavigationStack {
      Form {
        // Sold section
        Section("Selling") {
          instrumentPicker(
            label: "Instrument",
            selection: $draft.soldInstrument,
            defaultFiat: profileCurrency
          )
          TextField("Quantity", text: $draft.soldQuantityText)
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
            .monospacedDigit()
            .accessibilityLabel("Quantity sold")
        }

        // Bought section
        Section("Buying") {
          instrumentPicker(
            label: "Instrument",
            selection: $draft.boughtInstrument,
            defaultFiat: nil
          )
          TextField("Quantity", text: $draft.boughtQuantityText)
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
            .monospacedDigit()
            .accessibilityLabel("Quantity bought")
        }

        // Date
        Section {
          DatePicker("Date", selection: $draft.date, displayedComponents: .date)
        }

        // Fee (optional)
        Section {
          Toggle("Include Fee", isOn: $showFee)
          if showFee {
            TextField("Fee Amount", text: $draft.feeAmountText)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
              .monospacedDigit()
            // Category picker for fee
            Picker("Fee Category", selection: $draft.feeCategoryId) {
              Text("None").tag(UUID?.none)
              ForEach(categories.roots) { category in
                Text(category.name).tag(Optional(category.id))
              }
            }
          }
        }

        // Notes
        Section {
          TextField("Notes", text: $draft.notes, axis: .vertical)
            .lineLimit(3...)
        }
      }
      .navigationTitle("Record Trade")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Record") {
            Task {
              isSaving = true
              defer { isSaving = false }
              do {
                _ = try await tradeStore.executeTrade(draft)
                dismiss()
              } catch {
                // Error is captured on tradeStore.error
              }
            }
          }
          .disabled(!draft.isValid || isSaving)
        }
      }
      .alert("Error", isPresented: .constant(tradeStore.error != nil)) {
        Button("OK") { tradeStore.clearError() }
      } message: {
        if let error = tradeStore.error {
          Text(error.localizedDescription)
        }
      }
    }
  }

  // MARK: - Instrument Picker

  @ViewBuilder
  private func instrumentPicker(
    label: String,
    selection: Binding<Instrument?>,
    defaultFiat: Instrument?
  ) -> some View {
    // For Phase 3, this is a simplified display
    // Full instrument search/picker is a Phase 5 enhancement
    HStack {
      Text(label)
      Spacer()
      if let instrument = selection.wrappedValue {
        Text(instrument.name)
          .foregroundStyle(.secondary)
      } else {
        Text("Select")
          .foregroundStyle(.tertiary)
      }
    }
    // TODO: Replace with full instrument picker sheet in Phase 5
  }
}
