import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("CategoryStore")
@MainActor
struct CategoryStoreTests {
  @Test
  func testLoadPopulatesCategories() async throws {
    let cat = Moolah.Category(name: "Groceries")
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(categories: [cat], in: container)
    let store = CategoryStore(repository: backend.categories)

    await store.load()

    #expect(store.categories.roots.count == 1)
    #expect(store.categories.roots.first?.name == "Groceries")
  }

  @Test
  func testLoadSetsErrorOnFailure() async throws {
    let store = CategoryStore(repository: FailingCategoryRepository())

    await store.load()

    #expect(store.error != nil)
    #expect(store.categories.roots.isEmpty)
  }

  @Test
  func testCreateAddsCategory() async throws {
    let (backend, _) = try TestBackend.create()
    let store = CategoryStore(repository: backend.categories)

    let cat = Moolah.Category(name: "Transport")
    let created = await store.create(cat)

    #expect(created != nil)
    #expect(created?.name == "Transport")
    #expect(store.categories.roots.count == 1)
    #expect(store.categories.roots.first?.name == "Transport")
  }

  @Test
  func testCreateReturnsNilOnFailure() async throws {
    let store = CategoryStore(repository: FailingCategoryRepository())

    let result = await store.create(Moolah.Category(name: "Fails"))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test
  func testUpdateModifiesCategory() async throws {
    let cat = Moolah.Category(name: "Groceries")
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(categories: [cat], in: container)
    let store = CategoryStore(repository: backend.categories)
    await store.load()

    var modified = cat
    modified.name = "Food & Groceries"
    let updated = await store.update(modified)

    #expect(updated != nil)
    #expect(updated?.name == "Food & Groceries")
    #expect(store.categories.by(id: cat.id)?.name == "Food & Groceries")
  }

  @Test
  func testUpdateReturnsNilOnFailure() async throws {
    let store = CategoryStore(repository: FailingCategoryRepository())

    let result = await store.update(Moolah.Category(name: "Fails"))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test
  func testDeleteRemovesCategory() async throws {
    let cat = Moolah.Category(name: "Groceries")
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(categories: [cat], in: container)
    let store = CategoryStore(repository: backend.categories)
    await store.load()

    #expect(store.categories.roots.count == 1)

    let success = await store.delete(id: cat.id, withReplacement: nil)

    #expect(success == true)
    #expect(store.categories.roots.isEmpty)
  }

  @Test
  func testDeleteWithReplacementId() async throws {
    let cat1 = Moolah.Category(name: "Old Category")
    let cat2 = Moolah.Category(name: "New Category")
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(categories: [cat1, cat2], in: container)
    let store = CategoryStore(repository: backend.categories)
    await store.load()

    let success = await store.delete(id: cat1.id, withReplacement: cat2.id)

    #expect(success == true)
    #expect(store.categories.roots.count == 1)
    #expect(store.categories.roots.first?.name == "New Category")
  }

  @Test
  func testDeleteReturnsFalseOnFailure() async throws {
    let store = CategoryStore(repository: FailingCategoryRepository())

    let result = await store.delete(id: UUID(), withReplacement: nil)

    #expect(result == false)
    #expect(store.error != nil)
  }
}

// MARK: - Test helpers

private struct FailingCategoryRepository: CategoryRepository {
  func fetchAll() async throws -> [Moolah.Category] {
    throw BackendError.networkUnavailable
  }

  func create(_ category: Moolah.Category) async throws -> Moolah.Category {
    throw BackendError.networkUnavailable
  }

  func update(_ category: Moolah.Category) async throws -> Moolah.Category {
    throw BackendError.networkUnavailable
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    throw BackendError.networkUnavailable
  }
}
