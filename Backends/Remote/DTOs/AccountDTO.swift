import Foundation

struct AccountDTO: Codable {
    let id: String
    let name: String
    let type: String
    let balance: Int // Transaction-based balance in cents
    let value: Int? // Latest market value in cents (for investments)
    let position: Int
    let hidden: Bool
    
    func toDomain() -> Account {
        // For investments, prefer 'value' if present, otherwise fall back to 'balance'
        let effectiveBalance = (type == "investment" && value != nil) ? value! : balance
        
        return Account(
            id: FlexibleUUID.parse(id) ?? UUID(),
            name: name,
            type: AccountType(rawValue: type) ?? .asset,
            balance: effectiveBalance,
            position: position,
            isHidden: hidden
        )
    }
    
    struct ListWrapper: Codable {
        let accounts: [AccountDTO]
    }
}
