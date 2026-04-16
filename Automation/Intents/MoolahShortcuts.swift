import AppIntents

struct MoolahShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: GetNetWorthIntent(),
      phrases: ["What's my net worth in \(.applicationName)?"],
      shortTitle: "Net Worth",
      systemImageName: "chart.line.uptrend.xyaxis"
    )
    AppShortcut(
      intent: ListAccountsIntent(),
      phrases: ["Show my balances in \(.applicationName)"],
      shortTitle: "Account Balances",
      systemImageName: "list.bullet"
    )
    AppShortcut(
      intent: CreateTransactionIntent(),
      phrases: ["Add a transaction in \(.applicationName)"],
      shortTitle: "Add Transaction",
      systemImageName: "plus.circle"
    )
    AppShortcut(
      intent: GetAccountBalanceIntent(),
      phrases: ["What's my \(\.$account) balance in \(.applicationName)?"],
      shortTitle: "Account Balance",
      systemImageName: "dollarsign.circle"
    )
    AppShortcut(
      intent: GetEarmarkBalanceIntent(),
      phrases: ["How much is in \(\.$earmark) in \(.applicationName)?"],
      shortTitle: "Earmark Balance",
      systemImageName: "bookmark"
    )
    AppShortcut(
      intent: GetExpenseBreakdownIntent(),
      phrases: ["What did I spend this month in \(.applicationName)?"],
      shortTitle: "Monthly Spending",
      systemImageName: "chart.pie"
    )
    AppShortcut(
      intent: GetRecentTransactionsIntent(),
      phrases: ["Show my recent transactions in \(.applicationName)"],
      shortTitle: "Recent Transactions",
      systemImageName: "clock"
    )
  }
}
