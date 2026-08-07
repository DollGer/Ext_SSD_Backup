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
    @Published public var launchAtLoginEnabled: Bool {
        didSet { defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled) }
    }
    @Published public var rsyncExcludePatterns: [String] {
        didSet { defaults.set(rsyncExcludePatterns, forKey: Keys.rsyncExcludePatterns) }
    }
    @Published public var includeExtendedAttributes: Bool {
        didSet { defaults.set(includeExtendedAttributes, forKey: Keys.includeExtendedAttributes) }
    }
    /// Obergrenze für Löschungen pro Lauf (`--max-delete`); `0` schaltet die Grenze ab.
    /// Sicherheitsnetz gegen einen Lauf, der wegen einer falsch erkannten Quelle große
    /// Teile des Backups entfernen würde — rsync bricht dann ab, statt weiterzulöschen.
    @Published public var maxDeleteCount: Int {
        didSet { defaults.set(maxDeleteCount, forKey: Keys.maxDeleteCount) }
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
        launchAtLoginEnabled = defaults.object(forKey: Keys.launchAtLoginEnabled) as? Bool ?? true
        rsyncExcludePatterns = defaults.stringArray(forKey: Keys.rsyncExcludePatterns) ?? [".DS_Store"]
        includeExtendedAttributes = defaults.object(forKey: Keys.includeExtendedAttributes) as? Bool ?? false
        maxDeleteCount = defaults.object(forKey: Keys.maxDeleteCount) as? Int ?? 1000
        lastBackupDate = defaults.object(forKey: Keys.lastBackupDate) as? Date
        lastBackupSucceeded = defaults.object(forKey: Keys.lastBackupSucceeded) as? Bool
    }

    public var sourcePath: String {
        "/Volumes/\(sourceVolumeName)"
    }

    public var targetDir: String {
        (nasMountPoint as NSString).appendingPathComponent(targetSubpath)
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
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
        static let rsyncExcludePatterns = "rsyncExcludePatterns"
        static let includeExtendedAttributes = "includeExtendedAttributes"
        static let maxDeleteCount = "maxDeleteCount"
        static let lastBackupDate = "lastBackupDate"
        static let lastBackupSucceeded = "lastBackupSucceeded"
    }
}
