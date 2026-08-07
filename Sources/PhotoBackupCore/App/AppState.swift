import Foundation
import Combine
import Security
import UserNotifications

/// Zentrale, von der UI beobachtete Quelle der Wahrheit. Orchestriert Monitoring,
/// NAS-Mounting und den eigentlichen Backup-Lauf.
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
    /// Zeitpunkt, an dem die eigentliche Datenübertragung (nicht Aufräumen/Scannen) begonnen
    /// hat — Basis für die geschätzte Restdauer in der UI.
    @Published public private(set) var transferStartDate: Date?
    @Published public private(set) var lastBackupResult: BackupResult?
    @Published public var lastErrorMessage: String?
    @Published public private(set) var previewInProgress: Bool = false
    /// Ergebnis eines Trockenlaufs, das auf die Entscheidung des Nutzers wartet.
    @Published public private(set) var pendingPreview: BackupPreview?

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
        BackupLogger.log("App gestartet")
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
        BackupLogger.log("Backup gestartet (trigger=\(trigger), quelle=\(settings.sourcePath), ziel=\(settings.targetDir))")
        backupInProgress = true
        currentProgress = nil
        transferStartDate = nil
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
            try await ensureNASMounted()
        } catch {
            BackupLogger.log("NAS-Mount fehlgeschlagen: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
            lastBackupResult = .failure(message: error.localizedDescription)
            settings.lastBackupSucceeded = false
            scheduler.recordOutcome(.failed)
            await notify(title: "Backup fehlgeschlagen", message: error.localizedDescription)
            return
        }

        // Zweite Schutzebene gegen den Totalverlust-Fall (siehe BackupPreflight). Läuft
        // abseits des MainActors, weil die Ziel-Prüfung über den SMB-Mount geht.
        let sourcePath = settings.sourcePath
        let targetPath = settings.targetDir
        let refusal = await Task.detached(priority: .utility) { () -> String? in
            BackupPreflight.refusalReason(
                sourceIsEmpty: BackupPreflight.isEmptyDirectory(atPath: sourcePath),
                targetIsEmpty: BackupPreflight.isEmptyDirectory(atPath: targetPath)
            )
        }.value

        if let refusal {
            BackupLogger.log("Vorabprüfung abgelehnt: \(refusal)")
            lastErrorMessage = refusal
            lastBackupResult = .failure(message: refusal)
            settings.lastBackupSucceeded = false
            scheduler.recordOutcome(.failed)
            await notify(title: "Backup abgebrochen", message: refusal)
            return
        }

        let engine = BackupEngine()
        backupEngine = engine
        var loggedPhase: BackupPhase?

        let result = (try? await engine.run(
            source: settings.sourcePath,
            targetDir: settings.targetDir,
            excludePatterns: settings.rsyncExcludePatterns,
            includeExtendedAttributes: settings.includeExtendedAttributes,
            maxDeleteCount: settings.maxDeleteCount,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    if progress.phase == .transferring, self.transferStartDate == nil {
                        self.transferStartDate = Date()
                    }
                    if loggedPhase != progress.phase {
                        loggedPhase = progress.phase
                        switch progress.phase {
                        case .scanning:
                            BackupLogger.log("Vorab-Scan gestartet")
                        case .transferring:
                            BackupLogger.log("Übertragung gestartet (Gesamtzahl Dateien=\(progress.totalFiles.map(String.init) ?? "unbekannt"))")
                        }
                    }
                    self.currentProgress = progress
                }
            }
        )) ?? .failure(message: "rsync konnte nicht gestartet werden")

        backupEngine = nil
        lastBackupResult = result
        currentProgress = nil
        transferStartDate = nil

        switch result {
        case .success(let filesTransferred, let duration):
            BackupLogger.log("Backup erfolgreich: \(filesTransferred) Dateien übertragen, Dauer=\(Int(duration))s")
            settings.lastBackupDate = Date()
            settings.lastBackupSucceeded = true
            scheduler.recordOutcome(.succeeded)
            await notify(title: "Backup abgeschlossen", message: "\(filesTransferred) Dateien übertragen.")
        case .failure(let message):
            BackupLogger.log("Backup fehlgeschlagen: \(message)")
            settings.lastBackupSucceeded = false
            lastErrorMessage = message
            scheduler.recordOutcome(.failed)
            await notify(title: "Backup fehlgeschlagen", message: message)
        case .cancelled:
            BackupLogger.log("Backup abgebrochen")
            settings.lastBackupSucceeded = false
            scheduler.recordOutcome(.cancelledByUser)
        }
    }

    /// Gemeinsamer Mount-Schritt für Backup-Lauf und Trockenlauf-Vorschau.
    private func ensureNASMounted() async throws {
        if !smbMounter.isMounted(mountPoint: settings.nasMountPoint) {
            BackupLogger.log("NAS nicht gemountet, versuche zu mounten (host=\(settings.nasHost), share=\(settings.nasShare))")
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
            BackupLogger.log("NAS-Mount erfolgreich")
        }
        nasMounted = true
    }

    /// Ermittelt per Trockenlauf, was ein echter Lauf ändern würde. Ergebnis landet in
    /// `pendingPreview` und wartet dort auf `startPreviewedBackup()` oder `dismissPreview()`.
    public func loadPreview() async {
        guard !backupInProgress, !previewInProgress else { return }
        previewInProgress = true
        pendingPreview = nil
        defer { previewInProgress = false }

        do {
            try await ensureNASMounted()
        } catch {
            BackupLogger.log("Vorschau: NAS-Mount fehlgeschlagen: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
            return
        }

        BackupLogger.log("Vorschau (Trockenlauf) gestartet")
        let engine = BackupEngine()
        backupEngine = engine
        defer { backupEngine = nil }

        do {
            let preview = try await engine.preview(
                source: settings.sourcePath,
                targetDir: settings.targetDir,
                excludePatterns: settings.rsyncExcludePatterns,
                includeExtendedAttributes: settings.includeExtendedAttributes
            )
            BackupLogger.log("Vorschau: \(preview.newCount) neu, \(preview.changedCount) geändert, \(preview.deletedCount) zu löschen")
            pendingPreview = preview
        } catch {
            BackupLogger.log("Vorschau fehlgeschlagen: \(error.localizedDescription)")
            lastErrorMessage = error.localizedDescription
        }
    }

    public func dismissPreview() {
        pendingPreview = nil
    }

    public func startPreviewedBackup() async {
        pendingPreview = nil
        await startBackup(trigger: .manual)
    }

    public func cancelBackup() {
        BackupLogger.log("Abbruch angefordert")
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
