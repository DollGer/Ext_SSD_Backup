import Foundation
import Combine
import Security
import UserNotifications

/// Zentrale, von der UI beobachtete Quelle der Wahrheit. Orchestriert Monitoring,
/// NAS-Mounting, den eigentlichen Backup-Lauf und die Aufbewahrungs-Bereinigung.
@MainActor
public final class AppState: ObservableObject {
    public let settings: SettingsStore
    public let volumeMonitor: VolumeMonitor
    public let nasReachability: NASReachabilityMonitor
    private let scheduler: BackupScheduler
    private let smbMounter = SMBMounter()
    private let keychain = KeychainStore()
    private var backupEngine: BackupEngine?
    private var cancellables: Set<AnyCancellable> = []

    /// Gespiegelte Kopien von `volumeMonitor.isMounted`/`nasReachability.isReachable`.
    /// Nötig, weil SwiftUI-Views, die nur `AppState` als `@EnvironmentObject` beobachten,
    /// nicht automatisch neu rendern, wenn sich ein *verschachteltes* ObservableObject
    /// ändert — nur `AppState`s eigene `@Published`-Properties lösen das aus.
    @Published public private(set) var driveMounted: Bool = false
    @Published public private(set) var nasReachable: Bool = false
    @Published public private(set) var nasMounted: Bool = false
    @Published public private(set) var backupInProgress: Bool = false
    @Published public private(set) var currentProgress: BackupProgress?
    @Published public private(set) var lastBackupResult: BackupResult?
    @Published public var lastErrorMessage: String?

    public var canStartBackup: Bool {
        driveMounted && nasReachable && !backupInProgress
    }

    public init(settings: SettingsStore? = nil) {
        let settings = settings ?? SettingsStore()
        self.settings = settings
        self.volumeMonitor = VolumeMonitor(volumeName: settings.sourceVolumeName)
        self.nasReachability = NASReachabilityMonitor(host: settings.nasHost)
        self.scheduler = BackupScheduler(settings: settings)

        scheduler.onTriggerAutomaticBackup = { [weak self] in
            Task { [weak self] in await self?.startBackup(trigger: .automatic) }
        }
    }

    public func start() {
        volumeMonitor.start()
        nasReachability.startMonitoring()
        scheduler.startFallbackTimer { [weak self] in self?.evaluateScheduler() }

        volumeMonitor.$isMounted
            .sink { [weak self] mounted in
                self?.driveMounted = mounted
                self?.evaluateScheduler()
            }
            .store(in: &cancellables)
        nasReachability.$isReachable
            .sink { [weak self] reachable in
                self?.nasReachable = reachable
                self?.evaluateScheduler()
            }
            .store(in: &cancellables)
        settings.$autoBackupEnabled
            .sink { [weak self] _ in self?.evaluateScheduler() }
            .store(in: &cancellables)
        settings.$sourceVolumeName
            .sink { [weak self] name in self?.volumeMonitor.updateVolumeName(name) }
            .store(in: &cancellables)
        settings.$nasHost
            .sink { [weak self] host in self?.nasReachability.updateHost(host) }
            .store(in: &cancellables)
    }

    public func stop() {
        volumeMonitor.stop()
        nasReachability.stop()
        scheduler.stop()
        cancellables.removeAll()
    }

    private func evaluateScheduler() {
        scheduler.evaluate(
            driveMounted: driveMounted,
            nasReachable: nasReachable,
            backupInProgress: backupInProgress
        )
    }

    /// Einziger Einstiegspunkt für Backups — sowohl der manuelle Button als auch der
    /// Scheduler rufen dies auf. `backupInProgress` wird synchron vor jedem `await`
    /// gesetzt, damit ein gleichzeitiger zweiter Aufruf (z.B. Scheduler-Tick während
    /// ein manueller Klick noch läuft) sofort abgewiesen wird statt zu racen.
    public func startBackup(trigger: BackupTrigger) async {
        guard canStartBackup else { return }
        backupInProgress = true
        currentProgress = nil
        // Verhindert nur den Leerlauf-Ruhezustand (Bildschirmschoner/Inaktivität) — bei
        // zugeklapptem Deckel ohne externen Bildschirm erzwingt macOS den Schlaf trotzdem auf
        // Hardware-Ebene, das kann keine App verhindern.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "PhotoBackup-Lauf"
        )
        defer {
            backupInProgress = false
            ProcessInfo.processInfo.endActivity(activity)
        }

        do {
            if !smbMounter.isMounted(mountPoint: settings.nasMountPoint) {
                guard let password = try keychain.readPassword(), !password.isEmpty else {
                    throw KeychainError.readFailed(errSecItemNotFound)
                }
                try await smbMounter.mount(
                    host: settings.nasHost,
                    share: settings.nasShare,
                    user: settings.nasUser,
                    password: password,
                    mountPoint: settings.nasMountPoint
                )
            }
            nasMounted = true
        } catch {
            lastErrorMessage = error.localizedDescription
            await notify(title: "Backup fehlgeschlagen", message: error.localizedDescription)
            return
        }

        let targetDir = settings.targetDir
        currentProgress = BackupProgress(phase: .cleaningUp)
        // Auf einem Hintergrund-Thread: sowohl das Verzeichnis-Listing als auch insbesondere
        // das rekursive Löschen eines abgebrochenen Snapshot-Ordners können bei einem
        // Netzwerk-Mount (NAS über SMB) beliebig lange dauern. Synchron auf dem MainActor
        // ausgeführt blockiert das die komplette UI ("Rad des Todes") — deshalb hier bewusst
        // `Task.detached` statt der naheliegenden direkten Aufrufe.
        let previousSnapshot = await Task.detached(priority: .utility) { () -> SnapshotInfo? in
            let fileManager = FileManager.default
            // Ordner von abgebrochenen/unterbrochenen Läufen räumen: sie sind nie ein
            // vollständiges Abbild und würden sonst als Datenleiche auf dem NAS liegen bleiben.
            for incomplete in SnapshotNaming.incompleteSnapshots(in: targetDir, fileManager: fileManager) {
                try? fileManager.removeItem(atPath: incomplete.path)
            }
            return SnapshotNaming.previousSnapshot(in: targetDir, fileManager: fileManager)
        }.value
        let engine = BackupEngine()
        backupEngine = engine

        let result = (try? await engine.run(
            source: settings.sourcePath,
            targetDir: targetDir,
            previousSnapshotPath: previousSnapshot?.path,
            excludePatterns: settings.rsyncExcludePatterns,
            includeExtendedAttributes: settings.includeExtendedAttributes,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.currentProgress = progress }
            }
        )) ?? .failure(message: "rsync konnte nicht gestartet werden")

        backupEngine = nil
        lastBackupResult = result
        currentProgress = nil

        switch result {
        case .success(_, let filesTransferred, _):
            settings.lastBackupDate = Date()
            settings.lastBackupSucceeded = true
            // Wie beim Cleanup oben: Löschen alter Snapshot-Ordner kann über den NAS-Mount
            // lange dauern, deshalb nicht blockierend auf dem MainActor.
            let retentionPolicy = settings.currentRetentionPolicy
            await Task.detached(priority: .utility) {
                RetentionManager.prune(targetDir: targetDir, policy: retentionPolicy)
            }.value
            await notify(title: "Backup abgeschlossen", message: "\(filesTransferred) Dateien übertragen.")
        case .failure(let message):
            settings.lastBackupSucceeded = false
            lastErrorMessage = message
            await notify(title: "Backup fehlgeschlagen", message: message)
        case .cancelled:
            settings.lastBackupSucceeded = false
        }
    }

    public func cancelBackup() {
        backupEngine?.cancel()
    }

    private func notify(title: String, message: String) async {
        let center = UNUserNotificationCenter.current()
        let settingsAuth = await center.notificationSettings()
        guard settingsAuth.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}
