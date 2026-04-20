import SwiftUI

/// Settings → Import Rules list. Mail.app-shaped: ordered list, drag to
/// reorder, enable toggle per row, Add button to create a new rule.
struct ImportRulesSettingsView: View {
  @Environment(ImportRuleStore.self) private var ruleStore
  @Environment(CategoryStore.self) private var categoryStore
  @State private var editingRule: ImportRule?
  @State private var showingAddSheet = false

  var body: some View {
    List {
      if ruleStore.rules.isEmpty {
        ContentUnavailableView(
          "No rules yet",
          systemImage: "list.bullet.rectangle",
          description: Text(
            "Rules run at CSV import time to set the payee, category, "
              + "notes, or to mark a row as a transfer."))
      } else {
        ForEach(ruleStore.rules) { rule in
          RuleRow(rule: rule) { editingRule = rule }
        }
        .onMove { source, destination in
          var ids = ruleStore.rules.map(\.id)
          ids.move(fromOffsets: source, toOffset: destination)
          Task { await ruleStore.reorder(ids) }
        }
        .onDelete { offsets in
          let ids = offsets.map { ruleStore.rules[$0].id }
          for id in ids {
            Task { await ruleStore.delete(id: id) }
          }
        }
      }
    }
    .navigationTitle("Import Rules")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingAddSheet = true
        } label: {
          Label("Add Rule", systemImage: "plus")
        }
        .accessibilityLabel("Add Rule")
      }
      #if !os(macOS)
        ToolbarItem(placement: .navigationBarTrailing) {
          EditButton()
        }
      #endif
    }
    .task { await ruleStore.load() }
    .sheet(isPresented: $showingAddSheet) {
      RuleEditorView(
        initialRule: ImportRule(
          name: "New Rule",
          position: ruleStore.rules.count,
          conditions: [],
          actions: []),
        onSave: { newRule in
          Task { await ruleStore.create(newRule) }
        })
    }
    .sheet(item: $editingRule) { rule in
      RuleEditorView(
        initialRule: rule,
        onSave: { updated in
          Task { await ruleStore.update(updated) }
        })
    }
  }
}

private struct RuleRow: View {
  let rule: ImportRule
  let onEdit: () -> Void
  @Environment(ImportRuleStore.self) private var ruleStore

  var body: some View {
    HStack {
      Toggle(
        "",
        isOn: Binding(
          get: { rule.enabled },
          set: { newValue in
            var copy = rule
            copy.enabled = newValue
            Task { await ruleStore.update(copy) }
          })
      )
      .labelsHidden()
      .accessibilityLabel(rule.enabled ? "Disable \(rule.name)" : "Enable \(rule.name)")

      VStack(alignment: .leading, spacing: 2) {
        Text(rule.name)
        Text(summarise(rule))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .onTapGesture { onEdit() }
      Spacer()
      Button("Edit") { onEdit() }
        .buttonStyle(.borderless)
    }
    .contentShape(Rectangle())
  }

  private func summarise(_ rule: ImportRule) -> String {
    let conditionSummary =
      rule.conditions.isEmpty
      ? "matches every row"
      : rule.conditions.map(Self.describe).joined(separator: " · ")
    let actionSummary =
      rule.actions.isEmpty
      ? "(no actions)"
      : rule.actions.map(Self.describe).joined(separator: " · ")
    return "\(conditionSummary) → \(actionSummary)"
  }

  private static func describe(_ condition: RuleCondition) -> String {
    switch condition {
    case .descriptionContains(let tokens): return "contains \(tokens.joined(separator: ","))"
    case .descriptionDoesNotContain(let tokens):
      return "excludes \(tokens.joined(separator: ","))"
    case .descriptionBeginsWith(let prefix): return "starts \(prefix)"
    case .amountIsPositive: return "income"
    case .amountIsNegative: return "expense"
    case .amountBetween(let min, let max): return "between \(min) and \(max)"
    case .sourceAccountIs: return "on one account"
    }
  }

  private static func describe(_ action: RuleAction) -> String {
    switch action {
    case .setPayee(let p): return "payee=\(p)"
    case .setCategory: return "set category"
    case .appendNote(let n): return "note=\(n)"
    case .markAsTransfer: return "mark as transfer"
    case .skip: return "skip"
    }
  }
}
