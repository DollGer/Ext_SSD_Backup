import SwiftUI
import AppKit
import PhotoBackupCore

/// Gemeinsamer Status-/Fortschrittsblock für Menüleisten-Dropdown und den
/// "Status"-Tab in den Einstellungen — an beiden Stellen identisch, damit man
/// wahlweise das Dropdown kurz öffnet oder die Einstellungen offen lässt, um
/// den Fortschritt nebenbei mitlaufen zu sehen.
struct BackupStatusView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                VStack(alignment: .leading, spacing: 12) {
                    // Balken 1: aktuelle Datei. Kein echter Prozentwert möglich (openrsync
                    // meldet eine Datei erst nach Abschluss, nie währenddessen) — daher bewusst
                    // unbestimmt statt eines erfundenen Werts.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.currentProgress?.currentFile ?? phaseDetailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    // Balken 2: Gesamtfortschritt mit echtem Prozentwert (aus dem Vorab-Scan)
                    // und geschätzter Restdauer.
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
                        if let etaText {
                            Text("Verbleibend: \(etaText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Backup abbrechen") {
                        appState.cancelBackup()
                    }
                }
            } else {
                Button("Backup jetzt starten") {
                    // Ohne das kann das Fenster beim Start (z.B. während des NAS-Mountens)
                    // in den Hintergrund rutschen und wirkt dann, als hätte der Klick nichts
                    // bewirkt.
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await appState.startBackup(trigger: .manual) }
                }
                .disabled(!appState.canStartBackup)

                if let result = appState.lastBackupResult {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: resultIcon(for: result))
                            .foregroundStyle(resultColor(for: result))
                        Text(summary(for: result))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var phaseLabel: String {
        switch appState.currentProgress?.phase {
        case .scanning: return "Scanne…"
        case .transferring, nil: return "Gesamtfortschritt"
        }
    }

    private var phaseDetailText: String {
        switch appState.currentProgress?.phase {
        case .scanning: return "Ermittle Dateianzahl…"
        case .transferring, nil: return "Ermittle Dateien…"
        }
    }

    /// Schätzung auf Basis der bisherigen Rate (verarbeitete Dateien pro Sekunde seit
    /// Beginn der eigentlichen Übertragung). Grobe Näherung, da Dateigrößen stark streuen
    /// können — bewusst nur als Anhaltspunkt formatiert, nicht als exakte Uhrzeit.
    private var etaText: String? {
        guard let progress = appState.currentProgress,
              progress.phase == .transferring,
              let total = progress.totalFiles, total > 0,
              progress.filesProcessed > 0,
              let startDate = appState.transferStartDate else { return nil }

        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 0 else { return nil }
        let rate = Double(progress.filesProcessed) / elapsed
        guard rate > 0 else { return nil }
        let remainingFiles = total - progress.filesProcessed
        guard remainingFiles > 0 else { return nil }
        let remainingSeconds = Double(remainingFiles) / rate

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: remainingSeconds)
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

    private func resultIcon(for result: BackupResult) -> String {
        switch result {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    private func resultColor(for result: BackupResult) -> Color {
        switch result {
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .secondary
        }
    }

    private func summary(for result: BackupResult) -> String {
        switch result {
        case .success(let filesTransferred, _):
            return "Letztes Backup: \(filesTransferred) Dateien übertragen."
        case .failure(let message):
            return "Letztes Backup fehlgeschlagen: \(message)"
        case .cancelled:
            return "Letztes Backup abgebrochen."
        }
    }
}
