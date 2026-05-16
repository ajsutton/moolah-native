import Testing

@testable import Moolah

@MainActor
struct TransactionScrollCollapseTests {
  @Test
  func startsExpanded() {
    let model = TransactionScrollCollapse()
    #expect(model.isCollapsed == false)
  }

  @Test
  func collapsesAfterScrollingPastThreshold() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 10)
    #expect(model.isCollapsed == false)  // 10 < collapseThreshold (44) → no state change
    model.update(offsetY: 60)  // > 44
    #expect(model.isCollapsed == true)
  }

  @Test
  func staysCollapsedWhileScrollingInTheMiddle() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 60)
    #expect(model.isCollapsed == true)
    model.update(offsetY: 30)  // above expandThreshold, below collapse
    #expect(model.isCollapsed == true)  // no mid-list re-expansion
    model.update(offsetY: 200)
    #expect(model.isCollapsed == true)
  }

  @Test
  func reExpandsOnlyWhenBackAtTop() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 300)
    #expect(model.isCollapsed == true)
    model.update(offsetY: 0)
    #expect(model.isCollapsed == false)
  }

  @Test
  func overscrollBounceCountsAsTop() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 300)
    model.update(offsetY: -8)  // rubber-band bounce at top
    #expect(model.isCollapsed == false)
  }

  @Test
  func resetReturnsToExpanded() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 300)
    #expect(model.isCollapsed == true)
    model.reset()
    #expect(model.isCollapsed == false)
  }
}
