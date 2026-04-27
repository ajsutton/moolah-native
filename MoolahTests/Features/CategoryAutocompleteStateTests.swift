import Foundation
import Testing

@testable import Moolah

@Suite("CategoryAutocompleteState")
struct CategoryAutocompleteStateTests {
  @Test
  func testCancelClosesDropdownWithoutArmingJustSelected() {
    var state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 0,
      justSelected: false
    )

    state.cancel()

    #expect(state.showSuggestions == false)
    #expect(state.highlightedIndex == nil)
    // See `PayeeAutocompleteStateTests` for the reasoning — the text
    // didn't change on Escape, so the next keystroke must be free to
    // re-open the dropdown.
    #expect(state.justSelected == false)
  }

  @Test
  func testDismissArmsJustSelectedSoBindingDrivenOnChangeIsEaten() {
    var state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 0,
      justSelected: false
    )

    state.dismiss()

    #expect(state.showSuggestions == false)
    #expect(state.highlightedIndex == nil)
    #expect(state.justSelected == true)
  }
}
