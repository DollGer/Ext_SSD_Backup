import Foundation

public struct BackupProgress: Equatable, Sendable {
    public var currentFile: String?
    public var percentOfFile: Int?
    public var overallPercentEstimate: Double?

    public init(currentFile: String? = nil, percentOfFile: Int? = nil, overallPercentEstimate: Double? = nil) {
        self.currentFile = currentFile
        self.percentOfFile = percentOfFile
        self.overallPercentEstimate = overallPercentEstimate
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
