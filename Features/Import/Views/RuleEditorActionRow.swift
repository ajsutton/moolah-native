import SwiftUI

// Action-editor row for `RuleEditorView`, with its supporting `ActionKind`
// picker enum. Extracted from `RuleEditorView.swift` so the primary view
// file stays under SwiftLint's `file_length` threshold. These types are
// file-visible to this feature and referenced only from `RuleEditorView`.

struct RuleEditorActionRow: View {
  @Binding var action: RuleAction
  let categories: Categories
  let accounts: Accounts
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Picker("Action type", selection: actionKindBinding) {
        ForEach(RuleEditorActionKind.allCases, id: \.self) { kind in
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
            Text(categories.path(for: category)).tag(category.id)
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

  private var actionKindBinding: Binding<RuleEditorActionKind> {
    Binding(
      get: { RuleEditorActionKind.from(action) },
      set: { newKind in
        action = newKind.defaultAction(
          from: action, categories: categories, accounts: accounts)
      })
  }
}

enum RuleEditorActionKind: String, CaseIterable, Hashable {
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

  static func from(_ action: RuleAction) -> RuleEditorActionKind {
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
