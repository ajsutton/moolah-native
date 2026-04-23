#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("ProfileWindowLocator")
  @MainActor
  struct ProfileWindowLocatorTests {

    @Test("identifier is derived from the profile UUID")
    func identifierShape() throws {
      let profileID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
      let identifier = ProfileWindowLocator.identifier(for: profileID)
      #expect(identifier.rawValue == "moolah.profile.11111111-1111-1111-1111-111111111111")
    }

    @Test("identifiers are equal for the same profile UUID")
    func identifierEquality() {
      let profileID = UUID()
      let first = ProfileWindowLocator.identifier(for: profileID)
      let second = ProfileWindowLocator.identifier(for: profileID)
      #expect(first == second)
    }

    @Test("identifiers differ between profile UUIDs")
    func identifierDiffers() {
      let first = ProfileWindowLocator.identifier(for: UUID())
      let second = ProfileWindowLocator.identifier(for: UUID())
      #expect(first != second)
    }

    @Test("existingWindow finds a window tagged with the matching identifier")
    func findsTaggedWindow() {
      let profileID = UUID()
      let window = NSWindow()
      window.identifier = ProfileWindowLocator.identifier(for: profileID)
      let other = NSWindow()
      other.identifier = NSUserInterfaceItemIdentifier("something.else")

      let found = ProfileWindowLocator.existingWindow(for: profileID, in: [other, window])
      #expect(found === window)
    }

    @Test("existingWindow returns nil when no window matches")
    func noMatchReturnsNil() {
      let window = NSWindow()
      window.identifier = ProfileWindowLocator.identifier(for: UUID())
      let result = ProfileWindowLocator.existingWindow(for: UUID(), in: [window])
      #expect(result == nil)
    }

    @Test("existingWindow returns nil for an empty window list")
    func emptyListReturnsNil() {
      let result = ProfileWindowLocator.existingWindow(for: UUID(), in: [])
      #expect(result == nil)
    }

    @Test("existingWindow ignores windows with no identifier")
    func ignoresUntaggedWindows() {
      let untagged = NSWindow()
      let profileID = UUID()
      let tagged = NSWindow()
      tagged.identifier = ProfileWindowLocator.identifier(for: profileID)

      let found = ProfileWindowLocator.existingWindow(for: profileID, in: [untagged, tagged])
      #expect(found === tagged)
    }
  }
#endif
