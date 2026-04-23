import Testing

@testable import Moolah

struct CategoryMatchingTests {
  @Test
  func emptyQueryMatchesEverything() {
    #expect(matchesCategorySearch("Groceries:Food", query: ""))
    #expect(matchesCategorySearch("Income", query: ""))
    #expect(matchesCategorySearch("Income", query: "   "))
  }

  @Test
  func singleWordMatchesAnywhere() {
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "sal"))
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "Inc"))
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "jan"))
  }

  @Test
  func singleWordNoMatch() {
    #expect(!matchesCategorySearch("Groceries:Food", query: "Salary"))
  }

  @Test
  func multiWordAllMustMatch() {
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "Income Janet"))
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "Jan Inc"))
  }

  @Test
  func multiWordOneFailsNoMatch() {
    #expect(!matchesCategorySearch("Income:Salary:Janet", query: "Income Bob"))
  }

  @Test
  func caseInsensitive() {
    #expect(matchesCategorySearch("Groceries:Food", query: "groceries"))
    #expect(matchesCategorySearch("Groceries:Food", query: "FOOD"))
    #expect(matchesCategorySearch("Groceries:Food", query: "gro foo"))
  }

  @Test
  func colonIsSearchable() {
    #expect(matchesCategorySearch("Groceries:Food", query: "ries:Fo"))
  }

  @Test
  func partialWordMatches() {
    #expect(matchesCategorySearch("Groceries:Food", query: "Gro"))
    #expect(matchesCategorySearch("Entertainment:Movies", query: "Ent Mov"))
  }
}
