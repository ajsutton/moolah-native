import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft.normaliseCategoryText")
struct TransactionDraftCategoryTests {
  private let support = TransactionDraftTestSupport()

  // swiftlint:disable:next attributes
  @Test func validCategoryIdRewritesTextToCanonicalPath() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.categoryId = catId
    draft.categoryText = "groc"

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == catId)
    #expect(draft.categoryText == "Groceries")
  }

  // swiftlint:disable:next attributes
  @Test func unknownCategoryIdClearsBothFields() {
    let missingId = UUID()
    let categories = Categories(from: [])

    var draft = support.makeExpenseDraft()
    draft.categoryId = missingId
    draft.categoryText = "Something"

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == nil)
    #expect(draft.categoryText.isEmpty)
  }

  // swiftlint:disable:next attributes
  @Test func nilCategoryIdClearsText() {
    let categories = Categories(from: [Category(id: UUID(), name: "Groceries")])

    var draft = support.makeExpenseDraft()
    draft.categoryId = nil
    draft.categoryText = "partial input"

    draft.normaliseCategoryText(using: categories)

    #expect(draft.categoryId == nil)
    #expect(draft.categoryText.isEmpty)
  }
}
