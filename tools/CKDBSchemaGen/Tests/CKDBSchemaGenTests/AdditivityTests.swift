import Testing

@testable import CKDBSchemaGen

@Suite("Additivity (skeleton)")
struct AdditivitySkeletonTests {
  @Test("package builds")
  func packageBuilds() {
    #expect(true)
  }
}
