import XCTest
@testable import PhotoBackupCore

final class BackupPreflightTests: XCTestCase {
    /// Der Fall, der ohne diese Prüfung 391 GB Backup gelöscht hätte — und den rsync
    /// selbst mit Status 0 als "Erfolg" gemeldet hätte.
    func testRefusesEmptySourceAgainstNonEmptyTarget() {
        let reason = BackupPreflight.refusalReason(sourceIsEmpty: true, targetIsEmpty: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("Quelllaufwerk ist leer"))
    }

    func testAllowsNormalRun() {
        XCTAssertNil(BackupPreflight.refusalReason(sourceIsEmpty: false, targetIsEmpty: false))
    }

    func testAllowsFirstRunIntoEmptyTarget() {
        XCTAssertNil(BackupPreflight.refusalReason(sourceIsEmpty: false, targetIsEmpty: true))
    }

    /// Leere Quelle auf leeres Ziel kann nichts zerstören und soll nicht blockieren.
    func testAllowsEmptySourceWhenTargetIsAlsoEmpty() {
        XCTAssertNil(BackupPreflight.refusalReason(sourceIsEmpty: true, targetIsEmpty: true))
    }

    func testIsEmptyDirectoryDetectsContent() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        XCTAssertTrue(BackupPreflight.isEmptyDirectory(atPath: dir.path))
        fileManager.createFile(atPath: dir.appendingPathComponent("x.txt").path, contents: Data("x".utf8))
        XCTAssertFalse(BackupPreflight.isEmptyDirectory(atPath: dir.path))
    }

    /// Ein nicht existierender Pfad gilt als leer — wichtig, damit ein noch nicht
    /// angelegtes Ziel den ersten Lauf nicht blockiert.
    func testMissingDirectoryCountsAsEmpty() {
        XCTAssertTrue(BackupPreflight.isEmptyDirectory(atPath: "/gibt/es/nicht"))
    }
}
