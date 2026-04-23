import Foundation

/// Parses a URL string literal for use in tests; traps with a clear
/// message on malformed input.
///
/// Intended for use with compile-time string literals. A failure here means
/// the test source itself contains an invalid URL literal — a programmer
/// error the test run cannot proceed past. Using this helper keeps call
/// sites free of the `URL(string: "…")!` idiom (which SwiftLint's
/// `force_unwrapping` rule flags) while preserving the
/// fail-fast-on-programmer-error semantics the existing tests rely on.
func makeURL(
  _ literal: String,
  file: StaticString = #file,
  line: UInt = #line
) -> URL {
  guard let value = URL(string: literal) else {
    preconditionFailure(
      "Invalid URL literal: \(literal)",
      file: file,
      line: line
    )
  }
  return value
}
