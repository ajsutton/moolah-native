import SwiftUI

extension InstrumentAmount {
  /// Default foreground color for displaying this amount based on sign:
  /// `.green` when positive, `.red` when negative, `.primary` when zero.
  ///
  /// Intentionally non-localised — semantic meaning of green/red is shared
  /// with `InstrumentAmountView`, `SpamAwareAmountView`, and any future
  /// view rendering an amount with the standard convention. Callers that
  /// need a different rule pass a `colorOverride` instead.
  var magnitudeColor: Color {
    if isPositive { return .green }
    if isNegative { return .red }
    return .primary
  }
}
