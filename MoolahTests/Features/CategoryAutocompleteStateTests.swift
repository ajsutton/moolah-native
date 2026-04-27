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

  @Test
  func testHighlightedSuggestionReturnsTheArrowKeyedRow() {
    let groceriesId = UUID()
    let gymId = UUID()
    let categories = Categories(
      from: [
        Category(id: groceriesId, name: "Groceries"),
        Category(id: gymId, name: "Gym"),
      ])

    var state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 1,
      justSelected: false
    )

    let highlighted = state.highlightedSuggestion(for: "G", in: categories)

    // The visible-suggestion list is sorted by path (canonical category
    // tree order), so index 1 of "G" is "Gym".
    #expect(highlighted?.id == gymId)
    #expect(highlighted?.path == "Gym")

    state.highlightedIndex = nil
    #expect(state.highlightedSuggestion(for: "G", in: categories) == nil)
  }

  @Test
  func testHighlightedSuggestionReturnsNilForOutOfRangeIndex() {
    let categories = Categories(from: [Category(id: UUID(), name: "Groceries")])

    let state = CategoryAutocompleteState(
      showSuggestions: true,
      highlightedIndex: 5,
      justSelected: false
    )

    #expect(state.highlightedSuggestion(for: "G", in: categories) == nil)
  }

  @Test
  func testHighlightedSuggestionReturnsNilWhenDropdownHidden() {
    let categories = Categories(from: [Category(id: UUID(), name: "Groceries")])

    let state = CategoryAutocompleteState(
      showSuggestions: false,
      highlightedIndex: 0,
      justSelected: false
    )

    #expect(state.highlightedSuggestion(for: "G", in: categories) == nil)
  }
}
