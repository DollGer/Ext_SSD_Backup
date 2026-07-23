import Foundation
import Combine

/// Zentraler, beobachtbarer Settings-Speicher über `UserDefaults`. Bewusst nicht
/// als `@AppStorage` pro View umgesetzt, damit auch Nicht-View-Code
/// (`BackupScheduler`, `AppState`) lesend und beobachtend zugreifen kann.
/// Defaults entsprechen dem bestehenden `backup-external.sh`/launchd-Setup,
/// damit die Migration ohne Konfigurationsaufwand funktioniert.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var sourceVolumeName: String {
        didSet { defaults.set(sourceVolumeName, forKey: Keys.sourceVolumeName) }
    }
    @Published public var nasHost: String {
        didSet { defaults.set(nasHost, forKey: Keys.nasHost) }
    }
    @Published public var nasShare: String {
        didSet { defaults.set(nasShare, forKey: Keys.nasShare) }
    }
    @Published public var nasUser: String {
        didSet { defaults.set(nasUser, forKey: Keys.nasUser) }
    }
    @Published public var nasMountPoint: String {
        didSet { defaults.set(nasMountPoint, forKey: Keys.nasMountPoint) }
    }
    @Published public var targetSubpath: String {
        didSet { defaults.set(targetSubpath, forKey: Keys.targetSubpath) }
    }
    @Published public var autoBackupEnabled: Bool {
        didSet { defaults.set(autoBackupEnabled, forKey: Keys.autoBackupEnabled) }
    }
    @Published public var autoBackupIntervalHours: Double {
        didSet { defaults.set(autoBackupIntervalHours, forKey: Keys.autoBackupIntervalHours) }
    }
    @Published public var retentionMode: RetentionMode {
        didSet { defaults.set(retentionMode.rawValue, forKey: Keys.retentionMode) }
    }
    @Published public var retentionCount: Int {
        didSet { defaults.set(retentionCount, forKey: Keys.retentionCount) }
    }
    @Published public var retentionAgeDays: Int {
        didSet { defaults.set(retentionAgeDays, forKey: Keys.retentionAgeDays) }
    }
    @Published public var launchAtLoginEnabled: Bool {
        didSet { defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled) }
    }
    @Published public var rsyncExcludePatterns: [String] {
        didSet { defaults.set(rsyncExcludePatterns, forKey: Keys.rsyncExcludePatterns) }
    }
    @Published public var includeExtendedAttributes: Bool {
        didSet { defaults.set(includeExtendedAttributes, forKey: Keys.includeExtendedAttributes) }
    }
    @Published public var lastBackupDate: Date? {
        didSet { defaults.set(lastBackupDate, forKey: Keys.lastBackupDate) }
    }
    @Published public var lastBackupSucceeded: Bool? {
        didSet {
            if let value = lastBackupSucceeded {
                defaults.set(value, forKey: Keys.lastBackupSucceeded)
            } else {
                defaults.removeObject(forKey: Keys.lastBackupSucceeded)
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceVolumeName = defaults.string(forKey: Keys.sourceVolumeName) ?? "MeineFestplatte"
        nasHost = defaults.string(forKey: Keys.nasHost) ?? "nas"
        nasShare = defaults.string(forKey: Keys.nasShare) ?? "Backup"
        nasUser = defaults.string(forKey: Keys.nasUser) ?? "admin"
        nasMountPoint = defaults.string(forKey: Keys.nasMountPoint) ?? "/Volumes/NAS-Backup"
        targetSubpath = defaults.string(forKey: Keys.targetSubpath) ?? "Backups/MeineFestplatte"
        autoBackupEnabled = defaults.object(forKey: Keys.autoBackupEnabled) as? Bool ?? false
        autoBackupIntervalHours = defaults.object(forKey: Keys.autoBackupIntervalHours) as? Double ?? 24
        retentionMode = RetentionMode(rawValue: defaults.string(forKey: Keys.retentionMode) ?? "") ?? .count
        retentionCount = defaults.object(forKey: Keys.retentionCount) as? Int ?? 14
        retentionAgeDays = defaults.object(forKey: Keys.retentionAgeDays) as? Int ?? 30
        launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? true
        rsyncExcludePatterns = defaults.stringArray(forKey: Keys.rsyncExcludePatterns) ?? [".DS_Store"]
        includeExtendedAttributes = defaults.object(forKey: Keys.includeExtendedAttributes) as? Bool ?? false
        lastBackupDate = defaults.object(forKey: Keys.lastBackupDate) as? Date
        lastBackupSucceeded = defaults.object(forKey: Keys.lastBackupSucceeded) as? Bool
    }

    public var sourcePath: String {
        "/Volumes/\(sourceVolumeName)"
    }

    public var targetDir: String {
        (nasMountPoint as NSString).appendingPathComponent(targetSubpath)
    }

    public var currentRetentionPolicy: RetentionPolicy {
        switch retentionMode {
        case .unlimited: return .unlimited
        case .count: return .count(retentionCount)
        case .age: return .age(days: retentionAgeDays)
        }
    }

    private enum Keys {
        static let sourceVolumeName = "sourceVolumeName"
        static let nasHost = "nasHost"
        static let nasShare = "nasShare"
        static let nasUser = "nasUser"
        static let nasMountPoint = "nasMountPoint"
        static let targetSubpath = "targetSubpath"
        static let autoBackupEnabled = "autoBackupEnabled"
        static let autoBackupIntervalHours = "autoBackupIntervalHours"
        static let retentionMode = "retentionMode"
        static let retentionCount = "retentionCount"
        static let retentionAgeDays = "retentionAgeDays"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
        static let rsyncExcludePatterns = "rsyncExcludePatterns"
        static let includeExtendedAttributes = "includeExtendedAttributes"
        static let lastBackupDate = "lastBackupDate"
        static let lastBackupSucceeded = "lastBackupSucceeded"
    }
}
