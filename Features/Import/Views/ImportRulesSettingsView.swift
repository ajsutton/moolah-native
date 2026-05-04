import SwiftUI

/// Settings → Import Rules list. Mail.app-shaped: ordered list, drag to
/// reorder, enable toggle per row, Add button to create a new rule.
struct ImportRulesSettingsView: View {
  @Environment(ImportRuleStore.self) private var ruleStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(ProfileSession.self) private var session
  @State private var editingRule: ImportRule?
  @State private var showingAddSheet = false
  @State private var selectedRuleId: ImportRule.ID?

  var body: some View {
    List(selection: $selectedRuleId) {
      ForEach(ruleStore.rules) { rule in
        RuleRow(rule: rule)
          .tag(rule.id)
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
    // List selection + primaryAction wires Return / double-click to
    // open the editor — the same keyboard path the sidebar uses.
    .contextMenu(forSelectionType: ImportRule.ID.self) { _ in
      // Empty context menu items — primary action handles the open.
      // Returning no buttons keeps the right-click menu absent rather
      // than showing a stub item.
    } primaryAction: { ids in
      if let id = ids.first, let rule = ruleStore.rules.first(where: { $0.id == id }) {
        editingRule = rule
      }
    }
    .overlay {
      if ruleStore.rules.isEmpty {
        ContentUnavailableView(
          "No rules yet",
          systemImage: "list.bullet.rectangle",
          description: Text(
            "Rules run at CSV import time to set the payee, category, "
              + "notes, or to mark a row as a transfer."))
      }
    }
    .navigationTitle("Import Rules")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        // `Label("Add Rule", …)` already carries "Add Rule" as the
        // VoiceOver label; no explicit `.accessibilityLabel` needed.
        Button {
          showingAddSheet = true
        } label: {
          Label("Add Rule", systemImage: "plus")
        }
      }
      #if !os(macOS)
        ToolbarItem(placement: .navigationBarTrailing) {
          EditButton()
        }
      #endif
    }
    .task {
      await ruleStore.load()
      await ruleStore.refreshStats(backend: session.backend)
    }
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
        if let stats = ruleStore.matchStats[rule.id], stats.matchCount > 0 {
          Text(statsCaption(stats))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      Spacer()
    }
    // Make the full row a hit target so a click anywhere in the row
    // updates the List's selection (the editor opens via Return /
    // double-click via `contextMenu(forSelectionType:primaryAction:)`).
    .contentShape(Rectangle())
  }

  private func statsCaption(_ stats: ImportRuleStore.RuleMatchStats) -> String {
    let matches =
      stats.matchCount == 1
      ? "1 match" : "\(stats.matchCount) matches"
    guard let last = stats.lastMatchedAt else { return matches }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return "\(matches) · last \(formatter.localizedString(for: last, relativeTo: Date()))"
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
    return "\(conditionSummary) then \(actionSummary)"
  }

  private static func describe(_ condition: RuleCondition) -> String {
    switch condition {
    case .descriptionContains(let tokens): return "contains \(tokens.joined(separator: ","))"
    case .descriptionDoesNotContain(let tokens):
      return "excludes \(tokens.joined(separator: ","))"
    case .descriptionBeginsWith(let prefix): return "starts \(prefix)"
    case .amountIsPositive: return "income"
    case .amountIsNegative: return "expense"
    case let .amountBetween(min, max): return "between \(min) and \(max)"
    case .sourceAccountIs: return "on one account"
    }
  }

  private static func describe(_ action: RuleAction) -> String {
    switch action {
    case .setPayee(let payee): return "payee=\(payee)"
    case .setCategory: return "set category"
    case .appendNote(let n): return "note=\(n)"
    case .markAsTransfer: return "mark as transfer"
    case .skip: return "skip"
    }
  }
}
