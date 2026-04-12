# Phase 4: Crypto — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the multi-instrument model from Phases 1-3 to support cryptocurrency tokens. Wire the existing `CryptoPriceClient` infrastructure into `InstrumentConversionService`, build token swap transaction UI, display crypto positions in account detail, and migrate off `CryptoToken` onto `Instrument`.

**Architecture:** `Instrument.crypto(...)` factory creates crypto instruments using the same `chainId:address` ID scheme as the existing `CryptoToken`. The `InstrumentConversionService` gains a crypto conversion path: crypto -> USD (via `CryptoPriceService`) -> target fiat (via `ExchangeRateService`). Token swap transactions produce multi-leg transactions where both legs are transfer-type with non-fiat instruments. `CryptoToken` is retired, with its provider mapping data (`coingeckoId`, `cryptocompareSymbol`, `binanceSymbol`) moved to a dedicated `CryptoProviderMapping` type alongside `Instrument`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit, Swift Testing

**Key files to read before starting:**
- `plans/2026-04-12-multi-instrument-design.md` (overall design spec)
- `plans/2026-04-12-phase1-foundation-plan.md` (reference for Instrument, InstrumentAmount, TransactionLeg)
- `Domain/Models/CryptoToken.swift` (type being retired)
- `Domain/Repositories/CryptoPriceClient.swift` (protocol for price fetching)
- `Shared/CryptoPriceService.swift` (orchestrates price fetching with fallback)
- `Shared/PriceConversionService.swift` (crypto -> fiat conversion)
- `CLAUDE.md` (build/test instructions, architecture constraints)
- `CONCURRENCY_GUIDE.md`

**Prerequisite phases:** Phases 1-3 must be complete. This plan assumes `Instrument`, `InstrumentAmount`, `TransactionLeg`, `Position`, `InstrumentConversionService`, and the stock trade UI all exist.

---

## File Structure

### New Files
- `Domain/Models/CryptoProviderMapping.swift` — Maps instrument IDs to price provider identifiers (coingeckoId, etc.)
- `MoolahTests/Domain/CryptoProviderMappingTests.swift` — Unit tests
- `MoolahTests/Domain/InstrumentCryptoTests.swift` — Tests for `Instrument.crypto(...)` factory
- `MoolahTests/Shared/InstrumentConversionServiceCryptoTests.swift` — Tests for crypto conversion path
- `Features/Transactions/TokenSwapDraft.swift` — Draft model for token swap entry
- `Features/Transactions/TokenSwapView.swift` — Token swap transaction UI
- `MoolahTests/Features/TokenSwapDraftTests.swift` — Tests for swap draft -> legs conversion
- `Features/Accounts/CryptoPositionsSectionView.swift` — Crypto positions display in account detail

### Major Modifications
- `Domain/Models/Instrument.swift` — Add `crypto(...)` factory method
- `Shared/InstrumentConversionService.swift` — Add crypto -> fiat conversion path via CryptoPriceService
- `Shared/CryptoPriceService.swift` — Accept `Instrument` alongside `CryptoToken` (bridging during migration)
- `Domain/Repositories/CryptoPriceClient.swift` — Add overloads accepting `Instrument` (or adapt internally)
- `Domain/Repositories/CryptoTokenRepository.swift` — Replaced by `CryptoProviderMappingRepository`
- `Features/Settings/CryptoTokenStore.swift` — Migrate to use `Instrument` + `CryptoProviderMapping`
- `Shared/PriceConversionService.swift` — Retire (functionality absorbed into InstrumentConversionService)
- `Features/Accounts/AccountDetailView.swift` — Show crypto positions section
- `MoolahTests/Support/FixedCryptoPriceClient.swift` — Update to accept `Instrument`

### Files Deleted (at end of migration)
- `Domain/Models/CryptoToken.swift` — Replaced by `Instrument` + `CryptoProviderMapping`
- `Domain/Models/CryptoPriceCache.swift` — Updated to use instrument IDs directly
- `MoolahTests/Domain/CryptoTokenTests.swift` — Replaced by InstrumentCryptoTests

---

## Task 1: Instrument.crypto(...) Factory

**Files:**
- Create: `MoolahTests/Domain/InstrumentCryptoTests.swift`
- Modify: `Domain/Models/Instrument.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/InstrumentCryptoTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Instrument — Crypto")
struct InstrumentCryptoTests {
  // MARK: - Factory

  @Test func nativeTokenProperties() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    #expect(eth.id == "1:native")
    #expect(eth.kind == .cryptoToken)
    #expect(eth.name == "Ethereum")
    #expect(eth.decimals == 18)
    #expect(eth.chainId == 1)
    #expect(eth.contractAddress == nil)
    #expect(eth.ticker == nil)
    #expect(eth.exchange == nil)
  }

  @Test func contractTokenProperties() {
    let op = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18
    )
    #expect(op.id == "10:0x4200000000000000000000000000000000000042")
    #expect(op.kind == .cryptoToken)
    #expect(op.name == "Optimism")
    #expect(op.chainId == 10)
    #expect(op.contractAddress == "0x4200000000000000000000000000000000000042")
  }

  @Test func contractAddressNormalizedToLowercase() {
    let ens = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
      symbol: "ENS", name: "Ethereum Name Service", decimals: 18
    )
    #expect(ens.id == "1:0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
    #expect(ens.contractAddress == "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
  }

  @Test func btcUsesChainIdZero() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
    )
    #expect(btc.id == "0:native")
    #expect(btc.decimals == 8)
  }

  @Test func cryptoInstrumentIdMatchesCryptoTokenId() {
    // Verify the ID format is identical to the existing CryptoToken.id format
    // so that price caches, provider mappings, etc. align without migration.
    let instrument = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18
    )
    #expect(instrument.id == "10:0x4200000000000000000000000000000000000042")
  }

  @Test func equality() {
    let a = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let b = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "Ether", name: "Ether", decimals: 18)
    // Same chain + address = same instrument (name/symbol are display-only)
    #expect(a == b)
  }

  @Test func codableRoundTrip() throws {
    let original = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
      symbol: "ENS", name: "Ethereum Name Service", decimals: 18
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Instrument.self, from: data)
    #expect(decoded == original)
    #expect(decoded.kind == .cryptoToken)
    #expect(decoded.chainId == 1)
    #expect(decoded.contractAddress == "0xc18360217d8f7ab5e7c516566761ea12ce7f9d72")
  }

  // MARK: - Display symbol

  @Test func cryptoInstrumentHasNoCurrencySymbol() {
    let eth = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.currencySymbol == nil)
  }

  @Test func cryptoDisplaySymbolUsesName() {
    let eth = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    // displaySymbol should return the ticker symbol for crypto instruments
    #expect(eth.displaySymbol == "ETH")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-instrument-crypto.txt`
Expected: FAIL — `Instrument.crypto(...)` factory not defined.

- [ ] **Step 3: Implement `Instrument.crypto(...)` factory**

Add to `Domain/Models/Instrument.swift`:

```swift
extension Instrument {
  /// Factory for cryptocurrency token instruments.
  /// Uses the same `chainId:address` ID scheme as the legacy CryptoToken type.
  static func crypto(
    chainId: Int,
    contractAddress: String?,
    symbol: String,
    name: String,
    decimals: Int
  ) -> Instrument {
    let normalizedAddress = contractAddress?.lowercased()
    let id: String
    if let address = normalizedAddress {
      id = "\(chainId):\(address)"
    } else {
      id = "\(chainId):native"
    }
    return Instrument(
      id: id,
      kind: .cryptoToken,
      name: name,
      decimals: decimals,
      ticker: symbol,
      exchange: nil,
      chainId: chainId,
      contractAddress: normalizedAddress
    )
  }

  /// Convenience: the ticker symbol for display. For crypto, this is the short symbol (ETH, BTC).
  /// For stocks, the exchange ticker. For fiat, nil (use currencySymbol instead).
  var displaySymbol: String? {
    ticker
  }
}
```

**Note:** The `ticker` field stores the short symbol (ETH, BTC, OP) for crypto instruments. This keeps the `name` field for the full name (Ethereum, Bitcoin, Optimism) and `ticker` for the short code, consistent with how stocks use `ticker`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-instrument-crypto.txt`
Expected: All InstrumentCryptoTests PASS.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-instrument-crypto.txt
git add Domain/Models/Instrument.swift MoolahTests/Domain/InstrumentCryptoTests.swift
git commit -m "feat: add Instrument.crypto(...) factory for cryptocurrency instruments"
```

---

## Task 2: CryptoProviderMapping

**Files:**
- Create: `Domain/Models/CryptoProviderMapping.swift`
- Create: `MoolahTests/Domain/CryptoProviderMappingTests.swift`

The provider mapping holds the data currently on `CryptoToken` that is not on `Instrument`: the provider-specific identifiers needed for price lookups. This is a separate type because `Instrument` is a generic financial instrument — not all instruments need provider mappings, and the mappings are lookup metadata, not identity.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/CryptoProviderMappingTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoProviderMapping")
struct CryptoProviderMappingTests {
  @Test func initStoresAllFields() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native",
      coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    #expect(mapping.instrumentId == "1:native")
    #expect(mapping.coingeckoId == "ethereum")
    #expect(mapping.cryptocompareSymbol == "ETH")
    #expect(mapping.binanceSymbol == "ETHUSDT")
  }

  @Test func nilProviderFieldsAllowed() {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:native",
      coingeckoId: nil,
      cryptocompareSymbol: nil,
      binanceSymbol: nil
    )
    #expect(mapping.coingeckoId == nil)
  }

  @Test func codableRoundTrip() throws {
    let original = CryptoProviderMapping(
      instrumentId: "10:0x4200000000000000000000000000000000000042",
      coingeckoId: "optimism",
      cryptocompareSymbol: "OP",
      binanceSymbol: "OPUSDT"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CryptoProviderMapping.self, from: data)
    #expect(decoded == original)
  }

  @Test func identityBasedOnInstrumentId() {
    let a = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
    )
    let b = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "eth-changed",
      cryptocompareSymbol: nil, binanceSymbol: nil
    )
    // Same instrumentId = same mapping (even if provider fields differ)
    #expect(a.id == b.id)
  }

  // MARK: - Conversion from legacy CryptoToken

  @Test func fromCryptoTokenPreservesProviderIds() {
    let token = CryptoToken(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    let mapping = CryptoProviderMapping.from(token)
    #expect(mapping.instrumentId == "1:native")
    #expect(mapping.coingeckoId == "ethereum")
    #expect(mapping.cryptocompareSymbol == "ETH")
    #expect(mapping.binanceSymbol == "ETHUSDT")
  }

  @Test func fromCryptoTokenWithContractAddress() {
    let token = CryptoToken(
      chainId: 10,
      contractAddress: "0x4200000000000000000000000000000000000042",
      symbol: "OP", name: "Optimism", decimals: 18,
      coingeckoId: "optimism", cryptocompareSymbol: "OP",
      binanceSymbol: "OPUSDT"
    )
    let mapping = CryptoProviderMapping.from(token)
    #expect(mapping.instrumentId == "10:0x4200000000000000000000000000000000000042")
  }

  // MARK: - Built-in presets

  @Test func builtInPresetsMatchCryptoTokenPresets() {
    let presets = CryptoProviderMapping.builtInPresets
    #expect(presets.count == 5)

    let btc = presets.first { $0.instrumentId == "0:native" }!
    #expect(btc.coingeckoId == "bitcoin")
    #expect(btc.cryptocompareSymbol == "BTC")
    #expect(btc.binanceSymbol == "BTCUSDT")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-provider-mapping.txt`
Expected: FAIL — `CryptoProviderMapping` not defined.

- [ ] **Step 3: Implement CryptoProviderMapping**

```swift
// Domain/Models/CryptoProviderMapping.swift
import Foundation

/// Maps a crypto instrument to its price provider identifiers.
/// Separated from Instrument because provider IDs are lookup metadata,
/// not financial instrument identity.
struct CryptoProviderMapping: Codable, Sendable, Hashable, Identifiable {
  let instrumentId: String  // Matches Instrument.id, e.g. "1:native", "10:0xabc..."

  let coingeckoId: String?
  let cryptocompareSymbol: String?
  let binanceSymbol: String?

  var id: String { instrumentId }

  /// Convert from legacy CryptoToken.
  static func from(_ token: CryptoToken) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: token.id,
      coingeckoId: token.coingeckoId,
      cryptocompareSymbol: token.cryptocompareSymbol,
      binanceSymbol: token.binanceSymbol
    )
  }

  /// Convert legacy CryptoToken to an Instrument.
  static func instrument(from token: CryptoToken) -> Instrument {
    Instrument.crypto(
      chainId: token.chainId,
      contractAddress: token.contractAddress,
      symbol: token.symbol,
      name: token.name,
      decimals: token.decimals
    )
  }

  /// Built-in presets matching CryptoToken.builtInPresets.
  static let builtInPresets: [CryptoProviderMapping] =
    CryptoToken.builtInPresets.map { CryptoProviderMapping.from($0) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-provider-mapping.txt`
Expected: All CryptoProviderMappingTests PASS.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-provider-mapping.txt
git add Domain/Models/CryptoProviderMapping.swift MoolahTests/Domain/CryptoProviderMappingTests.swift
git commit -m "feat: add CryptoProviderMapping to separate provider IDs from Instrument identity"
```

---

## Task 3: Wire Crypto Prices into InstrumentConversionService

**Files:**
- Create: `MoolahTests/Shared/InstrumentConversionServiceCryptoTests.swift`
- Modify: `Shared/InstrumentConversionService.swift`

The `InstrumentConversionService` (created in Phase 2) already handles fiat -> fiat and stock -> fiat. This task adds the crypto -> fiat path. The routing is: look up the crypto instrument's provider mapping, get the USD price from `CryptoPriceService`, then convert USD -> target fiat via `ExchangeRateService`.

**Prerequisite assumption:** `InstrumentConversionService` exists from Phase 2 with signature:
```swift
protocol InstrumentConversionService: Sendable {
    func convert(_ quantity: Decimal, from: Instrument, to: Instrument, on date: Date) async throws -> Decimal
}
```

And a concrete implementation that takes `ExchangeRateService` and (from Phase 3) a stock price backend. This task adds `CryptoPriceService` as an additional dependency.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Shared/InstrumentConversionServiceCryptoTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentConversionService — Crypto")
struct InstrumentConversionServiceCryptoTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
  )
  private let aud = Instrument.AUD
  private let usd = Instrument.USD

  private func date(_ string: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: string)!
  }

  // Helper: create a service with fixed crypto prices and exchange rates.
  // cryptoPrices maps instrumentId -> { dateString -> USD price }.
  // exchangeRates maps dateString -> { currencyCode -> rate from USD }.
  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    providerMappings: [CryptoProviderMapping] = []
  ) -> DefaultInstrumentConversionService {
    let cryptoClient = FixedCryptoPriceClient(prices: cryptoPrices)
    let cryptoService = CryptoPriceService(
      clients: [cryptoClient],
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    )
    let exchangeClient = FixedRateClient(rates: exchangeRates)
    let exchangeService = ExchangeRateService(
      client: exchangeClient,
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    )
    return DefaultInstrumentConversionService(
      exchangeRates: exchangeService,
      cryptoPrices: cryptoService,
      providerMappings: providerMappings
    )
  }

  // MARK: - Crypto -> Fiat (USD)

  @Test func cryptoToUsdUsesDirectPrice() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        ),
      ]
    )
    let result = try await service.convert(
      Decimal(string: "2.5")!, from: eth, to: usd, on: date("2026-04-10")
    )
    // 2.5 * 1623.45 = 4058.625
    #expect(result == Decimal(string: "4058.625")!)
  }

  // MARK: - Crypto -> Fiat (non-USD, two-hop)

  @Test func cryptoToAudGoesViaUsd() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      exchangeRates: ["2026-04-10": ["AUD": Decimal(string: "1.58")!]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        ),
      ]
    )
    let result = try await service.convert(
      Decimal(string: "2.5")!, from: eth, to: aud, on: date("2026-04-10")
    )
    // 2.5 * 1623.45 * 1.58 = 6412.6275
    let expected = Decimal(string: "2.5")! * Decimal(string: "1623.45")! * Decimal(string: "1.58")!
    #expect(result == expected)
  }

  // MARK: - Crypto -> Crypto (both non-fiat)

  @Test func cryptoToCryptoChainsThroughUsd() async throws {
    let service = makeService(
      cryptoPrices: [
        "1:native": ["2026-04-10": Decimal(string: "1623.45")!],  // ETH
        "0:native": ["2026-04-10": Decimal(string: "63000.00")!],  // BTC
      ],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        ),
        CryptoProviderMapping(
          instrumentId: "0:native", coingeckoId: "bitcoin",
          cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
        ),
      ]
    )
    // Convert 10 ETH to BTC
    let result = try await service.convert(
      Decimal(10), from: eth, to: btc, on: date("2026-04-10")
    )
    // 10 ETH * $1623.45/ETH = $16234.50 USD
    // $16234.50 / $63000/BTC = 0.25769... BTC
    let usdValue = Decimal(10) * Decimal(string: "1623.45")!
    let expected = usdValue / Decimal(string: "63000.00")!
    #expect(result == expected)
  }

  // MARK: - Missing provider mapping throws

  @Test func missingProviderMappingThrows() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]]
      // No provider mappings provided
    )
    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1), from: eth, to: usd, on: date("2026-04-10"))
    }
  }

  // MARK: - Fiat -> Crypto (reverse direction)

  @Test func fiatToCryptoIsInverseOfCryptoToFiat() async throws {
    let service = makeService(
      cryptoPrices: ["1:native": ["2026-04-10": Decimal(string: "1623.45")!]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        ),
      ]
    )
    // Convert $5000 USD to ETH
    let result = try await service.convert(
      Decimal(5000), from: usd, to: eth, on: date("2026-04-10")
    )
    // 5000 / 1623.45 = 3.0798... ETH
    let expected = Decimal(5000) / Decimal(string: "1623.45")!
    #expect(result == expected)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-conversion-crypto.txt`
Expected: FAIL — `DefaultInstrumentConversionService` does not accept `cryptoPrices` or `providerMappings`.

- [ ] **Step 3: Extend InstrumentConversionService for crypto**

Add to `Shared/InstrumentConversionService.swift` (this modifies the existing implementation from Phase 2):

```swift
// Add to DefaultInstrumentConversionService init:
//   private let cryptoPrices: CryptoPriceService?
//   private let providerMappings: [String: CryptoProviderMapping]

// Add crypto init parameter:
init(
  exchangeRates: ExchangeRateService,
  stockPrices: StockPriceService? = nil,    // from Phase 3
  cryptoPrices: CryptoPriceService? = nil,
  providerMappings: [CryptoProviderMapping] = []
) {
  self.exchangeRates = exchangeRates
  self.stockPrices = stockPrices
  self.cryptoPrices = cryptoPrices
  self.providerMappingsByInstrumentId = Dictionary(
    providerMappings.map { ($0.instrumentId, $0) },
    uniquingKeysWith: { _, last in last }
  )
}
```

The conversion routing in the `convert` method gains crypto cases. The routing logic inside `convert(_:from:to:on:)`:

```swift
func convert(
  _ quantity: Decimal, from source: Instrument, to target: Instrument, on date: Date
) async throws -> Decimal {
  if source == target { return quantity }

  switch (source.kind, target.kind) {
  case (.fiatCurrency, .fiatCurrency):
    // Existing Phase 2 path
    let rate = try await exchangeRates.rate(from: source, to: target, on: date)
    return quantity * rate

  case (.cryptoToken, .fiatCurrency):
    return try await convertCryptoToFiat(quantity, crypto: source, fiat: target, on: date)

  case (.fiatCurrency, .cryptoToken):
    // Inverse: get price of 1 crypto in fiat, divide
    let oneUnitInFiat = try await convertCryptoToFiat(Decimal(1), crypto: target, fiat: source, on: date)
    return quantity / oneUnitInFiat

  case (.cryptoToken, .cryptoToken):
    // Chain through USD: source -> USD -> target
    let sourceUsdPrice = try await cryptoUsdPrice(for: source, on: date)
    let targetUsdPrice = try await cryptoUsdPrice(for: target, on: date)
    return (quantity * sourceUsdPrice) / targetUsdPrice

  case (.stock, .fiatCurrency), (.fiatCurrency, .stock), (.stock, .stock):
    // Existing Phase 3 paths — unchanged
    // ...

  case (.stock, .cryptoToken), (.cryptoToken, .stock):
    // Chain through USD as intermediate
    let sourceUsd = try await toUsd(quantity, instrument: source, on: date)
    return try await fromUsd(sourceUsd, instrument: target, on: date)
  }
}

private func convertCryptoToFiat(
  _ quantity: Decimal, crypto: Instrument, fiat: Instrument, on date: Date
) async throws -> Decimal {
  let usdPrice = try await cryptoUsdPrice(for: crypto, on: date)
  let usdValue = quantity * usdPrice
  if fiat.id == "USD" { return usdValue }
  let fiatRate = try await exchangeRates.rate(
    from: Instrument.USD, to: fiat, on: date
  )
  return usdValue * fiatRate
}

private func cryptoUsdPrice(for instrument: Instrument, on date: Date) async throws -> Decimal {
  guard let cryptoPrices else {
    throw InstrumentConversionError.noCryptoPriceService
  }
  guard let mapping = providerMappingsByInstrumentId[instrument.id] else {
    throw InstrumentConversionError.noProviderMapping(instrumentId: instrument.id)
  }
  // Bridge to CryptoToken for the existing CryptoPriceService API
  let token = CryptoToken(
    chainId: instrument.chainId ?? 0,
    contractAddress: instrument.contractAddress,
    symbol: instrument.ticker ?? instrument.name,
    name: instrument.name,
    decimals: instrument.decimals,
    coingeckoId: mapping.coingeckoId,
    cryptocompareSymbol: mapping.cryptocompareSymbol,
    binanceSymbol: mapping.binanceSymbol
  )
  return try await cryptoPrices.price(for: token, on: date)
}
```

Add to the error enum (or create it if needed):

```swift
enum InstrumentConversionError: Error, Equatable {
  case noCryptoPriceService
  case noProviderMapping(instrumentId: String)
  // existing cases from Phase 2/3...
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-conversion-crypto.txt`
Expected: All InstrumentConversionServiceCryptoTests PASS. Existing fiat and stock conversion tests still pass.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-conversion-crypto.txt
git add Shared/InstrumentConversionService.swift MoolahTests/Shared/InstrumentConversionServiceCryptoTests.swift
git commit -m "feat: wire crypto price conversion into InstrumentConversionService"
```

---

## Task 4: Token Swap Draft Model

**Files:**
- Create: `MoolahTests/Features/TokenSwapDraftTests.swift`
- Create: `Features/Transactions/TokenSwapDraft.swift`

A token swap is like the stock trade from Phase 3, but both sides can be non-fiat. The user specifies: source instrument + quantity, destination instrument + quantity, optional gas fee instrument + amount. The draft produces multi-leg transactions with `transfer` type legs.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Features/TokenSwapDraftTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("TokenSwapDraft")
struct TokenSwapDraftTests {
  let eth = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let uni = Instrument.crypto(
    chainId: 1,
    contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
    symbol: "UNI", name: "Uniswap", decimals: 18
  )
  let accountId = UUID()

  @Test func simpleSwapProducesTwoTransferLegs() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.date = Date()

    let legs = draft.buildLegs()
    #expect(legs.count == 2)

    // Source leg: outflow
    let sourceLeg = legs[0]
    #expect(sourceLeg.accountId == accountId)
    #expect(sourceLeg.instrument == eth)
    #expect(sourceLeg.quantity == Decimal(string: "-0.5")!)
    #expect(sourceLeg.type == .transfer)

    // Destination leg: inflow
    let destLeg = legs[1]
    #expect(destLeg.accountId == accountId)
    #expect(destLeg.instrument == uni)
    #expect(destLeg.quantity == Decimal(string: "1234.56")!)
    #expect(destLeg.type == .transfer)
  }

  @Test func swapWithGasFeeProducesThreeLegs() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.gasFeeInstrument = eth
    draft.gasFeeQuantity = Decimal(string: "0.002")!
    draft.date = Date()

    let legs = draft.buildLegs()
    #expect(legs.count == 3)

    // Gas fee leg: expense
    let feeLeg = legs[2]
    #expect(feeLeg.accountId == accountId)
    #expect(feeLeg.instrument == eth)
    #expect(feeLeg.quantity == Decimal(string: "-0.002")!)
    #expect(feeLeg.type == .expense)
  }

  @Test func swapWithGasFeeCategoryAssigned() {
    let gasCategoryId = UUID()
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.gasFeeInstrument = eth
    draft.gasFeeQuantity = Decimal(string: "0.002")!
    draft.gasFeeCategoryId = gasCategoryId
    draft.date = Date()

    let legs = draft.buildLegs()
    let feeLeg = legs[2]
    #expect(feeLeg.categoryId == gasCategoryId)
  }

  @Test func validationRequiresSourceAndDestination() {
    var draft = TokenSwapDraft(accountId: accountId)
    #expect(draft.isValid == false)

    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    #expect(draft.isValid == false)

    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "100")!
    #expect(draft.isValid == true)
  }

  @Test func validationRejectsZeroQuantities() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(0)
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "100")!
    #expect(draft.isValid == false)
  }

  @Test func buildTransactionCombinesLegsWithMetadata() {
    var draft = TokenSwapDraft(accountId: accountId)
    draft.sourceInstrument = eth
    draft.sourceQuantity = Decimal(string: "0.5")!
    draft.destinationInstrument = uni
    draft.destinationQuantity = Decimal(string: "1234.56")!
    draft.date = Date()
    draft.notes = "Uniswap swap"

    let transaction = draft.buildTransaction()
    #expect(transaction.legs.count == 2)
    #expect(transaction.notes == "Uniswap swap")
    #expect(transaction.payee == nil)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-swap-draft.txt`
Expected: FAIL — `TokenSwapDraft` not defined.

- [ ] **Step 3: Implement TokenSwapDraft**

```swift
// Features/Transactions/TokenSwapDraft.swift
import Foundation

/// Draft for a token swap transaction (e.g., ETH -> UNI on a DEX).
/// Produces multi-leg transactions: two transfer legs for the swap,
/// optional expense leg for gas fee.
struct TokenSwapDraft: Sendable {
  let accountId: UUID

  var sourceInstrument: Instrument?
  var sourceQuantity: Decimal = 0
  var destinationInstrument: Instrument?
  var destinationQuantity: Decimal = 0

  // Optional gas fee
  var gasFeeInstrument: Instrument?
  var gasFeeQuantity: Decimal = 0
  var gasFeeCategoryId: UUID?

  var date: Date = Date()
  var notes: String?

  var isValid: Bool {
    guard let source = sourceInstrument, let dest = destinationInstrument else { return false }
    guard sourceQuantity > 0, destinationQuantity > 0 else { return false }
    _ = source; _ = dest  // Suppress unused warnings
    return true
  }

  func buildLegs() -> [TransactionLeg] {
    guard let source = sourceInstrument, let dest = destinationInstrument else { return [] }

    var legs: [TransactionLeg] = []

    // Outflow: source instrument leaves the account
    legs.append(TransactionLeg(
      accountId: accountId,
      instrument: source,
      quantity: -sourceQuantity,
      type: .transfer,
      categoryId: nil,
      earmarkId: nil
    ))

    // Inflow: destination instrument enters the account
    legs.append(TransactionLeg(
      accountId: accountId,
      instrument: dest,
      quantity: destinationQuantity,
      type: .transfer,
      categoryId: nil,
      earmarkId: nil
    ))

    // Optional gas fee
    if let feeInstrument = gasFeeInstrument, gasFeeQuantity > 0 {
      legs.append(TransactionLeg(
        accountId: accountId,
        instrument: feeInstrument,
        quantity: -gasFeeQuantity,
        type: .expense,
        categoryId: gasFeeCategoryId,
        earmarkId: nil
      ))
    }

    return legs
  }

  func buildTransaction() -> Transaction {
    Transaction(
      id: UUID(),
      date: date,
      payee: nil,
      notes: notes,
      recurPeriod: nil,
      recurEvery: nil,
      legs: buildLegs()
    )
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-swap-draft.txt`
Expected: All TokenSwapDraftTests PASS.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-swap-draft.txt
git add Features/Transactions/TokenSwapDraft.swift MoolahTests/Features/TokenSwapDraftTests.swift
git commit -m "feat: add TokenSwapDraft model for multi-leg crypto swap transactions"
```

---

## Task 5: Token Swap UI

**Files:**
- Create: `Features/Transactions/TokenSwapView.swift`
- Modify: `Features/Accounts/AccountDetailView.swift` (add entry point)

This follows the same pattern as the stock trade UI from Phase 3. The key difference: both instrument pickers allow crypto instruments (not just the "bought" side).

- [ ] **Step 1: Design review — read Phase 3 trade UI for reference**

Read `Features/Transactions/TradeTransactionView.swift` (from Phase 3) to understand the pattern. The swap UI mirrors it but:
- Both sides can be non-fiat (stock trade has one fiat, one stock).
- Gas fee field replaces brokerage fee field.
- Gas fee instrument defaults to the chain's native token (e.g., ETH for chain 1).

- [ ] **Step 2: Implement TokenSwapView**

```swift
// Features/Transactions/TokenSwapView.swift
import SwiftUI

struct TokenSwapView: View {
  @Environment(BackendProvider.self) private var backend
  @State private var draft: TokenSwapDraft
  @State private var isSaving = false
  @State private var error: String?

  let accountId: UUID
  let onSave: () -> Void
  let onCancel: () -> Void

  init(accountId: UUID, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
    self.accountId = accountId
    self._draft = State(initialValue: TokenSwapDraft(accountId: accountId))
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var body: some View {
    Form {
      Section("You Send") {
        instrumentPicker(
          label: "Token",
          selection: $draft.sourceInstrument,
          filter: .cryptoToken
        )
        decimalField(
          label: "Amount",
          value: $draft.sourceQuantity,
          instrument: draft.sourceInstrument
        )
      }

      Section("You Receive") {
        instrumentPicker(
          label: "Token",
          selection: $draft.destinationInstrument,
          filter: .cryptoToken
        )
        decimalField(
          label: "Amount",
          value: $draft.destinationQuantity,
          instrument: draft.destinationInstrument
        )
      }

      Section("Gas Fee (Optional)") {
        instrumentPicker(
          label: "Fee Token",
          selection: $draft.gasFeeInstrument,
          filter: .cryptoToken
        )
        if draft.gasFeeInstrument != nil {
          decimalField(
            label: "Fee Amount",
            value: $draft.gasFeeQuantity,
            instrument: draft.gasFeeInstrument
          )
          // Category picker for gas fee (reuse existing CategoryPicker)
        }
      }

      Section {
        DatePicker("Date", selection: $draft.date, displayedComponents: .date)
        TextField("Notes", text: Binding(
          get: { draft.notes ?? "" },
          set: { draft.notes = $0.isEmpty ? nil : $0 }
        ))
      }

      if let error {
        Section {
          Text(error)
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("Token Swap")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel", action: onCancel)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          Task { await save() }
        }
        .disabled(!draft.isValid || isSaving)
      }
    }
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let transaction = draft.buildTransaction()
      try await backend.transactionRepository.create(transaction)
      onSave()
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private func instrumentPicker(
    label: String,
    selection: Binding<Instrument?>,
    filter: Instrument.Kind
  ) -> some View {
    // Reuse the InstrumentPicker from Phase 3, filtered to crypto instruments.
    // The picker shows registered crypto instruments from the provider mappings.
    InstrumentPicker(label: label, selection: selection, kindFilter: filter)
  }

  @ViewBuilder
  private func decimalField(
    label: String,
    value: Binding<Decimal>,
    instrument: Instrument?
  ) -> some View {
    // Decimal text field with appropriate precision for the instrument's decimals.
    DecimalTextField(
      label: label,
      value: value,
      maximumFractionDigits: instrument?.decimals ?? 18
    )
  }
}
```

**Note:** This assumes `InstrumentPicker` and `DecimalTextField` were created in Phase 3 for the trade UI. If not, they need to be created as shared components.

- [ ] **Step 3: Add entry point in account detail view**

In `Features/Accounts/AccountDetailView.swift`, add a "Token Swap" button in the transaction creation menu (alongside the existing "Trade" option from Phase 3). Show it when the account holds crypto positions:

```swift
// In the toolbar or action menu:
if account.type == .investment {
  // Existing from Phase 3:
  Button("Trade") { showingTradeSheet = true }
  // New:
  Button("Token Swap") { showingSwapSheet = true }
}
```

- [ ] **Step 4: Build and verify UI renders**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-swap-ui.txt`
Expected: Build succeeds with no warnings.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/build-swap-ui.txt
git add Features/Transactions/TokenSwapView.swift Features/Accounts/AccountDetailView.swift
git commit -m "feat: add token swap transaction UI for crypto-to-crypto swaps"
```

---

## Task 6: Crypto Positions Display

**Files:**
- Create: `Features/Accounts/CryptoPositionsSectionView.swift`
- Modify: `Features/Accounts/AccountDetailView.swift`

Display crypto positions (instrument + quantity + current fiat value) in the account detail view. This reuses the `Position` type from Phase 2 and the `InstrumentConversionService` wired in Task 3.

- [ ] **Step 1: Implement CryptoPositionsSectionView**

```swift
// Features/Accounts/CryptoPositionsSectionView.swift
import SwiftUI

/// Displays crypto token positions for an account with current fiat values.
struct CryptoPositionsSectionView: View {
  let positions: [Position]
  let profileCurrency: Instrument
  let conversionService: InstrumentConversionService

  @State private var valuations: [String: Decimal] = [:]  // instrumentId -> fiat value
  @State private var isLoading = true

  var body: some View {
    Section("Crypto Holdings") {
      if isLoading {
        ProgressView()
      } else if cryptoPositions.isEmpty {
        Text("No crypto holdings")
          .foregroundStyle(.secondary)
      } else {
        ForEach(cryptoPositions, id: \.instrument.id) { position in
          HStack {
            VStack(alignment: .leading) {
              Text(position.instrument.displaySymbol ?? position.instrument.name)
                .font(.headline)
              Text(position.instrument.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing) {
              Text(formatQuantity(position.quantity, instrument: position.instrument))
                .monospacedDigit()
              if let fiatValue = valuations[position.instrument.id] {
                let amount = InstrumentAmount(quantity: fiatValue, instrument: profileCurrency)
                Text(amount.formatted)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(accessibilityLabel(for: position))
        }
      }
    }
    .task {
      await loadValuations()
    }
  }

  private var cryptoPositions: [Position] {
    positions.filter { $0.instrument.kind == .cryptoToken && !$0.quantity.isZero }
  }

  private func loadValuations() async {
    isLoading = true
    defer { isLoading = false }

    for position in cryptoPositions {
      do {
        let fiatValue = try await conversionService.convert(
          position.quantity,
          from: position.instrument,
          to: profileCurrency,
          on: Date()
        )
        valuations[position.instrument.id] = fiatValue
      } catch {
        // Price unavailable — show quantity without value
      }
    }
  }

  private func formatQuantity(_ quantity: Decimal, instrument: Instrument) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = min(instrument.decimals, 8)
    formatter.minimumFractionDigits = 0
    let symbol = instrument.displaySymbol ?? ""
    let number = formatter.string(from: quantity as NSDecimalNumber) ?? "\(quantity)"
    return "\(number) \(symbol)"
  }

  private func accessibilityLabel(for position: Position) -> String {
    let qty = formatQuantity(position.quantity, instrument: position.instrument)
    if let fiatValue = valuations[position.instrument.id] {
      let amount = InstrumentAmount(quantity: fiatValue, instrument: profileCurrency)
      return "\(qty), valued at \(amount.formatted)"
    }
    return qty
  }
}
```

- [ ] **Step 2: Wire into AccountDetailView**

In `Features/Accounts/AccountDetailView.swift`, add the crypto positions section when the account has crypto positions:

```swift
// In the account detail body, after the existing positions section (from Phase 2/3):
let cryptoPositions = positions.filter { $0.instrument.kind == .cryptoToken }
if !cryptoPositions.isEmpty {
  CryptoPositionsSectionView(
    positions: cryptoPositions,
    profileCurrency: profileCurrency,
    conversionService: conversionService
  )
}
```

- [ ] **Step 3: Build and verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-positions.txt`
Expected: Build succeeds with no warnings.

- [ ] **Step 4: Run UI review agent**

```
@ui-review Features/Accounts/CryptoPositionsSectionView.swift
```

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/build-positions.txt
git add Features/Accounts/CryptoPositionsSectionView.swift Features/Accounts/AccountDetailView.swift
git commit -m "feat: display crypto positions with current fiat values in account detail"
```

---

## Task 7: CryptoPriceClient Migration to Instrument

**Files:**
- Modify: `Domain/Repositories/CryptoPriceClient.swift`
- Modify: `Shared/CryptoPriceService.swift`
- Modify: `MoolahTests/Support/FixedCryptoPriceClient.swift`
- Modify: `MoolahTests/Shared/CryptoPriceServiceTests.swift`
- Modify: `MoolahTests/Shared/PriceConversionServiceTests.swift`

The `CryptoPriceClient` protocol currently takes `CryptoToken`. This task adds `Instrument` overloads and bridges internally via `CryptoProviderMapping`. The `CryptoToken` overloads are retained temporarily for backward compatibility.

- [ ] **Step 1: Add Instrument overloads to CryptoPriceClient**

```swift
// Domain/Repositories/CryptoPriceClient.swift — add overloads:

protocol CryptoPriceClient: Sendable {
  // Existing CryptoToken-based methods (retained for backward compat)
  func dailyPrice(for token: CryptoToken, on date: Date) async throws -> Decimal
  func dailyPrices(for token: CryptoToken, in range: ClosedRange<Date>) async throws -> [String: Decimal]
  func currentPrices(for tokens: [CryptoToken]) async throws -> [String: Decimal]
}
```

**Decision:** Rather than changing the protocol, the bridging happens in `InstrumentConversionService` (Task 3 already does this). This task updates `CryptoPriceService` to also accept `Instrument` + `CryptoProviderMapping` as convenience methods:

```swift
// Shared/CryptoPriceService.swift — add convenience methods:

extension CryptoPriceService {
  /// Fetch price for an instrument using its provider mapping.
  func price(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    on date: Date
  ) async throws -> Decimal {
    let token = Self.bridgeToToken(instrument: instrument, mapping: mapping)
    return try await price(for: token, on: date)
  }

  /// Fetch price range for an instrument using its provider mapping.
  func prices(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async throws -> [(date: Date, price: Decimal)] {
    let token = Self.bridgeToToken(instrument: instrument, mapping: mapping)
    return try await prices(for: token, in: range)
  }

  static func bridgeToToken(instrument: Instrument, mapping: CryptoProviderMapping) -> CryptoToken {
    CryptoToken(
      chainId: instrument.chainId ?? 0,
      contractAddress: instrument.contractAddress,
      symbol: instrument.ticker ?? instrument.name,
      name: instrument.name,
      decimals: instrument.decimals,
      coingeckoId: mapping.coingeckoId,
      cryptocompareSymbol: mapping.cryptocompareSymbol,
      binanceSymbol: mapping.binanceSymbol
    )
  }
}
```

- [ ] **Step 2: Update FixedCryptoPriceClient for tests**

The `FixedCryptoPriceClient` already uses `token.id` as the key for price lookup. Since `Instrument.crypto(...)` produces the same ID format as `CryptoToken.id`, no changes are needed to the test double — it works for both.

Verify by adding a test:

```swift
// Add to existing test file or InstrumentConversionServiceCryptoTests:
@Test func fixedClientWorksWithBridgedToken() async throws {
  let instrument = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let mapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )
  let bridgedToken = CryptoPriceService.bridgeToToken(instrument: instrument, mapping: mapping)
  #expect(bridgedToken.id == "1:native")
  #expect(bridgedToken.coingeckoId == "ethereum")
}
```

- [ ] **Step 3: Run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-client-migration.txt`
Expected: All tests PASS.

- [ ] **Step 4: Clean up temp files and commit**

```bash
rm .agent-tmp/test-client-migration.txt
git add Shared/CryptoPriceService.swift MoolahTests/Shared/InstrumentConversionServiceCryptoTests.swift
git commit -m "feat: add Instrument-based convenience methods to CryptoPriceService"
```

---

## Task 8: CryptoTokenStore Migration

**Files:**
- Modify: `Features/Settings/CryptoTokenStore.swift`
- Modify: `MoolahTests/Features/CryptoTokenStoreTests.swift`

Migrate `CryptoTokenStore` to work with `Instrument` + `CryptoProviderMapping` instead of `CryptoToken`. The store manages registered crypto instruments and their provider mappings. The underlying storage still uses `CryptoTokenRepository` for now (it can be renamed in a follow-up cleanup).

- [ ] **Step 1: Update the tests first**

Update `MoolahTests/Features/CryptoTokenStoreTests.swift` to verify the store exposes `Instrument` objects:

```swift
// Key test changes:
// - store.tokens -> store.instruments (or store.cryptoInstruments)
// - Verify store.providerMappings contains correct mappings
// - Verify resolveToken produces an Instrument + CryptoProviderMapping pair

@Test func loadTokensReturnsInstruments() async {
  // ... setup ...
  await store.load()
  #expect(store.cryptoInstruments.count == expectedCount)
  #expect(store.cryptoInstruments.first?.kind == .cryptoToken)
}

@Test func resolveTokenProducesInstrumentAndMapping() async {
  // ... setup ...
  await store.resolveToken(chainId: 1, contractAddress: nil, symbol: "ETH", isNative: true)
  #expect(store.resolvedInstrument?.kind == .cryptoToken)
  #expect(store.resolvedMapping?.coingeckoId == "ethereum")
}
```

- [ ] **Step 2: Update CryptoTokenStore implementation**

```swift
// Features/Settings/CryptoTokenStore.swift
import Foundation

@MainActor @Observable
final class CryptoTokenStore {
  private(set) var cryptoInstruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]
  private(set) var isLoading = false
  private(set) var isResolving = false
  var resolvedInstrument: Instrument?
  var resolvedMapping: CryptoProviderMapping?
  private(set) var error: String?

  private let cryptoPriceService: CryptoPriceService

  private let apiKeyStore = KeychainStore(
    service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
  )

  init(cryptoPriceService: CryptoPriceService) {
    self.cryptoPriceService = cryptoPriceService
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    let tokens = await cryptoPriceService.registeredTokens()
    cryptoInstruments = tokens.map { CryptoProviderMapping.instrument(from: $0) }
    providerMappings = Dictionary(
      tokens.map { (CryptoProviderMapping.from($0).instrumentId, CryptoProviderMapping.from($0)) },
      uniquingKeysWith: { _, last in last }
    )
  }

  func removeInstrument(_ instrument: Instrument) async {
    // Bridge back to CryptoToken for the existing service API
    guard let mapping = providerMappings[instrument.id] else { return }
    let token = CryptoPriceService.bridgeToToken(instrument: instrument, mapping: mapping)
    do {
      try await cryptoPriceService.removeToken(token)
      cryptoInstruments.removeAll { $0.id == instrument.id }
      providerMappings.removeValue(forKey: instrument.id)
    } catch {
      self.error = error.localizedDescription
    }
  }

  func resolveToken(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async {
    isResolving = true
    resolvedInstrument = nil
    resolvedMapping = nil
    error = nil
    defer { isResolving = false }

    do {
      let token = try await cryptoPriceService.resolveToken(
        chainId: chainId,
        contractAddress: contractAddress,
        symbol: symbol,
        isNative: isNative
      )
      resolvedInstrument = CryptoProviderMapping.instrument(from: token)
      resolvedMapping = CryptoProviderMapping.from(token)
    } catch {
      self.error = "Resolution failed: \(error.localizedDescription)"
    }
  }

  func confirmRegistration() async {
    guard let instrument = resolvedInstrument, let mapping = resolvedMapping else { return }
    let token = CryptoPriceService.bridgeToToken(instrument: instrument, mapping: mapping)
    do {
      try await cryptoPriceService.registerToken(token)
      cryptoInstruments.append(instrument)
      providerMappings[instrument.id] = mapping
      resolvedInstrument = nil
      resolvedMapping = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  // MARK: - API Key (unchanged)

  var hasApiKey: Bool {
    (try? apiKeyStore.restoreString()) != nil
  }

  func saveApiKey(_ key: String) {
    do {
      try apiKeyStore.saveString(key)
    } catch {
      self.error = "Failed to save API key: \(error.localizedDescription)"
    }
  }

  func clearApiKey() {
    apiKeyStore.clear()
  }
}
```

- [ ] **Step 3: Run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-store-migration.txt`
Expected: All CryptoTokenStore tests PASS.

- [ ] **Step 4: Update any views that reference `store.tokens`**

Search for references to `store.tokens` where the store is a `CryptoTokenStore` and update to `store.cryptoInstruments`.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-store-migration.txt
git add Features/Settings/CryptoTokenStore.swift MoolahTests/Features/CryptoTokenStoreTests.swift
git commit -m "refactor: migrate CryptoTokenStore to use Instrument + CryptoProviderMapping"
```

---

## Task 9: Retire PriceConversionService

**Files:**
- Modify: `Shared/PriceConversionService.swift` — deprecate or delete
- Modify: any callers that use `PriceConversionService` directly

The `PriceConversionService` (crypto -> fiat conversion via CryptoPriceService + ExchangeRateService) is now fully absorbed by `InstrumentConversionService`. Any code still calling `PriceConversionService.convert(amount:token:to:on:)` should be migrated to `InstrumentConversionService.convert(_:from:to:on:)`.

- [ ] **Step 1: Search for PriceConversionService callers**

```bash
grep -r "PriceConversionService" --include="*.swift" -l
```

- [ ] **Step 2: Migrate each caller to InstrumentConversionService**

For each call site:
- Replace `priceConversionService.convert(amount: qty, token: token, to: currency, on: date)` with `conversionService.convert(qty, from: cryptoInstrument, to: Instrument.fiat(code: currency.code), on: date)`.
- Replace `priceConversionService.unitPrice(for: token, in: currency, on: date)` with `conversionService.convert(Decimal(1), from: cryptoInstrument, to: fiatInstrument, on: date)`.

- [ ] **Step 3: Delete PriceConversionService.swift**

Once no callers remain:
```bash
git rm Shared/PriceConversionService.swift
git rm MoolahTests/Shared/PriceConversionServiceTests.swift
```

- [ ] **Step 4: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-retire-pcs.txt`
Expected: All tests PASS.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-retire-pcs.txt
git add -A
git commit -m "refactor: retire PriceConversionService in favor of InstrumentConversionService"
```

---

## Task 10: Retire CryptoToken Type

**Files:**
- Delete: `Domain/Models/CryptoToken.swift`
- Delete: `MoolahTests/Domain/CryptoTokenTests.swift`
- Modify: `Shared/CryptoPriceService.swift` — internal use only, bridge from Instrument
- Modify: `Domain/Repositories/CryptoPriceClient.swift` — change to accept instrument ID + mapping
- Modify: `MoolahTests/Support/FixedCryptoPriceClient.swift`
- Modify: `Domain/Repositories/CryptoTokenRepository.swift` — rename or replace

This is the final cleanup. By this point, all external callers use `Instrument` + `CryptoProviderMapping`. The `CryptoToken` type is only used internally by `CryptoPriceService` and the `CryptoPriceClient` implementations.

- [ ] **Step 1: Search for remaining CryptoToken references**

```bash
grep -r "CryptoToken" --include="*.swift" -l | grep -v DerivedData | grep -v .build
```

- [ ] **Step 2: Update CryptoPriceClient protocol**

Change the protocol to accept `Instrument` + `CryptoProviderMapping`:

```swift
// Domain/Repositories/CryptoPriceClient.swift
protocol CryptoPriceClient: Sendable {
  func dailyPrice(
    for instrument: Instrument, mapping: CryptoProviderMapping, on date: Date
  ) async throws -> Decimal

  func dailyPrices(
    for instrument: Instrument, mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal]

  func currentPrices(
    for instruments: [(Instrument, CryptoProviderMapping)]
  ) async throws -> [String: Decimal]
}
```

- [ ] **Step 3: Update all CryptoPriceClient implementations**

Update `CoinGeckoClient`, `CryptoCompareClient`, `BinanceClient` (the concrete implementations) to accept the new protocol. Each implementation extracts the provider-specific ID from the mapping:

```swift
// Example for CoinGecko:
func dailyPrice(for instrument: Instrument, mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
  guard let coinId = mapping.coingeckoId else {
    throw CryptoPriceError.noProviderMapping(tokenId: instrument.id, provider: "coingecko")
  }
  // ... existing fetch logic using coinId ...
}
```

- [ ] **Step 4: Update FixedCryptoPriceClient**

```swift
// MoolahTests/Support/FixedCryptoPriceClient.swift
struct FixedCryptoPriceClient: CryptoPriceClient, Sendable {
  let prices: [String: [String: Decimal]]  // instrument ID -> { date -> price }
  let shouldFail: Bool

  func dailyPrice(
    for instrument: Instrument, mapping: CryptoProviderMapping, on date: Date
  ) async throws -> Decimal {
    if shouldFail { throw URLError(.notConnectedToInternet) }
    let dateString = Self.dateFormatter.string(from: date)
    guard let price = prices[instrument.id]?[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: instrument.id, date: dateString)
    }
    return price
  }

  // ... update other methods similarly ...
}
```

- [ ] **Step 5: Update CryptoPriceService**

Remove the `CryptoToken` bridge methods. The service now works directly with `Instrument` + `CryptoProviderMapping`:

```swift
// Shared/CryptoPriceService.swift
// Change internal cache keys to use instrument IDs (already the case — CryptoToken.id == Instrument.id)
// Remove bridgeToToken, use Instrument + mapping directly in all methods
```

- [ ] **Step 6: Replace CryptoTokenRepository**

The `CryptoTokenRepository` stores registered tokens as `[CryptoToken]`. Replace with a repository that stores `[(Instrument, CryptoProviderMapping)]` pairs. Since the on-disk format is JSON in iCloud KV store, the migration is:

```swift
// Domain/Repositories/CryptoProviderMappingRepository.swift
protocol CryptoProviderMappingRepository: Sendable {
  func loadMappings() async throws -> [(Instrument, CryptoProviderMapping)]
  func saveMappings(_ mappings: [(Instrument, CryptoProviderMapping)]) async throws
}
```

The iCloud implementation reads the old format (if present), converts via `CryptoProviderMapping.from(_:)` and `CryptoProviderMapping.instrument(from:)`, and writes the new format.

- [ ] **Step 7: Delete CryptoToken files**

```bash
git rm Domain/Models/CryptoToken.swift
git rm MoolahTests/Domain/CryptoTokenTests.swift
```

- [ ] **Step 8: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-retire-token.txt`
Expected: All tests PASS.

- [ ] **Step 9: Clean up temp files and commit**

```bash
rm .agent-tmp/test-retire-token.txt
git add -A
git commit -m "refactor: retire CryptoToken type, all crypto uses Instrument + CryptoProviderMapping"
```

---

## Task 11: Update project.yml and Final Verification

**Files:**
- Modify: `project.yml` — ensure new files are in correct groups

- [ ] **Step 1: Regenerate Xcode project**

```bash
just generate
```

- [ ] **Step 2: Run full test suite on both platforms**

```bash
just test 2>&1 | tee .agent-tmp/test-final.txt
grep -i 'failed\|error:' .agent-tmp/test-final.txt
```

Expected: All tests PASS on both iOS and macOS.

- [ ] **Step 3: Check for warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` to verify no warnings in user code.

- [ ] **Step 4: Run concurrency review agent**

```
@concurrency-review Shared/InstrumentConversionService.swift Shared/CryptoPriceService.swift Features/Settings/CryptoTokenStore.swift
```

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-final.txt
git add project.yml
git commit -m "chore: regenerate project after Phase 4 crypto implementation"
```

---

## Summary

| Task | Description | New Files | Key Deliverable |
|------|-------------|-----------|-----------------|
| 1 | Instrument.crypto factory | 1 test | Crypto instruments use same ID format as CryptoToken |
| 2 | CryptoProviderMapping | 1 model + 1 test | Provider IDs separated from instrument identity |
| 3 | InstrumentConversionService crypto path | 1 test | Crypto -> USD -> fiat conversion routing |
| 4 | TokenSwapDraft | 1 model + 1 test | Multi-leg crypto swap transaction builder |
| 5 | Token Swap UI | 1 view | User-facing swap entry screen |
| 6 | Crypto Positions Display | 1 view | Current holdings with fiat valuations |
| 7 | CryptoPriceClient migration | 0 new | Instrument-based convenience methods |
| 8 | CryptoTokenStore migration | 0 new | Store exposes Instrument, not CryptoToken |
| 9 | Retire PriceConversionService | -2 files | Functionality absorbed into InstrumentConversionService |
| 10 | Retire CryptoToken | -2 files | Clean break from legacy type |
| 11 | Final verification | 0 new | Full test suite green, no warnings |

**Estimated effort:** Tasks 1-4 are small (domain model work). Task 5-6 are medium (UI). Tasks 7-10 are medium (migration/refactoring). Task 11 is verification only.

**Dependencies:** Tasks 1-2 are independent. Task 3 depends on 1-2. Task 4 depends on 1. Tasks 5-6 depend on 3-4. Tasks 7-8 depend on 1-2. Tasks 9-10 depend on 3, 7-8. Task 11 depends on all.
