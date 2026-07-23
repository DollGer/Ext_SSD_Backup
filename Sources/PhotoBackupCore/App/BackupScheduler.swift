import Foundation

/// Entscheidet, wann ein automatischer Backup-Lauf fällig ist. Event-getrieben:
/// wird sowohl bei Zustandsänderungen (Laufwerk/NAS/Auto-Backup-Toggle) als auch
/// von einem groben Fallback-Timer aufgerufen (falls beide Bedingungen bereits
/// erfüllt waren und nur die Zeit bis zum Intervall verstreicht).
@MainActor
public final class BackupScheduler {
    private let settings: SettingsStore
    private var lastAttemptDate: Date?
    private let failureCooldown: TimeInterval
    private var fallbackTimer: Timer?

    /// Wird aufgerufen, wenn ein automatischer Lauf gestartet werden soll.
    public var onTriggerAutomaticBackup: (() -> Void)?

    public init(settings: SettingsStore, failureCooldown: TimeInterval = 300) {
        self.settings = settings
        self.failureCooldown = failureCooldown
    }

    /// Reine, testbare Kernprüfung: ist ein automatischer Lauf anhand der letzten
    /// erfolgreichen Sicherung und des konfigurierten Intervalls fällig?
    public nonisolated static func isDue(lastBackupDate: Date?, intervalHours: Double, now: Date = Date()) -> Bool {
        guard let lastBackupDate else { return true }
        let elapsed = now.timeIntervalSince(lastBackupDate)
        return elapsed >= intervalHours * 3600
    }

    /// Startet den groben 5-Minuten-Fallback-Timer, der `onEvaluate` auch dann anstößt,
    /// wenn Laufwerk/NAS bereits beide erfüllt waren und nur die Zeit bis zum
    /// konfigurierten Intervall verstreicht (in diesem Fall ändert sich sonst kein
    /// beobachteter Zustand, der ein erneutes `evaluate()` auslösen würde).
    public func startFallbackTimer(onEvaluate: @escaping @MainActor () -> Void) {
        fallbackTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in onEvaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    /// Wird vom `AppState` bei jeder relevanten Zustandsänderung (Laufwerk, NAS,
    /// Auto-Backup-Toggle) sowie vom Fallback-Timer aufgerufen.
    public func evaluate(driveMounted: Bool, nasReachable: Bool, backupInProgress: Bool) {
        guard settings.autoBackupEnabled else { return }
        guard driveMounted, nasReachable, !backupInProgress else { return }

        guard Self.isDue(lastBackupDate: settings.lastBackupDate, intervalHours: settings.autoBackupIntervalHours) else {
            return
        }

        if let lastAttemptDate, Date().timeIntervalSince(lastAttemptDate) < failureCooldown {
            return
        }

        lastAttemptDate = Date()
        onTriggerAutomaticBackup?()
    }

    public func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }
}
