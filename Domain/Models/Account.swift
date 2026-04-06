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

struct Account: Codable, Sendable, Identifiable, Hashable, Comparable {
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
    
    static func < (lhs: Account, rhs: Account) -> Bool {
        lhs.position < rhs.position
    }
}

struct Accounts : RandomAccessCollection {
    let startIndex: Int = 0
    
    let ordered : [Account]
    let byId : [UUID: Account]
    
    init(from: [Account]) {
        byId = from.reduce(into: [:]) { $0[$1.id] = $1 }
        ordered = from.sorted()
    }
    
    func by(id: UUID) -> Account? {
        byId[id]
    }
    
    var endIndex: Int {
        return ordered.count
    }
    
    subscript(idex: Int) -> Account {
        ordered[idex]
    }
}
