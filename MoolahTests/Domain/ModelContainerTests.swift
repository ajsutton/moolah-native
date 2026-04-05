import Testing
import SwiftData

@Suite("ModelContainer")
struct ModelContainerTests {
    @Test("Initialises with empty schema without error")
    func initialisesWithEmptySchema() throws {
        let container = try ModelContainer(for: Schema([]))
        #expect(container.configurations.isEmpty == false)
    }
}
