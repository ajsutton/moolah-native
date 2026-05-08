import Foundation
import Testing

@testable import Moolah

struct ParentCategorySelectionTests {
  // MARK: Fixtures

  private static let groceriesId = UUID()
  private static let fruitId = UUID()
  private static let transportId = UUID()

  private static let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(id: fruitId, name: "Fruit", parentId: groceriesId),
    Category(id: transportId, name: "Transport"),
  ])

  // MARK: init(initialId:in:)

  @Test
  func initFromNilIdYieldsEmptySelection() {
    let selection = ParentCategorySelection(
      initialId: nil, in: Self.categories)
    #expect(selection.id == nil)
    #expect(selection.text.isEmpty)
  }

  @Test
  func initFromTopLevelIdPopulatesPath() {
    let selection = ParentCategorySelection(
      initialId: Self.transportId, in: Self.categories)
    #expect(selection.id == Self.transportId)
    #expect(selection.text == "Transport")
  }

  @Test
  func initFromNestedIdPopulatesFullPath() {
    let selection = ParentCategorySelection(
      initialId: Self.fruitId, in: Self.categories)
    #expect(selection.id == Self.fruitId)
    #expect(selection.text == "Groceries:Fruit")
  }

  @Test
  func initFromUnknownIdClearsBoth() {
    let strangerId = UUID()
    let selection = ParentCategorySelection(
      initialId: strangerId, in: Self.categories)
    #expect(selection.id == nil)
    #expect(selection.text.isEmpty)
  }

  // MARK: commit(_:)

  @Test
  func commitAssignsIdAndPath() {
    var selection = ParentCategorySelection()
    selection.commit(
      CategorySuggestion(id: Self.fruitId, path: "Groceries:Fruit"))
    #expect(selection.id == Self.fruitId)
    #expect(selection.text == "Groceries:Fruit")
  }

  // MARK: commitHighlightedOrNormalise(highlighted:in:)

  @Test
  func highlightedSuggestionWinsOverTypedText() {
    var selection = ParentCategorySelection(
      id: nil, text: "stale-typed-text")
    selection.commitHighlightedOrNormalise(
      highlighted: CategorySuggestion(
        id: Self.transportId, path: "Transport"),
      in: Self.categories)
    #expect(selection.id == Self.transportId)
    #expect(selection.text == "Transport")
  }

  @Test
  func emptyTextClearsBoth() {
    var selection = ParentCategorySelection(
      id: Self.transportId, text: "")
    selection.commitHighlightedOrNormalise(
      highlighted: nil, in: Self.categories)
    #expect(selection.id == nil)
    #expect(selection.text.isEmpty)
  }

  @Test
  func whitespaceOnlyTextClearsBoth() {
    var selection = ParentCategorySelection(
      id: Self.transportId, text: "   ")
    selection.commitHighlightedOrNormalise(
      highlighted: nil, in: Self.categories)
    #expect(selection.id == nil)
    #expect(selection.text.isEmpty)
  }

  @Test
  func unmatchedTextWithLiveIdRestoresCanonicalPath() {
    var selection = ParentCategorySelection(
      id: Self.fruitId, text: "Frui")
    selection.commitHighlightedOrNormalise(
      highlighted: nil, in: Self.categories)
    #expect(selection.id == Self.fruitId)
    #expect(selection.text == "Groceries:Fruit")
  }

  @Test
  func unmatchedTextWithStaleIdClearsBoth() {
    let staleId = UUID()
    var selection = ParentCategorySelection(
      id: staleId, text: "Whatever")
    selection.commitHighlightedOrNormalise(
      highlighted: nil, in: Self.categories)
    #expect(selection.id == nil)
    #expect(selection.text.isEmpty)
  }

  @Test
  func unmatchedTextWithoutIdClearsBoth() {
    var selection = ParentCategorySelection(
      id: nil, text: "made-up")
    selection.commitHighlightedOrNormalise(
      highlighted: nil, in: Self.categories)
    #expect(selection.id == nil)
    #expect(selection.text.isEmpty)
  }
}
