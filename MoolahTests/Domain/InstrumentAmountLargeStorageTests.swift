import Foundation
import Testing

@testable import Moolah

/// Guards `storageValue` against `NSDecimalNumber.int64Value` overflow:
/// for a non-integer Decimal whose scaled significand exceeds 64 bits
/// the conversion wraps mod 2^64 and can flip sign. Large 18-decimal
/// token balances (e.g. 24 752 OP at full precision) hit this; round
/// amounts do not.
@Suite("InstrumentAmount — large fractional storage")
struct InstrumentAmountLargeStorageTests {
  private static let opToken = Instrument.crypto(
    chainId: 10,
    contractAddress: "0x4200000000000000000000000000000000000042",
    symbol: "OP", name: "Optimism", decimals: 18)

  @Test
  func largePositiveFractionalQuantityTruncatesToEightDecimalPlaces() {
    // Real corrupted transfer: 24752.479166666627062700 OP.
    // 8-dp storage truncates toward zero → 24752.47916666 × 1e8.
    let amount = InstrumentAmount(
      quantity: dec("24752.479166666627062700"), instrument: Self.opToken)
    #expect(amount.storageValue == 2_475_247_916_666)
  }

  @Test
  func largeNegativeFractionalQuantityTruncatesTowardZeroKeepingSign() {
    let amount = InstrumentAmount(
      quantity: dec("-40167.948970346473430700"), instrument: Self.opToken)
    #expect(amount.storageValue == -4_016_794_897_034)
  }

  @Test
  func largeFractionalQuantityRoundTripsThroughStorage() {
    let amount = InstrumentAmount(
      quantity: dec("24752.479166666627062700"), instrument: Self.opToken)
    let restored = InstrumentAmount(
      storageValue: amount.storageValue, instrument: Self.opToken)
    #expect(restored.quantity == dec("24752.47916666"))
  }
}
