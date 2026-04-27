import Foundation
import Testing

@testable import Moolah

@Suite("PayeeAutocompleteState")
struct PayeeAutocompleteStateTests {
  @Test
  func testCancelClosesDropdownWithoutArmingJustSelected() {
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
    // the user types should be free to re-open the dropdown. Setting
    // `justSelected = true` here would silently eat that next keystroke.
    #expect(state.justSelected == false)
  }

  @Test
  func testDismissArmsJustSelectedSoBindingDrivenOnChangeIsEaten() {
    var state = PayeeAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 1,
      justSelected: false
    )

    state.dismiss()

    #expect(state.showSuggestions == false)
    #expect(state.highlightedIndex == nil)
    // Used by the suggestion-acceptance path: the resulting binding write
    // triggers an `onChange(of: text)` we want to ignore.
    #expect(state.justSelected == true)
  }
}
