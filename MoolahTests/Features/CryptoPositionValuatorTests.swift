import Foundation
import Testing

@testable import Moolah

/// Covers the per-position valuation helper used by `CryptoPositionsSectionView`.
///
/// Per Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: a conversion error
/// on a single position must be (a) logged and (b) surfaced to the view as an
/// explicit failure state so the row can render "Value unavailable" with a
/// retry affordance. It must NOT be silently swallowed, nor substituted with
/// zero, nor rendered in the native instrument as a fallback.
@Suite("CryptoPositionValuator")
struct CryptoPositionValuatorTests {
  let aud = Instrument.fiat(code: "AUD")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)

  @Test func convertsEachPositionAndReturnsSuccessResults() async throws {
    let positions = [
      Position(instrument: eth, quantity: Decimal(2)),
      Position(instrument: btc, quantity: Decimal(string: "0.5")!),
    ]
    let service = FixedConversionService(rates: [
      eth.id: Decimal(3000),
      btc.id: Decimal(60_000),
    ])

    let valuator = CryptoPositionValuator(conversionService: service)
    let results = await valuator.valuate(
      positions: positions, profileCurrency: aud, on: Date())

    #expect(try results[eth.id]?.get() == Decimal(6000))
    #expect(try results[btc.id]?.get() == Decimal(30_000))
  }

  @Test func surfacesFailureForPositionWhoseConversionThrows() async throws {
    let positions = [
      Position(instrument: eth, quantity: Decimal(2)),
      Position(instrument: btc, quantity: Decimal(1)),
    ]
    let service = FailingConversionService(
      rates: [eth.id: Decimal(3000)],
      failingInstrumentIds: [btc.id]
    )

    let valuator = CryptoPositionValuator(conversionService: service)
    let results = await valuator.valuate(
      positions: positions, profileCurrency: aud, on: Date())

    // Success row rendered normally.
    #expect(try results[eth.id]?.get() == Decimal(6000))

    // Failing row surfaces the failure — not silently dropped, not zeroed.
    let btcResult = try #require(results[btc.id])
    if case .success = btcResult {
      Issue.record("Expected btc valuation to be a failure, got success")
    }
  }

  @Test func sameInstrumentFastPathReturnsQuantityDirectly() async throws {
    // A crypto "position" whose instrument equals the profile currency is a
    // degenerate case, but the fast path guards against pointless async hops.
    let positions = [Position(instrument: aud, quantity: Decimal(42))]
    let service = FailingConversionService(failingInstrumentIds: [aud.id])

    let valuator = CryptoPositionValuator(conversionService: service)
    let results = await valuator.valuate(
      positions: positions, profileCurrency: aud, on: Date())

    #expect(try results[aud.id]?.get() == Decimal(42))
  }
}
