import Foundation

/// Schreibt eine einfache, dauerhafte Ereignis-Historie nach
/// `~/Library/Logs/PhotoBackup/backup.log`. Grund: `AppState.lastBackupResult`/
/// `lastErrorMessage` leben nur im Speicher und sind nach einem Neustart (App-Neustart,
/// Mac-Neustart, Schlaf-Unterbrechung mitten im Lauf) unwiederbringlich weg — bei der
/// Diagnose vergangener Läufe gab es deshalb wiederholt keine verlässliche Quelle mehr,
/// nur indirekte Rückschlüsse aus Prozess-Status und Dateisystem-Zeitstempeln.
///
/// Bewusst nur grobe Ereignisse (Start, Phasenwechsel, Ergebnis) statt einer Zeile pro
/// Datei — bei Zehntausenden Dateien pro Lauf wäre Letzteres selbst schnell unlesbar groß.
public enum BackupLogger {
    private static let maxFileSizeBytes = 2_000_000

    public static var logFileURL: URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PhotoBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("backup.log")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func log(_ message: String, to url: URL = BackupLogger.logFileURL) {
        let line = "[\(dateFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded(at: url)
    }

    /// Hält die Datei bei Bedarf klein: bei Überschreiten der Grenze wird auf die jüngere
    /// Hälfte gekürzt statt unbegrenzt zu wachsen.
    private static func trimIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              size > maxFileSizeBytes,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let keep = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? keep.write(to: url, atomically: true, encoding: .utf8)
    }
}
