import Foundation

protocol AccountRepository: Sendable {
    func fetchAll() async throws -> [Account]
}
