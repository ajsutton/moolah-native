extension ValuationMode {
  /// Short, sentence-fragment description of where this mode's
  /// balance comes from. Used as a VoiceOver `.accessibilityHint`
  /// in the Edit Account picker; reusable wherever a brief one-line
  /// description of the mode's data source is needed.
  var dataSourceHint: String {
    switch self {
    case .recordedValue:
      return "Balance comes from the value you last recorded"
    case .calculatedFromTrades:
      return
        "Balance is calculated from your trade history and current prices of your holdings"
    }
  }

  /// Full-sentence description of the mode's data source, with
  /// terminating period. Used as the Edit Account picker's section
  /// footer; reusable as descriptive copy elsewhere.
  var dataSourceDescription: String {
    switch self {
    case .recordedValue:
      return "The balance comes from the value you last recorded manually."
    case .calculatedFromTrades:
      return
        "The balance is calculated from your trade history and the current prices of your holdings."
    }
  }
}
