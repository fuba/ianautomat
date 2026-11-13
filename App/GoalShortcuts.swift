import AppIntents
import Foundation

struct OpenGoalIntent: AppIntent {
    static let title: LocalizedStringResource = "Open goal composer"
    static let description = IntentDescription("Open the goal composer in ianautomat.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct LatestGoalLogIntent: AppIntent {
    static let title: LocalizedStringResource = "Get latest goal log"
    static let description = IntentDescription("Return the latest goal log as text for another shortcut action.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try Workspace.local.load().first?.transcript ?? "")
    }
}

struct GoalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenGoalIntent(), phrases: [
            "Open a goal in \(.applicationName)"
        ], shortTitle: "Open goal", systemImageName: "scope")
    }
}
