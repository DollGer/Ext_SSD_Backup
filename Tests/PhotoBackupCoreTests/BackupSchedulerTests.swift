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
