import Foundation

enum AccountType: String, Codable, Sendable, CaseIterable {
    case bank
    case creditCard = "cc"
    case asset
    case investment
    
    var isCurrent: Bool {
        self == .bank || self == .asset || self == .creditCard
    }
}

struct Account: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var type: AccountType
    var balance: Int // Balance in cents
    var position: Int
    var isHidden: Bool
    
    init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        balance: Int = 0,
        position: Int = 0,
        isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.balance = balance
        self.position = position
        self.isHidden = isHidden
    }
    
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case balance
        case position
        case isHidden = "hidden"
    }
}
