import Testing

@testable import Moolah

struct CategoriesTests {
  @Test
  func categoryPathForRootCategory() {
    let root = Category(name: "Groceries")
    let categories = Categories(from: [root])

    #expect(categories.path(for: root) == "Groceries")
  }

  @Test
  func categoryPathForChildCategory() {
    let root = Category(name: "Groceries")
    let child = Category(name: "Food", parentId: root.id)
    let categories = Categories(from: [root, child])

    #expect(categories.path(for: child) == "Groceries:Food")
  }

  @Test
  func categoryPathForDeeplyNestedCategory() {
    let root = Category(name: "Income")
    let mid = Category(name: "Salary", parentId: root.id)
    let leaf = Category(name: "Janet", parentId: mid.id)
    let categories = Categories(from: [root, mid, leaf])

    #expect(categories.path(for: leaf) == "Income:Salary:Janet")
  }

  @Test
  func flattenedSortedAlphabeticallyByPath() {
    let groceries = Category(name: "Groceries")
    let food = Category(name: "Food", parentId: groceries.id)
    let drinks = Category(name: "Drinks", parentId: groceries.id)
    let income = Category(name: "Income")
    let categories = Categories(from: [groceries, food, drinks, income])

    let flattened = categories.flattenedByPath()
    let paths = flattened.map(\.path)

    #expect(paths == ["Groceries", "Groceries:Drinks", "Groceries:Food", "Income"])
  }

  @Test
  func flattenedReturnsEmptyForEmptyCategories() {
    let categories = Categories(from: [])
    #expect(categories.flattenedByPath().isEmpty)
  }
}
