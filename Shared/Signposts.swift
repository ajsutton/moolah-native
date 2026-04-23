import os

enum Signposts {
  static let repository = OSLog(subsystem: "com.moolah.app", category: "Repository")
  static let sync = OSLog(subsystem: "com.moolah.app", category: "Sync")
  static let balance = OSLog(subsystem: "com.moolah.app", category: "Balance")
  /// Per-stage boundaries for the CSV import pipeline. Instruments traces
  /// attribute time to `tokenize`, `parse`, `dedup`, `rules`, and the outer
  /// `ingest` range. See `guides/BENCHMARKING_GUIDE.md`.
  static let importPipeline = OSLog(subsystem: "com.moolah.app", category: "ImportPipeline")
  /// Per-stage boundaries for the profile export pipeline
  /// (`DataExporter.export`). Each step (accounts, categories, earmarks,
  /// transactions, investmentValues) emits its own region so hangs surface
  /// in Instruments rather than as a user-reported silent failure.
  static let export = OSLog(subsystem: "com.moolah.app", category: "Export")
}

extension Duration {
  /// Milliseconds as an integer, for performance logging.
  var inMilliseconds: Int {
    let (seconds, attoseconds) = components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
