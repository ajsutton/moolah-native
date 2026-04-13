import os

enum Signposts {
  static let repository = OSLog(subsystem: "com.moolah.app", category: "Repository")
  static let sync = OSLog(subsystem: "com.moolah.app", category: "Sync")
  static let balance = OSLog(subsystem: "com.moolah.app", category: "Balance")
}
