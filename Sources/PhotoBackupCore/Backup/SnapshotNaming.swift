import Foundation

/// Zeitstempel-basierte Snapshot-Ordnernamen, kompatibel zum bisherigen
/// `backup-external.sh`-Schema (`yyyy-MM-dd_HH-mm-ss`). String-Sortierung
/// dieses Formats entspricht chronologischer Sortierung — darauf verlassen
/// sich `previousSnapshot(in:)` und die Retention-Logik.
public enum SnapshotNaming {
    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }

    private static let namePattern = try! NSRegularExpression(
        pattern: "^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}$"
    )

    public static func timestampString(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }

    public static func parseTimestamp(_ name: String, timeZone: TimeZone = .current) -> Date? {
        formatter(timeZone: timeZone).date(from: name)
    }

    private static func matchesNamingScheme(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return namePattern.firstMatch(in: name, range: range) != nil
    }

    /// Marker-Datei, die `BackupEngine` erst nach erfolgreichem Abschluss eines Laufs anlegt.
    /// Unterscheidet ein vollständiges Abbild von einem abgebrochenen/unterbrochenen Snapshot,
    /// dessen Ordner zwar existiert, aber nur einen Teil der Quelle enthält.
    public static let completionMarkerFileName = ".complete"

    public static func isComplete(_ snapshotPath: String, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: (snapshotPath as NSString).appendingPathComponent(completionMarkerFileName))
    }

    /// Listet alle gültigen Snapshot-Verzeichnisse in `targetDir`, aufsteigend nach Datum.
    /// Verzeichnisse, deren Name nicht dem Zeitstempel-Schema entspricht, werden ignoriert.
    public static func snapshots(in targetDir: String, fileManager: FileManager = .default) -> [SnapshotInfo] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: targetDir) else {
            return []
        }
        return entries
            .filter(matchesNamingScheme)
            .compactMap { name -> SnapshotInfo? in
                guard let date = parseTimestamp(name) else { return nil }
                let path = (targetDir as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return nil
                }
                return SnapshotInfo(name: name, date: date, path: path)
            }
            .sorted { $0.date < $1.date }
    }

    /// Wie `snapshots(in:)`, aber nur vollständige Läufe — Basis für `--link-dest` und
    /// die Aufbewahrungs-Zählung, damit ein abgebrochener Lauf nie als gültiger Snapshot zählt.
    public static func completeSnapshots(in targetDir: String, fileManager: FileManager = .default) -> [SnapshotInfo] {
        snapshots(in: targetDir, fileManager: fileManager).filter { isComplete($0.path, fileManager: fileManager) }
    }

    /// Snapshot-Ordner, die existieren, aber nie fertig wurden (abgebrochen oder die App/der
    /// Rechner wurde währenddessen beendet) — werden vor dem nächsten Lauf entfernt.
    public static func incompleteSnapshots(in targetDir: String, fileManager: FileManager = .default) -> [SnapshotInfo] {
        let completeNames = Set(completeSnapshots(in: targetDir, fileManager: fileManager).map(\.name))
        return snapshots(in: targetDir, fileManager: fileManager).filter { !completeNames.contains($0.name) }
    }

    /// Der jüngste vollständige Snapshot — Ziel für `--link-dest` des nächsten Laufs.
    public static func previousSnapshot(in targetDir: String, fileManager: FileManager = .default) -> SnapshotInfo? {
        completeSnapshots(in: targetDir, fileManager: fileManager).last
    }
}
