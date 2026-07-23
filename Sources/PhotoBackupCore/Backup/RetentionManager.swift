import Foundation

/// Bestimmt und entfernt alte Snapshots gemäß der konfigurierten Aufbewahrungs-Policy.
///
/// Da jede unveränderte Datei in einem Snapshot ein Hardlink auf dieselbe Inode wie im
/// Vorgänger-Snapshot ist (siehe `BackupEngine`, `--link-dest`), ist das Löschen einzelner
/// Snapshot-Verzeichnisse in beliebiger Reihenfolge immer sicher: jeder Verzeichniseintrag
/// ist eine unabhängige Referenz, die zugrunde liegenden Daten werden erst frei, wenn der
/// letzte Link auf sie entfernt wurde. Es gibt daher keine "Kette", die brechen könnte.
public enum RetentionManager {
    /// Reine Auswahl-Logik ohne I/O — einfach testbar.
    /// Der jeweils neueste Snapshot wird nie zur Löschung vorgeschlagen, unabhängig von der
    /// Policy, damit eine (fehl-)konfigurierte Policy nie den gerade erstellten oder einzig
    /// vorhandenen Snapshot entfernt.
    public static func snapshotsToDelete(
        _ snapshots: [SnapshotInfo],
        policy: RetentionPolicy,
        now: Date = Date()
    ) -> [SnapshotInfo] {
        guard snapshots.count > 1 else { return [] }

        let sortedAscending = snapshots.sorted { $0.date < $1.date }
        // Der letzte Eintrag ist der neueste Snapshot und wird nie zur Löschung vorgeschlagen.
        let candidates = sortedAscending.dropLast()

        switch policy {
        case .unlimited:
            return []

        case .count(let keep):
            let keepCount = max(keep, 1)
            let toKeepFromCandidates = max(keepCount - 1, 0)
            // Behalte die (keepCount - 1) jüngsten Kandidaten, lösche die älteren.
            return Array(candidates.dropLast(toKeepFromCandidates))

        case .age(let days):
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            return candidates.filter { $0.date < cutoff }
        }
    }

    /// I/O-Wrapper: berechnet die zu löschenden Snapshots und entfernt sie vom Dateisystem.
    /// Wird nur nach einem *erfolgreichen* Backup-Lauf aufgerufen.
    @discardableResult
    public static func prune(
        targetDir: String,
        policy: RetentionPolicy,
        fileManager: FileManager = .default,
        onDelete: ((SnapshotInfo) -> Void)? = nil
    ) -> [SnapshotInfo] {
        let all = SnapshotNaming.snapshots(in: targetDir, fileManager: fileManager)
        let victims = snapshotsToDelete(all, policy: policy)
        for victim in victims {
            try? fileManager.removeItem(atPath: victim.path)
            onDelete?(victim)
        }
        return victims
    }
}
