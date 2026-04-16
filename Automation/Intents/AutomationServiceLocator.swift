import Foundation

/// Static accessor for App Intents to reach the app's AutomationService.
/// App Intents are instantiated by the system and cannot use dependency injection,
/// so this service locator bridges the gap. Set during app initialization.
@MainActor
final class AutomationServiceLocator {
  static let shared = AutomationServiceLocator()
  var service: AutomationService?
  private init() {}
}
