import SwiftUI

extension Transaction {
  /// `Text` rendering of `tradeTitleSegments`, ready to drop into the row title.
  /// Returns `nil` when `tradeTitleSegments` returns an empty array (non-trade
  /// or unsupported shape). Composes via Text string interpolation on each
  /// segment so SF Symbols and per-segment foreground styles survive.
  func tradeTitleText(
    scopeReference: Instrument,
    spamInstruments: Set<Instrument>
  ) -> Text? {
    let segments = tradeTitleSegments(
      scopeReference: scopeReference, spamInstruments: spamInstruments)
    guard !segments.isEmpty else { return nil }
    return segments.dropFirst().reduce(into: segments[0].text) { partial, segment in
      partial = Text("\(partial)\(segment.text)")
    }
  }
}
