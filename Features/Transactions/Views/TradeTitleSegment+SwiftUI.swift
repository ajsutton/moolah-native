import SwiftUI

// MARK: - Per-segment SwiftUI rendering

extension TradeTitleSegment {
  /// SwiftUI `Text` rendering of a single segment.
  ///
  /// `.literal` and `.magnitude` pass through unstyled. `.spamMagnitude`
  /// emits the formatted quantity followed by a red `exclamationmark.triangle.fill`
  /// SF Symbol and the word "Spam" in red, composed via `Text` string
  /// interpolation (the non-deprecated replacement for `Text + Text` on
  /// macOS 26+).
  var text: Text {
    switch self {
    case .literal(let string):
      return Text(verbatim: string)
    case .magnitude(let amount):
      return Text(verbatim: amount.formatted)
    case .spamMagnitude(let amount):
      let warning = Text(Image(systemName: "exclamationmark.triangle.fill"))
        .foregroundStyle(.red)
      let label = Text("Spam").foregroundStyle(.red)
      return Text("\(amount.formatNoSymbolVariablePrecision) \(warning) \(label)")
    }
  }
}
