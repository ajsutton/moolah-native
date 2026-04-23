import SwiftUI

// Condition-editor row for `RuleEditorView`, with its supporting
// `ConditionKind` picker enum. Extracted from `RuleEditorView.swift` so
// the primary view file stays under SwiftLint's `file_length` threshold.
// These types are file-visible to this feature and referenced only from
// `RuleEditorView`.

struct RuleEditorConditionRow: View {
  @Binding var condition: RuleCondition
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Picker("Condition type", selection: conditionKindBinding) {
        ForEach(RuleEditorConditionKind.allCases, id: \.self) { kind in
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
      case let .amountBetween(min, max):
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

  private var conditionKindBinding: Binding<RuleEditorConditionKind> {
    Binding(
      get: { RuleEditorConditionKind.from(condition) },
      set: { newKind in
        condition = newKind.defaultCondition(from: condition)
      })
  }
}

enum RuleEditorConditionKind: String, CaseIterable, Hashable {
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

  static func from(_ condition: RuleCondition) -> RuleEditorConditionKind {
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
    case .contains: return .descriptionContains(Self.carriedTokens(from: existing))
    case .doesNotContain:
      return .descriptionDoesNotContain(Self.carriedTokens(from: existing))
    case .beginsWith: return .descriptionBeginsWith(Self.carriedPrefix(from: existing))
    case .amountPositive: return .amountIsPositive
    case .amountNegative: return .amountIsNegative
    case .amountBetween:
      let bounds = Self.carriedAmountBounds(from: existing) ?? AmountBounds(min: 0, max: 0)
      return .amountBetween(min: bounds.min, max: bounds.max)
    case .sourceAccount: return .sourceAccountIs(Self.carriedSourceAccountId(from: existing))
    }
  }

  /// Returns the tokens carried forward from a description-based
  /// condition, or `[""]` (a single empty token) as the default for a new
  /// contains/does-not-contain rule.
  private static func carriedTokens(from existing: RuleCondition) -> [String] {
    switch existing {
    case .descriptionContains(let tokens), .descriptionDoesNotContain(let tokens):
      return tokens
    default: return [""]
    }
  }

  private static func carriedPrefix(from existing: RuleCondition) -> String {
    if case .descriptionBeginsWith(let prefix) = existing { return prefix }
    return ""
  }

  private static func carriedAmountBounds(
    from existing: RuleCondition
  ) -> AmountBounds? {
    if case let .amountBetween(min, max) = existing {
      return AmountBounds(min: min, max: max)
    }
    return nil
  }

  private struct AmountBounds {
    let min: Decimal
    let max: Decimal
  }

  private static func carriedSourceAccountId(from existing: RuleCondition) -> UUID {
    if case .sourceAccountIs(let id) = existing { return id }
    return UUID()
  }
}
