// Shared/CryptoImport/TransferEventBuilder+NativeRegistration.swift
import Foundation

extension TransferEventBuilder {
  /// Pre-register the chain's native gas instrument via discovery so
  /// the registry stores a row carrying a real provider mapping.
  ///
  /// Both transfer-leg construction (`.external` / `.internal` cases
  /// of `resolveInstrument`) and gas-leg construction
  /// (`TransferReceiptCoalescer.makeGasLeg`) use
  /// `chain.nativeInstrument` directly. Without this pre-registration,
  /// `ensureInstrumentReadable` inserts a placeholder `InstrumentRow`
  /// with default `pricingStatus=.priced` and no provider mapping,
  /// which `allCryptoRegistrations()` then projects to nil — and the
  /// downstream conversion of `10:native` (and other native gas
  /// tokens like `1:native`, `137:native`, `8453:native`) throws
  /// `ConversionError.noProviderMapping`. See issue #791.
  ///
  /// Idempotent at the discovery actor: when a registration already
  /// exists for the chain's native id, `resolveOrLoad` short-circuits
  /// to the registry and skips network resolution.
  static func preregisterChainNativeInstrument(
    chain: ChainConfig,
    discovery: CryptoTokenDiscoveryService
  ) async throws {
    let nativeInstrument = chain.nativeInstrument
    _ = try await discovery.resolveOrLoad(
      chain: chain,
      contractAddress: nil,
      symbol: nativeInstrument.ticker ?? nativeInstrument.name,
      name: nativeInstrument.name,
      decimals: nativeInstrument.decimals)
  }
}
