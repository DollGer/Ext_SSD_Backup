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

            StatusRow(
                label: "Externe Platte",
                ok: appState.driveMounted,
                okText: "verbunden",
                notOkText: "getrennt"
            )
            StatusRow(
                label: "NAS",
                ok: appState.nasReachable,
                okText: "erreichbar",
                notOkText: "nicht erreichbar"
            )

            if appState.backupInProgress {
                VStack(alignment: .leading, spacing: 4) {
                    if let file = appState.currentProgress?.currentFile {
                        Text(file)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ProgressView(value: appState.currentProgress?.overallPercentEstimate ?? 0)
                    Button("Backup abbrechen") {
                        appState.cancelBackup()
                    }
                }
            } else {
                Button("Backup jetzt starten") {
                    Task { await appState.startBackup(trigger: .manual) }
                }
                .disabled(!appState.canStartBackup)

                if let result = appState.lastBackupResult {
                    Text(summary(for: result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Automatisches Backup", isOn: $settings.autoBackupEnabled)

            Divider()

            SettingsLink {
                Text("Einstellungen…")
            }

            Button("Beenden") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func summary(for result: BackupResult) -> String {
        switch result {
        case .success(_, let filesTransferred, _):
            return "Letztes Backup: \(filesTransferred) Dateien übertragen."
        case .failure(let message):
            return "Letztes Backup fehlgeschlagen: \(message)"
        case .cancelled:
            return "Letztes Backup abgebrochen."
        }
    }
}
