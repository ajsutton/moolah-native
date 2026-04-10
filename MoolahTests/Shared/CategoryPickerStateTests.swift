import Testing

@testable import Moolah

@MainActor
struct CategoryPickerStateTests {
  private func makeCategories() -> (Categories, Category, Category, Category) {
    let groceries = Category(name: "Groceries")
    let food = Category(name: "Food", parentId: groceries.id)
    let income = Category(name: "Income")
    let categories = Categories(from: [groceries, food, income])
    return (categories, groceries, food, income)
  }

  @Test func initialState() {
    let state = CategoryPickerState()
    #expect(!state.isEditing)
    #expect(state.searchText == "")
    #expect(state.highlightedIndex == nil)
  }

  @Test func openSetsEditingTrue() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()

    state.open(categories: categories)

    #expect(state.isEditing)
    #expect(state.searchText == "")
    #expect(state.highlightedIndex == nil)
  }

  @Test func closeResetsState() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()

    state.open(categories: categories)
    state.searchText = "Gro"
    state.highlightedIndex = 2
    state.close()

    #expect(!state.isEditing)
    #expect(state.searchText == "")
    #expect(state.highlightedIndex == nil)
  }

  @Test func openAfterCloseWorks() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()

    // First open/close cycle
    state.open(categories: categories)
    state.close()
    #expect(!state.isEditing)

    // Second open
    state.open(categories: categories)
    #expect(state.isEditing)
    #expect(state.searchText == "")
  }

  @Test func openCloseSelectCycleRepeatable() {
    let (categories, groceries, _, _) = makeCategories()
    let state = CategoryPickerState()

    // First cycle: open, select, verify closed
    state.open(categories: categories)
    #expect(state.isEditing)
    let firstResult = state.acceptHighlighted(at: 1)
    state.close()
    #expect(firstResult == groceries.id)
    #expect(!state.isEditing)

    // Second cycle: open again, select different, verify closed
    state.open(categories: categories)
    #expect(state.isEditing)
    let secondResult = state.acceptHighlighted(at: 0)
    state.close()
    #expect(secondResult == nil)  // "None" at index 0
    #expect(!state.isEditing)

    // Third cycle: open again
    state.open(categories: categories)
    #expect(state.isEditing)
  }

  @Test func filteredEntriesShowAllWhenSearchEmpty() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()

    state.open(categories: categories)
    #expect(state.filteredEntries.count == 3)
  }

  @Test func filteredEntriesFilterBySearch() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()

    state.open(categories: categories)
    state.searchText = "Gro"

    let paths = state.filteredEntries.map(\.path)
    #expect(paths.contains("Groceries"))
    #expect(paths.contains("Groceries:Food"))
    #expect(!paths.contains("Income"))
  }

  @Test func acceptHighlightedAtZeroReturnsNil() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()
    state.open(categories: categories)

    let result = state.acceptHighlighted(at: 0)
    #expect(result == nil)
  }

  @Test func acceptHighlightedAtOneReturnsFirstCategory() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()
    state.open(categories: categories)

    let result = state.acceptHighlighted(at: 1)
    // First entry alphabetically
    let firstEntry = state.visibleEntries[0]
    #expect(result == firstEntry.category.id)
  }

  @Test func acceptHighlightedOutOfBoundsReturnsNil() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()
    state.open(categories: categories)

    let result = state.acceptHighlighted(at: 100)
    #expect(result == nil)
  }

  @Test func totalRowCountIncludesNone() {
    let (categories, _, _, _) = makeCategories()
    let state = CategoryPickerState()
    state.open(categories: categories)

    // 3 categories + 1 "None" row
    #expect(state.totalRowCount == 4)
  }

  @Test func visibleEntriesLimitedToEight() {
    var cats: [Category] = []
    for i in 0..<15 {
      cats.append(Category(name: "Category \(i)"))
    }
    let categories = Categories(from: cats)
    let state = CategoryPickerState()
    state.open(categories: categories)

    #expect(state.visibleEntries.count == 8)
    #expect(state.allEntries.count == 15)
  }
}
