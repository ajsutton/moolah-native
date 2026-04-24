import Foundation
import OSLog

struct InstrumentSearchService: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let cryptoSearchClient: any CryptoSearchClient
  private let resolutionClient: any TokenResolutionClient
  private let stockValidator: any StockTickerValidator
  private let logger = Logger(
    subsystem: "com.moolah.app",
    category: "InstrumentSearch"
  )

  init(
    registry: any InstrumentRegistryRepository,
    cryptoSearchClient: any CryptoSearchClient,
    resolutionClient: any TokenResolutionClient,
    stockValidator: any StockTickerValidator
  ) {
    self.registry = registry
    self.cryptoSearchClient = cryptoSearchClient
    self.resolutionClient = resolutionClient
    self.stockValidator = stockValidator
  }

  func search(
    query: String,
    kinds: Set<Instrument.Kind> = Set(Instrument.Kind.allCases)
  ) async -> [InstrumentSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let registered = await loadRegisteredOrLog()
    if trimmed.isEmpty {
      return registered.map {
        InstrumentSearchResult(
          instrument: $0,
          cryptoMapping: nil,
          isRegistered: true,
          requiresResolution: false
        )
      }
    }

    async let fiatResults: [InstrumentSearchResult] =
      kinds.contains(.fiatCurrency) ? fiatMatches(query: trimmed) : []
    async let cryptoResults: [InstrumentSearchResult] =
      kinds.contains(.cryptoToken) ? cryptoMatches(query: trimmed) : []
    async let stockResults: [InstrumentSearchResult] =
      kinds.contains(.stock) ? stockMatches(query: trimmed) : []

    let provider = await (fiatResults + cryptoResults + stockResults)
    let registeredMatches = registeredMatches(query: trimmed, all: registered)
    return merge(registered: registeredMatches, provider: provider)
  }

  private func loadRegisteredOrLog() async -> [Instrument] {
    do {
      return try await registry.all()
    } catch {
      logger.warning(
        "Registry fetch failed; returning empty registered set: \(error, privacy: .public)"
      )
      return []
    }
  }

  // MARK: - Fiat

  /// Fiat-currency search path.
  ///
  /// Every fiat result is marked `isRegistered: true` by design (see the design
  /// spec §2.1): fiat is ambient — the full ISO currency set from
  /// `Locale.Currency.isoCurrencies` is always available without any registration
  /// step. From a picker's perspective "already in registry" is the correct
  /// affordance for fiat: no "Add" button should appear. Stock/crypto hits, in
  /// contrast, default `isRegistered: false` until they're promoted by the
  /// merge step when they share an id with a stored row.
  private func fiatMatches(query: String) -> [InstrumentSearchResult] {
    let lowered = query.lowercased()
    return Locale.Currency.isoCurrencies.compactMap { currency in
      let code = currency.identifier
      let lowerCode = code.lowercased()
      let localizedName =
        Locale.current.localizedString(forCurrencyCode: code)?.lowercased() ?? ""
      guard lowerCode.hasPrefix(lowered) || localizedName.contains(lowered)
      else { return nil }
      return InstrumentSearchResult(
        instrument: Instrument.fiat(code: code),
        cryptoMapping: nil,
        isRegistered: true,
        requiresResolution: false
      )
    }
  }

  // MARK: - Crypto

  private func cryptoMatches(query: String) async -> [InstrumentSearchResult] {
    if isContractAddress(query) {
      return await cryptoContractLookup(address: query)
    }
    do {
      let hits = try await cryptoSearchClient.search(query: query)
      return hits.map { hit in
        let placeholder = Instrument.crypto(
          chainId: 0,
          contractAddress: nil,
          symbol: hit.symbol,
          name: hit.name,
          decimals: 18
        )
        let mapping = CryptoProviderMapping(
          instrumentId: placeholder.id,
          coingeckoId: hit.coingeckoId,
          cryptocompareSymbol: nil,
          binanceSymbol: nil
        )
        return InstrumentSearchResult(
          instrument: placeholder,
          cryptoMapping: mapping,
          isRegistered: false,
          requiresResolution: true
        )
      }
    } catch {
      logger.warning(
        "Crypto search failed for query=\(query, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  private func cryptoContractLookup(address: String) async -> [InstrumentSearchResult] {
    do {
      // chainId 1 (Ethereum mainnet) is the most common; the follow-up UI
      // can expose a chain selector later.
      let result = try await resolutionClient.resolve(
        chainId: 1,
        contractAddress: address,
        symbol: nil,
        isNative: false
      )
      guard let coingeckoId = result.coingeckoId,
        let symbol = result.resolvedSymbol,
        let name = result.resolvedName,
        let decimals = result.resolvedDecimals
      else { return [] }
      let instrument = Instrument.crypto(
        chainId: 1,
        contractAddress: address,
        symbol: symbol,
        name: name,
        decimals: decimals
      )
      let mapping = CryptoProviderMapping(
        instrumentId: instrument.id,
        coingeckoId: coingeckoId,
        cryptocompareSymbol: result.cryptocompareSymbol,
        binanceSymbol: result.binanceSymbol
      )
      return [
        InstrumentSearchResult(
          instrument: instrument,
          cryptoMapping: mapping,
          isRegistered: false,
          requiresResolution: false
        )
      ]
    } catch {
      logger.warning(
        "Contract resolve failed for address=\(address, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  private func isContractAddress(_ query: String) -> Bool {
    guard query.count == 42 else { return false }
    guard query.hasPrefix("0x") else { return false }
    let hexPart = query.dropFirst(2)
    return hexPart.allSatisfy { $0.isHexDigit }
  }

  // MARK: - Stock

  private func stockMatches(query: String) async -> [InstrumentSearchResult] {
    do {
      guard let validated = try await stockValidator.validate(query: query) else {
        return []
      }
      let stock = Instrument.stock(
        ticker: validated.ticker,
        exchange: validated.exchange,
        name: validated.ticker,
        decimals: 0
      )
      return [
        InstrumentSearchResult(
          instrument: stock,
          cryptoMapping: nil,
          isRegistered: false,
          requiresResolution: false
        )
      ]
    } catch {
      logger.warning(
        "Stock validator failed for query=\(query, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  // MARK: - Merge + rank

  private func registeredMatches(
    query: String,
    all: [Instrument]
  ) -> [InstrumentSearchResult] {
    let lowered = query.lowercased()
    return all.compactMap { instrument in
      let id = instrument.id.lowercased()
      let ticker = instrument.ticker?.lowercased() ?? ""
      let name = instrument.name.lowercased()
      guard id.contains(lowered) || ticker.contains(lowered) || name.contains(lowered)
      else { return nil }
      return InstrumentSearchResult(
        instrument: instrument,
        cryptoMapping: nil,
        isRegistered: true,
        requiresResolution: false
      )
    }
  }

  private func merge(
    registered: [InstrumentSearchResult],
    provider: [InstrumentSearchResult]
  ) -> [InstrumentSearchResult] {
    var seen = Set<String>()
    var out: [InstrumentSearchResult] = []
    for result in registered where seen.insert(result.id).inserted {
      out.append(result)
    }
    for result in provider where seen.insert(result.id).inserted {
      out.append(result)
    }
    return out
  }
}
