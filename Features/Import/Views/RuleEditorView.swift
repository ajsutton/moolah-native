import SwiftUI

/// Rule editor sheet. Two sections — Conditions (If any/all of these are
/// true) and Actions (Perform these). Each row has a field/operator/value
/// dropdown. Save writes back through the `onSave` closure; Cancel throws
/// the draft away.
struct RuleEditorView: View {
  @State private var rule: ImportRule
  /// UUID-keyed view-state wrappers around each condition / action. Using
  /// stable IDs (rather than `Array.Index` offsets) keeps SwiftUI's view
  /// identity pinned to the same row after a mid-list delete, so focus,
  /// in-flight text edits, and Binding reads don't jump to a stale index.
  @State private var identifiedConditions: [IdentifiedCondition]
  @State private var identifiedActions: [IdentifiedAction]
  @State private var affectedCount: Int?
  @State private var countingTask: Task<Void, Never>?
  let onSave: (ImportRule) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(ImportRuleStore.self) private var ruleStore
  @Environment(ProfileSession.self) private var session

  init(initialRule: ImportRule, onSave: @escaping (ImportRule) -> Void) {
    _rule = State(initialValue: initialRule)
    _identifiedConditions = State(
      initialValue: initialRule.conditions.map {
        IdentifiedCondition(id: UUID(), condition: $0)
      })
    _identifiedActions = State(
      initialValue: initialRule.actions.map {
        IdentifiedAction(id: UUID(), action: $0)
      })
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      form
    }
  }

  private var form: some View {
    Form {
      ruleSection
      conditionsSection
      actionsSection
      previewSection
    }
    .formStyle(.grouped)
    .navigationTitle(rule.name.isEmpty ? "New Rule" : rule.name)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          var out = rule
          out.conditions = identifiedConditions.map(\.condition)
          out.actions = identifiedActions.map(\.action)
          onSave(out)
          dismiss()
        }
        .disabled(rule.name.isEmpty)
      }
    }
    .task(id: previewKey) {
      await schedulePreview()
    }
    #if os(macOS)
      .frame(minWidth: 540, minHeight: 520)
    #endif
  }

  private var ruleSection: some View {
    Section(header: Text("Rule")) {
      TextField("Name", text: $rule.name)
      Toggle("Enabled", isOn: $rule.enabled)
      Picker(
        "Applies to",
        selection: Binding(
          get: { rule.accountScope },
          set: { rule.accountScope = $0 })
      ) {
        Text("All accounts").tag(UUID?.none)
        ForEach(accountStore.accounts.ordered, id: \.id) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }
    }
  }

  private var conditionsSection: some View {
    Section(header: Text("If \(matchModeLabel) of these are true")) {
      Picker("Match mode", selection: $rule.matchMode) {
        Text("All").tag(MatchMode.all)
        Text("Any").tag(MatchMode.any)
      }
      .pickerStyle(.segmented)
      ForEach($identifiedConditions) { $item in
        ConditionRow(
          condition: $item.condition,
          onDelete: {
            identifiedConditions.removeAll { $0.id == item.id }
          })
      }
      Button {
        identifiedConditions.append(
          IdentifiedCondition(id: UUID(), condition: .descriptionContains([""])))
      } label: {
        Label("Add Condition", systemImage: "plus.circle")
      }
    }
  }

  private var actionsSection: some View {
    Section(header: Text("Perform these actions")) {
      ForEach($identifiedActions) { $item in
        ActionRow(
          action: $item.action,
          categories: categoryStore.categories,
          accounts: accountStore.accounts,
          onDelete: {
            identifiedActions.removeAll { $0.id == item.id }
          })
      }
      addActionMenu
    }
  }

  @ViewBuilder private var addActionMenu: some View {
    Menu {
      Button("Set Payee") {
        identifiedActions.append(
          IdentifiedAction(id: UUID(), action: .setPayee("")))
      }
      // Only offer Set Category when categories exist — spec forbids
      // rules referencing invented category UUIDs.
      if let firstCategory = categoryStore.categories.flattenedByPath().first?.category {
        Button("Set Category") {
          identifiedActions.append(
            IdentifiedAction(id: UUID(), action: .setCategory(firstCategory.id)))
        }
      }
      Button("Append Note") {
        identifiedActions.append(
          IdentifiedAction(id: UUID(), action: .appendNote("")))
      }
      if let firstAccount = accountStore.accounts.ordered.first {
        Button("Mark as Transfer") {
          identifiedActions.append(
            IdentifiedAction(
              id: UUID(),
              action: .markAsTransfer(toAccountId: firstAccount.id)))
        }
      }
      Button("Skip Row") {
        identifiedActions.append(
          IdentifiedAction(id: UUID(), action: .skip))
      }
    } label: {
      Label("Add Action", systemImage: "plus.circle")
    }
  }

  private var previewSection: some View {
    Section(header: Text("Preview")) {
      HStack(spacing: 6) {
        if affectedCount == nil {
          ProgressView().controlSize(.small)
        }
        Text(previewText)
          .font(.subheadline)
          .foregroundStyle(affectedCount == nil ? .secondary : .primary)
      }
    }
  }

  /// Serialises the conditions + matchMode + accountScope so the preview
  /// task cancels and re-runs on any change, but not on name / action edits
  /// (which don't affect the match set).
  private var previewKey: String {
    var bits: [String] = [rule.matchMode.rawValue]
    for item in identifiedConditions {
      bits.append(String(describing: item.condition))
    }
    if let scope = rule.accountScope {
      bits.append("scope:\(scope.uuidString)")
    }
    return bits.joined(separator: "|")
  }

  private var previewText: String {
    guard let count = affectedCount else {
      return "Counting past transactions…"
    }
    switch count {
    case 0: return "No past transactions would match this rule."
    case 1: return "1 past transaction would match this rule."
    default: return "\(count) past transactions would match this rule."
    }
  }

  /// Wait a short debounce before re-counting so typing in the token
  /// editor doesn't hammer the backend.
  private func schedulePreview() async {
    affectedCount = nil
    try? await Task.sleep(nanoseconds: 500_000_000)
    if Task.isCancelled { return }
    let count = await ruleStore.countAffected(
      conditions: identifiedConditions.map(\.condition),
      matchMode: rule.matchMode,
      accountScope: rule.accountScope,
      backend: session.backend)
    if Task.isCancelled { return }
    affectedCount = count
  }

  private var matchModeLabel: String {
    rule.matchMode == .all ? "all" : "any"
  }
}

// MARK: - UUID-keyed view-state wrappers

/// Wraps a `RuleCondition` with a persistent UUID so SwiftUI `ForEach` can
/// keep view identity stable across mid-list deletes. Mirrors into
/// `rule.conditions` on Save.
private struct IdentifiedCondition: Identifiable {
  let id: UUID
  var condition: RuleCondition
}

/// Wraps a `RuleAction` with a persistent UUID for the same reason.
private struct IdentifiedAction: Identifiable {
  let id: UUID
  var action: RuleAction
}

// MARK: - Condition editor row

private struct ConditionRow: View {
  @Binding var condition: RuleCondition
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Picker("Condition type", selection: conditionKindBinding) {
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
          format: .number
        )
        .monospacedDigit()
        .accessibilityLabel("Minimum amount")
        TextField(
          "max",
          value: Binding(
            get: { max },
            set: { condition = .amountBetween(min: min, max: $0) }),
          format: .number
        )
        .monospacedDigit()
        .accessibilityLabel("Maximum amount")
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
      if case .descriptionContains(let tokens) = existing {
        return .descriptionContains(tokens)
      }
      if case .descriptionDoesNotContain(let tokens) = existing {
        return .descriptionContains(tokens)
      }
      return .descriptionContains([""])
    case .doesNotContain:
      if case .descriptionContains(let tokens) = existing {
        return .descriptionDoesNotContain(tokens)
      }
      if case .descriptionDoesNotContain(let tokens) = existing {
        return .descriptionDoesNotContain(tokens)
      }
      return .descriptionDoesNotContain([""])
    case .beginsWith:
      if case .descriptionBeginsWith(let prefix) = existing {
        return .descriptionBeginsWith(prefix)
      }
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
      Picker("Action type", selection: actionKindBinding) {
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
      if case .setPayee(let payee) = existing { return .setPayee(payee) }
      return .setPayee("")
    case .setCategory:
      if case .setCategory(let id) = existing { return .setCategory(id) }
      // Prefer an existing category; if none exist the caller shouldn't
      // have offered this option in the picker, so the fallback is
      // defensive. The rule editor's "Add Action" menu hides Set Category
      // entirely when categories are empty.
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
