import Foundation

/// Identifiable wrapper for a category suggestion in the dropdown.
/// Defined here (rather than alongside the SwiftUI dropdown view) so
/// `TransactionDraft` blur-handling helpers can take it as a parameter
/// without pulling SwiftUI into the domain extension.
struct CategorySuggestion: Identifiable, Equatable, Sendable {
  let id: UUID
  let path: String
}
