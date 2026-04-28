import SwiftUI

// Profile detail views extracted from `SettingsView.swift` so the main
// settings file stays under SwiftLint's `file_length` threshold.
// `SettingsView.profileDetailView(for:)` routes here; each view maintains
// its own form state and persists changes back through `ProfileStore`.

/// Settings detail for an iCloud profile. Shows label, currency, and financial year start.
struct CloudKitProfileDetailView: View {
  @Environment(ProfileStore.self) private var profileStore
  let profile: Profile

  @State private var label: String
  @State private var currency: Instrument
  @State private var financialYearStartMonth: Int

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  init(profile: Profile) {
    self.profile = profile
    _label = State(initialValue: profile.label)
    _currency = State(initialValue: Instrument.fiat(code: profile.currencyCode))
    _financialYearStartMonth = State(initialValue: profile.financialYearStartMonth)
  }

  var body: some View {
    Form {
      Section("Profile") {
        TextField("Name", text: $label)
          .onChange(of: label) { _, _ in saveChanges() }

        HStack {
          Text("Storage")
          Spacer()
          Label("iCloud", systemImage: "icloud")
            .foregroundStyle(.secondary)
        }
      }

      Section("Settings") {
        InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
          .onChange(of: currency) { _, _ in saveChanges() }

        Picker("Financial Year Starts", selection: $financialYearStartMonth) {
          ForEach(1...12, id: \.self) { month in
            if month <= Self.monthNames.count {
              Text(Self.monthNames[month - 1])
                .tag(month)
            }
          }
        }
        .onChange(of: financialYearStartMonth) { _, _ in saveChanges() }
      }
    }
    .formStyle(.grouped)
  }

  private func saveChanges() {
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    guard !trimmedLabel.isEmpty else { return }

    var updated = profile
    var changed = false

    if trimmedLabel != profile.label {
      updated.label = trimmedLabel
      changed = true
    }
    if currency.id != profile.currencyCode {
      updated.currencyCode = currency.id
      changed = true
    }
    if financialYearStartMonth != profile.financialYearStartMonth {
      updated.financialYearStartMonth = financialYearStartMonth
      changed = true
    }

    if changed {
      profileStore.updateProfile(updated)
    }
  }
}
