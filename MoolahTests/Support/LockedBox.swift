// MoolahTests/Support/LockedBox.swift
import Foundation

/// Lock-guarded mutable box used by tests to capture state from `@Sendable`
/// closures (e.g. `URLProtocol` request handlers) without tripping Swift 6
/// strict concurrency rules. Module-internal so multiple test files can share
/// a single definition rather than each declaring their own private copy.
final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ initial: Value) { self.value = initial }

  func get() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ newValue: Value) {
    lock.lock()
    defer { lock.unlock() }
    value = newValue
  }
}
