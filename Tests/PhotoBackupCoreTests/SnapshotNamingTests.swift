import XCTest
@testable import PhotoBackupCore

final class SnapshotNamingTests: XCTestCase {
    func testTimestampRoundTrip() {
        let timeZone = TimeZone(identifier: "Europe/Vienna")!
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 23
        components.hour = 14
        components.minute = 5
        components.second = 30
        components.timeZone = timeZone
        let calendar = Calendar(identifier: .gregorian)
        let originalDate = calendar.date(from: components)!

        let name = SnapshotNaming.timestampString(date: originalDate, timeZone: timeZone)
        XCTAssertEqual(name, "2026-07-23_14-05-30")

        let parsedDate = SnapshotNaming.parseTimestamp(name, timeZone: timeZone)
        XCTAssertNotNil(parsedDate)
        XCTAssertEqual(parsedDate!.timeIntervalSince1970, originalDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSnapshotsFiltersNonMatchingDirectoryNames() throws {
        let fileManager = FileManager.default
        let baseDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDir) }

        let validNames = ["2025-01-01_10-00-00", "2025-06-15_23-59-59"]
        let invalidNames = ["latest", ".DS_Store", "not-a-snapshot", "2025-13-99_99-99-99"]
        for name in validNames + invalidNames {
            try fileManager.createDirectory(at: baseDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let snapshots = SnapshotNaming.snapshots(in: baseDir.path, fileManager: fileManager)
        XCTAssertEqual(snapshots.map(\.name), validNames.sorted())
    }

    func testPreviousSnapshotReturnsMostRecent() throws {
        let fileManager = FileManager.default
        let baseDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDir) }

        for name in ["2024-01-01_00-00-00", "2025-01-01_00-00-00", "2023-01-01_00-00-00"] {
            try fileManager.createDirectory(at: baseDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let previous = SnapshotNaming.previousSnapshot(in: baseDir.path, fileManager: fileManager)
        XCTAssertEqual(previous?.name, "2025-01-01_00-00-00")
    }

    func testPreviousSnapshotIsNilWhenEmpty() throws {
        let fileManager = FileManager.default
        let baseDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDir) }

        XCTAssertNil(SnapshotNaming.previousSnapshot(in: baseDir.path, fileManager: fileManager))
    }
}
