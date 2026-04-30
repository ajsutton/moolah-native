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

  @Test
  func descendantsOfLeafCategoryIsEmpty() {
    let leaf = Category(name: "Groceries")
    let categories = Categories(from: [leaf])

    #expect(categories.descendants(of: leaf.id).isEmpty)
  }

  @Test
  func descendantsOfParentReturnsDirectChildren() {
    let groceries = Category(name: "Groceries")
    let costco = Category(name: "Costco", parentId: groceries.id)
    let farmers = Category(name: "Farmers Market", parentId: groceries.id)
    let categories = Categories(from: [groceries, costco, farmers])

    let names = Set(categories.descendants(of: groceries.id).map(\.name))

    #expect(names == ["Costco", "Farmers Market"])
  }

  @Test
  func descendantsOfDeepParentReturnsAllLevels() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let janet = Category(name: "Janet", parentId: salary.id)
    let adrian = Category(name: "Adrian", parentId: salary.id)
    let categories = Categories(from: [income, salary, janet, adrian])

    let names = Set(categories.descendants(of: income.id).map(\.name))

    #expect(names == ["Salary", "Janet", "Adrian"])
  }

  @Test
  func descendantsExcludesSelfAndUnrelatedSubtrees() {
    let groceries = Category(name: "Groceries")
    let costco = Category(name: "Costco", parentId: groceries.id)
    let transport = Category(name: "Transport")
    let fuel = Category(name: "Fuel", parentId: transport.id)
    let categories = Categories(from: [groceries, costco, transport, fuel])

    let descendants = categories.descendants(of: groceries.id)
    let ids = Set(descendants.map(\.id))

    #expect(ids == [costco.id])
    #expect(!ids.contains(groceries.id))
    #expect(!ids.contains(transport.id))
    #expect(!ids.contains(fuel.id))
  }
}
