import Foundation

/// Structured outcome of a failed wallet/exchange/price sync. Stored in
/// `WalletSyncState.lastError` (a per-device, non-cross-device-synced
/// checkpoint) so the UI can format it without coupling the domain to
/// localised strings.
///
/// `provider` records which external provider produced the failure so the
/// caption can name it. It is `nil` when the failure is not attributable
/// to a single provider (e.g. account-data validation) or when decoding a
/// legacy row written before attribution existed.
struct WalletSyncError: Error, Codable, Sendable, Hashable {
  /// The failure category — exactly the cases the bare enum carried
  /// before attribution was added.
  enum Kind: Codable, Sendable, Hashable {
    case missingApiKey
    case invalidApiKey
    case rateLimited(retryAfter: Date?)
    case network(underlyingDescription: String)
    case providerMalformedResponse(stage: String)
  }

  var provider: SyncProvider?
  var kind: Kind

  /// Returns a copy attributed to `provider`, but only if it is not
  /// already attributed — the innermost (closest-to-source) provider
  /// wins, so an outer boundary never relabels a deeper one's error.
  func attributed(to provider: SyncProvider) -> WalletSyncError {
    guard self.provider == nil else { return self }
    return WalletSyncError(provider: provider, kind: kind)
  }
}

// MARK: - Call-site-preserving factories

// These keep every existing `throw WalletSyncError.network(…)` /
// `.missingApiKey` / etc. site compiling unchanged, producing an
// unattributed error that a leaf boundary later stamps.
extension WalletSyncError {
  static var missingApiKey: WalletSyncError {
    WalletSyncError(provider: nil, kind: .missingApiKey)
  }

  static var invalidApiKey: WalletSyncError {
    WalletSyncError(provider: nil, kind: .invalidApiKey)
  }

  static func rateLimited(retryAfter: Date?) -> WalletSyncError {
    WalletSyncError(provider: nil, kind: .rateLimited(retryAfter: retryAfter))
  }

  static func network(underlyingDescription: String) -> WalletSyncError {
    WalletSyncError(
      provider: nil, kind: .network(underlyingDescription: underlyingDescription))
  }

  static func providerMalformedResponse(stage: String) -> WalletSyncError {
    WalletSyncError(provider: nil, kind: .providerMalformedResponse(stage: stage))
  }
}

// MARK: - Codable with legacy-row migration

// Persisted shape (new): {"provider": "alchemy"|null, "kind": <Kind JSON>}.
// Legacy shape (pre-attribution): the bare enum encoding — a single-key
// object whose key is the case name, e.g. {"network":{...}} or
// {"missingApiKey":{}}. The decoder accepts both; the encoder only ever
// writes the new shape.
extension WalletSyncError {
  private enum CodingKeys: String, CodingKey { case provider, kind }

  init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: CodingKeys.self),
      container.contains(.kind)
    {
      let provider = try container.decodeIfPresent(
        SyncProvider.self, forKey: .provider)
      let kind = try container.decode(Kind.self, forKey: .kind)
      self.init(provider: provider, kind: kind)
      return
    }
    let legacyKind = try Kind(from: decoder)
    self.init(provider: nil, kind: legacyKind)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(provider, forKey: .provider)
    try container.encode(kind, forKey: .kind)
  }
}
