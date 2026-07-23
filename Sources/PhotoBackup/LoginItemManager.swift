import Foundation
import ServiceManagement

/// Registriert/entfernt PhotoBackup als Login-Objekt via `SMAppService`.
/// Ersetzt den bisherigen immer geladenen launchd-Agent — die App startet
/// künftig sich selbst beim Login statt über einen separaten Cron-Job.
enum LoginItemManager {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("LoginItemManager: konnte Login-Objekt-Status nicht ändern: \(error)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
