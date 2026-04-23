import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator")
struct CapitalGainsCalculatorTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test
  func stockPurchase_thenSale_producesGainEvent() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    // Buy: transfer AUD out, BHP in
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // Sell: BHP out, AUD in
    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1000)
    #expect(result.events[0].isLongTerm == true)
    #expect(result.totalRealizedGain == 1000)
  }

  @Test
  func noSales_noGainEvents() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    #expect(result.events.isEmpty)
    #expect(result.openLots.count == 1)
    #expect(result.openLots[0].remainingQuantity == 100)
  }

  @Test
  func cryptoSwap_tracksGainOnSoldToken() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    // Buy ETH with AUD
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // Swap ETH for UNI
    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: [eth.id: 4000, uni.id: 8])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    // ETH sold: cost basis 3000, proceeds 4000 (1 ETH at AUD 4000 on swap date)
    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == eth.id)
    #expect(result.events[0].gain == 1000)
  }

  @Test
  func financialYearFilter_onlyIncludesEventsInRange() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let allResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )
    #expect(allResult.events.count == 1)

    let earlyResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:]),
      sellDateRange: date(0)...date(100)
    )
    // Sale on day 400 is outside the range
    #expect(earlyResult.events.isEmpty)
  }

  // MARK: - Multi-instrument scenarios

  @Test
  func multipleStocks_produceIndependentGainEvents() async throws {
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    let accountId = UUID()

    let buyBHP = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let sellBHP = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let buyCBA = LegTransaction(
      date: date(50),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: 50, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let sellCBA = LegTransaction(
      date: date(500),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: -50, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 7000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyBHP, buyCBA, sellBHP, sellCBA],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    #expect(result.events.count == 2)
    let bhpGain = result.events.first { $0.instrument.id == "ASX:BHP" }?.gain
    let cbaGain = result.events.first { $0.instrument.id == "ASX:CBA" }?.gain
    #expect(bhpGain == 1000)
    #expect(cbaGain == 2000)
    #expect(result.totalRealizedGain == 3000)
  }

  @Test
  func sellingOneInstrumentDoesNotTouchCostBasisOfAnother() async throws {
    // If a user sells BHP, CBA cost basis must not change.
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    let accountId = UUID()

    let buyBHP = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let buyCBA = LegTransaction(
      date: date(50),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: 50, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let sellAllBHP = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyBHP, buyCBA, sellAllBHP],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    // Only BHP sale produces an event; CBA is still held.
    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == "ASX:BHP")
    #expect(result.events[0].gain == 1000)
  }

  /// Mixed-fiat buy: 100 BHP paid for with USD 2000 + AUD 100 fee,
  /// profile currency = AUD at 1 USD = 1.5 AUD. The calculator must
  /// convert each fiat leg to the profile currency before summing,
  /// producing a cost basis of AUD 3100 (not the raw 2100 from blending
  /// USD and AUD quantities).
  @Test
  func mixedFiatLegs_convertToProfileCurrencyBeforeSumming() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service
    )

    // Cost basis AUD 3100 (USD 2000 × 1.5 = 3000 plus AUD 100 fee),
    // proceeds AUD 4000. Gain 900.
    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 900)
  }

  /// Mixed-fiat sell: 100 BHP sold for USD 3000 with AUD 50 fee,
  /// profile currency = AUD at 1 USD = 1.5 AUD. Proceeds must aggregate
  /// to AUD 4500 − AUD 50 direction depends on the fee side; here the
  /// fee is modelled as an inflow because the existing fiat-paired
  /// classifier only sums absolute inflow. Covers the sell-side symmetry
  /// of the fix.
  @Test
  func mixedFiatLegs_sellSide_convertInflowToProfileCurrency() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // Sell 100 BHP, receive USD 3000. Expected proceeds: AUD 4500.
    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service
    )

    // Cost basis AUD 3000, proceeds AUD 4500. Gain 1500.
    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1500)
  }

  // MARK: - Date-sensitive routing
  //
  // `computeWithConversion` must convert every fiat or non-fiat-swap leg
  // on the transaction's date (Rule 5). The rate-ignoring
  // `FixedConversionService` would not detect a regression that swapped
  // `tx.date` for `Date()` or another date; this test uses
  // `DateBasedFixedConversionService` to make that observable.

  /// Crypto-to-crypto swap: both legs are valued via the conversion
  /// service. The rate schedule below has a different rate effective at
  /// the swap date than would be returned for "today" (`Date()`), so a
  /// regression that misrouted the lookup date would yield a different
  /// gain than the assertion permits.
  @Test
  func cryptoSwap_conversionUsesTransactionDate() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // Rate schedule:
    //   pre-date(100): no rates (1:1 fallback)
    //   date(100)..<date(365): ETH=4000 AUD, UNI=8 AUD  ← effective on swap date(200)
    //   date(365) onward:      ETH=10 AUD,   UNI=0.01 AUD  ← what `Date()` would resolve to
    //
    // Correct routing (tx.date=swap date(200)) → ETH proceeds 4000 AUD,
    // gain = 4000 − 3000 = 1000.
    // Mistake (`Date()` ≈ today, > date(365)) → proceeds 10 AUD, gain ≈ −2990.
    // Mistake (`buyTx.date`=date(0)) → 1:1 fallback, proceeds 1 AUD, gain = −2999.
    let service = DateBasedFixedConversionService(rates: [
      date(100): [eth.id: 4000, uni.id: 8],
      date(365): [eth.id: 10, uni.id: Decimal(string: "0.01")!],
    ])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == eth.id)
    #expect(result.events[0].gain == 1000)
  }

  // MARK: - Sign preservation through conversion (CLAUDE.md sign convention)
  //
  // `classifyLegsWithConversion` must pass each leg's natural (signed)
  // quantity through `InstrumentConversionService.convert` rather than
  // pre-applying `abs()` and rebuilding the sign afterwards. This keeps
  // the calculator faithful to the CLAUDE.md monetary sign convention and
  // matches the sign-preserving pattern used in the fiat-only
  // `classifyLegs`. The conversion service below records the sign of every
  // quantity it receives so the tests can assert the contract directly.

  private actor SignRecordingConversionService: InstrumentConversionService {
    private var calls: [(from: String, quantity: Decimal)] = []
    private let rates: [String: Decimal]

    init(rates: [String: Decimal]) {
      self.rates = rates
    }

    func convert(
      _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
    ) async throws -> Decimal {
      calls.append((from: from.id, quantity: quantity))
      if from.id == to.id { return quantity }
      let rate = rates[from.id] ?? 1
      return quantity * rate
    }

    func convertAmount(
      _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
    ) async throws -> InstrumentAmount {
      let converted = try await convert(
        amount.quantity, from: amount.instrument, to: instrument, on: date
      )
      return InstrumentAmount(quantity: converted, instrument: instrument)
    }

    func recordedCalls() -> [(from: String, quantity: Decimal)] { calls }
  }

  /// Fiat outflow/inflow legs must pass their *signed* quantity through
  /// the conversion service so the sign convention is preserved end to
  /// end. An outflow leg (negative quantity) must arrive at the
  /// conversion service as a negative number; an inflow leg as positive.
  @Test
  func fiatLegs_passSignedQuantityToConversionService() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let service = SignRecordingConversionService(rates: ["USD": Decimal(string: "1.5")!])
    _ = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service
    )

    let usdCalls = await service.recordedCalls().filter { $0.from == "USD" }
    #expect(usdCalls.count == 2)
    // Outflow leg (-2000 USD) must reach the conversion service with its
    // natural negative sign; inflow leg (+3000 USD) with its natural
    // positive sign. Any implementation that strips the sign before
    // conversion (e.g. `abs(leg.quantity)`) will fail this check.
    #expect(usdCalls.contains { $0.quantity == -2000 })
    #expect(usdCalls.contains { $0.quantity == 3000 })
  }

  /// Non-fiat swap legs must also preserve their sign across the
  /// conversion boundary. The outgoing leg of a swap is negative and must
  /// arrive at the conversion service as negative; the incoming leg as
  /// positive.
  @Test
  func cryptoSwap_passesSignedQuantityToConversionService() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let service = SignRecordingConversionService(rates: [eth.id: 4000, uni.id: 8])
    _ = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    let ethCalls = await service.recordedCalls().filter { $0.from == eth.id }
    let uniCalls = await service.recordedCalls().filter { $0.from == uni.id }
    // ETH is sold (leg.quantity == -1), UNI is bought (leg.quantity == 500).
    #expect(ethCalls.contains { $0.quantity == -1 })
    #expect(uniCalls.contains { $0.quantity == 500 })
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument(
      id: "ASX:\(name)", kind: .stock, name: name, decimals: 0,
      ticker: "\(name).AX", exchange: "ASX", chainId: nil, contractAddress: nil)
  }

  private func cryptoInstrument(_ symbol: String) -> Instrument {
    Instrument(
      id: "1:\(symbol.lowercased())", kind: .cryptoToken, name: symbol, decimals: 8,
      ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let base = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2024, month: 1, day: 1))!
    return Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromBase, to: base)!
  }
}
