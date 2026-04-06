import Testing
import Foundation
@testable import Moolah

@Suite("AccountStore")
@MainActor
struct AccountStoreTests {
    @Test func testPopulatesFromRepository() async throws {
        let account = Account(name: "Checking", type: .checking, balance: 100000)
        let repository = InMemoryAccountRepository(initialAccounts: [account])
        let store = AccountStore(repository: repository)
        
        await store.load()
        
        #expect(store.accounts.count == 1)
        #expect(store.accounts.first?.name == "Checking")
    }
    
    @Test func testSortingByPosition() async throws {
        let a1 = Account(name: "A1", type: .checking, balance: 10000, position: 2)
        let a2 = Account(name: "A2", type: .checking, balance: 20000, position: 1)
        let repository = InMemoryAccountRepository(initialAccounts: [a1, a2])
        let store = AccountStore(repository: repository)
        
        await store.load()
        
        #expect(store.accounts.count == 2)
        #expect(store.accounts[0].name == "A2")
        #expect(store.accounts[1].name == "A1")
    }
    
    @Test func testCalculatesTotals() async throws {
        let accounts = [
            Account(name: "Checking", type: .checking, balance: 100000),
            Account(name: "Savings", type: .savings, balance: 500000),
            Account(name: "Credit Card", type: .creditCard, balance: -50000),
            Account(name: "Investment", type: .investment, balance: 2000000),
            Account(name: "House Fund", type: .earmark, balance: 300000),
            Account(name: "Hidden", type: .checking, balance: 100000000, isHidden: true)
        ]
        let repository = InMemoryAccountRepository(initialAccounts: accounts)
        let store = AccountStore(repository: repository)
        
        await store.load()
        
        #expect(store.currentTotal == 550000) // 100000 + 500000 - 50000
        #expect(store.earmarkedTotal == 300000)
        #expect(store.investmentTotal == 2000000)
        #expect(store.netWorth == 2850000)
    }
}
