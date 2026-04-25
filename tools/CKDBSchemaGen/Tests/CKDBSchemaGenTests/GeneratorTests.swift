import Testing

@testable import CKDBSchemaGen

@Suite("Generator (skeleton)")
struct GeneratorSkeletonTests {
  @Test("package builds")
  func packageBuilds() {
    #expect(true)
  }
}
