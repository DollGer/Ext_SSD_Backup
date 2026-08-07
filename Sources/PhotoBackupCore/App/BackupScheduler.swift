import Foundation

/// Entscheidet, wann ein automatischer Backup-Lauf fällig ist. Event-getrieben:
/// wird sowohl bei Zustandsänderungen (Laufwerk/NAS/Auto-Backup-Toggle) als auch
/// von einem groben Fallback-Timer aufgerufen (falls beide Bedingungen bereits
/// erfüllt waren und nur die Zeit bis zum Intervall verstreicht).
///
/// Die Fälligkeit allein (`isDue`) reicht als Kriterium nicht aus, weil sie sich auf
/// `lastBackupDate` stützt — und das wird nur bei *Erfolg* fortgeschrieben. Ohne die
/// zusätzliche Sperre über `recordOutcome` würde ein abgebrochener Lauf innerhalb weniger
/// Minuten automatisch neu starten (der Abbruch wäre also wirkungslos) und ein dauerhaft
/// scheiternder Lauf sich endlos im Fallback-Takt wiederholen.
@MainActor
public final class BackupScheduler {
    public enum RunOutcome: Equatable, Sendable {
        case succeeded
        case failed
        case cancelledByUser
    }

    private let settings: SettingsStore
    private var lastAttemptDate: Date?
    private let triggerDebounce: TimeInterval
    private var fallbackTimer: Timer?
    private var suppressedUntil: Date?
    private var consecutiveFailures: Int = 0

    /// Wird aufgerufen, wenn ein automatischer Lauf gestartet werden soll.
    public var onTriggerAutomaticBackup: (() -> Void)?

    public init(settings: SettingsStore, triggerDebounce: TimeInterval = 300) {
        self.settings = settings
        self.triggerDebounce = triggerDebounce
    }

    /// Ansteigende Wartezeit nach einem Lauf, bevor der Scheduler erneut auslösen darf.
    ///
    /// - Erfolg: keine Sperre nötig, die reguläre Intervall-Prüfung greift wieder.
    /// - Abbruch durch den Nutzer: bis zum nächsten regulären Intervall, sonst würde die
    ///   App die gerade bewusst gestoppte Arbeit von sich aus wieder aufnehmen.
    /// - Fehlschlag: 15 min, dann 1 h, dann 4 h als Obergrenze — ein dauerhaft scheiterndes
    ///   Ziel (z.B. NAS-Problem) soll nicht im Minutentakt erneut belastet werden.
    public nonisolated static func cooldown(
        after outcome: RunOutcome,
        consecutiveFailures: Int,
        intervalHours: Double
    ) -> TimeInterval {
        switch outcome {
        case .succeeded:
            return 0
        case .cancelledByUser:
            return max(intervalHours, 0) * 3600
        case .failed:
            switch max(consecutiveFailures, 1) {
            case 1: return 15 * 60
            case 2: return 60 * 60
            default: return 4 * 3600
            }
        }
    }

    /// Muss nach jedem beendeten Lauf aufgerufen werden — unabhängig davon, ob er manuell
    /// oder automatisch gestartet wurde.
    public func recordOutcome(_ outcome: RunOutcome, now: Date = Date()) {
        switch outcome {
        case .succeeded:
            consecutiveFailures = 0
        case .failed:
            consecutiveFailures += 1
        case .cancelledByUser:
            // Kein Fehler des Ziels — die Backoff-Stufe soll dadurch nicht steigen.
            break
        }
        let wait = Self.cooldown(
            after: outcome,
            consecutiveFailures: consecutiveFailures,
            intervalHours: settings.autoBackupIntervalHours
        )
        suppressedUntil = wait > 0 ? now.addingTimeInterval(wait) : nil
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
    public func evaluate(driveMounted: Bool, nasReachable: Bool, backupInProgress: Bool, now: Date = Date()) {
        guard settings.autoBackupEnabled else { return }
        guard driveMounted, nasReachable, !backupInProgress else { return }

        guard Self.isDue(lastBackupDate: settings.lastBackupDate, intervalHours: settings.autoBackupIntervalHours, now: now) else {
            return
        }

        if let suppressedUntil, now < suppressedUntil {
            return
        }

        // Kurze Entprellung: `backupInProgress` wird erst gesetzt, wenn der ausgelöste
        // Task tatsächlich läuft — ohne diese Sperre könnte ein zweites `evaluate()` in
        // der Zwischenzeit denselben Lauf ein weiteres Mal anstoßen.
        if let lastAttemptDate, now.timeIntervalSince(lastAttemptDate) < triggerDebounce {
            return
        }

        lastAttemptDate = now
        onTriggerAutomaticBackup?()
    }

    public func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }
}
