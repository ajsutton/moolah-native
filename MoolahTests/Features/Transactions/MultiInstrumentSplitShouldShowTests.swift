import Foundation
import Testing

@testable import Moolah

/// Tests for `MultiInstrumentPositionsSplitModifier.shouldShow`. The
/// modifier wraps a transaction list in a positions/transactions split
/// only when the account has positions worth surfacing alongside the
/// transactions. Two inputs feed the decision:
///
/// - Raw `[Position]` from the repository (pre-valuation).
/// - The valuated `PositionsViewInput`, populated asynchronously by
///   `PositionsValuator` after the modifier mounts. The valuator drops
///   `.knownZero` (`.unpriced` / `.spam` crypto) entries, so its
///   `shouldHide` agrees with what `PositionsView` will actually
///   render.
///
/// Once `positionsInput` is available it is authoritative: relying on
/// the raw heuristic alone could leave the split allocated for content
/// the inner `PositionsView` will refuse to render — manifesting as a
/// large blank section above the transactions list (the case fixed by
/// this suite).
@Suite("MultiInstrumentPositionsSplitModifier.shouldShow")
struct MultiInstrumentSplitShouldShowTests {
  let aud = Instrument.AUD
  let usd = Instrument.USD
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let spam = Instrument.crypto(
    chainId: 1,
    contractAddress: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    symbol: "SPAM", name: "Spam Airdrop", decimals: 18)

  // MARK: - Authoritative path (positionsInput available)

  /// Spam-airdrop scenario: an Ethereum wallet (`hostCurrency = ETH`)
  /// holds an ETH balance plus a `.spam`-marked airdrop token. The raw
  /// positions list still contains both, but the valuator drops the
  /// spam token to `.knownZero`, so the valuated input ends up with
  /// only ETH — making the split redundant with the wallet header's
  /// already-visible balance. The modifier must collapse the split or
  /// the user sees a blank pane where positions would have rendered.
  @Test("hides when positionsInput.shouldHide is true even if raw positions look multi-instrument")
  func hidesWhenInputSaysShouldHide() {
    let rawPositions = [
      Position(instrument: eth, quantity: Decimal(string: "0.5") ?? 0),
      Position(instrument: spam, quantity: 1_000_000),
    ]
    // Simulating the post-valuation state: spam dropped to `.knownZero`,
    // only the ETH row survived.
    let input = PositionsViewInput(
      title: "Trust Ethereum 2",
      hostCurrency: eth,
      positions: [
        ValuedPosition(
          instrument: eth, quantity: Decimal(string: "0.5") ?? 0,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: Decimal(string: "0.5") ?? 0, instrument: eth))
      ],
      historicalValue: nil)
    #expect(input.shouldHide)
    #expect(
      !MultiInstrumentPositionsSplitModifier.shouldShow(
        rawPositions: rawPositions, hostCurrency: eth, positionsInput: input))
  }

  /// The genuinely-multi-instrument case after valuation: both legs
  /// survived, so the input does NOT report shouldHide and the split
  /// continues to render.
  @Test("shows when positionsInput contains a non-host-currency row")
  func showsWhenInputHasNonHostInstrument() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: aud)),
        ValuedPosition(
          instrument: usd, quantity: 200, unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 304, instrument: aud)),
      ],
      historicalValue: nil)
    #expect(
      MultiInstrumentPositionsSplitModifier.shouldShow(
        rawPositions: [
          Position(instrument: aud, quantity: 1_000),
          Position(instrument: usd, quantity: 200),
        ],
        hostCurrency: aud, positionsInput: input))
  }

  // MARK: - Pre-valuation fallback (positionsInput == nil)

  /// Before the valuator has produced a `positionsInput`, fall back to
  /// the raw-positions heuristic so the split can render with a
  /// `ProgressView` while the valuator works.
  @Test("falls back to raw heuristic when positionsInput is nil — multi-instrument shows split")
  func fallbackShowsForMultiInstrumentRaw() {
    #expect(
      MultiInstrumentPositionsSplitModifier.shouldShow(
        rawPositions: [
          Position(instrument: aud, quantity: 1_000),
          Position(instrument: usd, quantity: 200),
        ],
        hostCurrency: aud, positionsInput: nil))
  }

  /// Single host-currency position pre-valuation: redundant with the
  /// host's balance, no split.
  @Test(
    "falls back to raw heuristic when positionsInput is nil — single host instrument hides split")
  func fallbackHidesForHostOnlyRaw() {
    #expect(
      !MultiInstrumentPositionsSplitModifier.shouldShow(
        rawPositions: [Position(instrument: aud, quantity: 1_000)],
        hostCurrency: aud, positionsInput: nil))
  }

  /// Empty raw positions pre-valuation: no content for the split.
  @Test("falls back to raw heuristic when positionsInput is nil — empty positions hides split")
  func fallbackHidesForEmptyRaw() {
    #expect(
      !MultiInstrumentPositionsSplitModifier.shouldShow(
        rawPositions: [], hostCurrency: aud, positionsInput: nil))
  }

  /// Zero-quantity rows in the raw positions don't fool the heuristic
  /// into rendering the split — only non-zero quantities count toward
  /// the instrument set.
  @Test("falls back to raw heuristic when positionsInput is nil — zero-qty rows are ignored")
  func fallbackIgnoresZeroQuantities() {
    #expect(
      !MultiInstrumentPositionsSplitModifier.shouldShow(
        rawPositions: [
          Position(instrument: aud, quantity: 1_000),
          Position(instrument: usd, quantity: 0),
        ],
        hostCurrency: aud, positionsInput: nil))
  }
}
