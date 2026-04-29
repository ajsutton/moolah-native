import Foundation
import Testing

@testable import Moolah

@Suite("PayeeAutocompleteState")
struct PayeeAutocompleteStateTests {
  @Test
  func escapeClosesDropdownAndLeavesNextKeystrokeFree() {
    var state = PayeeAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 2,
      justSelected: false
    )

    state.cancel()

    #expect(state.showSuggestions == false)
    #expect(state.highlightedIndex == nil)
    // `justSelected` must stay false: no binding-driven `onTextChange` is
    // triggered by Escape (the text didn't change), so the next character
    // the user types should be free to re-open the dropdown.
    #expect(state.justSelected == false)
  }

  @Test
  func acceptingSuggestionHidesDropdownAndArmsEchoGuard() {
    var state = PayeeAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 1,
      justSelected: false
    )

    state.dismiss()

    #expect(state.showSuggestions == false)
    #expect(state.highlightedIndex == nil)
    // The acceptance writes the suggestion back through the binding; the
    // resulting `onChange(of: text)` must be ignored once.
    #expect(state.justSelected == true)
  }

  @Test
  func typingAfterSuggestionAcceptedDoesNotReopenDropdown() {
    // After `dismiss()` arms `justSelected`, the next text-change callback
    // must clear the flag without asking the caller to fetch — that
    // callback is the binding echo of the suggestion acceptance, not a
    // real user edit.
    var state = PayeeAutocompleteState(
      showSuggestions: false,
      highlightedIndex: nil,
      justSelected: true
    )

    let shouldFetch = state.registerTextEdit(to: "Woolworths")

    #expect(shouldFetch == false)
    #expect(state.justSelected == false)
    // `showSuggestions` must NOT be promoted to true — re-opening it on
    // the echoed text change would show the suggestion the user just
    // picked.
    #expect(state.showSuggestions == false)
  }

  @Test
  func typingRealTextOpensDropdownAndRequestsFetch() {
    var state = PayeeAutocompleteState(
      showSuggestions: false,
      highlightedIndex: nil,
      justSelected: false
    )

    let shouldFetch = state.registerTextEdit(to: "Wool")

    #expect(shouldFetch == true)
    #expect(state.showSuggestions == true)
  }

  @Test
  func clearingTextHidesDropdownAndRequestsFetch() {
    // The fetch call short-circuits empty prefixes itself (clearing
    // `suggestions`); the state mirrors that by hiding the dropdown.
    // Returning `true` keeps the contract simple — the source decides
    // what to do with an empty prefix, not the state.
    var state = PayeeAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 0,
      justSelected: false
    )

    let shouldFetch = state.registerTextEdit(to: "")

    #expect(shouldFetch == true)
    #expect(state.showSuggestions == false)
  }
}
