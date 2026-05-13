import SwiftUI

extension InstrumentAmount {
  /// Semantic foreground colour for a gain/loss amount. Negative → red,
  /// zero → primary (no colour signal), positive → green.
  ///
  /// `guides/UI_GUIDE.md` §5 (Selected-Row Contrast Override) treats
  /// `.red` / `.green` here as the canonical exception to the
  /// "no hand-tuned `Color.opacity`" rule — the gain sign is a
  /// semantically-load-bearing colour signal.
  var gainColor: Color {
    if isNegative { return .red }
    if isZero { return .primary }
    return .green
  }
}
