import Foundation
import Testing

@testable import Moolah

/// Tests for the platform-action-verb helper used in UI copy.
///
/// macOS users click, iOS users tap — empty-state strings must use the
/// correct verb for the platform per `guides/STYLE_GUIDE.md` §1 (macOS-First).
@Suite("Platform Action Verb Tests")
struct PlatformActionVerbTests {

  @Test("Imperative action verb matches current platform")
  func imperativeActionVerb() {
    #if os(macOS)
      #expect(PlatformActionVerb.imperative == "Click")
    #else
      #expect(PlatformActionVerb.imperative == "Tap")
    #endif
  }

  @Test("Empty-state prompt uses platform-correct verb")
  func emptyStatePrompt() {
    let prompt = PlatformActionVerb.emptyStatePrompt(
      buttonLabel: "+",
      suffix: "to record a value"
    )
    #if os(macOS)
      #expect(prompt == "Click + to record a value")
    #else
      #expect(prompt == "Tap + to record a value")
    #endif
  }
}
