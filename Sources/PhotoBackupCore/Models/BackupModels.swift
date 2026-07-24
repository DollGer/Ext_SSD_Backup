import Foundation

/// Grobe Phasen eines Laufs — insbesondere wichtig, weil das Aufräumen alter Snapshot-Ordner
/// und der Vorab-Scan über einen langsamen/gestörten NAS-Mount unbestimmt lange dauern können,
/// ohne dass sich `filesProcessed` schon bewegt. Ohne diese Unterscheidung sieht ein UI, das nur
/// "0 von ? Dateien" zeigt, identisch aus, egal ob gerade wirklich nichts passiert oder ob noch
/// vorbereitet wird.
public enum BackupPhase: Equatable, Sendable {
    case cleaningUp
    case scanning
    case transferring
}

/// `totalFiles` stammt aus einem `--dry-run`-Vorab-Scan (siehe `BackupEngine`), da Apples
/// `openrsync` keine Gesamtzahl vorab kennt und pro Datei erst nach deren Abschluss überhaupt
/// eine Zeile ausgibt — unveränderte, nur hartverlinkte Dateien lösen sonst keine Prozent-
/// Zwischenwerte aus. `overallPercentEstimate` ist entsprechend `nil`, solange kein
/// Vorab-Scan-Ergebnis vorliegt.
public struct BackupProgress: Equatable, Sendable {
    public var phase: BackupPhase
    public var currentFile: String?
    public var filesProcessed: Int
    public var totalFiles: Int?

    public init(phase: BackupPhase, currentFile: String? = nil, filesProcessed: Int = 0, totalFiles: Int? = nil) {
        self.phase = phase
        self.currentFile = currentFile
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
    }

    public var overallPercentEstimate: Double? {
        guard let totalFiles, totalFiles > 0 else { return nil }
        return min(Double(filesProcessed) / Double(totalFiles), 1)
    }
}

public enum BackupResult: Equatable, Sendable {
    case success(snapshotPath: String, filesTransferred: Int, duration: TimeInterval)
    case failure(message: String)
    case cancelled
}

public enum BackupTrigger: Sendable {
    case manual
    case automatic
}

public struct SnapshotInfo: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let date: Date
    public let path: String

    public init(name: String, date: Date, path: String) {
        self.name = name
        self.date = date
        self.path = path
    }
}

public enum RetentionMode: String, CaseIterable, Sendable {
    case unlimited
    case count
    case age
}

public enum RetentionPolicy: Equatable, Sendable {
    case unlimited
    case count(Int)
    case age(days: Int)
}

public enum SMBMountError: Error, LocalizedError, Sendable {
    case mountFailed(String)

    public var errorDescription: String? {
        switch self {
        case .mountFailed(let message):
            return "NAS-Share konnte nicht eingebunden werden: \(message)"
        }
    }
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "NAS-Passwort konnte nicht gespeichert werden (Status \(status))."
        case .readFailed(let status):
            return "NAS-Passwort konnte nicht gelesen werden (Status \(status))."
        case .deleteFailed(let status):
            return "NAS-Passwort konnte nicht gelöscht werden (Status \(status))."
        }
    }
}

public enum BackupEngineError: Error, LocalizedError, Sendable {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "rsync konnte nicht gestartet werden: \(message)"
        }
    }
}
