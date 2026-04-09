import SwiftUI

struct EditAccountView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var type: AccountType
  @State private var isHidden: Bool
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false

  let account: Account
  let accountStore: AccountStore

  init(account: Account, accountStore: AccountStore) {
    self.account = account
    self.accountStore = accountStore
    _name = State(initialValue: account.name)
    _type = State(initialValue: account.type)
    _isHidden = State(initialValue: account.isHidden)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
            .accessibilityLabel("Account name")

          Picker("Account Type", selection: $type) {
            ForEach(AccountType.allCases, id: \.self) { type in
              Text(type.displayName).tag(type)
            }
          }

          LabeledContent("Current Balance") {
            MonetaryAmountView(amount: account.displayBalance)
              .foregroundStyle(.secondary)
          }
          .accessibilityLabel("Current balance, read-only")
        }

        Section {
          Toggle("Hide Account", isOn: $isHidden)
            .disabled(account.balance.cents != 0)
            .accessibilityHint(
              account.balance.cents != 0
                ? "Account must have zero balance to hide"
                : ""
            )
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .font(.caption)
          }
        }

        Section {
          Button("Delete Account", role: .destructive) {
            showingDeleteConfirmation = true
          }
          .disabled(account.balance.cents != 0)
          .accessibilityHint(
            account.balance.cents != 0
              ? "Account must have zero balance to delete"
              : ""
          )
        }
      }
      .navigationTitle("Edit Account")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }
            .disabled(!isValid || isSubmitting)
        }
      }
      .confirmationDialog(
        "Delete Account",
        isPresented: $showingDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          Task { await delete() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This account will be hidden. You can unhide it later if needed.")
      }
    }
  }

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func save() async {
    guard isValid else { return }

    isSubmitting = true
    errorMessage = nil

    var updated = account
    updated.name = name.trimmingCharacters(in: .whitespaces)
    updated.type = type
    updated.isHidden = isHidden

    do {
      _ = try await accountStore.update(updated)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }

  private func delete() async {
    isSubmitting = true
    errorMessage = nil

    do {
      try await accountStore.delete(id: account.id)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }
}
