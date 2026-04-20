import SwiftUI

/// Rule editor sheet. Two sections — Conditions (If any/all of these are
/// true) and Actions (Perform these). Each row has a field/operator/value
/// dropdown. Save writes back through the `onSave` closure; Cancel throws
/// the draft away.
struct RuleEditorView: View {
  @State private var rule: ImportRule
  let onSave: (ImportRule) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(AccountStore.self) private var accountStore

  init(initialRule: ImportRule, onSave: @escaping (ImportRule) -> Void) {
    _rule = State(initialValue: initialRule)
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(header: Text("Rule")) {
          TextField("Name", text: $rule.name)
          Toggle("Enabled", isOn: $rule.enabled)
        }

        Section(header: Text("If \(matchModeLabel) of these are true")) {
          Picker("Match mode", selection: $rule.matchMode) {
            Text("All").tag(MatchMode.all)
            Text("Any").tag(MatchMode.any)
          }
          .pickerStyle(.segmented)
          ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, _ in
            ConditionRow(
              condition: Binding(
                get: { rule.conditions[index] },
                set: { rule.conditions[index] = $0 }),
              onDelete: { rule.conditions.remove(at: index) })
          }
          Button {
            rule.conditions.append(.descriptionContains([""]))
          } label: {
            Label("Add Condition", systemImage: "plus.circle")
          }
        }

        Section(header: Text("Perform these actions")) {
          ForEach(Array(rule.actions.enumerated()), id: \.offset) { index, _ in
            ActionRow(
              action: Binding(
                get: { rule.actions[index] },
                set: { rule.actions[index] = $0 }),
              categories: categoryStore.categories,
              accounts: accountStore.accounts,
              onDelete: { rule.actions.remove(at: index) })
          }
          Menu {
            Button("Set Payee") { rule.actions.append(.setPayee("")) }
            Button("Set Category") {
              if let firstCategory = categoryStore.categories.flattenedByPath().first?.category {
                rule.actions.append(.setCategory(firstCategory.id))
              } else {
                rule.actions.append(.setCategory(UUID()))
              }
            }
            Button("Append Note") { rule.actions.append(.appendNote("")) }
            if let firstAccount = accountStore.accounts.ordered.first {
              Button("Mark as Transfer") {
                rule.actions.append(.markAsTransfer(toAccountId: firstAccount.id))
              }
            }
            Button("Skip Row") { rule.actions.append(.skip) }
          } label: {
            Label("Add Action", systemImage: "plus.circle")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(rule.name.isEmpty ? "New Rule" : rule.name)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(rule)
            dismiss()
          }
          .disabled(rule.name.isEmpty)
        }
      }
    }
  }

  private var matchModeLabel: String {
    rule.matchMode == .all ? "all" : "any"
  }
}

// MARK: - Condition editor row

private struct ConditionRow: View {
  @Binding var condition: RuleCondition
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Picker("", selection: conditionKindBinding) {
        ForEach(ConditionKind.allCases, id: \.self) { kind in
          Text(kind.label).tag(kind)
        }
      }
      .labelsHidden()

      switch condition {
      case .descriptionContains(let tokens), .descriptionDoesNotContain(let tokens):
        TextField(
          "tokens, comma separated",
          text: Binding(
            get: { tokens.joined(separator: ", ") },
            set: { newValue in
              let parts =
                newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
              switch condition {
              case .descriptionContains: condition = .descriptionContains(parts)
              case .descriptionDoesNotContain: condition = .descriptionDoesNotContain(parts)
              default: break
              }
            }))
      case .descriptionBeginsWith(let prefix):
        TextField(
          "prefix",
          text: Binding(
            get: { prefix },
            set: { condition = .descriptionBeginsWith($0) }))
      case .amountIsPositive, .amountIsNegative:
        EmptyView()
      case .amountBetween(let min, let max):
        TextField(
          "min",
          value: Binding(
            get: { min },
            set: { condition = .amountBetween(min: $0, max: max) }),
          format: .number)
        TextField(
          "max",
          value: Binding(
            get: { max },
            set: { condition = .amountBetween(min: min, max: $0) }),
          format: .number)
      case .sourceAccountIs:
        Text("(on routed account)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button(role: .destructive) {
        onDelete()
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove condition")
    }
  }

  // MARK: - Condition kind picker

  private var conditionKindBinding: Binding<ConditionKind> {
    Binding(
      get: { ConditionKind.from(condition) },
      set: { newKind in
        condition = newKind.defaultCondition(from: condition)
      })
  }
}

private enum ConditionKind: String, CaseIterable, Hashable {
  case contains, doesNotContain, beginsWith
  case amountPositive, amountNegative, amountBetween
  case sourceAccount

  var label: String {
    switch self {
    case .contains: return "Contains"
    case .doesNotContain: return "Does not contain"
    case .beginsWith: return "Begins with"
    case .amountPositive: return "Amount is income"
    case .amountNegative: return "Amount is expense"
    case .amountBetween: return "Amount between"
    case .sourceAccount: return "Source is routed account"
    }
  }

  static func from(_ condition: RuleCondition) -> ConditionKind {
    switch condition {
    case .descriptionContains: return .contains
    case .descriptionDoesNotContain: return .doesNotContain
    case .descriptionBeginsWith: return .beginsWith
    case .amountIsPositive: return .amountPositive
    case .amountIsNegative: return .amountNegative
    case .amountBetween: return .amountBetween
    case .sourceAccountIs: return .sourceAccount
    }
  }

  /// Transition to the new kind, carrying forward tokens/prefix/min+max if
  /// shapes overlap.
  func defaultCondition(from existing: RuleCondition) -> RuleCondition {
    switch self {
    case .contains:
      if case .descriptionContains(let t) = existing { return .descriptionContains(t) }
      if case .descriptionDoesNotContain(let t) = existing { return .descriptionContains(t) }
      return .descriptionContains([""])
    case .doesNotContain:
      if case .descriptionContains(let t) = existing { return .descriptionDoesNotContain(t) }
      if case .descriptionDoesNotContain(let t) = existing { return .descriptionDoesNotContain(t) }
      return .descriptionDoesNotContain([""])
    case .beginsWith:
      if case .descriptionBeginsWith(let p) = existing { return .descriptionBeginsWith(p) }
      return .descriptionBeginsWith("")
    case .amountPositive: return .amountIsPositive
    case .amountNegative: return .amountIsNegative
    case .amountBetween:
      if case .amountBetween(let min, let max) = existing {
        return .amountBetween(min: min, max: max)
      }
      return .amountBetween(min: 0, max: 0)
    case .sourceAccount:
      if case .sourceAccountIs(let id) = existing { return .sourceAccountIs(id) }
      return .sourceAccountIs(UUID())
    }
  }
}

// MARK: - Action editor row

private struct ActionRow: View {
  @Binding var action: RuleAction
  let categories: Categories
  let accounts: Accounts
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Picker("", selection: actionKindBinding) {
        ForEach(ActionKind.allCases, id: \.self) { kind in
          Text(kind.label).tag(kind)
        }
      }
      .labelsHidden()

      switch action {
      case .setPayee(let payee):
        TextField(
          "payee",
          text: Binding(get: { payee }, set: { action = .setPayee($0) }))
      case .setCategory(let id):
        Picker(
          "Category",
          selection: Binding(
            get: { id },
            set: { action = .setCategory($0) })
        ) {
          ForEach(flatCategories, id: \.id) { category in
            Text(category.name).tag(category.id)
          }
        }
        .labelsHidden()
      case .appendNote(let note):
        TextField(
          "note",
          text: Binding(get: { note }, set: { action = .appendNote($0) }))
      case .markAsTransfer(let accountId):
        Picker(
          "To account",
          selection: Binding(
            get: { accountId },
            set: { action = .markAsTransfer(toAccountId: $0) })
        ) {
          ForEach(accounts.ordered, id: \.id) { account in
            Text(account.name).tag(account.id)
          }
        }
        .labelsHidden()
      case .skip:
        Text("(drops the row)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button(role: .destructive) {
        onDelete()
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove action")
    }
  }

  private var flatCategories: [Category] {
    categories.flattenedByPath().map(\.category)
  }

  private var actionKindBinding: Binding<ActionKind> {
    Binding(
      get: { ActionKind.from(action) },
      set: { newKind in
        action = newKind.defaultAction(
          from: action, categories: categories, accounts: accounts)
      })
  }
}

private enum ActionKind: String, CaseIterable, Hashable {
  case setPayee, setCategory, appendNote, markAsTransfer, skip

  var label: String {
    switch self {
    case .setPayee: return "Set payee"
    case .setCategory: return "Set category"
    case .appendNote: return "Append note"
    case .markAsTransfer: return "Mark as transfer"
    case .skip: return "Skip row"
    }
  }

  static func from(_ action: RuleAction) -> ActionKind {
    switch action {
    case .setPayee: return .setPayee
    case .setCategory: return .setCategory
    case .appendNote: return .appendNote
    case .markAsTransfer: return .markAsTransfer
    case .skip: return .skip
    }
  }

  func defaultAction(
    from existing: RuleAction, categories: Categories, accounts: Accounts
  ) -> RuleAction {
    switch self {
    case .setPayee:
      if case .setPayee(let p) = existing { return .setPayee(p) }
      return .setPayee("")
    case .setCategory:
      if case .setCategory(let id) = existing { return .setCategory(id) }
      let first = categories.flattenedByPath().first?.category.id ?? UUID()
      return .setCategory(first)
    case .appendNote:
      if case .appendNote(let n) = existing { return .appendNote(n) }
      return .appendNote("")
    case .markAsTransfer:
      if case .markAsTransfer(let id) = existing { return .markAsTransfer(toAccountId: id) }
      let first = accounts.ordered.first?.id ?? UUID()
      return .markAsTransfer(toAccountId: first)
    case .skip: return .skip
    }
  }
}
