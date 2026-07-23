import XCTest
@testable import PhotoBackupCore

final class RetentionManagerTests: XCTestCase {
    private func snapshot(_ name: String, daysAgo: Double, now: Date) -> SnapshotInfo {
        SnapshotInfo(name: name, date: now.addingTimeInterval(-daysAgo * 86_400), path: "/tmp/\(name)")
    }

    func testUnlimitedKeepsEverything() {
        let now = Date()
        let snapshots = (0..<5).map { snapshot("s\($0)", daysAgo: Double($0), now: now) }
        XCTAssertEqual(RetentionManager.snapshotsToDelete(snapshots, policy: .unlimited, now: now), [])
    }

    func testCountKeepsNewestN() {
        let now = Date()
        // s0 = heute (neuester), s4 = vor 4 Tagen (ältester)
        let snapshots = (0..<5).map { snapshot("s\($0)", daysAgo: Double($0), now: now) }
        let victims = RetentionManager.snapshotsToDelete(snapshots, policy: .count(2), now: now)
        XCTAssertEqual(Set(victims.map(\.name)), Set(["s2", "s3", "s4"]))
    }

    func testCountNeverDeletesNewestEvenWithCountZero() {
        let now = Date()
        let snapshots = (0..<3).map { snapshot("s\($0)", daysAgo: Double($0), now: now) }
        let victims = RetentionManager.snapshotsToDelete(snapshots, policy: .count(0), now: now)
        XCTAssertFalse(victims.contains { $0.name == "s0" })
        XCTAssertEqual(Set(victims.map(\.name)), Set(["s1", "s2"]))
    }

    func testAgeDeletesOlderThanCutoff() {
        let now = Date()
        let snapshots = [
            snapshot("recent", daysAgo: 1, now: now),
            snapshot("borderline", daysAgo: 10, now: now),
            snapshot("old", daysAgo: 40, now: now)
        ]
        let victims = RetentionManager.snapshotsToDelete(snapshots, policy: .age(days: 30), now: now)
        XCTAssertEqual(victims.map(\.name), ["old"])
    }

    func testAgeNeverDeletesNewestEvenIfOlderThanCutoff() {
        let now = Date()
        // Nur ein einziger, sehr alter Snapshot vorhanden -> darf nicht gelöscht werden.
        let snapshots = [snapshot("onlyOne", daysAgo: 400, now: now)]
        let victims = RetentionManager.snapshotsToDelete(snapshots, policy: .age(days: 30), now: now)
        XCTAssertEqual(victims, [])
    }

    func testSingleSnapshotNeverDeleted() {
        let now = Date()
        let snapshots = [snapshot("only", daysAgo: 0, now: now)]
        XCTAssertEqual(RetentionManager.snapshotsToDelete(snapshots, policy: .count(1), now: now), [])
    }

    func testPruneRemovesFilesFromDisk() throws {
        let fileManager = FileManager.default
        let baseDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDir) }

        let names = ["2020-01-01_00-00-00", "2020-01-02_00-00-00", "2020-01-03_00-00-00"]
        for name in names {
            try fileManager.createDirectory(at: baseDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let deleted = RetentionManager.prune(targetDir: baseDir.path, policy: .count(1), fileManager: fileManager)
        XCTAssertEqual(deleted.map(\.name).sorted(), ["2020-01-01_00-00-00", "2020-01-02_00-00-00"])

        let remaining = try fileManager.contentsOfDirectory(atPath: baseDir.path)
        XCTAssertEqual(remaining, ["2020-01-03_00-00-00"])
    }
}
