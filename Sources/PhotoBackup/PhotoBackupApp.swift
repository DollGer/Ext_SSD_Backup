import SwiftUI
import AppKit
import Combine
import PhotoBackupCore
import UserNotifications

/// Besitzt die eine, kanonische `AppState`-Instanz. Absichtlich hier statt als
/// `@StateObject` in `PhotoBackupApp` verwaltet: Ein `@StateObject`, dessen
/// `wrappedValue` (hier über `start()`) bereits im `App`-`init()` angesprochen wird,
/// kann dazu führen, dass SwiftUI eine zweite, von der eigentlichen View-Hierarchie
/// losgelöste Instanz erzeugt — deren Zustand (z.B. `driveMounted`) nie mit dem
/// tatsächlich angezeigten synchron ist. Der `NSApplicationDelegateAdaptor` hat
/// dieses Problem nicht: seine Instanz ist von Anfang an stabil.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    private var forwardChange: AnyCancellable?

    override init() {
        super.init()
        forwardChange = appState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        appState.start()
    }
}

@main
struct PhotoBackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("PhotoBackup", systemImage: statusIconName) {
            MenuBarView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.appState.settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.appState.settings)
                .frame(width: 520, height: 480)
        }
        // Ohne das versucht die TabView, die Fenstergröße pro Tab an dessen Inhalt anzupassen —
        // dabei schrumpft sie beim Wechsel zuverlässig, wächst aber beim Zurückwechseln nicht
        // wieder (bekannter SwiftUI-Bug). Feste Größe umgeht das komplett.
        .windowResizability(.contentSize)
    }

    private var statusIconName: String {
        let appState = appDelegate.appState
        if appState.backupInProgress {
            return "arrow.triangle.2.circlepath"
        } else if appState.canStartBackup {
            return "externaldrive.badge.checkmark"
        } else {
            return "externaldrive.badge.xmark"
        }
    }
}
