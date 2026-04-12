// Features/Transactions/TokenSwapView.swift
import SwiftUI

struct TokenSwapView: View {
  let accountId: UUID
  let categories: Categories
  let tradeStore: TradeStore

  @State private var draft: TokenSwapDraft
  @State private var showGasFee = false
  @State private var isSaving = false
  @Environment(\.dismiss) private var dismiss

  init(
    accountId: UUID,
    categories: Categories,
    tradeStore: TradeStore
  ) {
    self.accountId = accountId
    self.categories = categories
    self.tradeStore = tradeStore
    self._draft = State(initialValue: TokenSwapDraft(accountId: accountId))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("You Send") {
          instrumentField(
            label: "Token",
            instrument: draft.sourceInstrument
          )
          quantityField(
            label: "Amount",
            value: $draft.sourceQuantity,
            instrument: draft.sourceInstrument
          )
        }

        Section("You Receive") {
          instrumentField(
            label: "Token",
            instrument: draft.destinationInstrument
          )
          quantityField(
            label: "Amount",
            value: $draft.destinationQuantity,
            instrument: draft.destinationInstrument
          )
        }

        Section {
          DatePicker("Date", selection: $draft.date, displayedComponents: .date)
        }

        Section {
          Toggle("Include Gas Fee", isOn: $showGasFee)
          if showGasFee {
            instrumentField(
              label: "Fee Token",
              instrument: draft.gasFeeInstrument
            )
            quantityField(
              label: "Fee Amount",
              value: $draft.gasFeeQuantity,
              instrument: draft.gasFeeInstrument
            )
            Picker("Fee Category", selection: $draft.gasFeeCategoryId) {
              Text("None").tag(UUID?.none)
              ForEach(categories.roots) { category in
                Text(category.name).tag(Optional(category.id))
              }
            }
          }
        }

        Section {
          TextField(
            "Notes",
            text: Binding(
              get: { draft.notes ?? "" },
              set: { draft.notes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical
          )
          .lineLimit(3...)
        }
      }
      .navigationTitle("Token Swap")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Swap") {
            Task { await save() }
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

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    let transaction = draft.buildTransaction()
    do {
      _ = try await tradeStore.executeSwap(transaction)
      dismiss()
    } catch {
      // Error is captured on tradeStore.error
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private func instrumentField(
    label: String,
    instrument: Instrument?
  ) -> some View {
    HStack {
      Text(label)
      Spacer()
      if let inst = instrument {
        Text(inst.displaySymbol ?? inst.name)
          .foregroundStyle(.secondary)
      } else {
        Text("Select")
          .foregroundStyle(.tertiary)
      }
    }
    // TODO: Replace with full instrument picker sheet
  }

  @ViewBuilder
  private func quantityField(
    label: String,
    value: Binding<Decimal>,
    instrument: Instrument?
  ) -> some View {
    let maxDecimals = instrument?.decimals ?? 18
    TextField(label, value: value, format: .number.precision(.fractionLength(0...maxDecimals)))
      .monospacedDigit()
      .accessibilityLabel(label)
      #if os(iOS)
        .keyboardType(.decimalPad)
      #endif
  }
}
