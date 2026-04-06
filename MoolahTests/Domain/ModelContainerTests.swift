import SwiftData
import Testing

@Suite("ModelContainer")
struct ModelContainerTests {
  @Test("Initialises with empty schema without error")
  func initialisesWithEmptySchema() throws {
    let container = try ModelContainer(for: Schema([]))
    #expect(container.configurations.isEmpty == false)
  }
}
