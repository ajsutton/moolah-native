import Foundation

protocol CSVImportProfileRepository: Sendable {
  func fetchAll() async throws -> [CSVImportProfile]
  func create(_ profile: CSVImportProfile) async throws -> CSVImportProfile
  func update(_ profile: CSVImportProfile) async throws -> CSVImportProfile
  func delete(id: UUID) async throws
}
