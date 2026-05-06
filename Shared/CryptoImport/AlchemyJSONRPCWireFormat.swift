// Shared/CryptoImport/AlchemyJSONRPCWireFormat.swift
import Foundation
import OSLog

/// Namespace anchor matching the filename so SwiftLint's `file_name`
/// rule stays satisfied alongside the loose top-level wire-format
/// types declared below. Mirrors the pattern used in
/// `WalletSyncTestDoubles.swift` etc.
enum AlchemyJSONRPCWireFormat {}

/// JSON-RPC envelope and wire-format payloads used by `LiveAlchemyClient`.
/// Lifted out of `AlchemyClient.swift` so the main client file stays
/// inside SwiftLint's `file_length` / `type_body_length` budgets.
///
/// Visibility: every type here is module-internal but unused outside
/// `AlchemyClient.swift` and the test files. Keeping them at the file
/// scope (rather than nested inside `LiveAlchemyClient`) lets the
/// generic `JSONRPCRequest` / `JSONRPCResponse` envelopes stay shared
/// across the three JSON-RPC methods without re-declaring the wrapper.

/// Outer JSON-RPC 2.0 request envelope. `id` is fixed at 1 — Alchemy
/// echoes it back, but our requests are single-shot so we don't
/// correlate.
struct AlchemyJSONRPCRequest<Params: Encodable>: Encodable {
  let jsonrpc: String
  let id: Int
  let method: String
  let params: Params

  init(method: String, params: Params) {
    self.jsonrpc = "2.0"
    self.id = 1
    self.method = method
    self.params = params
  }
}

/// Outer JSON-RPC 2.0 response envelope, generic over the result body.
struct AlchemyJSONRPCResponse<Result: Decodable>: Decodable {
  let result: Result
}

/// JSON-RPC 2.0 envelope variant that allows `result: null`. Used by
/// `eth_getTransactionReceipt` because the spec returns `null` for
/// hashes the node hasn't seen yet (instead of an error envelope).
struct AlchemyJSONRPCNullableResponse<Result: Decodable>: Decodable {
  let result: Result?
}

/// Discriminated `params` payload — covers the JSON-RPC methods this
/// client makes today. Each case encodes as the JSON-RPC convention of
/// a one-element array around the parameter object (or address /
/// hash string).
enum AlchemyJSONRPCParams: Encodable {
  case assetTransfers(AlchemyAssetTransfersParams)
  case tokenMetadata(contractAddress: String)
  case transactionReceipt(hash: String)

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    switch self {
    case .assetTransfers(let params):
      try container.encode(params)
    case .tokenMetadata(let address):
      try container.encode(address)
    case .transactionReceipt(let hash):
      try container.encode(hash)
    }
  }
}

/// Body for the `params[0]` object of `alchemy_getAssetTransfers`.
struct AlchemyAssetTransfersParams: Encodable {
  let fromBlock: String
  let toBlock: String
  let fromAddress: String?
  let toAddress: String?
  let category: [String]
  let withMetadata: Bool
  let excludeZeroValue: Bool
}

/// Decodes the `result` object of `alchemy_getAssetTransfers`. The
/// outer envelope wraps this in
/// `AlchemyJSONRPCResponse<AlchemyTransferResult>`.
struct AlchemyTransferEnvelope: Decodable {
  let result: AlchemyTransferResult
}

struct AlchemyTransferResult: Decodable {
  let transfers: [AlchemyTransfer]
}

/// HTTP response validator for `LiveAlchemyClient`. Maps status codes
/// to `WalletSyncError` cases and parses `Retry-After` for the 429
/// path. Lifted out of `AlchemyClient.swift` so the main client struct
/// stays inside SwiftLint's `type_body_length` budget.
enum AlchemyResponseValidator {
  /// Validates the HTTP response, throwing the appropriate
  /// `WalletSyncError` on non-2xx status. `logger` is the per-instance
  /// `Logger` from the calling client; passed in so log messages remain
  /// attributed to the same subsystem/category as the rest of the
  /// client's output.
  static func validate(
    response: URLResponse,
    stage: String,
    logger: Logger
  ) throws {
    guard let http = response as? HTTPURLResponse else {
      logger.error(
        "Alchemy \(stage, privacy: .public): non-HTTP response"
      )
      throw WalletSyncError.network(underlyingDescription: "No HTTP response")
    }
    switch http.statusCode {
    case 200...299:
      return
    case 401, 403:
      logger.error(
        "Alchemy \(stage, privacy: .public): API key rejected (HTTP \(http.statusCode, privacy: .public))"
      )
      throw WalletSyncError.invalidApiKey
    case 429:
      let retryAfter = parseRetryAfter(http: http)
      logger.notice(
        "Alchemy \(stage, privacy: .public): rate limited (HTTP 429)"
      )
      throw WalletSyncError.rateLimited(retryAfter: retryAfter)
    default:
      logger.error(
        "Alchemy \(stage, privacy: .public): HTTP \(http.statusCode, privacy: .public)"
      )
      throw WalletSyncError.network(
        underlyingDescription: "HTTP \(http.statusCode)"
      )
    }
  }

  /// Parses `Retry-After` per RFC 7231: either a non-negative integer
  /// seconds value or an HTTP-date. Returns `nil` when the header is
  /// absent or unparseable.
  private static func parseRetryAfter(http: HTTPURLResponse) -> Date? {
    guard let header = http.value(forHTTPHeaderField: "Retry-After") else {
      return nil
    }
    let trimmed = header.trimmingCharacters(in: .whitespaces)
    if let seconds = TimeInterval(trimmed) {
      return Date().addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: trimmed)
  }
}

/// Wire-format payload for `eth_getTransactionReceipt`. We only decode
/// the two fields the gas-leg builder needs (`gasUsed`,
/// `effectiveGasPrice`); everything else on the receipt is ignored.
///
/// Hex parsing happens in `toReceipt(hash:)` rather than in a custom
/// `init(from:)` so the throw-site stays close to the call. Both
/// fields are required — the JSON-RPC spec mandates them on a non-null
/// receipt, so a missing one is a malformed response we reject rather
/// than silently zero out (a zero gas leg would look like a free
/// transaction and corrupt the user's ledger).
struct AlchemyTransactionReceiptPayload: Decodable {
  let gasUsed: String
  let effectiveGasPrice: String

  func toReceipt(hash: String) throws -> AlchemyTransactionReceipt {
    guard
      let gasUsedValue = HexDecimal.parse(gasUsed),
      let effectiveGasPriceValue = HexDecimal.parse(effectiveGasPrice)
    else {
      throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
    }
    return AlchemyTransactionReceipt(
      hash: hash,
      gasUsed: gasUsedValue,
      effectiveGasPrice: effectiveGasPriceValue
    )
  }
}
