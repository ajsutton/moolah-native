import Foundation
import OSLog

@MainActor
@Observable
final class InstrumentPickerStore {
  private(set) var query: String = ""
  private(set) var results: [InstrumentSearchResult] = []
  private(set) var isLoading: Bool = false
  /// True while the picker is awaiting a crypto resolve + register on the
  /// user's selection. Surfaced so consumers (the sheet) can show progress
  /// without coupling to internal task state.
  private(set) var isResolving: Bool = false
  private(set) var error: String?

  let kinds: Set<Instrument.Kind>

  private let searchService: InstrumentSearchService?
  private let registry: (any InstrumentRegistryRepository)?
  private let resolutionClient: (any TokenResolutionClient)?
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentPickerStore")
  private var searchTask: Task<Void, Never>?

  init(
    searchService: InstrumentSearchService? = nil,
    registry: (any InstrumentRegistryRepository)? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil,
    kinds: Set<Instrument.Kind>
  ) {
    self.searchService = searchService
    self.registry = registry
    self.resolutionClient = resolutionClient
    self.kinds = kinds
  }

  func start() async {
    await runSearch()
  }

  func updateQuery(_ newQuery: String) {
    query = newQuery
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
      await self?.runSearch()
    }
  }

  /// Awaits the in-flight debounced search, if one is scheduled. Returns
  /// immediately when no search is pending. Tests use this instead of a
  /// time-based sleep so they don't race the debounce on slow CI runners.
  func waitForPendingSearch() async {
    guard let task = searchTask else { return }
    await task.value
  }

  /// Resolves the user's pick into a final `Instrument` ready for the caller
  /// to bind. Branches by kind:
  /// - Already registered (any kind) → return the instrument as-is.
  /// - Fiat → ambient; return the instrument with no registry write.
  /// - Stock → register through the registry directly. Yahoo's lookup key is
  ///   the ticker so no resolve step is needed.
  /// - Crypto → resolve provider IDs first (`TokenResolutionClient.resolve`),
  ///   refuse to write when all three provider IDs are nil (the row could
  ///   never be priced), then register the instrument together with its
  ///   resolved `CryptoProviderMapping`. Surfaces user-facing error text on
  ///   failure and returns `nil`.
  func select(_ result: InstrumentSearchResult) async -> Instrument? {
    if result.isRegistered { return result.instrument }
    switch result.instrument.kind {
    case .fiatCurrency:
      return result.instrument
    case .stock:
      return await registerStock(result.instrument)
    case .cryptoToken:
      return await registerCrypto(result.instrument)
    }
  }

  private func registerStock(_ instrument: Instrument) async -> Instrument? {
    guard let registry else { return instrument }
    do {
      try await registry.registerStock(instrument)
      return instrument
    } catch {
      logger.error("Stock registration failed: \(error, privacy: .public)")
      self.error = "Couldn't add \(instrument.displayLabel)."
      return nil
    }
  }

  /// Resolves the catalog row's provider IDs and persists the instrument
  /// alongside its mapping. A row is unwriteable when all three of
  /// `coingeckoId`, `cryptocompareSymbol`, and `binanceSymbol` are nil — none
  /// of the price clients can quote it, so we refuse the registration and
  /// surface a user-facing error instead of poisoning the registry with a
  /// row that will never price.
  ///
  /// Native (chain-only) tokens are detected by a nil `contractAddress`. The
  /// resolver gets `isNative: true` and a nil contract on those rows; tokens
  /// with a contract pass it through verbatim.
  private func registerCrypto(_ instrument: Instrument) async -> Instrument? {
    guard let registry, let resolutionClient else { return nil }
    isResolving = true
    error = nil
    defer { isResolving = false }
    let isNative = instrument.contractAddress == nil
    let chainId = instrument.chainId ?? 0
    do {
      let resolution = try await resolutionClient.resolve(
        chainId: chainId,
        contractAddress: isNative ? nil : instrument.contractAddress,
        symbol: instrument.ticker,
        isNative: isNative
      )
      guard hasAnyProviderId(resolution) else {
        self.error = "Could not find a price source for this token."
        return nil
      }
      let mapping = CryptoProviderMapping(
        instrumentId: instrument.id,
        coingeckoId: resolution.coingeckoId,
        cryptocompareSymbol: resolution.cryptocompareSymbol,
        binanceSymbol: resolution.binanceSymbol
      )
      try await registry.registerCrypto(instrument, mapping: mapping)
      return instrument
    } catch {
      logger.error("Crypto registration failed: \(error, privacy: .public)")
      self.error = "Couldn't add \(instrument.displayLabel)."
      return nil
    }
  }

  private func hasAnyProviderId(_ resolution: TokenResolutionResult) -> Bool {
    resolution.coingeckoId != nil
      || resolution.cryptocompareSymbol != nil
      || resolution.binanceSymbol != nil
  }

  private func runSearch() async {
    isLoading = true
    defer { isLoading = false }
    if let searchService {
      let snapshot = await searchService.search(
        query: query,
        kinds: kinds
      )
      results = snapshot
      return
    }
    results = staticFiatResults(for: query)
  }

  private func staticFiatResults(for query: String) -> [InstrumentSearchResult] {
    guard kinds.contains(.fiatCurrency) else { return [] }
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    return Instrument.commonFiatCodes
      .filter { code in
        trimmed.isEmpty
          || code.lowercased().contains(trimmed)
          || Instrument.localizedName(for: code).localizedCaseInsensitiveContains(trimmed)
      }
      .map { code in
        InstrumentSearchResult(
          instrument: Instrument.fiat(code: code),
          cryptoMapping: nil,
          isRegistered: true,
          requiresResolution: false
        )
      }
  }
}

extension InstrumentPickerStore {
  /// Empty-state description for the picker, phrased to the kinds the picker
  /// is filtering on (so a fiat-only picker doesn't tell the user about
  /// stocks or tokens). Surfaced by `InstrumentPickerSheet.listContent`.
  var noMatchesDescription: String {
    var parts: [String] = []
    if kinds.contains(.fiatCurrency) { parts.append("currencies") }
    if kinds.contains(.stock) { parts.append("stocks") }
    if kinds.contains(.cryptoToken) { parts.append("registered tokens") }
    let kindsLabel = parts.formatted(.list(type: .or))
    return "No matching \(kindsLabel) for \"\(query)\"."
  }
}
