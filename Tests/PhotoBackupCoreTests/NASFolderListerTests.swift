import XCTest
@testable import PhotoBackupCore

final class NASFolderListerTests: XCTestCase {
    func testListsNestedDirectoriesUpToMaxDepth() throws {
        let fileManager = FileManager.default
        let baseDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDir) }

        try fileManager.createDirectory(at: baseDir.appendingPathComponent("Backups/MeineFestplatte"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baseDir.appendingPathComponent("Backups/Anderes/TiefEbene3"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baseDir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        fileManager.createFile(atPath: baseDir.appendingPathComponent("readme.txt").path, contents: Data())

        let result = NASFolderLister.subdirectories(under: baseDir.path, maxDepth: 2, fileManager: fileManager)

        XCTAssertEqual(Set(result), Set(["Backups", "Backups/MeineFestplatte", "Backups/Anderes"]))
    }

    func testMissingRootReturnsEmpty() {
        XCTAssertEqual(NASFolderLister.subdirectories(under: "/does/not/exist"), [])
    }
}
