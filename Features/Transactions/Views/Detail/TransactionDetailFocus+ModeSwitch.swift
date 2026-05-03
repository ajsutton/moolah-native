import Foundation

extension TransactionDetailFocus {
  /// Returns the equivalent focus in `newStructure`. Payee always stays
  /// put. An amount-shaped focus is preserved when the new structure can
  /// still host it (e.g. `.legAmount(N)` survives a custom→custom switch),
  /// otherwise it is remapped to the new structure's primary amount slot.
  ///
  /// `.tradeFeeAmount(_)`'s associated index is intentionally discarded
  /// when leaving Trade — fee legs don't survive a structural change, so
  /// any non-trade target lands the user on the new structure's primary
  /// amount.
  func remapping(toStructure newStructure: ModeStructure) -> TransactionDetailFocus {
    let primary: TransactionDetailFocus =
      switch newStructure {
      case .simple: .amount
      case .trade: .tradePaidAmount
      case .custom: .legAmount(0)
      }
    switch self {
    case .payee:
      return .payee
    case .legAmount:
      return newStructure == .custom ? self : primary
    case .tradePaidAmount, .tradeReceivedAmount, .tradeFeeAmount:
      return newStructure == .trade ? self : primary
    case .amount, .counterpartAmount:
      return primary
    }
  }
}
