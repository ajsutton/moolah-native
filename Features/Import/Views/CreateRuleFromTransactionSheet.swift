import SwiftUI

/// "Create a rule from this…" affordance. Pre-fills a new `ImportRule` with
/// `descriptionContains([distinguishingTokens])` extracted from the source
/// transaction's raw description + the user's currently-assigned payee /
/// category actions. Hands off to `RuleEditorView` for final review.
struct CreateRuleFromTransactionSheet: View {
  let transaction: Transaction
  let corpus: [String]
  @Environment(ImportRuleStore.self) private var ruleStore

  var body: some View {
    RuleEditorView(
      initialRule: prefilledRule(),
      onSave: { rule in
        Task { await ruleStore.create(rule) }
      })
  }

  private func prefilledRule() -> ImportRule {
    let rawDescription = transaction.importOrigin?.rawDescription ?? ""
    let tokens = DistinguishingTokens.extract(
      from: rawDescription, corpus: corpus, limit: 3)
    var actions: [RuleAction] = []
    if let payee = transaction.payee, !payee.isEmpty {
      actions.append(.setPayee(payee))
    }
    if let firstCategoryId = transaction.legs.compactMap(\.categoryId).first {
      actions.append(.setCategory(firstCategoryId))
    }
    if actions.isEmpty {
      // Default: just describe the match; user fills in the action in the editor.
      actions = [.appendNote("")]
    }
    return ImportRule(
      name: "Rule from \(rawDescription.prefix(20))",
      position: ruleStore.rules.count,
      conditions: [.descriptionContains(tokens.isEmpty ? [rawDescription] : tokens)],
      actions: actions)
  }
}
