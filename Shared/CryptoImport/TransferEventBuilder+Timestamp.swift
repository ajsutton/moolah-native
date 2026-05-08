// Shared/CryptoImport/TransferEventBuilder+Timestamp.swift
import Foundation

extension TransferEventBuilder {
  /// Parses Alchemy's ISO-8601 block timestamp (`"2024-09-12T12:34:56.000Z"`).
  /// Returns `nil` on malformed input — caller falls back to
  /// `ImportOrigin.importedAt`.
  ///
  /// `ISO8601DateFormatter` is allocated per call to keep the builder a
  /// pure `Sendable` value type (no `nonisolated(unsafe)` static state).
  /// The build hot path is dominated by the Alchemy round-trip and the
  /// discovery actor, so a per-row allocation here is a non-event.
  func parseTimestamp(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }
}
