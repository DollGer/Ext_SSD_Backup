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
                label: settings.sourceVolumeName,
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
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(phaseLabel)
                            Spacer()
                            Text(filesCounterText)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let overall = appState.currentProgress?.overallPercentEstimate {
                            ProgressView(value: overall)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }

                    Text(appState.currentProgress?.currentFile ?? phaseDetailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

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

    private var phaseLabel: String {
        switch appState.currentProgress?.phase {
        case .cleaningUp: return "Räume auf…"
        case .scanning: return "Scanne…"
        case .transferring, nil: return "Gesamtfortschritt"
        }
    }

    private var phaseDetailText: String {
        switch appState.currentProgress?.phase {
        case .cleaningUp: return "Entferne unvollständigen Snapshot vom letzten Abbruch…"
        case .scanning: return "Ermittle Dateianzahl…"
        case .transferring, nil: return "Ermittle Dateien…"
        }
    }

    private var filesCounterText: String {
        guard let progress = appState.currentProgress else { return "" }
        if let total = progress.totalFiles {
            let percent = Int(((progress.overallPercentEstimate ?? 0) * 100).rounded())
            return "\(progress.filesProcessed)/\(total) (\(percent)%)"
        } else {
            return "\(progress.filesProcessed) Dateien"
        }
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
