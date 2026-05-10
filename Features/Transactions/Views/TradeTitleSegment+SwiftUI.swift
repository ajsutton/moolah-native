import SwiftUI

// MARK: - Per-segment SwiftUI rendering

extension TradeTitleSegment {
  /// SwiftUI `Text` rendering of a single segment.
  ///
  /// `.literal` and `.magnitude` pass through unstyled. `.spamMagnitude`
  /// emits the formatted quantity followed by a yellow
  /// `exclamationmark.octagon.fill` palette badge and the instrument's
  /// `displayLabel` with strikethrough — the badge warns that the token's
  /// claimed name may be impersonating a legitimate token (a common
  /// crypto-spam tactic), and the strikethrough discourages the reader
  /// from trusting the name as-is.
  var text: Text {
    switch self {
    case .literal(let string):
      return Text(verbatim: string)
    case .magnitude(let amount):
      return Text(verbatim: amount.formatted)
    case .spamMagnitude(let amount):
      // Strike through the instrument's claimed display label so the reader
      // doesn't trust the name — spam tokens routinely impersonate
      // legitimate tickers. Row-level signal is the leading-icon yellow
      // octagon overlay; this rendering avoids stacking another badge here.
      let magnitude = Text(verbatim: amount.formatNoSymbolVariablePrecision)
      let symbol = Text(verbatim: amount.instrument.displayLabel).strikethrough()
      return Text("\(magnitude) \(symbol)")
    }
  }
}
