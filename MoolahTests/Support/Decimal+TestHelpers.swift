import Foundation

/// Parses a decimal string literal for use in tests; traps with a clear
/// message on malformed input.
///
/// Intended for use with compile-time string literals. A failure here means
/// the test source itself contains an invalid numeric literal — a programmer
/// error the test run cannot proceed past. Using this helper keeps call
/// sites free of the `Decimal(string: "…")!` idiom (which SwiftLint's
/// `force_unwrapping` rule flags) while preserving the
/// fail-fast-on-programmer-error semantics the existing tests rely on.
func dec(
  _ literal: String,
  file: StaticString = #file,
  line: UInt = #line
) -> Decimal {
  guard let value = Decimal(string: literal) else {
    preconditionFailure(
      "Invalid decimal literal: \(literal)",
      file: file,
      line: line
    )
  }
  return value
}
