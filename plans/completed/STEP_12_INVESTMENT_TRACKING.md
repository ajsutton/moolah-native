# Step 12 — Investment Tracking — Detailed Implementation Plan

**Date:** 2026-04-08
**Status:** Not started
**Related:** NATIVE_APP_PLAN.md (lines 462-485)

---

## Executive Summary

Investment tracking allows users to manually record the value of investment accounts over time and visualize performance through a line chart. This feature enables users to track assets like retirement funds, brokerage accounts, mutual funds, and cryptocurrency holdings that cannot be automatically synchronized.

The implementation follows Moolah's backend abstraction pattern: a `InvestmentValue` domain model, an `InvestmentRepository` protocol, concrete implementations (`InMemoryInvestmentRepository` and `RemoteInvestmentRepository`), and a SwiftUI view (`InvestmentValuesView`) integrated into `AccountDetailView` for investment-type accounts.

**Estimated effort:** 12 hours

---

## 1. Domain Model: InvestmentValue

### 1.1 Data Structure

**File:** `Domain/Models/InvestmentValue.swift`

```swift
import Foundation

/// Represents a single point-in-time valuation of an investment account.
struct InvestmentValue: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  let accountId: UUID
  let date: Date
  let value: MonetaryAmount

  init(
    id: UUID = UUID(),
    accountId: UUID,
    date: Date,
    value: MonetaryAmount
  ) {
    self.id = id
    self.accountId = accountId
    self.date = date
    self.value = value
  }

  // Sort by date descending (newest first), then by id for stable ordering
  static func < (lhs: InvestmentValue, rhs: InvestmentValue) -> Bool {
    if lhs.date != rhs.date { return lhs.date > rhs.date }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
```

### 1.2 Pagination Model

**File:** `Domain/Models/InvestmentValue.swift`

```swift
struct InvestmentValuePage: Sendable {
  let values: [InvestmentValue]
  let hasMore: Bool
}
```

### 1.3 Validation Rules

- **id:** Must be unique (enforced by backend)
- **accountId:** Must reference an existing account with `type == .investment`
- **date:** Must be a valid date (past or present; future dates rejected)
- **value:** Must be >= 0 (investment values cannot be negative)

**Validation location:** Form-level validation in `InvestmentValuesView`, domain-level validation can be added as an extension if needed.

---

## 2. Repository Protocol

### 2.1 InvestmentRepository Protocol

**File:** `Domain/Repositories/InvestmentRepository.swift`

```swift
import Foundation

protocol InvestmentRepository: Sendable {
  /// Fetch investment values for a given account, paginated and sorted by date descending.
  /// - Parameters:
  ///   - accountId: The investment account to fetch values for
  ///   - page: Zero-indexed page number
  ///   - pageSize: Number of items per page (default: 50)
  /// - Returns: A page of investment values with hasMore flag
  /// - Throws: BackendError if the request fails
  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage

  /// Create a new investment value entry.
  /// - Parameter value: The investment value to create (id will be generated if not provided)
  /// - Returns: The created investment value with server-assigned ID
  /// - Throws: BackendError if validation fails or account does not exist
  func createValue(_ value: InvestmentValue) async throws -> InvestmentValue

  /// Delete an investment value entry by ID.
  /// - Parameter id: The ID of the value to delete
  /// - Throws: BackendError.notFound if the value does not exist
  func deleteValue(id: UUID) async throws
}
```

### 2.2 Update BackendProvider

**File:** `Domain/Repositories/BackendProvider.swift`

```diff
protocol BackendProvider: Sendable {
  var auth: any AuthProvider { get }
  var accounts: any AccountRepository { get }
  var transactions: any TransactionRepository { get }
  var categories: any CategoryRepository { get }
  var earmarks: any EarmarkRepository { get }
+  var investments: any InvestmentRepository { get }
}
```

### 2.3 Error Handling

Investment operations can fail with:
- `BackendError.notFound` — account or value does not exist
- `BackendError.serverError(statusCode)` — validation failure (e.g., negative value, future date)
- `BackendError.networkError` — connection issues

All errors are surfaced to the UI layer via `@MainActor` methods in `InvestmentStore`.

---

## 3. Backend Implementations

### 3.1 InMemoryInvestmentRepository

**File:** `Backends/InMemory/InMemoryInvestmentRepository.swift`

```swift
import Foundation

actor InMemoryInvestmentRepository: InvestmentRepository {
  private var values: [UUID: InvestmentValue]

  init(initialValues: [InvestmentValue] = []) {
    self.values = Dictionary(uniqueKeysWithValues: initialValues.map { ($0.id, $0) })
  }

  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage {
    // Filter by accountId
    var result = Array(values.values).filter { $0.accountId == accountId }

    // Sort by date descending, then id for stability
    result.sort()

    // Paginate
    let offset = page * pageSize
    guard offset < result.count else {
      return InvestmentValuePage(values: [], hasMore: false)
    }
    let end = min(offset + pageSize, result.count)
    let pageValues = Array(result[offset..<end])
    let hasMore = end < result.count

    return InvestmentValuePage(values: pageValues, hasMore: hasMore)
  }

  func createValue(_ value: InvestmentValue) async throws -> InvestmentValue {
    values[value.id] = value
    return value
  }

  func deleteValue(id: UUID) async throws {
    guard values.removeValue(forKey: id) != nil else {
      throw BackendError.notFound
    }
  }

  // Test helper
  func setValues(_ values: [InvestmentValue]) {
    self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
  }
}
```

**Pagination Logic:**
- Sort by `date` descending (newest first), then `id` for stable ordering
- Return `hasMore: true` if there are more values beyond the current page
- Empty page returns `values: []` and `hasMore: false`

### 3.2 RemoteInvestmentRepository

**File:** `Backends/Remote/Repositories/RemoteInvestmentRepository.swift`

```swift
import Foundation
import OSLog

final class RemoteInvestmentRepository: InvestmentRepository, Sendable {
  private let client: APIClient
  private let logger = Logger(subsystem: "com.moolah.app", category: "RemoteInvestmentRepository")

  init(client: APIClient) {
    self.client = client
  }

  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage {
    let queryItems = [
      URLQueryItem(name: "account", value: accountId.uuidString),
      URLQueryItem(name: "pageSize", value: String(pageSize)),
      URLQueryItem(name: "offset", value: String(page * pageSize))
    ]

    let data = try await client.get("investment-values/", queryItems: queryItems)
    let wrapper = try JSONDecoder().decode(InvestmentValueDTO.ListWrapper.self, from: data)

    return InvestmentValuePage(
      values: wrapper.values.map { $0.toDomain() },
      hasMore: wrapper.hasMore
    )
  }

  func createValue(_ value: InvestmentValue) async throws -> InvestmentValue {
    let dto = CreateInvestmentValueDTO.fromDomain(value)
    let data = try await client.post("investment-values/", body: dto)
    let responseDTO = try JSONDecoder().decode(InvestmentValueDTO.self, from: data)
    return responseDTO.toDomain()
  }

  func deleteValue(id: UUID) async throws {
    _ = try await client.delete("investment-values/\(id.uuidString)/")
  }
}
```

**API Endpoints (moolah-server):**
- `GET /investment-values/?account={uuid}&pageSize={n}&offset={n}` → list values for an account
- `POST /investment-values/` → create a new value
- `DELETE /investment-values/{id}/` → delete a value by ID

### 3.3 InvestmentValueDTO

**File:** `Backends/Remote/DTOs/InvestmentValueDTO.swift`

```swift
import Foundation

struct InvestmentValueDTO: Codable {
  let id: String
  let accountId: String
  let date: String  // "YYYY-MM-DD"
  let value: Int     // Cents

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  func toDomain() -> InvestmentValue {
    let parsedDate = InvestmentValueDTO.dateFormatter.date(from: date) ?? Date()
    return InvestmentValue(
      id: FlexibleUUID.parse(id) ?? UUID(),
      accountId: FlexibleUUID.parse(accountId) ?? UUID(),
      date: parsedDate,
      value: MonetaryAmount(cents: value, currency: Currency.defaultCurrency)
    )
  }

  static func fromDomain(_ value: InvestmentValue) -> InvestmentValueDTO {
    let dateString = dateFormatter.string(from: value.date)
    return InvestmentValueDTO(
      id: value.id.uuidString,
      accountId: value.accountId.uuidString,
      date: dateString,
      value: value.value.cents
    )
  }

  struct ListWrapper: Codable {
    let values: [InvestmentValueDTO]
    let hasMore: Bool
  }
}

struct CreateInvestmentValueDTO: Codable {
  let accountId: String
  let date: String  // "YYYY-MM-DD"
  let value: Int     // Cents

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  static func fromDomain(_ value: InvestmentValue) -> CreateInvestmentValueDTO {
    let dateString = dateFormatter.string(from: value.date)
    return CreateInvestmentValueDTO(
      accountId: value.accountId.uuidString,
      date: dateString,
      value: value.value.cents
    )
  }
}
```

**Server Response Format:**

```json
{
  "values": [
    {
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "accountId": "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c",
      "date": "2024-03-15",
      "value": 12500000
    },
    {
      "id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
      "accountId": "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c",
      "date": "2024-02-15",
      "value": 12300000
    }
  ],
  "hasMore": false
}
```

### 3.4 Update RemoteBackend

**File:** `Backends/Remote/RemoteBackend.swift`

```diff
final class RemoteBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
+  let investments: any InvestmentRepository

  init(client: APIClient, authProvider: RemoteAuthProvider) {
    self.auth = authProvider
    self.accounts = RemoteAccountRepository(client: client)
    self.transactions = RemoteTransactionRepository(client: client)
    self.categories = RemoteCategoryRepository(client: client)
    self.earmarks = RemoteEarmarkRepository(client: client)
+    self.investments = RemoteInvestmentRepository(client: client)
  }
}
```

### 3.5 Update InMemoryBackend

**File:** `Backends/InMemory/InMemoryBackend.swift`

```diff
final class InMemoryBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
+  let investments: any InvestmentRepository

  init(
    accounts: [Account] = [],
    transactions: [Transaction] = [],
    categories: [Category] = [],
    earmarks: [Earmark] = [],
+    investmentValues: [InvestmentValue] = [],
    authProvider: InMemoryAuthProvider = InMemoryAuthProvider()
  ) {
    self.auth = authProvider
    self.accounts = InMemoryAccountRepository(initialAccounts: accounts)
    self.transactions = InMemoryTransactionRepository(initialTransactions: transactions)
    self.categories = InMemoryCategoryRepository(initialCategories: categories)
    self.earmarks = InMemoryEarmarkRepository(initialEarmarks: earmarks)
+    self.investments = InMemoryInvestmentRepository(initialValues: investmentValues)
  }
}
```

---

## 4. UI Components

### 4.1 InvestmentStore

**File:** `Features/Investments/InvestmentStore.swift`

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class InvestmentStore {
  private let backend: BackendProvider

  var values: [InvestmentValue] = []
  var hasMore = false
  var isLoading = false
  var error: Error?

  private var currentPage = 0
  private let pageSize = 50

  init(backend: BackendProvider) {
    self.backend = backend
  }

  func loadValues(accountId: UUID, reset: Bool = false) async {
    if reset {
      currentPage = 0
      values = []
    }

    guard !isLoading else { return }
    isLoading = true
    error = nil

    do {
      let page = try await backend.investments.fetchValues(
        accountId: accountId,
        page: currentPage,
        pageSize: pageSize
      )

      if reset {
        values = page.values
      } else {
        values.append(contentsOf: page.values)
      }

      hasMore = page.hasMore
      currentPage += 1
    } catch {
      self.error = error
    }

    isLoading = false
  }

  func createValue(_ value: InvestmentValue) async {
    do {
      let created = try await backend.investments.createValue(value)
      // Insert at the beginning (newest first)
      values.insert(created, at: 0)
    } catch {
      self.error = error
    }
  }

  func deleteValue(_ value: InvestmentValue) async {
    do {
      try await backend.investments.deleteValue(id: value.id)
      values.removeAll { $0.id == value.id }
    } catch {
      self.error = error
    }
  }
}
```

### 4.2 InvestmentValuesView

**File:** `Features/Investments/Views/InvestmentValuesView.swift`

```swift
import SwiftUI
import Charts

struct InvestmentValuesView: View {
  @Environment(BackendProvider.self) private var backend
  @State private var store: InvestmentStore

  let account: Account
  @State private var showingAddValue = false

  init(account: Account, backend: BackendProvider) {
    self.account = account
    _store = State(initialValue: InvestmentStore(backend: backend))
  }

  var body: some View {
    VStack(spacing: 0) {
      // Line chart showing value over time
      if !store.values.isEmpty {
        investmentChart
          .frame(height: 200)
          .padding()
      }

      Divider()

      // List of values
      List {
        ForEach(store.values) { value in
          InvestmentValueRow(value: value, onDelete: {
            Task {
              await store.deleteValue(value)
            }
          })
        }

        if store.hasMore {
          ProgressView()
            .frame(maxWidth: .infinity)
            .task {
              await store.loadValues(accountId: account.id)
            }
        }
      }
      .listStyle(.inset)
    }
    .navigationTitle(account.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingAddValue = true
        } label: {
          Label("Add Value", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $showingAddValue) {
      AddInvestmentValueView(account: account, store: store)
    }
    .task {
      await store.loadValues(accountId: account.id, reset: true)
    }
    .refreshable {
      await store.loadValues(accountId: account.id, reset: true)
    }
  }

  @ViewBuilder
  private var investmentChart: some View {
    Chart {
      ForEach(store.values.reversed()) { value in
        LineMark(
          x: .value("Date", value.date),
          y: .value("Value", value.value.cents)
        )
        .foregroundStyle(Color.blue)
        .interpolationMethod(.catmullRom)

        AreaMark(
          x: .value("Date", value.date),
          y: .value("Value", value.value.cents)
        )
        .foregroundStyle(Color.blue.opacity(0.1))
        .interpolationMethod(.catmullRom)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        if let cents = value.as(Int.self) {
          let amount = MonetaryAmount(cents: cents, currency: Currency.defaultCurrency)
          AxisValueLabel {
            Text(amount.formatted)
              .font(.caption)
              .monospacedDigit()
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks { value in
        if let date = value.as(Date.self) {
          AxisValueLabel {
            Text(date, format: .dateTime.month(.abbreviated).year())
              .font(.caption)
          }
        }
      }
    }
  }
}
```

### 4.3 InvestmentValueRow

**File:** `Features/Investments/Views/InvestmentValueRow.swift`

```swift
import SwiftUI

struct InvestmentValueRow: View {
  let value: InvestmentValue
  let onDelete: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(value.date, format: .dateTime.day().month().year())
          .font(.headline)
          .monospacedDigit()

        Text("Value")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text(value.value.formatted)
        .font(.headline)
        .monospacedDigit()
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .contextMenu {
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }
}
```

### 4.4 AddInvestmentValueView

**File:** `Features/Investments/Views/AddInvestmentValueView.swift`

```swift
import SwiftUI

struct AddInvestmentValueView: View {
  @Environment(\.dismiss) private var dismiss

  let account: Account
  let store: InvestmentStore

  @State private var date = Date()
  @State private var valueString = ""
  @State private var isSubmitting = false

  var canSubmit: Bool {
    guard let cents = parseCurrencyInput(valueString) else { return false }
    return cents >= 0 && !date.isFuture
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          DatePicker("Date", selection: $date, displayedComponents: .date)

          TextField("Value", text: $valueString)
            .keyboardType(.decimalPad)
            #if os(iOS)
            .autocorrectionDisabled()
            #endif
        } header: {
          Text("Investment Value")
        } footer: {
          if let cents = parseCurrencyInput(valueString) {
            Text("Value: \(MonetaryAmount(cents: cents, currency: Currency.defaultCurrency).formatted)")
              .monospacedDigit()
          }
        }
      }
      .navigationTitle("Add Value")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            Task {
              await submitValue()
            }
          }
          .disabled(!canSubmit || isSubmitting)
        }
      }
    }
  }

  private func submitValue() async {
    guard let cents = parseCurrencyInput(valueString) else { return }

    isSubmitting = true

    let value = InvestmentValue(
      accountId: account.id,
      date: date,
      value: MonetaryAmount(cents: cents, currency: Currency.defaultCurrency)
    )

    await store.createValue(value)

    isSubmitting = false
    dismiss()
  }

  private func parseCurrencyInput(_ input: String) -> Int? {
    let cleaned = input.replacingOccurrences(of: ",", with: "")
    guard let amount = Double(cleaned) else { return nil }
    return Int(amount * 100)
  }
}

extension Date {
  var isFuture: Bool {
    self > Date()
  }
}
```

### 4.5 Integration with AccountDetailView

**Location:** Currently, there is no `AccountDetailView` file found. This view will need to be created or the investment chart needs to be integrated into the existing account UI.

**Assuming future AccountDetailView exists:**

```swift
struct AccountDetailView: View {
  let account: Account
  @Environment(BackendProvider.self) private var backend

  var body: some View {
    if account.type == .investment {
      InvestmentValuesView(account: account, backend: backend)
    } else {
      // Existing account detail UI (transactions list, etc.)
      AccountTransactionsView(account: account)
    }
  }
}
```

**Alternative (if no AccountDetailView exists yet):**

Add a navigation link in `AccountRowView` or `SidebarView` that presents `InvestmentValuesView` when the account is an investment account.

---

## 5. Testing Strategy

### 5.1 Contract Tests

**File:** `MoolahTests/Domain/InvestmentRepositoryContractTests.swift`

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentRepository Contract")
struct InvestmentRepositoryContractTests {

  @Test(
    "Fetch values for account - returns sorted by date descending",
    arguments: [
      InMemoryInvestmentRepository(initialValues: makeTestInvestmentValues())
    ])
  func testFetchValuesSortedByDate(repository: InMemoryInvestmentRepository) async throws {
    let accountId = UUID(uuidString: "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c")!

    let page = try await repository.fetchValues(accountId: accountId, page: 0, pageSize: 50)

    #expect(page.values.count > 0)

    // Verify descending date order
    for i in 0..<(page.values.count - 1) {
      #expect(page.values[i].date >= page.values[i + 1].date)
    }
  }

  @Test(
    "Fetch values - pagination works correctly",
    arguments: [
      InMemoryInvestmentRepository(initialValues: makeTestInvestmentValues())
    ])
  func testPagination(repository: InMemoryInvestmentRepository) async throws {
    let accountId = UUID(uuidString: "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c")!

    // Fetch page 0 with pageSize 2
    let page0 = try await repository.fetchValues(accountId: accountId, page: 0, pageSize: 2)
    #expect(page0.values.count == 2)
    #expect(page0.hasMore == true)

    // Fetch page 1
    let page1 = try await repository.fetchValues(accountId: accountId, page: 1, pageSize: 2)
    #expect(page1.values.count > 0)

    // Values should not overlap
    let page0Ids = Set(page0.values.map(\.id))
    let page1Ids = Set(page1.values.map(\.id))
    #expect(page0Ids.intersection(page1Ids).isEmpty)
  }

  @Test(
    "Create value - returns created value with ID",
    arguments: [
      InMemoryInvestmentRepository()
    ])
  func testCreateValue(repository: InMemoryInvestmentRepository) async throws {
    let accountId = UUID()
    let value = InvestmentValue(
      accountId: accountId,
      date: Date(),
      value: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency)
    )

    let created = try await repository.createValue(value)

    #expect(created.id == value.id)
    #expect(created.accountId == accountId)
    #expect(created.value.cents == 100000)
  }

  @Test(
    "Delete value - removes value from storage",
    arguments: [
      InMemoryInvestmentRepository(initialValues: makeTestInvestmentValues())
    ])
  func testDeleteValue(repository: InMemoryInvestmentRepository) async throws {
    let values = makeTestInvestmentValues()
    let toDelete = values[0]

    try await repository.deleteValue(id: toDelete.id)

    // Verify it's gone
    let page = try await repository.fetchValues(
      accountId: toDelete.accountId,
      page: 0,
      pageSize: 50
    )
    #expect(!page.values.contains(where: { $0.id == toDelete.id }))
  }

  @Test(
    "Delete non-existent value - throws notFound",
    arguments: [
      InMemoryInvestmentRepository()
    ])
  func testDeleteNonExistent(repository: InMemoryInvestmentRepository) async throws {
    let randomId = UUID()

    await #expect(throws: BackendError.notFound) {
      try await repository.deleteValue(id: randomId)
    }
  }

  @Test(
    "Fetch empty account - returns empty page",
    arguments: [
      InMemoryInvestmentRepository()
    ])
  func testFetchEmptyAccount(repository: InMemoryInvestmentRepository) async throws {
    let randomAccountId = UUID()

    let page = try await repository.fetchValues(
      accountId: randomAccountId,
      page: 0,
      pageSize: 50
    )

    #expect(page.values.isEmpty)
    #expect(page.hasMore == false)
  }
}

// Test fixtures
private func makeTestInvestmentValues() -> [InvestmentValue] {
  let accountId = UUID(uuidString: "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c")!
  let calendar = Calendar.current

  return [
    InvestmentValue(
      id: UUID(),
      accountId: accountId,
      date: calendar.date(from: DateComponents(year: 2024, month: 3, day: 15))!,
      value: MonetaryAmount(cents: 12500000, currency: Currency.defaultCurrency)
    ),
    InvestmentValue(
      id: UUID(),
      accountId: accountId,
      date: calendar.date(from: DateComponents(year: 2024, month: 2, day: 15))!,
      value: MonetaryAmount(cents: 12300000, currency: Currency.defaultCurrency)
    ),
    InvestmentValue(
      id: UUID(),
      accountId: accountId,
      date: calendar.date(from: DateComponents(year: 2024, month: 1, day: 15))!,
      value: MonetaryAmount(cents: 12100000, currency: Currency.defaultCurrency)
    ),
    InvestmentValue(
      id: UUID(),
      accountId: accountId,
      date: calendar.date(from: DateComponents(year: 2023, month: 12, day: 15))!,
      value: MonetaryAmount(cents: 12000000, currency: Currency.defaultCurrency)
    ),
  ]
}
```

### 5.2 Remote Backend Tests

**File:** `MoolahTests/Backends/RemoteInvestmentRepositoryTests.swift`

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("RemoteInvestmentRepository")
struct RemoteInvestmentRepositoryTests {

  @Test("Fetch values - parses fixture JSON correctly")
  func testFetchValues() async throws {
    let mockClient = MockAPIClient(fixture: "investment_values.json")
    let repository = RemoteInvestmentRepository(client: mockClient)
    let accountId = UUID(uuidString: "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c")!

    let page = try await repository.fetchValues(accountId: accountId, page: 0, pageSize: 50)

    #expect(page.values.count == 3)
    #expect(page.hasMore == false)

    let first = page.values[0]
    #expect(first.accountId == accountId)
    #expect(first.value.cents == 12500000)
  }

  @Test("Create value - sends correct DTO")
  func testCreateValue() async throws {
    let mockClient = MockAPIClient(fixture: "investment_value_created.json")
    let repository = RemoteInvestmentRepository(client: mockClient)

    let accountId = UUID(uuidString: "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c")!
    let value = InvestmentValue(
      accountId: accountId,
      date: Date(),
      value: MonetaryAmount(cents: 13000000, currency: Currency.defaultCurrency)
    )

    let created = try await repository.createValue(value)

    #expect(created.accountId == accountId)
    #expect(created.value.cents == 13000000)
  }

  @Test("Delete value - calls correct endpoint")
  func testDeleteValue() async throws {
    let mockClient = MockAPIClient(fixture: nil)
    let repository = RemoteInvestmentRepository(client: mockClient)

    let valueId = UUID()
    try await repository.deleteValue(id: valueId)

    // Verify the delete request was made (test implementation detail depends on MockAPIClient)
  }
}
```

**Fixture:** `MoolahTests/Support/Fixtures/investment_values.json`

```json
{
  "values": [
    {
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "accountId": "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c",
      "date": "2024-03-15",
      "value": 12500000
    },
    {
      "id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
      "accountId": "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c",
      "date": "2024-02-15",
      "value": 12300000
    },
    {
      "id": "c3d4e5f6-a7b8-9012-cdef-123456789012",
      "accountId": "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c",
      "date": "2024-01-15",
      "value": 12100000
    }
  ],
  "hasMore": false
}
```

**Fixture:** `MoolahTests/Support/Fixtures/investment_value_created.json`

```json
{
  "id": "d4e5f6a7-b8c9-0123-defa-234567890123",
  "accountId": "76e3d2a4-56b1-4f9e-a89c-8c8d8b9a0b1c",
  "date": "2024-04-08",
  "value": 13000000
}
```

### 5.3 UI Tests

**File:** `MoolahTests/Features/InvestmentStoreTests.swift`

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentStore")
@MainActor
struct InvestmentStoreTests {

  @Test("Load values - populates values array")
  func testLoadValues() async throws {
    let values = makeTestInvestmentValues()
    let backend = InMemoryBackend(investmentValues: values)
    let store = InvestmentStore(backend: backend)

    let accountId = values[0].accountId
    await store.loadValues(accountId: accountId, reset: true)

    #expect(store.values.count > 0)
    #expect(store.isLoading == false)
    #expect(store.error == nil)
  }

  @Test("Create value - adds to list")
  func testCreateValue() async throws {
    let backend = InMemoryBackend()
    let store = InvestmentStore(backend: backend)

    let accountId = UUID()
    let value = InvestmentValue(
      accountId: accountId,
      date: Date(),
      value: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency)
    )

    await store.createValue(value)

    #expect(store.values.count == 1)
    #expect(store.values[0].id == value.id)
  }

  @Test("Delete value - removes from list")
  func testDeleteValue() async throws {
    let values = makeTestInvestmentValues()
    let backend = InMemoryBackend(investmentValues: values)
    let store = InvestmentStore(backend: backend)

    let accountId = values[0].accountId
    await store.loadValues(accountId: accountId, reset: true)

    let toDelete = store.values[0]
    await store.deleteValue(toDelete)

    #expect(!store.values.contains(where: { $0.id == toDelete.id }))
  }

  @Test("Pagination - loads more values")
  func testPagination() async throws {
    // Create 10 values
    let accountId = UUID()
    let values = (0..<10).map { i in
      InvestmentValue(
        id: UUID(),
        accountId: accountId,
        date: Calendar.current.date(byAdding: .day, value: -i, to: Date())!,
        value: MonetaryAmount(cents: 100000 + (i * 1000), currency: Currency.defaultCurrency)
      )
    }

    let backend = InMemoryBackend(investmentValues: values)
    let store = InvestmentStore(backend: backend)

    // Load first page (pageSize: 50 should get all)
    await store.loadValues(accountId: accountId, reset: true)
    #expect(store.values.count == 10)
  }
}

private func makeTestInvestmentValues() -> [InvestmentValue] {
  let accountId = UUID()
  return [
    InvestmentValue(
      accountId: accountId,
      date: Date(),
      value: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency)
    )
  ]
}
```

### 5.4 Edge Cases to Test

1. **Empty state** — account has no values recorded yet
2. **Single value** — chart renders correctly with one data point
3. **Large dataset** — pagination handles 100+ values
4. **Future date validation** — form prevents adding values with future dates
5. **Negative value validation** — form prevents negative investment values
6. **Network errors** — graceful error handling in UI
7. **Concurrent creates** — multiple values added rapidly (race conditions)

---

## 6. Acceptance Criteria

### 6.1 Domain & Backend

- [ ] `InvestmentValue` model defined with id, accountId, date, value
- [ ] `InvestmentRepository` protocol defined with fetchValues, createValue, deleteValue
- [ ] `BackendProvider` exposes `investments` property
- [ ] `InMemoryInvestmentRepository` implements repository protocol
- [ ] `RemoteInvestmentRepository` implements repository protocol
- [ ] Pagination works correctly (hasMore flag, offset calculation)
- [ ] Contract tests pass for both in-memory and remote backends

### 6.2 UI

- [ ] `InvestmentValuesView` displays a line chart of values over time
- [ ] Chart uses `LineMark` with area fill for visual appeal
- [ ] List shows all investment values sorted by date descending
- [ ] "Add Value" button opens a form sheet
- [ ] Form validates: date not in future, value >= 0
- [ ] Swipe-to-delete and context menu delete work on rows
- [ ] Pull-to-refresh reloads values
- [ ] Infinite scroll loads more values when reaching bottom
- [ ] Empty state shows helpful message ("No values recorded yet")
- [ ] Integration with `AccountDetailView` (or equivalent) for investment accounts

### 6.3 Testing

- [ ] Contract tests verify CRUD operations on both backends
- [ ] Pagination tests verify hasMore logic and non-overlapping pages
- [ ] Remote backend tests use fixture JSON
- [ ] UI store tests verify optimistic updates and error handling
- [ ] Edge cases tested: empty, single value, large dataset, validation failures

### 6.4 Documentation

- [ ] Code comments explain chart interpolation and pagination logic
- [ ] CLAUDE.md updated if new patterns introduced
- [ ] This plan archived in `plans/completed/` when done

---

## 7. Implementation Steps (TDD Order)

Follow strict Test-Driven Development: write the test file **before** the implementation file.

### Step 1: Domain Model
1. Create `MoolahTests/Domain/InvestmentValueTests.swift`
   - Test Comparable implementation (sort by date descending)
   - Test Codable round-trip
2. Create `Domain/Models/InvestmentValue.swift`
   - Implement InvestmentValue struct
   - Implement InvestmentValuePage struct
3. Run tests, verify they pass

### Step 2: Repository Protocol
1. Create `Domain/Repositories/InvestmentRepository.swift`
   - Define protocol with fetchValues, createValue, deleteValue
2. Update `Domain/Repositories/BackendProvider.swift`
   - Add `investments` property

### Step 3: InMemoryBackend Implementation
1. Create `MoolahTests/Domain/InvestmentRepositoryContractTests.swift`
   - Write all contract tests (fetch, pagination, create, delete, edge cases)
2. Create `Backends/InMemory/InMemoryInvestmentRepository.swift`
   - Implement actor with in-memory storage
   - Implement pagination logic
3. Run contract tests, verify they pass

### Step 4: RemoteBackend Implementation
1. Create `Backends/Remote/DTOs/InvestmentValueDTO.swift`
   - Implement DTO with toDomain/fromDomain
   - Implement CreateInvestmentValueDTO
   - Implement ListWrapper
2. Create `MoolahTests/Support/Fixtures/investment_values.json`
   - Add fixture data
3. Create `MoolahTests/Support/Fixtures/investment_value_created.json`
   - Add fixture data
4. Create `MoolahTests/Backends/RemoteInvestmentRepositoryTests.swift`
   - Test fetchValues parses JSON correctly
   - Test createValue sends correct DTO
   - Test deleteValue calls correct endpoint
5. Create `Backends/Remote/Repositories/RemoteInvestmentRepository.swift`
   - Implement using APIClient
6. Run remote backend tests, verify they pass

### Step 5: Update Backend Providers
1. Update `Backends/Remote/RemoteBackend.swift`
   - Add `investments` property initialization
2. Update `Backends/InMemory/InMemoryBackend.swift`
   - Add `investments` property initialization
3. Run all backend tests to ensure no regressions

### Step 6: Investment Store
1. Create `MoolahTests/Features/InvestmentStoreTests.swift`
   - Test loadValues populates array
   - Test createValue adds to list
   - Test deleteValue removes from list
   - Test pagination logic
2. Create `Features/Investments/InvestmentStore.swift`
   - Implement @Observable store
   - Implement load, create, delete methods
3. Run store tests, verify they pass

### Step 7: UI Components
1. Create `Features/Investments/Views/InvestmentValueRow.swift`
   - Implement row view with date, value, delete actions
2. Create `Features/Investments/Views/AddInvestmentValueView.swift`
   - Implement form with date picker, currency field, validation
3. Create `Features/Investments/Views/InvestmentValuesView.swift`
   - Implement chart using Swift Charts
   - Implement list with pagination
   - Wire up toolbar, sheets, refresh
4. Manual UI testing:
   - Open investment account
   - Add values
   - Verify chart updates
   - Delete values
   - Test pull-to-refresh
   - Test pagination with 20+ values

### Step 8: Integration with Account Detail
1. Update or create `AccountDetailView.swift` (or equivalent)
   - Conditionally show `InvestmentValuesView` when `account.type == .investment`
2. Update navigation in `SidebarView` or `AccountRowView`
   - Link to investment detail view
3. Manual testing:
   - Navigate to investment account
   - Verify chart and list appear
   - Create/delete values
   - Verify UI updates correctly

### Step 9: UI Polish
1. Run `ui-review` agent on `InvestmentValuesView`
   - Address accessibility issues
   - Verify VoiceOver labels
   - Check color contrast
   - Verify Dynamic Type support
2. Test on macOS and iOS
   - Verify chart renders correctly on both platforms
   - Test keyboard navigation (macOS)
   - Test touch interactions (iOS)
3. Test edge cases:
   - Empty state
   - Single value (chart with one point)
   - Large dataset (100+ values)

### Step 10: Documentation & Cleanup
1. Add code comments to complex logic (chart config, pagination)
2. Update CLAUDE.md if new patterns introduced
3. Run `just test` to verify all tests pass
4. Commit with descriptive message

---

## 8. moolah-server API Specification

The following endpoints need to exist in `moolah-server` for `RemoteInvestmentRepository` to function. If they don't exist yet, they must be implemented server-side before this step can be completed.

### GET /investment-values/

**Query Parameters:**
- `account` (required): UUID string
- `pageSize` (optional): integer, default 50
- `offset` (optional): integer, default 0

**Response (200 OK):**
```json
{
  "values": [
    {
      "id": "uuid-string",
      "accountId": "uuid-string",
      "date": "YYYY-MM-DD",
      "value": 12500000
    }
  ],
  "hasMore": false
}
```

**Errors:**
- `400 Bad Request` — missing or invalid account parameter
- `404 Not Found` — account does not exist
- `500 Internal Server Error` — database error

### POST /investment-values/

**Request Body:**
```json
{
  "accountId": "uuid-string",
  "date": "YYYY-MM-DD",
  "value": 12500000
}
```

**Response (201 Created):**
```json
{
  "id": "uuid-string",
  "accountId": "uuid-string",
  "date": "YYYY-MM-DD",
  "value": 12500000
}
```

**Errors:**
- `400 Bad Request` — validation failure (missing field, negative value, future date)
- `404 Not Found` — account does not exist or is not an investment account
- `500 Internal Server Error` — database error

### DELETE /investment-values/{id}/

**Path Parameters:**
- `id`: UUID string

**Response (204 No Content)**

**Errors:**
- `404 Not Found` — value does not exist
- `500 Internal Server Error` — database error

### Server-Side Validation

The server should enforce:
- `accountId` must reference an existing account with `type = 'investment'`
- `date` must be a valid date in `YYYY-MM-DD` format
- `date` must not be in the future
- `value` must be >= 0 (non-negative integer in cents)
- `id` is auto-generated (UUID v4)

### Database Schema (suggested)

If not already present in `moolah-server/db/patches/`:

```sql
CREATE TABLE investment_values (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  value INTEGER NOT NULL CHECK (value >= 0),
  created_at TIMESTAMP DEFAULT NOW(),
  UNIQUE (account_id, date)
);

CREATE INDEX idx_investment_values_account_id ON investment_values(account_id);
CREATE INDEX idx_investment_values_date ON investment_values(date DESC);
```

**Note:** The `UNIQUE (account_id, date)` constraint ensures only one value per day per account. If multiple values per day are desired, remove this constraint.

---

## 9. Future Enhancements (Out of Scope)

The following features are **not** included in this step but could be added later:

1. **Performance Metrics**
   - Calculate and display annualized return percentage
   - Show total gain/loss since first entry
   - Display performance vs. benchmark (e.g., S&P 500)

2. **Import from CSV**
   - Allow users to upload CSV files with historical values
   - Parse and bulk-insert values

3. **Export to CSV**
   - Export all values for an account to CSV

4. **Editable Values**
   - Add "Edit" action to modify date or value of existing entries
   - Requires `updateValue(_:)` method in repository

5. **Charts Customization**
   - Toggle between line chart and bar chart
   - Adjust date range (1 month, 3 months, 1 year, all time)
   - Display percentage change instead of absolute values

6. **Multiple Accounts Comparison**
   - Overlay multiple investment accounts on the same chart
   - Show aggregate portfolio value

7. **Notifications**
   - Remind user to record investment values monthly

8. **Auto-Fetch from APIs**
   - Integrate with brokerage APIs to automatically fetch values
   - This would require OAuth flows and third-party integrations

---

## 10. Dependencies & Blockers

### Prerequisites
- moolah-server must implement investment value endpoints (see section 8)
- Database migration must be applied
- Server-side validation must be in place

### Parallel Work
- This step can be developed in parallel with other steps as long as the backend endpoints are stubbed or mocked

### No Blockers
- All domain models and patterns already exist in the codebase
- Swift Charts is available in iOS 26+ and macOS 26+
- No new external dependencies required

---

## 11. Summary

This plan provides a comprehensive, test-driven roadmap for implementing investment tracking in moolah-native. The feature enables users to manually record investment account values over time and visualize performance through a native Swift Charts line graph.

**Key Design Decisions:**
- **Pagination:** 50 values per page (configurable)
- **Sorting:** Date descending (newest first)
- **Validation:** No future dates, no negative values
- **UI Integration:** Conditional view in AccountDetailView based on account type
- **Chart Library:** Swift Charts (native, zero dependencies)

**Estimated Effort:** 12 hours (6 hours backend + 4 hours UI + 2 hours testing & polish)

**Definition of Done:**
- All contract tests pass
- Remote backend tests pass with fixture JSON
- UI renders correctly on macOS and iOS
- Pull-to-refresh and pagination work
- Chart displays correctly with 1, 10, and 100+ values
- VoiceOver accessibility verified
- Code reviewed for style guide compliance

---

**End of Implementation Plan**
