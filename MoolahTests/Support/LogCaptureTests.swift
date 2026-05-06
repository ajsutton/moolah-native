// MoolahTests/Support/LogCaptureTests.swift
import Foundation
import OSLog
import Testing

@testable import Moolah

@Suite("LogCapture")
struct LogCaptureTests {
  /// Each test uses a fresh subsystem/category so concurrent test runs
  /// can't observe each other's emissions.
  private let subsystem = "com.moolah.tests.logcapture"

  @Test
  func capturesSingleWarning() async throws {
    let category = uniqueCategory()
    let logger = Logger(subsystem: subsystem, category: category)

    let entries = try await LogCapture.capture(
      subsystem: subsystem, category: category
    ) {
      logger.warning("\("a single warning", privacy: .public)")
    }

    #expect(entries.count == 1)
    #expect(entries.first?.message == "a single warning")
    // `Logger.warning` emits at level `.error` — see Apple docs for
    // `OSLogEntryLog.Level` (warning is mapped to error).
    #expect(entries.first?.level == .error)
    #expect(entries.first?.category == category)
  }

  @Test
  func returnsEmptyListWhenNothingLogged() async throws {
    let category = uniqueCategory()
    let entries = try await LogCapture.capture(
      subsystem: subsystem, category: category
    ) {
      // No emissions.
    }
    #expect(entries.isEmpty)
  }

  @Test
  func capturesEmissionsInOrder() async throws {
    let category = uniqueCategory()
    let logger = Logger(subsystem: subsystem, category: category)

    let entries = try await LogCapture.capture(
      subsystem: subsystem, category: category
    ) {
      logger.notice("\("first", privacy: .public)")
      logger.warning("\("second", privacy: .public)")
      logger.error("\("third", privacy: .public)")
    }

    #expect(entries.map(\.message) == ["first", "second", "third"])
  }

  @Test
  func filtersOutOtherCategoriesOnSameSubsystem() async throws {
    let wantedCategory = uniqueCategory()
    let unwantedCategory = uniqueCategory()
    let wanted = Logger(subsystem: subsystem, category: wantedCategory)
    let unwanted = Logger(subsystem: subsystem, category: unwantedCategory)

    let entries = try await LogCapture.capture(
      subsystem: subsystem, category: wantedCategory
    ) {
      wanted.warning("\("kept", privacy: .public)")
      unwanted.warning("\("dropped", privacy: .public)")
    }

    #expect(entries.map(\.message) == ["kept"])
  }

  @Test
  func filtersOutOtherSubsystems() async throws {
    let category = uniqueCategory()
    let wanted = Logger(subsystem: subsystem, category: category)
    let unwanted = Logger(subsystem: "com.moolah.tests.other", category: category)

    let entries = try await LogCapture.capture(
      subsystem: subsystem, category: category
    ) {
      wanted.warning("\("kept", privacy: .public)")
      unwanted.warning("\("dropped", privacy: .public)")
    }

    #expect(entries.map(\.message) == ["kept"])
  }

  @Test
  func capturesAllCategoriesWhenCategoryIsNil() async throws {
    // Use a fresh subsystem so emissions from concurrent tests sharing
    // the suite-level `subsystem` can't leak into this one.
    let scopedSubsystem = "\(subsystem).any-category-\(UUID().uuidString)"
    let categoryA = uniqueCategory()
    let categoryB = uniqueCategory()
    let loggerA = Logger(subsystem: scopedSubsystem, category: categoryA)
    let loggerB = Logger(subsystem: scopedSubsystem, category: categoryB)

    let entries = try await LogCapture.capture(subsystem: scopedSubsystem) {
      loggerA.warning("\("from-a", privacy: .public)")
      loggerB.warning("\("from-b", privacy: .public)")
    }

    #expect(Set(entries.map(\.message)) == ["from-a", "from-b"])
  }

  private func uniqueCategory() -> String { "case-\(UUID().uuidString)" }
}
