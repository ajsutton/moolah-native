import SwiftUI

/// One-screen Needs Setup form per the design doc. Presented as a sheet from
/// `NeedsSetupAndFailedPanel`. Lets the user pick the target account, review
/// the detected parser / mapping, preview the first five rows, set a
/// filename pattern, and toggle delete-after-import.
struct CSVImportSetupView: View {
  let store: CSVImportSetupStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(\.dismiss) private var dismiss

  @State private var dateFormatChoice: DateFormatChoice = .auto

  enum DateFormatChoice: String, Hashable, CaseIterable, Identifiable {
    case auto
    case ddMMYYYY
    case mmDDYYYY
    case iso
    var id: String { rawValue }
    var label: String {
      switch self {
      case .auto: return "Auto-detect"
      case .ddMMYYYY: return "DD/MM/YYYY"
      case .mmDDYYYY: return "MM/DD/YYYY"
      case .iso: return "YYYY-MM-DD"
      }
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(header: Text("File")) {
          LabeledContent("Filename", value: store.pending.originalFilename)
          LabeledContent("Parser", value: store.detectedParserIdentifier)
          LabeledContent("Rows") {
            Text("\(store.rowCount)").monospacedDigit()
          }
        }

        Section(header: Text("Target account")) {
          Picker(
            "Account",
            selection: Binding(
              get: { store.targetAccountId },
              set: { store.targetAccountId = $0 }
            )
          ) {
            Text("Select…").tag(UUID?.none)
            ForEach(availableAccounts, id: \.id) { account in
              Text(account.name).tag(UUID?.some(account.id))
            }
          }
        }

        if store.isGenericParser, let mapping = store.detectedMapping {
          Section(header: Text("Column mapping")) {
            columnMappingRows(mapping: mapping)
            Picker("Date format", selection: $dateFormatChoice) {
              ForEach(DateFormatChoice.allCases) { choice in
                Text(choice.label).tag(choice)
              }
            }
            if mapping.dateFormatAmbiguous {
              Label(
                "Dates are ambiguous — pick the format to match your file.",
                systemImage: "exclamationmark.triangle"
              )
              .foregroundStyle(.orange)
              .font(.caption)
            }
          }
        }

        if !store.preview.isEmpty {
          Section(header: Text("Preview (first 5 rows)")) {
            ForEach(Array(store.preview.enumerated()), id: \.offset) { _, tx in
              PreviewRow(transaction: tx)
            }
          }
        }

        Section(header: Text("Options")) {
          TextField(
            "Filename pattern",
            text: Binding(
              get: { store.filenamePattern },
              set: { store.filenamePattern = $0 })
          )
          .textFieldStyle(.roundedBorder)
          Toggle(
            "Delete CSV after import",
            isOn: Binding(
              get: { store.deleteAfterImport },
              set: { store.deleteAfterImport = $0 }))
        }

        if let error = store.saveError {
          Label(error, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Set up CSV import")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            store.cancel()
            dismiss()
          }
        }
        ToolbarItem(placement: .destructiveAction) {
          Button("Delete", role: .destructive) {
            Task {
              await store.deletePending()
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save & Import") {
            Task {
              _ = await store.saveAndImport()
              if store.saveError == nil {
                dismiss()
              }
            }
          }
          .disabled(store.targetAccountId == nil || store.isSaving)
        }
      }
      .task {
        await store.regeneratePreview()
      }
      .onChange(of: dateFormatChoice) { _, newValue in
        store.dateFormatOverride = newValue.resolved
        Task { await store.regeneratePreview() }
      }
    }
  }

  private var availableAccounts: [Account] {
    accountStore.accounts.ordered.filter { !$0.isHidden }
  }

  @ViewBuilder
  private func columnMappingRows(
    mapping: GenericBankCSVParser.ColumnMapping
  ) -> some View {
    let entries: [(label: String, index: Int?)] = [
      ("Date", mapping.date),
      ("Description", mapping.description),
      ("Amount", mapping.amount),
      ("Debit", mapping.debit),
      ("Credit", mapping.credit),
      ("Balance", mapping.balance),
      ("Reference", mapping.reference),
    ]
    ForEach(entries, id: \.label) { entry in
      HStack {
        Text(entry.label)
        Spacer()
        if let index = entry.index, index < store.detectedHeaders.count {
          Text(store.detectedHeaders[index])
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else {
          Text("—").foregroundStyle(.secondary)
        }
      }
    }
  }
}

extension CSVImportSetupView.DateFormatChoice {
  /// Resolve to a concrete `GenericBankCSVParser.DateFormat` when the user
  /// overrides detection. `nil` means "use the detector's pick".
  var resolved: GenericBankCSVParser.DateFormat? {
    switch self {
    case .auto: return nil
    case .ddMMYYYY: return .ddMMyyyy(separator: "/")
    case .mmDDYYYY: return .mmDDyyyy(separator: "/")
    case .iso: return .iso
    }
  }
}

/// Renders one preview row using the parsed payee/amount/date — the rules
/// engine hasn't run yet so the payee is the raw description.
private struct PreviewRow: View {
  let transaction: ParsedTransaction
  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(transaction.rawDescription).lineLimit(1)
        Text(transaction.date, format: .dateTime.day().month().year())
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      Spacer()
      Text(transaction.rawAmount, format: .number.precision(.fractionLength(2)))
        .monospacedDigit()
    }
  }
}
