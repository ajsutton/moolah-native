import SwiftUI

/// Renders an `InstrumentAmount` exactly as `InstrumentAmountView` does
/// when the instrument is not in `spamInstruments`. When it is, replaces
/// the symbol portion with the inline "⚠️ Spam" indicator (red SF Symbol
/// `exclamationmark.triangle.fill` + the word "Spam" in red) and emits a
/// substituted VoiceOver string ("<magnitude> spam token"). The magnitude's
/// sign is preserved on the displayed quantity.
struct SpamAwareAmountView: View {
  let amount: InstrumentAmount
  let spamInstruments: Set<Instrument>
  var font: Font?
  var colorOverride: Color?

  var body: some View {
    if spamInstruments.contains(amount.instrument) {
      spamBody
        .accessibilityLabel(Text("Amount"))
        .accessibilityValue(amount.accessibilityString(isSpam: true))
    } else {
      InstrumentAmountView(amount: amount, font: font, colorOverride: colorOverride)
    }
  }

  private var spamBody: some View {
    let magnitude = Text(verbatim: amount.formatNoSymbolVariablePrecision)
      .foregroundStyle(colorOverride ?? amount.magnitudeColor)
    let warning = Text(Image(systemName: "exclamationmark.triangle.fill"))
      .foregroundStyle(.red)
    let label = Text("Spam").foregroundStyle(.red)
    return Text("\(magnitude) \(warning) \(label)")
      .monospacedDigit()
      .font(font)
  }
}
