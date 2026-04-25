import Testing

@testable import CKDBSchemaGen

@Suite("Parser (skeleton)")
struct ParserSkeletonTests {
  @Test("package builds")
  func packageBuilds() {
    #expect(true)
  }
}
