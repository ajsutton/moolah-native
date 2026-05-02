/// SF Symbol used for an account in the sidebar and in account-selection
/// pickers. Keep this mapping in one place so the sidebar and the pickers
/// stay in sync.
extension Account {
  var sidebarIcon: String {
    switch type {
    case .bank: return "building.columns"
    case .asset: return "house.fill"
    case .creditCard: return "creditcard"
    case .investment: return "chart.line.uptrend.xyaxis"
    }
  }
}
