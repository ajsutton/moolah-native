import Foundation

/// Building block for the row's parenthesised action sentence on a `.trade`
/// transaction. The view layer renders `.magnitude` as the instrument's
/// normal formatted string and `.spamMagnitude` as
/// `<numericMagnitude> ⚠️ Spam` in red (with the SF Symbol, not the
/// emoji glyph). VoiceOver renders `.spamMagnitude` as
/// "<numericMagnitude> spam token" — see `accessibilityString`.
///
/// Sign convention: `.magnitude` and `.spamMagnitude` always carry an
/// **absolute** quantity (display magnitude only). The signed direction
/// of the underlying leg is encoded in the `.literal` verb that precedes
/// it (`"Bought "`, `"Sold "`, `"Swapped "`/`" for "`). Callers must not
/// inspect the segment's `InstrumentAmount.quantity` for sign — it is
/// always positive.
enum TradeTitleSegment: Equatable, Sendable {
  case literal(String)
  case magnitude(InstrumentAmount)
  case spamMagnitude(InstrumentAmount)
}

extension TradeTitleSegment {
  /// VoiceOver substitution. Spam magnitudes read as
  /// "<magnitude> spam token" (lowercase, spelled out) so the warning
  /// glyph is never announced as punctuation.
  var accessibilityString: String {
    switch self {
    case .literal(let string): return string
    case .magnitude(let amount): return amount.formatted
    case .spamMagnitude(let amount):
      return amount.accessibilityString(isSpam: true)
    }
  }
}
