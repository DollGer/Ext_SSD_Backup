import SwiftUI
import PhotoBackupCore
import UserNotifications

@main
struct PhotoBackupApp: App {
    @StateObject private var appState = AppState()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        appState.start()
    }

    var body: some Scene {
        MenuBarExtra("PhotoBackup", systemImage: statusIconName) {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .frame(minWidth: 480, minHeight: 420)
        }
    }

    private var statusIconName: String {
        if appState.backupInProgress {
            return "arrow.triangle.2.circlepath"
        } else if appState.canStartBackup {
            return "externaldrive.badge.checkmark"
        } else {
            return "externaldrive.badge.xmark"
        }
    }
}
