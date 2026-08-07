import XCTest
@testable import PhotoBackupCore

final class BackupSchedulerTests: XCTestCase {
    func testDueWhenNeverBackedUp() {
        XCTAssertTrue(BackupScheduler.isDue(lastBackupDate: nil, intervalHours: 24))
    }

    func testNotDueBeforeIntervalElapsed() {
        let now = Date()
        let lastBackup = now.addingTimeInterval(-23 * 3600)
        XCTAssertFalse(BackupScheduler.isDue(lastBackupDate: lastBackup, intervalHours: 24, now: now))
    }

    func testDueExactlyAtIntervalBoundary() {
        let now = Date()
        let lastBackup = now.addingTimeInterval(-24 * 3600)
        XCTAssertTrue(BackupScheduler.isDue(lastBackupDate: lastBackup, intervalHours: 24, now: now))
    }

    func testDueJustAfterIntervalBoundary() {
        let now = Date()
        let lastBackup = now.addingTimeInterval(-24 * 3600 - 1)
        XCTAssertTrue(BackupScheduler.isDue(lastBackupDate: lastBackup, intervalHours: 24, now: now))
    }

    func testNotDueJustBeforeIntervalBoundary() {
        let now = Date()
        let lastBackup = now.addingTimeInterval(-24 * 3600 + 1)
        XCTAssertFalse(BackupScheduler.isDue(lastBackupDate: lastBackup, intervalHours: 24, now: now))
    }

    @MainActor
    func testEvaluateDoesNotTriggerWhenAutoBackupDisabled() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: #function)!)
        settings.autoBackupEnabled = false
        let scheduler = BackupScheduler(settings: settings)
        var triggered = false
        scheduler.onTriggerAutomaticBackup = { triggered = true }

        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false)
        XCTAssertFalse(triggered)
    }

    @MainActor
    func testEvaluateTriggersWhenDueAndConditionsMet() {
        let defaults = UserDefaults(suiteName: #function)!
        let settings = SettingsStore(defaults: defaults)
        settings.autoBackupEnabled = true
        settings.autoBackupIntervalHours = 24
        settings.lastBackupDate = nil
        let scheduler = BackupScheduler(settings: settings)
        var triggered = false
        scheduler.onTriggerAutomaticBackup = { triggered = true }

        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false)
        XCTAssertTrue(triggered)
    }

    // MARK: - Sperre nach Lauf-Ergebnis

    func testCooldownAfterSuccessIsNone() {
        XCTAssertEqual(
            BackupScheduler.cooldown(after: .succeeded, consecutiveFailures: 0, intervalHours: 24),
            0
        )
    }

    /// Ein bewusster Abbruch darf nicht wenige Minuten später von der App selbst
    /// rückgängig gemacht werden.
    func testCooldownAfterUserCancelSpansFullInterval() {
        XCTAssertEqual(
            BackupScheduler.cooldown(after: .cancelledByUser, consecutiveFailures: 0, intervalHours: 24),
            24 * 3600
        )
    }

    func testCooldownAfterFailuresIncreasesAndIsCapped() {
        XCTAssertEqual(BackupScheduler.cooldown(after: .failed, consecutiveFailures: 1, intervalHours: 24), 15 * 60)
        XCTAssertEqual(BackupScheduler.cooldown(after: .failed, consecutiveFailures: 2, intervalHours: 24), 60 * 60)
        XCTAssertEqual(BackupScheduler.cooldown(after: .failed, consecutiveFailures: 3, intervalHours: 24), 4 * 3600)
        XCTAssertEqual(BackupScheduler.cooldown(after: .failed, consecutiveFailures: 99, intervalHours: 24), 4 * 3600)
    }

    @MainActor
    private func makeScheduler(_ name: String) -> (BackupScheduler, SettingsStore) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: name)!)
        settings.autoBackupEnabled = true
        settings.autoBackupIntervalHours = 24
        settings.lastBackupDate = nil
        // Entprellung aus, damit sie die Ergebnis-Sperre in den Tests nicht überlagert.
        return (BackupScheduler(settings: settings, triggerDebounce: 0), settings)
    }

    /// Kernregression: Nach einem Abbruch startete der Fallback-Timer denselben Lauf
    /// bisher binnen ~5 Minuten automatisch neu, weil `lastBackupDate` unverändert blieb.
    @MainActor
    func testDoesNotRestartShortlyAfterUserCancel() {
        let (scheduler, _) = makeScheduler(#function)
        var triggers = 0
        scheduler.onTriggerAutomaticBackup = { triggers += 1 }

        let cancelTime = Date()
        scheduler.recordOutcome(.cancelledByUser, now: cancelTime)

        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false,
                           now: cancelTime.addingTimeInterval(5 * 60))
        XCTAssertEqual(triggers, 0, "Abbruch wurde von der App eigenmächtig rückgängig gemacht")

        // Nach Ablauf des reguläreren Intervalls darf wieder gestartet werden.
        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false,
                           now: cancelTime.addingTimeInterval(24 * 3600 + 1))
        XCTAssertEqual(triggers, 1)
    }

    /// Zweite Kernregression: ohne Backoff wiederholte sich ein dauerhaft scheiternder
    /// Lauf endlos im 5-Minuten-Takt des Fallback-Timers.
    @MainActor
    func testFailuresBackOffInsteadOfRetryingEveryFiveMinutes() {
        let (scheduler, _) = makeScheduler(#function)
        var triggers = 0
        scheduler.onTriggerAutomaticBackup = { triggers += 1 }

        let firstFailure = Date()
        scheduler.recordOutcome(.failed, now: firstFailure)

        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false,
                           now: firstFailure.addingTimeInterval(5 * 60))
        XCTAssertEqual(triggers, 0, "erneuter Versuch schon nach 5 Minuten")

        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false,
                           now: firstFailure.addingTimeInterval(16 * 60))
        XCTAssertEqual(triggers, 1)

        // Zweiter Fehlschlag in Folge: Wartezeit steigt auf eine Stunde.
        let secondFailure = firstFailure.addingTimeInterval(16 * 60)
        scheduler.recordOutcome(.failed, now: secondFailure)
        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false,
                           now: secondFailure.addingTimeInterval(30 * 60))
        XCTAssertEqual(triggers, 1, "Wartezeit ist nach dem zweiten Fehlschlag nicht gestiegen")
    }

    /// Nach einem erfolgreichen Lauf muss die Backoff-Stufe zurückgesetzt sein.
    @MainActor
    func testSuccessResetsFailureBackoff() {
        let (scheduler, settings) = makeScheduler(#function)
        var triggers = 0
        scheduler.onTriggerAutomaticBackup = { triggers += 1 }

        let start = Date()
        scheduler.recordOutcome(.failed, now: start)
        scheduler.recordOutcome(.failed, now: start)
        scheduler.recordOutcome(.succeeded, now: start)

        // Erfolg setzt `lastBackupDate`; das übernimmt hier die reguläre Fälligkeitsprüfung.
        settings.lastBackupDate = nil
        scheduler.recordOutcome(.failed, now: start)
        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: false,
                           now: start.addingTimeInterval(16 * 60))
        XCTAssertEqual(triggers, 1, "Backoff wurde nach dem Erfolg nicht zurückgesetzt")
    }

    @MainActor
    func testEvaluateDoesNotTriggerWhenConditionsUnmet() {
        let defaults = UserDefaults(suiteName: #function)!
        let settings = SettingsStore(defaults: defaults)
        settings.autoBackupEnabled = true
        let scheduler = BackupScheduler(settings: settings)
        var triggered = false
        scheduler.onTriggerAutomaticBackup = { triggered = true }

        scheduler.evaluate(driveMounted: false, nasReachable: true, backupInProgress: false)
        XCTAssertFalse(triggered)

        scheduler.evaluate(driveMounted: true, nasReachable: false, backupInProgress: false)
        XCTAssertFalse(triggered)

        scheduler.evaluate(driveMounted: true, nasReachable: true, backupInProgress: true)
        XCTAssertFalse(triggered)
    }
}
