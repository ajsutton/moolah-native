import os

enum Signposts {
  static let repository = OSLog(subsystem: "com.moolah.app", category: "Repository")
  static let sync = OSLog(subsystem: "com.moolah.app", category: "Sync")
  static let balance = OSLog(subsystem: "com.moolah.app", category: "Balance")
}

extension Duration {
  /// Milliseconds as an integer, for performance logging.
  var inMilliseconds: Int {
    let (seconds, attoseconds) = components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
