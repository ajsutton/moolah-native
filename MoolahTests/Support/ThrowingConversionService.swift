import Foundation

@testable import Moolah

// Visibility is internal (was fileprivate) so sibling test files across the
// split AnalysisRepository* test suites can use this helper — `strict_fileprivate`
// disallows fileprivate in this codebase.
//
// Conversion service that throws on any invocation. Used to assert that a code
// path does not call into conversion at all (e.g., same-currency short-circuits).
// internal (was fileprivate) so sibling test files can use this helper
struct ThrowingConversionService: InstrumentConversionService {
  struct Invoked: Error {}
  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    throw Invoked()
  }
  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    throw Invoked()
  }
}
