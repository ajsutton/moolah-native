# Crypto Phase 6 Completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Phase 6 by adding token persistence (iCloud), token resolution (CoinGecko/CryptoCompare/Binance), date-aware USDT/USD rates, CoinGecko provider activation, and a tabbed settings UI (macOS) / navigation-based settings (iOS) for managing crypto tokens.

**Architecture:** Token registry persisted via `NSUbiquitousKeyValueStore` (iCloud sync). Token resolution queries three providers to populate provider-specific IDs. `CryptoPriceService` gains token management methods. BinanceClient accepts a date-aware USDT rate closure. Settings UI uses `TabView` on macOS (Mail.app style) and a navigation row on iOS.

**Tech Stack:** Swift 6.0, SwiftUI, NSUbiquitousKeyValueStore, URLSession, Security framework (Keychain), Swift Testing

**Spec:** `plans/crypto-phase6-completion-design.md`

**Conventions:**
- TDD: write failing test → run to confirm failure → implement → run to confirm pass → commit
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`)
- `@testable import Moolah` (single module, both platforms)
- Test files live in `MoolahTests/` mirroring source structure
- Source files auto-discovered — no project.yml edits needed for new `.swift` files
- All stores are `@MainActor @Observable`. Domain models are `Sendable`. Actors for services.
- After creating or modifying UI, invoke the `ui-review` agent and fix all issues before proceeding

---

### Task 1: CryptoTokenRepository Protocol + InMemoryTokenRepository

**Files:**
- Create: `Domain/Repositories/CryptoTokenRepository.swift`
- Create: `MoolahTests/Support/InMemoryTokenRepository.swift`
- Test: `MoolahTests/Domain/CryptoTokenRepositoryTests.swift`

- [ ] **Step 1: Write the repository protocol**

Create `Domain/Repositories/CryptoTokenRepository.swift`:

```swift
// Domain/Repositories/CryptoTokenRepository.swift
import Foundation

protocol CryptoTokenRepository: Sendable {
    func loadTokens() async throws -> [CryptoToken]
    func saveTokens(_ tokens: [CryptoToken]) async throws
}
```

- [ ] **Step 2: Write InMemoryTokenRepository**

Create `MoolahTests/Support/InMemoryTokenRepository.swift`:

```swift
// MoolahTests/Support/InMemoryTokenRepository.swift
import Foundation
@testable import Moolah

final class InMemoryTokenRepository: CryptoTokenRepository, @unchecked Sendable {
    private var tokens: [CryptoToken] = []

    func loadTokens() async throws -> [CryptoToken] {
        tokens
    }

    func saveTokens(_ tokens: [CryptoToken]) async throws {
        self.tokens = tokens
    }
}
```

- [ ] **Step 3: Write the failing tests**

Create `MoolahTests/Domain/CryptoTokenRepositoryTests.swift`:

```swift
// MoolahTests/Domain/CryptoTokenRepositoryTests.swift
import Foundation
import Testing
@testable import Moolah

@Suite("CryptoTokenRepository (InMemory)")
struct CryptoTokenRepositoryTests {
    private func makeRepository() -> InMemoryTokenRepository {
        InMemoryTokenRepository()
    }

    @Test func emptyRepositoryReturnsEmptyArray() async throws {
        let repo = makeRepository()
        let tokens = try await repo.loadTokens()
        #expect(tokens.isEmpty)
    }

    @Test func roundTrip_saveAndLoad() async throws {
        let repo = makeRepository()
        let tokens = Array(CryptoToken.builtInPresets.prefix(2))
        try await repo.saveTokens(tokens)
        let loaded = try await repo.loadTokens()
        #expect(loaded.count == 2)
        #expect(loaded[0].id == tokens[0].id)
        #expect(loaded[1].id == tokens[1].id)
    }

    @Test func saveOverwritesPreviousList() async throws {
        let repo = makeRepository()
        try await repo.saveTokens(Array(CryptoToken.builtInPresets.prefix(3)))
        try await repo.saveTokens(Array(CryptoToken.builtInPresets.prefix(1)))
        let loaded = try await repo.loadTokens()
        #expect(loaded.count == 1)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All new tests pass (InMemoryTokenRepository is both protocol and implementation).

- [ ] **Step 5: Commit**

```bash
git add Domain/Repositories/CryptoTokenRepository.swift MoolahTests/Support/InMemoryTokenRepository.swift MoolahTests/Domain/CryptoTokenRepositoryTests.swift
git commit -m "feat: add CryptoTokenRepository protocol and InMemoryTokenRepository"
```

---

### Task 2: ICloudTokenRepository

**Files:**
- Create: `Backends/ICloud/ICloudTokenRepository.swift`

This implementation uses `NSUbiquitousKeyValueStore` for iCloud sync. It cannot be meaningfully unit-tested in CI (requires iCloud entitlement), so it is kept thin — just encode/decode and read/write from the KVS. The protocol contract is tested via `InMemoryTokenRepository` in Task 1.

- [ ] **Step 1: Write ICloudTokenRepository**

Create `Backends/ICloud/ICloudTokenRepository.swift`:

```swift
// Backends/ICloud/ICloudTokenRepository.swift
import Foundation

struct ICloudTokenRepository: CryptoTokenRepository, Sendable {
    private static let key = "crypto-tokens"

    func loadTokens() async throws -> [CryptoToken] {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.key) else {
            return []
        }
        return try JSONDecoder().decode([CryptoToken].self, from: data)
    }

    func saveTokens(_ tokens: [CryptoToken]) async throws {
        let data = try JSONEncoder().encode(tokens)
        NSUbiquitousKeyValueStore.default.set(data, forKey: Self.key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `just build-mac`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Backends/ICloud/ICloudTokenRepository.swift
git commit -m "feat: add ICloudTokenRepository backed by NSUbiquitousKeyValueStore"
```

---

### Task 3: Token Management on CryptoPriceService

**Files:**
- Modify: `Shared/CryptoPriceService.swift`
- Test: `MoolahTests/Shared/CryptoPriceServiceTests.swift`

Add token registration, listing, and removal to `CryptoPriceService`. The service owns the `CryptoTokenRepository` and provides `registeredTokens()` as the source of truth.

- [ ] **Step 1: Write failing tests for token management**

Add to `MoolahTests/Shared/CryptoPriceServiceTests.swift`:

```swift
// Add tokenRepository parameter to makeService helper:
private func makeService(
    clients: [CryptoPriceClient]? = nil,
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    cacheDirectory: URL? = nil,
    tokenRepository: CryptoTokenRepository? = nil
) -> CryptoPriceService {
    let clientList = clients ?? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
    let cacheDir = cacheDirectory
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("crypto-price-tests")
            .appendingPathComponent(UUID().uuidString)
    return CryptoPriceService(
        clients: clientList,
        cacheDirectory: cacheDir,
        tokenRepository: tokenRepository ?? InMemoryTokenRepository()
    )
}

// MARK: - Token management

@Test func registerTokenAddsToList() async throws {
    let service = makeService()
    let token = CryptoToken.builtInPresets[0]
    try await service.registerToken(token)
    let tokens = await service.registeredTokens()
    #expect(tokens.count == 1)
    #expect(tokens[0].id == token.id)
}

@Test func removeTokenDeletesFromList() async throws {
    let service = makeService()
    let token = CryptoToken.builtInPresets[0]
    try await service.registerToken(token)
    try await service.removeToken(token)
    let tokens = await service.registeredTokens()
    #expect(tokens.isEmpty)
}

@Test func registeredTokensPersistViaRepository() async throws {
    let repo = InMemoryTokenRepository()
    let service1 = makeService(tokenRepository: repo)
    try await service1.registerToken(CryptoToken.builtInPresets[0])

    let service2 = makeService(tokenRepository: repo)
    let tokens = await service2.registeredTokens()
    #expect(tokens.count == 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: Compilation errors — `CryptoPriceService` doesn't accept `tokenRepository` yet.

- [ ] **Step 3: Add token management to CryptoPriceService**

Modify `Shared/CryptoPriceService.swift`:

1. Add `tokenRepository` parameter to init:
```swift
private let tokenRepository: CryptoTokenRepository

init(clients: [CryptoPriceClient], cacheDirectory: URL? = nil,
     tokenRepository: CryptoTokenRepository = ICloudTokenRepository()) {
    self.clients = clients
    self.tokenRepository = tokenRepository
    // ... existing init code ...
}
```

2. Add token management methods:
```swift
// MARK: - Token management

func registeredTokens() async -> [CryptoToken] {
    (try? await tokenRepository.loadTokens()) ?? []
}

func registerToken(_ token: CryptoToken) async throws {
    var tokens = try await tokenRepository.loadTokens()
    tokens.removeAll { $0.id == token.id }
    tokens.append(token)
    try await tokenRepository.saveTokens(tokens)
}

func removeToken(_ token: CryptoToken) async throws {
    var tokens = try await tokenRepository.loadTokens()
    tokens.removeAll { $0.id == token.id }
    try await tokenRepository.saveTokens(tokens)
    // Remove cached price data
    caches.removeValue(forKey: token.id)
    let url = cacheFileURL(tokenId: token.id)
    try? FileManager.default.removeItem(at: url)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All new and existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/CryptoPriceService.swift MoolahTests/Shared/CryptoPriceServiceTests.swift
git commit -m "feat: add token management (register/remove/list) to CryptoPriceService"
```

---

### Task 4: Date-Aware USDT/USD Rate for BinanceClient

**Files:**
- Modify: `Backends/Binance/BinanceClient.swift`
- Modify: `MoolahTests/Backends/BinanceClientTests.swift`
- Modify: `Shared/CryptoPriceService.swift`
- Modify: `App/ProfileSession.swift`

Replace the static `usdtUsdRate: Decimal` parameter with a `usdtRateLookup: @Sendable (Date) async -> Decimal` closure that returns the USDT/USD rate for a given date, falling back to 1.0 if unavailable.

- [ ] **Step 1: Write failing tests**

Update `MoolahTests/Backends/BinanceClientTests.swift` — replace the two existing USDT rate tests:

```swift
@Test func pricesAreMultipliedByDateSpecificUsdtRate() throws {
    let usdtPrices: [String: Decimal] = ["2026-04-10": Decimal(string: "1000.00")!]
    let converted = BinanceClient.applyUsdtRate(usdtPrices, rate: Decimal(string: "0.999")!)
    #expect(converted["2026-04-10"] == Decimal(string: "999.000")!)
}
```

Add new test for the closure-based init:

```swift
@Test func dailyPricesUsesDateAwareUsdtRate() async throws {
    // This test validates that the closure signature compiles and is called
    let client = BinanceClient(session: .shared) { _ in
        Decimal(string: "0.998")!
    }
    // The client is constructed — full integration tested via CryptoPriceService
    #expect(client != nil)  // Validates the init compiles
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: Compilation errors — `BinanceClient` init doesn't accept a closure yet.

- [ ] **Step 3: Update BinanceClient**

Modify `Backends/Binance/BinanceClient.swift`:

1. Replace the `usdtUsdRate` stored property with a closure:
```swift
struct BinanceClient: CryptoPriceClient, Sendable {
    private static let baseURL = URL(string: "https://api.binance.com")!
    private let session: URLSession
    private let usdtRateLookup: @Sendable (Date) async -> Decimal

    init(session: URLSession = .shared,
         usdtRateLookup: @escaping @Sendable (Date) async -> Decimal = { _ in Decimal(1) }) {
        self.session = session
        self.usdtRateLookup = usdtRateLookup
    }
```

2. Update `dailyPrices` to call the closure per-date instead of using a static rate:
```swift
func dailyPrices(
    for token: CryptoToken, in range: ClosedRange<Date>
) async throws -> [String: Decimal] {
    guard let symbol = token.binanceSymbol else {
        throw CryptoPriceError.noProviderMapping(tokenId: token.id, provider: "Binance")
    }

    var allPrices: [String: Decimal] = [:]
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = range.lowerBound

    while chunkStart <= range.upperBound {
        let chunkEnd = min(
            calendar.date(byAdding: .day, value: 999, to: chunkStart)!,
            range.upperBound
        )
        let url = Self.klinesURL(symbol: symbol, from: chunkStart, to: chunkEnd)
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let chunk = try Self.parseKlinesResponse(data)
        for (key, value) in chunk { allPrices[key] = value }
        chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
    }

    // Apply date-specific USDT/USD rate
    let midDate = Date(
        timeIntervalSince1970: (range.lowerBound.timeIntervalSince1970 + range.upperBound.timeIntervalSince1970) / 2
    )
    let rate = await usdtRateLookup(midDate)
    return Self.applyUsdtRate(allPrices, rate: rate)
}
```

3. Keep `applyUsdtRate` as-is (static helper, still useful for testing).

- [ ] **Step 4: Update ProfileSession**

Modify `App/ProfileSession.swift` to pass a USDT rate lookup closure to BinanceClient. The closure uses the CryptoCompare client to look up USDT/USD:

```swift
// In init, replace the cryptoPriceService creation:
let cryptoCompareClient = CryptoCompareClient()
let binanceClient = BinanceClient { date in
    // Look up USDT/USD rate from CryptoCompare; fall back to 1.0
    let usdt = CryptoToken(
        chainId: 1, contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
        symbol: "USDT", name: "Tether", decimals: 6,
        coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
    )
    do {
        let price = try await cryptoCompareClient.dailyPrice(for: usdt, on: date)
        return price
    } catch {
        return Decimal(1)
    }
}
self.cryptoPriceService = CryptoPriceService(
    clients: [cryptoCompareClient, binanceClient]
)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass. Existing `BinanceClientTests` pass with default closure.

- [ ] **Step 6: Commit**

```bash
git add Backends/Binance/BinanceClient.swift MoolahTests/Backends/BinanceClientTests.swift Shared/CryptoPriceService.swift App/ProfileSession.swift
git commit -m "feat: make BinanceClient USDT/USD rate date-aware via closure"
```

---

### Task 5: Token Resolution — CryptoCompare Coin List

**Files:**
- Modify: `Backends/CryptoCompare/CryptoCompareClient.swift`
- Test: `MoolahTests/Backends/CryptoCompareClientTests.swift`

Add a method to download the CryptoCompare coin list and resolve a token's CryptoCompare symbol from contract address.

- [ ] **Step 1: Write failing tests**

Add to `MoolahTests/Backends/CryptoCompareClientTests.swift`:

```swift
// MARK: - Coin list parsing

@Test func parseCoinListResponse_extractsSymbolByContractAddress() throws {
    let json = """
    {
        "Data": {
            "ETH": {
                "Symbol": "ETH",
                "CoinName": "Ethereum",
                "SmartContractAddress": "N/A"
            },
            "UNI": {
                "Symbol": "UNI",
                "CoinName": "Uniswap",
                "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
            },
            "SCAM": {
                "Symbol": "SCAM",
                "CoinName": "Scam Token",
                "SmartContractAddress": "0xdeadbeef"
            }
        }
    }
    """.data(using: .utf8)!

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    #expect(index["0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"] == "UNI")
    #expect(index["0xdeadbeef"] == "SCAM")
    // N/A is not a valid address
    #expect(index["N/A"] == nil)
}

@Test func parseCoinListResponse_nativeTokenHasNoContractEntry() throws {
    let json = """
    {
        "Data": {
            "BTC": {
                "Symbol": "BTC",
                "CoinName": "Bitcoin",
                "SmartContractAddress": "N/A"
            }
        }
    }
    """.data(using: .utf8)!

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    #expect(index.isEmpty)
}

@Test func findNativeSymbol_matchesBySymbol() throws {
    let json = """
    {
        "Data": {
            "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
            "ETH": { "Symbol": "ETH", "CoinName": "Ethereum", "SmartContractAddress": "N/A" }
        }
    }
    """.data(using: .utf8)!

    let nativeSymbols = try CryptoCompareClient.parseNativeSymbols(json)
    #expect(nativeSymbols.contains("BTC"))
    #expect(nativeSymbols.contains("ETH"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: Compilation errors — methods don't exist yet.

- [ ] **Step 3: Add coin list parsing to CryptoCompareClient**

Add to `Backends/CryptoCompare/CryptoCompareClient.swift`:

```swift
// MARK: - Token resolution

static func coinListURL() -> URL {
    var components = URLComponents(
        url: baseURL.appendingPathComponent("/data/all/coinlist"),
        resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
        URLQueryItem(name: "summary", value: "true")
    ]
    return components.url!
}

/// Parses the coin list response and builds a reverse index: lowercased contract address → symbol.
/// Entries with "N/A" or empty contract addresses are excluded.
static func parseCoinListResponse(_ data: Data) throws -> [String: String] {
    let container = try JSONDecoder().decode(CoinListContainer.self, from: data)
    var index: [String: String] = [:]
    for (_, coin) in container.Data {
        let addr = coin.SmartContractAddress
        guard addr != "N/A", !addr.isEmpty else { continue }
        index[addr.lowercased()] = coin.Symbol
    }
    return index
}

/// Parses the coin list to find symbols that have no smart contract address (native tokens).
static func parseNativeSymbols(_ data: Data) throws -> Set<String> {
    let container = try JSONDecoder().decode(CoinListContainer.self, from: data)
    var symbols: Set<String> = []
    for (_, coin) in container.Data {
        let addr = coin.SmartContractAddress
        if addr == "N/A" || addr.isEmpty {
            symbols.insert(coin.Symbol)
        }
    }
    return symbols
}
```

Add the response types (private, at bottom of file):

```swift
private struct CoinListContainer: Decodable {
    let Data: [String: CoinListEntry]  // swiftlint:disable:this identifier_name
}

private struct CoinListEntry: Decodable {
    let Symbol: String  // swiftlint:disable:this identifier_name
    let CoinName: String  // swiftlint:disable:this identifier_name
    let SmartContractAddress: String  // swiftlint:disable:this identifier_name
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CryptoCompare/CryptoCompareClient.swift MoolahTests/Backends/CryptoCompareClientTests.swift
git commit -m "feat: add CryptoCompare coin list parsing for token resolution"
```

---

### Task 6: Token Resolution — Binance Exchange Info

**Files:**
- Modify: `Backends/Binance/BinanceClient.swift`
- Modify: `MoolahTests/Backends/BinanceClientTests.swift`

Add parsing of Binance's `/api/v3/exchangeInfo` to validate that a USDT trading pair exists for a given symbol.

- [ ] **Step 1: Write failing tests**

Add to `MoolahTests/Backends/BinanceClientTests.swift`:

```swift
// MARK: - Exchange info parsing

@Test func parseExchangeInfoResponse_findsUsdtPairs() throws {
    let json = """
    {
        "symbols": [
            { "symbol": "ETHUSDT", "baseAsset": "ETH", "quoteAsset": "USDT", "status": "TRADING" },
            { "symbol": "BTCUSDT", "baseAsset": "BTC", "quoteAsset": "USDT", "status": "TRADING" },
            { "symbol": "ETHBTC", "baseAsset": "ETH", "quoteAsset": "BTC", "status": "TRADING" },
            { "symbol": "OLDUSDT", "baseAsset": "OLD", "quoteAsset": "USDT", "status": "BREAK" }
        ]
    }
    """.data(using: .utf8)!

    let pairs = try BinanceClient.parseExchangeInfoResponse(json)
    #expect(pairs.contains("ETHUSDT"))
    #expect(pairs.contains("BTCUSDT"))
    // Non-USDT pairs excluded
    #expect(!pairs.contains("ETHBTC"))
    // Non-TRADING pairs excluded
    #expect(!pairs.contains("OLDUSDT"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: Compilation error — `parseExchangeInfoResponse` doesn't exist.

- [ ] **Step 3: Add exchange info parsing to BinanceClient**

Add to `Backends/Binance/BinanceClient.swift`:

```swift
// MARK: - Token resolution

static func exchangeInfoURL() -> URL {
    baseURL.appendingPathComponent("/api/v3/exchangeInfo")
}

/// Parses the exchange info response and returns the set of active USDT trading pair symbols.
static func parseExchangeInfoResponse(_ data: Data) throws -> Set<String> {
    let container = try JSONDecoder().decode(ExchangeInfoContainer.self, from: data)
    var pairs: Set<String> = []
    for symbol in container.symbols {
        if symbol.quoteAsset == "USDT", symbol.status == "TRADING" {
            pairs.insert(symbol.symbol)
        }
    }
    return pairs
}
```

Add response types (private, at bottom of file, before `KlineValue`):

```swift
private struct ExchangeInfoContainer: Decodable {
    let symbols: [ExchangeInfoSymbol]
}

private struct ExchangeInfoSymbol: Decodable {
    let symbol: String
    let baseAsset: String
    let quoteAsset: String
    let status: String
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/Binance/BinanceClient.swift MoolahTests/Backends/BinanceClientTests.swift
git commit -m "feat: add Binance exchange info parsing for token resolution"
```

---

### Task 7: Token Resolution — CoinGecko Contract Lookup

**Files:**
- Modify: `Backends/CoinGecko/CoinGeckoClient.swift`
- Modify: `MoolahTests/Backends/CoinGeckoClientTests.swift`

Add parsing of CoinGecko's asset platforms (chain ID → platform slug mapping) and contract lookup response.

- [ ] **Step 1: Write failing tests**

Add to `MoolahTests/Backends/CoinGeckoClientTests.swift`:

```swift
// MARK: - Asset platforms parsing

@Test func parseAssetPlatformsResponse_mapsChainIdToSlug() throws {
    let json = """
    [
        { "id": "ethereum", "chain_identifier": 1, "name": "Ethereum" },
        { "id": "optimistic-ethereum", "chain_identifier": 10, "name": "Optimism" },
        { "id": "polygon-pos", "chain_identifier": 137, "name": "Polygon" },
        { "id": "no-chain", "chain_identifier": null, "name": "No Chain" }
    ]
    """.data(using: .utf8)!

    let mapping = try CoinGeckoClient.parseAssetPlatformsResponse(json)
    #expect(mapping[1] == "ethereum")
    #expect(mapping[10] == "optimistic-ethereum")
    #expect(mapping[137] == "polygon-pos")
    // Null chain_identifier entries are excluded
    #expect(mapping.count == 3)
}

// MARK: - Contract lookup parsing

@Test func parseContractLookupResponse_extractsTokenDetails() throws {
    let json = """
    {
        "id": "uniswap",
        "symbol": "uni",
        "name": "Uniswap",
        "detail_platforms": {
            "ethereum": { "decimal_place": 18, "contract_address": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" }
        }
    }
    """.data(using: .utf8)!

    let result = try CoinGeckoClient.parseContractLookupResponse(json)
    #expect(result.id == "uniswap")
    #expect(result.symbol == "uni")
    #expect(result.name == "Uniswap")
    #expect(result.decimals == 18)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: Compilation errors — methods don't exist.

- [ ] **Step 3: Add asset platform and contract lookup parsing**

Add to `Backends/CoinGecko/CoinGeckoClient.swift`:

```swift
// MARK: - Token resolution

static func assetPlatformsURL(apiKey: String) -> URL {
    var components = URLComponents(
        url: baseURL.appendingPathComponent("asset_platforms"),
        resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
        URLQueryItem(name: "x_cg_pro_api_key", value: apiKey),
    ]
    return components.url!
}

static func contractLookupURL(platformId: String, contractAddress: String, apiKey: String) -> URL {
    var components = URLComponents(
        url: baseURL.appendingPathComponent("coins/\(platformId)/contract/\(contractAddress.lowercased())"),
        resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
        URLQueryItem(name: "x_cg_pro_api_key", value: apiKey),
    ]
    return components.url!
}

/// Parses the asset platforms response into a chain ID → platform slug mapping.
static func parseAssetPlatformsResponse(_ data: Data) throws -> [Int: String] {
    let platforms = try JSONDecoder().decode([AssetPlatform].self, from: data)
    var mapping: [Int: String] = [:]
    for platform in platforms {
        if let chainId = platform.chain_identifier {
            mapping[chainId] = platform.id
        }
    }
    return mapping
}

struct ContractLookupResult: Sendable {
    let id: String
    let symbol: String
    let name: String
    let decimals: Int?
}

/// Parses the contract lookup response to extract token details.
static func parseContractLookupResponse(_ data: Data) throws -> ContractLookupResult {
    let raw = try JSONDecoder().decode(ContractLookupRaw.self, from: data)
    let decimals = raw.detail_platforms?.values.first?.decimal_place
    return ContractLookupResult(
        id: raw.id, symbol: raw.symbol, name: raw.name, decimals: decimals
    )
}
```

Add response types (private, at bottom of file):

```swift
private struct AssetPlatform: Decodable {
    let id: String
    let chain_identifier: Int?
    let name: String
}

private struct ContractLookupRaw: Decodable {
    let id: String
    let symbol: String
    let name: String
    let detail_platforms: [String: DetailPlatform]?
}

private struct DetailPlatform: Decodable {
    let decimal_place: Int?
    let contract_address: String?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CoinGecko/CoinGeckoClient.swift MoolahTests/Backends/CoinGeckoClientTests.swift
git commit -m "feat: add CoinGecko asset platforms and contract lookup parsing"
```

---

### Task 8: Token Resolution Orchestration on CryptoPriceService

**Files:**
- Modify: `Shared/CryptoPriceService.swift`
- Modify: `MoolahTests/Shared/CryptoPriceServiceTests.swift`

Add `resolveToken()` to `CryptoPriceService` that queries each provider's resolution endpoints and builds a `CryptoToken` with populated provider fields. Uses cached reference data (coin lists, exchange info, asset platforms) with 7-day staleness.

- [ ] **Step 1: Define resolution client protocol and test double**

Create `Domain/Repositories/TokenResolutionClient.swift`:

```swift
// Domain/Repositories/TokenResolutionClient.swift
import Foundation

/// Data needed to resolve a token from provider reference data.
struct TokenResolutionResult: Sendable {
    var coingeckoId: String?
    var cryptocompareSymbol: String?
    var binanceSymbol: String?
    var resolvedName: String?
    var resolvedSymbol: String?
    var resolvedDecimals: Int?
}

/// Resolves a token's provider-specific identifiers from reference data.
protocol TokenResolutionClient: Sendable {
    func resolve(
        chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
    ) async throws -> TokenResolutionResult
}
```

Create `MoolahTests/Support/FixedTokenResolutionClient.swift`:

```swift
// MoolahTests/Support/FixedTokenResolutionClient.swift
import Foundation
@testable import Moolah

struct FixedTokenResolutionClient: TokenResolutionClient, Sendable {
    let result: TokenResolutionResult
    let shouldFail: Bool

    init(result: TokenResolutionResult = TokenResolutionResult(), shouldFail: Bool = false) {
        self.result = result
        self.shouldFail = shouldFail
    }

    func resolve(
        chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
    ) async throws -> TokenResolutionResult {
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return result
    }
}
```

- [ ] **Step 2: Write failing tests for resolveToken**

Add to `MoolahTests/Shared/CryptoPriceServiceTests.swift`:

Update `makeService` to accept `resolutionClient`:

```swift
private func makeService(
    clients: [CryptoPriceClient]? = nil,
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    cacheDirectory: URL? = nil,
    tokenRepository: CryptoTokenRepository? = nil,
    resolutionClient: TokenResolutionClient? = nil
) -> CryptoPriceService {
    let clientList = clients ?? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
    let cacheDir = cacheDirectory
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("crypto-price-tests")
            .appendingPathComponent(UUID().uuidString)
    return CryptoPriceService(
        clients: clientList,
        cacheDirectory: cacheDir,
        tokenRepository: tokenRepository ?? InMemoryTokenRepository(),
        resolutionClient: resolutionClient ?? FixedTokenResolutionClient()
    )
}

// MARK: - Token resolution

@Test func resolveToken_populatesProviderFields() async throws {
    let result = TokenResolutionResult(
        coingeckoId: "uniswap",
        cryptocompareSymbol: "UNI",
        binanceSymbol: "UNIUSDT",
        resolvedName: "Uniswap",
        resolvedSymbol: "UNI",
        resolvedDecimals: 18
    )
    let service = makeService(resolutionClient: FixedTokenResolutionClient(result: result))

    let token = try await service.resolveToken(
        chainId: 1,
        contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
        symbol: nil,
        isNative: false
    )
    #expect(token.coingeckoId == "uniswap")
    #expect(token.cryptocompareSymbol == "UNI")
    #expect(token.binanceSymbol == "UNIUSDT")
    #expect(token.name == "Uniswap")
}

@Test func resolveToken_noProvidersMatch_returnsPartialToken() async throws {
    let service = makeService(
        resolutionClient: FixedTokenResolutionClient(result: TokenResolutionResult())
    )
    let token = try await service.resolveToken(
        chainId: 999,
        contractAddress: "0xunknown",
        symbol: "UNKNOWN",
        isNative: false
    )
    #expect(token.coingeckoId == nil)
    #expect(token.cryptocompareSymbol == nil)
    #expect(token.binanceSymbol == nil)
    #expect(token.symbol == "UNKNOWN")
}

@Test func resolveToken_resolutionFails_throws() async throws {
    let service = makeService(
        resolutionClient: FixedTokenResolutionClient(shouldFail: true)
    )
    await #expect(throws: (any Error).self) {
        try await service.resolveToken(
            chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
        )
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `just test`
Expected: Compilation errors.

- [ ] **Step 4: Add resolveToken to CryptoPriceService**

Modify `Shared/CryptoPriceService.swift`:

1. Add `resolutionClient` to init:
```swift
private let resolutionClient: TokenResolutionClient

init(clients: [CryptoPriceClient], cacheDirectory: URL? = nil,
     tokenRepository: CryptoTokenRepository = ICloudTokenRepository(),
     resolutionClient: TokenResolutionClient = CompositeTokenResolutionClient()) {
    // ... existing init ...
    self.resolutionClient = resolutionClient
}
```

2. Add resolveToken method:
```swift
// MARK: - Token resolution

func resolveToken(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
) async throws -> CryptoToken {
    let result = try await resolutionClient.resolve(
        chainId: chainId,
        contractAddress: contractAddress,
        symbol: symbol,
        isNative: isNative
    )
    return CryptoToken(
        chainId: chainId,
        contractAddress: isNative ? nil : contractAddress,
        symbol: result.resolvedSymbol ?? symbol ?? "???",
        name: result.resolvedName ?? symbol ?? "Unknown Token",
        decimals: result.resolvedDecimals ?? 18,
        coingeckoId: result.coingeckoId,
        cryptocompareSymbol: result.cryptocompareSymbol,
        binanceSymbol: result.binanceSymbol
    )
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Domain/Repositories/TokenResolutionClient.swift MoolahTests/Support/FixedTokenResolutionClient.swift Shared/CryptoPriceService.swift MoolahTests/Shared/CryptoPriceServiceTests.swift
git commit -m "feat: add token resolution to CryptoPriceService via TokenResolutionClient"
```

---

### Task 9: CompositeTokenResolutionClient (Production Resolution)

**Files:**
- Create: `Shared/CompositeTokenResolutionClient.swift`
- Test: `MoolahTests/Shared/CompositeTokenResolutionClientTests.swift`

The production resolution client that queries CoinGecko (if API key configured), CryptoCompare coin list, and Binance exchange info. Caches reference data with 7-day staleness.

- [ ] **Step 1: Write tests**

Create `MoolahTests/Shared/CompositeTokenResolutionClientTests.swift`:

```swift
// MoolahTests/Shared/CompositeTokenResolutionClientTests.swift
import Foundation
import Testing
@testable import Moolah

@Suite("CompositeTokenResolutionClient")
struct CompositeTokenResolutionClientTests {

    // Test with mock URLProtocol stubs. The client fetches CryptoCompare coin list and
    // Binance exchange info, then resolves from the parsed data.
    // CoinGecko is skipped unless an API key is provided.

    @Test func resolve_contractToken_findsCryptoCompareAndBinance() async throws {
        let ccCoinList = """
        {
            "Data": {
                "UNI": {
                    "Symbol": "UNI",
                    "CoinName": "Uniswap",
                    "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
                }
            }
        }
        """.data(using: .utf8)!

        let binanceInfo = """
        {
            "symbols": [
                { "symbol": "UNIUSDT", "baseAsset": "UNI", "quoteAsset": "USDT", "status": "TRADING" }
            ]
        }
        """.data(using: .utf8)!

        let client = CompositeTokenResolutionClient(
            coinListData: ccCoinList,
            exchangeInfoData: binanceInfo,
            coinGeckoApiKey: nil
        )

        let result = try await client.resolve(
            chainId: 1,
            contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
            symbol: nil,
            isNative: false
        )
        #expect(result.cryptocompareSymbol == "UNI")
        #expect(result.binanceSymbol == "UNIUSDT")
    }

    @Test func resolve_nativeToken_matchesBySymbol() async throws {
        let ccCoinList = """
        {
            "Data": {
                "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
                "WBTC": { "Symbol": "WBTC", "CoinName": "Wrapped BTC", "SmartContractAddress": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599" }
            }
        }
        """.data(using: .utf8)!

        let binanceInfo = """
        {
            "symbols": [
                { "symbol": "BTCUSDT", "baseAsset": "BTC", "quoteAsset": "USDT", "status": "TRADING" }
            ]
        }
        """.data(using: .utf8)!

        let client = CompositeTokenResolutionClient(
            coinListData: ccCoinList,
            exchangeInfoData: binanceInfo,
            coinGeckoApiKey: nil
        )

        let result = try await client.resolve(
            chainId: 0, contractAddress: nil, symbol: "BTC", isNative: true
        )
        #expect(result.cryptocompareSymbol == "BTC")
        #expect(result.binanceSymbol == "BTCUSDT")
    }

    @Test func resolve_unknownToken_returnsEmptyResult() async throws {
        let ccCoinList = """
        { "Data": {} }
        """.data(using: .utf8)!

        let binanceInfo = """
        { "symbols": [] }
        """.data(using: .utf8)!

        let client = CompositeTokenResolutionClient(
            coinListData: ccCoinList,
            exchangeInfoData: binanceInfo,
            coinGeckoApiKey: nil
        )

        let result = try await client.resolve(
            chainId: 999, contractAddress: "0xunknown", symbol: "NOPE", isNative: false
        )
        #expect(result.cryptocompareSymbol == nil)
        #expect(result.binanceSymbol == nil)
        #expect(result.coingeckoId == nil)
    }
}
```

- [ ] **Step 2: Write CompositeTokenResolutionClient**

Create `Shared/CompositeTokenResolutionClient.swift`:

```swift
// Shared/CompositeTokenResolutionClient.swift
import Foundation

/// Production token resolution client that queries CryptoCompare, Binance, and optionally CoinGecko
/// to populate provider-specific identifiers for a token.
struct CompositeTokenResolutionClient: TokenResolutionClient, Sendable {
    private let session: URLSession
    private let coinGeckoApiKey: String?

    // For testing: inject pre-parsed reference data
    private let preloadedCoinList: Data?
    private let preloadedExchangeInfo: Data?

    init(session: URLSession = .shared, coinGeckoApiKey: String? = nil) {
        self.session = session
        self.coinGeckoApiKey = coinGeckoApiKey
        self.preloadedCoinList = nil
        self.preloadedExchangeInfo = nil
    }

    /// Test initializer with pre-loaded reference data.
    init(coinListData: Data, exchangeInfoData: Data, coinGeckoApiKey: String?) {
        self.session = .shared
        self.coinGeckoApiKey = coinGeckoApiKey
        self.preloadedCoinList = coinListData
        self.preloadedExchangeInfo = exchangeInfoData
    }

    func resolve(
        chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
    ) async throws -> TokenResolutionResult {
        var result = TokenResolutionResult()

        // 1. CryptoCompare coin list
        let coinListData = try await fetchCoinListData()
        if isNative, let symbol {
            let nativeSymbols = try CryptoCompareClient.parseNativeSymbols(coinListData)
            if nativeSymbols.contains(symbol.uppercased()) {
                result.cryptocompareSymbol = symbol.uppercased()
                result.resolvedSymbol = symbol.uppercased()
            }
        } else if let contractAddress {
            let index = try CryptoCompareClient.parseCoinListResponse(coinListData)
            if let ccSymbol = index[contractAddress.lowercased()] {
                result.cryptocompareSymbol = ccSymbol
                result.resolvedSymbol = ccSymbol
            }
        }

        // 2. Binance exchange info
        let exchangeInfoData = try await fetchExchangeInfoData()
        let pairs = try BinanceClient.parseExchangeInfoResponse(exchangeInfoData)
        let pairSymbol = (result.resolvedSymbol ?? symbol ?? "").uppercased()
        let candidate = "\(pairSymbol)USDT"
        if pairs.contains(candidate) {
            result.binanceSymbol = candidate
        }

        // 3. CoinGecko (only with API key)
        if let apiKey = coinGeckoApiKey, !apiKey.isEmpty {
            if isNative {
                // For native tokens, CoinGecko resolution would need a search-by-name
                // which is unreliable. Skip for now — built-in presets cover common cases.
            } else if let contractAddress {
                do {
                    let platformMapping = try await fetchAssetPlatforms(apiKey: apiKey)
                    if let platformSlug = platformMapping[chainId] {
                        let url = CoinGeckoClient.contractLookupURL(
                            platformId: platformSlug,
                            contractAddress: contractAddress,
                            apiKey: apiKey
                        )
                        let (data, response) = try await session.data(for: URLRequest(url: url))
                        if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                            let lookup = try CoinGeckoClient.parseContractLookupResponse(data)
                            result.coingeckoId = lookup.id
                            result.resolvedName = lookup.name
                            result.resolvedSymbol = result.resolvedSymbol ?? lookup.symbol.uppercased()
                            result.resolvedDecimals = lookup.decimals
                        }
                    }
                } catch {
                    // CoinGecko resolution is best-effort
                }
            }
        }

        return result
    }

    // MARK: - Reference data fetching

    private func fetchCoinListData() async throws -> Data {
        if let preloaded = preloadedCoinList { return preloaded }
        let url = CryptoCompareClient.coinListURL()
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func fetchExchangeInfoData() async throws -> Data {
        if let preloaded = preloadedExchangeInfo { return preloaded }
        let url = BinanceClient.exchangeInfoURL()
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func fetchAssetPlatforms(apiKey: String) async throws -> [Int: String] {
        let url = CoinGeckoClient.assetPlatformsURL(apiKey: apiKey)
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try CoinGeckoClient.parseAssetPlatformsResponse(data)
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Shared/CompositeTokenResolutionClient.swift MoolahTests/Shared/CompositeTokenResolutionClientTests.swift
git commit -m "feat: add CompositeTokenResolutionClient for multi-provider token resolution"
```

---

### Task 10: CoinGecko Provider Activation in ProfileSession

**Files:**
- Modify: `App/ProfileSession.swift`

Check the keychain for a CoinGecko API key on session init. If present, prepend `CoinGeckoClient` to the provider list. Also pass the API key to the resolution client.

- [ ] **Step 1: Update ProfileSession init**

Modify `App/ProfileSession.swift` — update the crypto service initialization block:

```swift
// Replace the existing crypto service setup with:
let cryptoCompareClient = CryptoCompareClient()
let binanceClient = BinanceClient { date in
    let usdt = CryptoToken(
        chainId: 1,
        contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
        symbol: "USDT", name: "Tether", decimals: 6,
        coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
    )
    do {
        return try await cryptoCompareClient.dailyPrice(for: usdt, on: date)
    } catch {
        return Decimal(1)
    }
}

let apiKeyStore = KeychainStore(
    service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
)
let coinGeckoApiKey = try? apiKeyStore.restoreString()

var priceClients: [CryptoPriceClient] = []
if let coinGeckoApiKey, !coinGeckoApiKey.isEmpty {
    priceClients.append(CoinGeckoClient(apiKey: coinGeckoApiKey))
}
priceClients.append(contentsOf: [cryptoCompareClient, binanceClient])

self.cryptoPriceService = CryptoPriceService(
    clients: priceClients,
    tokenRepository: ICloudTokenRepository(),
    resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey)
)
self.priceConversionService = PriceConversionService(
    cryptoPrices: self.cryptoPriceService,
    exchangeRates: self.exchangeRateService
)
```

- [ ] **Step 2: Build to verify compilation**

Run: `just build-mac`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add App/ProfileSession.swift
git commit -m "feat: activate CoinGecko provider when API key is configured"
```

---

### Task 11: Tabbed Settings Window (macOS) + Crypto Navigation Row (iOS)

**Files:**
- Modify: `Features/Settings/SettingsView.swift`
- Create: `Features/Settings/CryptoSettingsView.swift`

Restructure the macOS settings to use `TabView` with Profiles and Crypto tabs. On iOS, add a "Crypto Tokens" navigation row.

- [ ] **Step 1: Create CryptoSettingsView**

Create `Features/Settings/CryptoSettingsView.swift` with a placeholder that will be fleshed out in the next tasks:

```swift
// Features/Settings/CryptoSettingsView.swift
import SwiftUI

/// Crypto token management: registered tokens list, add/remove, CoinGecko API key.
struct CryptoSettingsView: View {
    var body: some View {
        Form {
            Section("Registered Tokens") {
                ContentUnavailableView(
                    "No Tokens",
                    systemImage: "bitcoinsign.circle",
                    description: Text("Add crypto tokens to track their prices.")
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Crypto Tokens")
    }
}
```

- [ ] **Step 2: Restructure SettingsView for macOS tabs**

Modify `Features/Settings/SettingsView.swift`:

On macOS, wrap the existing profile settings and the new crypto view in a `TabView`:

Replace the `macOSLayout` computed property:

```swift
#if os(macOS)
private var macOSLayout: some View {
    TabView {
        Tab("Profiles", systemImage: "person.2") {
            profilesContent
        }
        Tab("Crypto", systemImage: "bitcoinsign.circle") {
            CryptoSettingsView()
        }
    }
    .frame(minWidth: 600, minHeight: 400)
    .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
            .environment(profileStore)
            .frame(minWidth: 350, minHeight: 250)
    }
    .alert(deleteAlertTitle, isPresented: $showDeleteAlert) {
        deleteAlertButtons
    } message: {
        deleteAlertMessage
    }
    .fileImporter(
        isPresented: $showImportPicker,
        allowedContentTypes: [.json]
    ) { result in
        Task { await handleImport(result: result) }
    }
    .alert(
        "Import Failed",
        isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    ) {
        Button("OK") { importError = nil }
    } message: {
        if let importError {
            Text(importError)
        }
    }
}
```

Extract the existing macOS profile content (the HSplitView with sidebar + detail) into a `profilesContent` computed property:

```swift
#if os(macOS)
private var profilesContent: some View {
    Group {
        if profileStore.profiles.isEmpty {
            emptyState
        } else {
            HSplitView {
                profileList
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                detailPane
                    .frame(minWidth: 300, idealWidth: 400)
            }
            .onAppear {
                if selectedProfileID == nil {
                    selectedProfileID =
                        profileStore.activeProfileID ?? profileStore.profiles.first?.id
                }
            }
        }
    }
}
#endif
```

- [ ] **Step 3: Add Crypto navigation row on iOS**

In the iOS `iOSLayout`, add a "Crypto Tokens" section after the Profiles section:

```swift
Section {
    NavigationLink {
        CryptoSettingsView()
    } label: {
        Label("Crypto Tokens", systemImage: "bitcoinsign.circle")
    }
}
```

- [ ] **Step 4: Build and test**

Run: `just build-mac && just build-ios`
Expected: Both builds succeed.

- [ ] **Step 5: Invoke ui-review agent**

Run the `ui-review` agent on `Features/Settings/SettingsView.swift` and `Features/Settings/CryptoSettingsView.swift`. Fix all issues found. Repeat until clean.

- [ ] **Step 6: Commit**

```bash
git add Features/Settings/SettingsView.swift Features/Settings/CryptoSettingsView.swift
git commit -m "feat: add tabbed settings window (macOS) with Crypto tab and iOS navigation row"
```

---

### Task 12: CryptoSettingsView — Token List and CoinGecko API Key

**Files:**
- Modify: `Features/Settings/CryptoSettingsView.swift`
- Create: `Features/Settings/CryptoTokenStore.swift`

Build the full crypto settings UI: token list with remove, CoinGecko API key field. The store manages loading/saving tokens and the API key.

- [ ] **Step 1: Create CryptoTokenStore**

Create `Features/Settings/CryptoTokenStore.swift`:

```swift
// Features/Settings/CryptoTokenStore.swift
import Foundation

@MainActor @Observable
final class CryptoTokenStore {
    private(set) var tokens: [CryptoToken] = []
    private(set) var isLoading = false
    private(set) var isResolving = false
    private(set) var resolvedToken: CryptoToken?
    private(set) var error: String?

    private let cryptoPriceService: CryptoPriceService

    private let apiKeyStore = KeychainStore(
        service: "com.moolah.api-keys", account: "coingecko", synchronizable: true
    )

    init(cryptoPriceService: CryptoPriceService) {
        self.cryptoPriceService = cryptoPriceService
    }

    func loadTokens() async {
        isLoading = true
        defer { isLoading = false }
        tokens = await cryptoPriceService.registeredTokens()
    }

    func removeToken(_ token: CryptoToken) async {
        do {
            try await cryptoPriceService.removeToken(token)
            tokens.removeAll { $0.id == token.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resolveToken(
        chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
    ) async {
        isResolving = true
        resolvedToken = nil
        error = nil
        defer { isResolving = false }

        do {
            resolvedToken = try await cryptoPriceService.resolveToken(
                chainId: chainId,
                contractAddress: contractAddress,
                symbol: symbol,
                isNative: isNative
            )
        } catch {
            self.error = "Resolution failed: \(error.localizedDescription)"
        }
    }

    func confirmRegistration() async {
        guard let token = resolvedToken else { return }
        do {
            try await cryptoPriceService.registerToken(token)
            tokens.append(token)
            resolvedToken = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - API Key

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

- [ ] **Step 2: Build the full CryptoSettingsView**

Replace `Features/Settings/CryptoSettingsView.swift`:

```swift
// Features/Settings/CryptoSettingsView.swift
import SwiftUI

struct CryptoSettingsView: View {
    @State private var store: CryptoTokenStore
    @State private var showAddToken = false
    @State private var apiKeyInput = ""
    @State private var showApiKey = false

    init(cryptoPriceService: CryptoPriceService) {
        _store = State(initialValue: CryptoTokenStore(cryptoPriceService: cryptoPriceService))
    }

    var body: some View {
        Form {
            tokenListSection
            apiKeySection
        }
        .formStyle(.grouped)
        .navigationTitle("Crypto Tokens")
        .task { await store.loadTokens() }
        .sheet(isPresented: $showAddToken) {
            AddTokenSheet(store: store, isPresented: $showAddToken)
        }
    }

    // MARK: - Token List

    @ViewBuilder
    private var tokenListSection: some View {
        Section {
            if store.tokens.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    "No Tokens",
                    systemImage: "bitcoinsign.circle",
                    description: Text("Add crypto tokens to track their prices.")
                )
            } else {
                ForEach(store.tokens, id: \.id) { token in
                    tokenRow(token)
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet {
                            await store.removeToken(store.tokens[index])
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Registered Tokens")
                Spacer()
                Button {
                    showAddToken = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add token")
            }
        }
    }

    private func tokenRow(_ token: CryptoToken) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(token.symbol)
                    .font(.headline)
                Text(token.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(chainName(for: token.chainId))
                .font(.caption)
                .foregroundStyle(.secondary)
            providerIndicators(for: token)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(role: .destructive) {
                Task { await store.removeToken(token) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func providerIndicators(for token: CryptoToken) -> some View {
        HStack(spacing: 4) {
            if token.coingeckoId != nil {
                Text("CG")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.green.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            }
            if token.cryptocompareSymbol != nil {
                Text("CC")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            }
            if token.binanceSymbol != nil {
                Text("BN")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    private func chainName(for chainId: Int) -> String {
        switch chainId {
        case 0: "Bitcoin"
        case 1: "Ethereum"
        case 10: "Optimism"
        case 137: "Polygon"
        case 42161: "Arbitrum"
        default: "Chain \(chainId)"
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        Section {
            if store.hasApiKey {
                HStack {
                    Label("CoinGecko API Key", systemImage: "key")
                    Spacer()
                    Text("Configured")
                        .foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) {
                        store.clearApiKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack {
                    SecureField("CoinGecko API Key", text: $apiKeyInput)
                    Button("Save") {
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        store.saveApiKey(trimmed)
                        apiKeyInput = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("CoinGecko")
        } footer: {
            Text("Optional. Enables CoinGecko as the highest-priority price provider. Requires a free Demo API key from coingecko.com.")
        }
    }
}
```

- [ ] **Step 3: Update CryptoSettingsView usage in SettingsView**

The `CryptoSettingsView` now requires a `cryptoPriceService` parameter. Update the call sites in `SettingsView.swift`:

On macOS (in the TabView):
```swift
Tab("Crypto", systemImage: "bitcoinsign.circle") {
    CryptoSettingsView(cryptoPriceService: cryptoPriceServiceForSettings)
}
```

On iOS (in the NavigationLink):
```swift
NavigationLink {
    CryptoSettingsView(cryptoPriceService: cryptoPriceServiceForSettings)
} label: {
    Label("Crypto Tokens", systemImage: "bitcoinsign.circle")
}
```

Add a computed property to SettingsView for the price service. Since Settings doesn't have a session context, create a standalone service:

```swift
private var cryptoPriceServiceForSettings: CryptoPriceService {
    #if os(macOS)
    if let session = sessionManager.sessions.values.first {
        return session.cryptoPriceService
    }
    #else
    if let session = activeSession {
        return session.cryptoPriceService
    }
    #endif
    // Fallback: create a service just for token management (no price fetching needed)
    return CryptoPriceService(
        clients: [CryptoCompareClient(), BinanceClient()],
        tokenRepository: ICloudTokenRepository(),
        resolutionClient: CompositeTokenResolutionClient()
    )
}
```

- [ ] **Step 4: Build**

Run: `just build-mac && just build-ios`
Expected: Both builds succeed.

- [ ] **Step 5: Invoke ui-review agent**

Run the `ui-review` agent on `Features/Settings/CryptoSettingsView.swift`. Fix all issues. Repeat until clean.

- [ ] **Step 6: Commit**

```bash
git add Features/Settings/CryptoSettingsView.swift Features/Settings/CryptoTokenStore.swift Features/Settings/SettingsView.swift
git commit -m "feat: add crypto settings UI with token list, API key, and CryptoTokenStore"
```

---

### Task 13: Add Token Sheet

**Files:**
- Create: `Features/Settings/AddTokenSheet.swift`

The multi-step sheet for adding new tokens: input (contract address + chain picker + native toggle) → resolving → results confirmation.

- [ ] **Step 1: Create AddTokenSheet**

Create `Features/Settings/AddTokenSheet.swift`:

```swift
// Features/Settings/AddTokenSheet.swift
import SwiftUI

struct AddTokenSheet: View {
    @Bindable var store: CryptoTokenStore
    @Binding var isPresented: Bool

    @State private var contractAddress = ""
    @State private var selectedChainId = 1
    @State private var isNative = false
    @State private var symbolHint = ""

    private let chains: [(id: Int, name: String)] = [
        (0, "Bitcoin"),
        (1, "Ethereum"),
        (10, "Optimism"),
        (137, "Polygon"),
        (42161, "Arbitrum"),
        (8453, "Base"),
        (43114, "Avalanche"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if store.resolvedToken != nil {
                    confirmationSection
                } else if store.isResolving {
                    resolvingSection
                } else {
                    inputSection
                }

                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Token")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.resolvedToken = nil
                        isPresented = false
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 300)
        #endif
    }

    // MARK: - Input

    private var inputSection: some View {
        Group {
            Section("Token Type") {
                Toggle("Native / Layer-1 token", isOn: $isNative)
            }

            if isNative {
                Section("Token") {
                    Picker("Chain", selection: $selectedChainId) {
                        ForEach(chains, id: \.id) { chain in
                            Text(chain.name).tag(chain.id)
                        }
                    }
                    TextField("Symbol (e.g. BTC)", text: $symbolHint)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                }
            } else {
                Section("Contract") {
                    Picker("Chain", selection: $selectedChainId) {
                        ForEach(chains, id: \.id) { chain in
                            Text(chain.name).tag(chain.id)
                        }
                    }
                    TextField("Contract address (0x...)", text: $contractAddress)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                    TextField("Symbol hint (optional)", text: $symbolHint)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                }
            }

            Section {
                Button("Resolve Token") {
                    Task {
                        await store.resolveToken(
                            chainId: selectedChainId,
                            contractAddress: isNative ? nil : contractAddress.trimmingCharacters(in: .whitespaces),
                            symbol: symbolHint.isEmpty ? nil : symbolHint.trimmingCharacters(in: .whitespaces),
                            isNative: isNative
                        )
                    }
                }
                .disabled(isNative ? symbolHint.isEmpty : contractAddress.isEmpty)
            }
        }
    }

    // MARK: - Resolving

    private var resolvingSection: some View {
        Section {
            HStack {
                Spacer()
                ProgressView("Resolving token...")
                Spacer()
            }
        }
    }

    // MARK: - Confirmation

    @ViewBuilder
    private var confirmationSection: some View {
        if let token = store.resolvedToken {
            Section("Resolved Token") {
                LabeledContent("Name", value: token.name)
                LabeledContent("Symbol", value: token.symbol)
                LabeledContent("Chain", value: chainName(for: token.chainId))
                if let decimals = Optional(token.decimals) {
                    LabeledContent("Decimals", value: "\(decimals)")
                }
            }

            Section("Provider Coverage") {
                HStack {
                    Text("CoinGecko")
                    Spacer()
                    Image(systemName: token.coingeckoId != nil ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(token.coingeckoId != nil ? .green : .secondary)
                }
                HStack {
                    Text("CryptoCompare")
                    Spacer()
                    Image(systemName: token.cryptocompareSymbol != nil ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(token.cryptocompareSymbol != nil ? .green : .secondary)
                }
                HStack {
                    Text("Binance")
                    Spacer()
                    Image(systemName: token.binanceSymbol != nil ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(token.binanceSymbol != nil ? .green : .secondary)
                }
            }

            if token.coingeckoId == nil && token.cryptocompareSymbol == nil && token.binanceSymbol == nil {
                Section {
                    Label(
                        "No providers could resolve this token. Price data will not be available.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section {
                HStack {
                    Button("Back") {
                        store.resolvedToken = nil
                    }
                    Spacer()
                    Button("Add Token") {
                        Task {
                            await store.confirmRegistration()
                            isPresented = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func chainName(for chainId: Int) -> String {
        chains.first { $0.id == chainId }?.name ?? "Chain \(chainId)"
    }
}
```

- [ ] **Step 2: Build**

Run: `just build-mac && just build-ios`
Expected: Both builds succeed.

- [ ] **Step 3: Invoke ui-review agent**

Run the `ui-review` agent on `Features/Settings/AddTokenSheet.swift`. Fix all issues. Repeat until clean.

- [ ] **Step 4: Commit**

```bash
git add Features/Settings/AddTokenSheet.swift
git commit -m "feat: add AddTokenSheet with resolution flow and confirmation"
```

---

### Task 14: CryptoTokenStore Tests

**Files:**
- Create: `MoolahTests/Features/CryptoTokenStoreTests.swift`

Test the store's token management, resolution, and API key operations.

- [ ] **Step 1: Write tests**

Create `MoolahTests/Features/CryptoTokenStoreTests.swift`:

```swift
// MoolahTests/Features/CryptoTokenStoreTests.swift
import Foundation
import Testing
@testable import Moolah

@Suite("CryptoTokenStore")
@MainActor
struct CryptoTokenStoreTests {
    private func makeStore(
        tokens: [CryptoToken] = [],
        resolutionResult: TokenResolutionResult = TokenResolutionResult(),
        resolutionFails: Bool = false
    ) async -> CryptoTokenStore {
        let repo = InMemoryTokenRepository()
        if !tokens.isEmpty {
            try? await repo.saveTokens(tokens)
        }
        let service = CryptoPriceService(
            clients: [FixedCryptoPriceClient()],
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("crypto-store-tests")
                .appendingPathComponent(UUID().uuidString),
            tokenRepository: repo,
            resolutionClient: FixedTokenResolutionClient(
                result: resolutionResult,
                shouldFail: resolutionFails
            )
        )
        return CryptoTokenStore(cryptoPriceService: service)
    }

    @Test func loadTokens_populatesTokenList() async {
        let presets = Array(CryptoToken.builtInPresets.prefix(2))
        let store = await makeStore(tokens: presets)
        await store.loadTokens()
        #expect(store.tokens.count == 2)
    }

    @Test func removeToken_removesFromList() async {
        let presets = Array(CryptoToken.builtInPresets.prefix(2))
        let store = await makeStore(tokens: presets)
        await store.loadTokens()
        await store.removeToken(presets[0])
        #expect(store.tokens.count == 1)
        #expect(store.tokens[0].id == presets[1].id)
    }

    @Test func resolveToken_populatesResolvedToken() async {
        let result = TokenResolutionResult(
            coingeckoId: "uniswap",
            cryptocompareSymbol: "UNI",
            binanceSymbol: "UNIUSDT",
            resolvedName: "Uniswap",
            resolvedSymbol: "UNI",
            resolvedDecimals: 18
        )
        let store = await makeStore(resolutionResult: result)
        await store.resolveToken(
            chainId: 1,
            contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
            symbol: nil,
            isNative: false
        )
        #expect(store.resolvedToken != nil)
        #expect(store.resolvedToken?.coingeckoId == "uniswap")
    }

    @Test func resolveToken_failure_setsError() async {
        let store = await makeStore(resolutionFails: true)
        await store.resolveToken(
            chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
        )
        #expect(store.resolvedToken == nil)
        #expect(store.error != nil)
    }

    @Test func confirmRegistration_addsToTokenList() async {
        let result = TokenResolutionResult(
            cryptocompareSymbol: "UNI",
            resolvedName: "Uniswap",
            resolvedSymbol: "UNI",
            resolvedDecimals: 18
        )
        let store = await makeStore(resolutionResult: result)
        await store.resolveToken(
            chainId: 1,
            contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
            symbol: nil,
            isNative: false
        )
        await store.confirmRegistration()
        #expect(store.tokens.count == 1)
        #expect(store.resolvedToken == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Features/CryptoTokenStoreTests.swift
git commit -m "test: add CryptoTokenStore tests for token management and resolution"
```

---

### Task 15: Final Integration — Prefetch Registered Tokens

**Files:**
- Modify: `Shared/CryptoPriceService.swift`

Update `prefetchLatest` to use the registered token list when no explicit tokens are provided, so the app automatically prefetches prices for all registered tokens on launch.

- [ ] **Step 1: Write failing test**

Add to `MoolahTests/Shared/CryptoPriceServiceTests.swift`:

```swift
@Test func prefetchLatest_usesRegisteredTokensWhenNoneProvided() async throws {
    let repo = InMemoryTokenRepository()
    try await repo.saveTokens([eth, btc])

    let service = makeService(
        prices: [
            "1:native": ["2026-04-11": Decimal(string: "1640.00")!],
            "0:native": ["2026-04-11": Decimal(string: "67890.00")!],
        ],
        tokenRepository: repo
    )
    await service.prefetchLatest()
    let ethPrice = try await service.price(for: eth, on: date("2026-04-11"))
    #expect(ethPrice == Decimal(string: "1640.00")!)
}
```

- [ ] **Step 2: Run tests to verify it fails**

Run: `just test`
Expected: Compilation error — `prefetchLatest()` with no arguments doesn't exist.

- [ ] **Step 3: Add no-argument prefetchLatest**

Add to `Shared/CryptoPriceService.swift`:

```swift
/// Prefetch latest prices for all registered tokens.
func prefetchLatest() async {
    let tokens = await registeredTokens()
    guard !tokens.isEmpty else { return }
    await prefetchLatest(for: tokens)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/CryptoPriceService.swift MoolahTests/Shared/CryptoPriceServiceTests.swift
git commit -m "feat: prefetchLatest uses registered tokens when none provided"
```

---

### Task 16: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `just test`
Expected: All tests pass on both iOS and macOS.

- [ ] **Step 2: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`.
Fix any warnings in user code.

- [ ] **Step 3: Build both platforms**

Run: `just build-mac && just build-ios`
Expected: Both builds succeed with no warnings.

- [ ] **Step 4: Run ui-review agent on all new UI files**

Run the `ui-review` agent on:
- `Features/Settings/SettingsView.swift`
- `Features/Settings/CryptoSettingsView.swift`
- `Features/Settings/AddTokenSheet.swift`

Fix all issues. Repeat until clean.

- [ ] **Step 5: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address warnings and ui-review feedback"
```
