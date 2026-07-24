import SwiftUI
import AppKit
import PhotoBackupCore

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PhotoBackup")
                .font(.headline)

            BackupStatusView()

            Toggle("Automatisches Backup", isOn: $settings.autoBackupEnabled)

            Divider()

            HStack {
                SettingsLink {
                    Text("Einstellungen…")
                }
                Spacer()
                Button("Beenden") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 280)
    }
}
