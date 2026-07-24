import XCTest
@testable import PhotoBackupCore

final class BackupEngineTests: XCTestCase {
    func testParseItemizeLineTransferredFile() {
        XCTAssertEqual(BackupEngine.parseItemizeLine(">f.s..... file1.bin"), "file1.bin")
    }

    func testParseItemizeLineHardlinkedFile() {
        XCTAssertEqual(BackupEngine.parseItemizeLine("hf        sub/s1.bin"), "sub/s1.bin")
    }

    func testParseItemizeLineDirectory() {
        XCTAssertEqual(BackupEngine.parseItemizeLine("cd+++++++ sub/"), "sub/")
    }

    func testParseItemizeLineMalformedReturnsNil() {
        XCTAssertNil(BackupEngine.parseItemizeLine("no-space-here"))
        XCTAssertNil(BackupEngine.parseItemizeLine(""))
    }

    /// Regression: `script` (siehe Doku in BackupEngine) schreibt vor der allerersten Zeile
    /// ein sichtbares `^D`-Artefakt (zwei druckbare Zeichen) gefolgt von zwei Backspaces, die
    /// es auf einem echten Terminal wieder löschen würden — das muss simuliert werden.
    func testParseItemizeLineCollapsesLeadingBackspaceArtifact() {
        XCTAssertEqual(BackupEngine.parseItemizeLine("^D\u{08}\u{08}cd+++++++ ./"), "./")
    }

    /// Regression: `--stats` läuft im selben Prozess/Stream direkt nach den Itemize-Zeilen;
    /// deren Zeilen dürfen nicht als verarbeitete Dateien mitgezählt werden.
    func testParseItemizeLineIgnoresStatsSummaryLines() {
        XCTAssertNil(BackupEngine.parseItemizeLine("Number of files: 8"))
        XCTAssertNil(BackupEngine.parseItemizeLine("Total file size: 665600 B"))
        XCTAssertNil(BackupEngine.parseItemizeLine("sent 429 bytes  received 82 bytes  154285 bytes/sec"))
        XCTAssertNil(BackupEngine.parseItemizeLine("total size is 512000  speedup is 1580.24"))
    }

    func testParseTotalFilesFromDryRunStats() {
        let stats = """
        Number of files: 10
        Number of files transferred: 0
        Total file size: 665600 B
        """
        XCTAssertEqual(BackupEngine.parseTotalFiles(from: stats), 10)
    }

    func testParseTotalFilesHandlesThousandsSeparator() {
        let stats = "Number of files: 12,345\n"
        XCTAssertEqual(BackupEngine.parseTotalFiles(from: stats), 12345)
    }

    func testParseTotalFilesMissingReturnsNil() {
        XCTAssertNil(BackupEngine.parseTotalFiles(from: "no stats here"))
    }

    func testParseFilesTransferred() {
        let stats = "Number of files transferred: 42\n"
        XCTAssertEqual(BackupEngine.parseFilesTransferred(from: stats), 42)
    }

    func testParseFilesTransferredMissingReturnsZero() {
        XCTAssertEqual(BackupEngine.parseFilesTransferred(from: "no stats here"), 0)
    }

    func testFullRunProducesCompleteMirrorWithAccurateProgress() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        for i in 0..<5 {
            fileManager.createFile(atPath: source.appendingPathComponent("file\(i).txt").path, contents: Data("hello \(i)".utf8))
        }
        fileManager.createFile(atPath: source.appendingPathComponent("sub/nested.txt").path, contents: Data("nested".utf8))

        let engine = BackupEngine()
        let progressUpdates = LockedArray<BackupProgress>()
        let result = try await engine.run(
            source: source.path,
            targetDir: target.path,
            previousSnapshotPath: nil,
            excludePatterns: [],
            includeExtendedAttributes: false,
            timestamp: "2030-01-01_00-00-00",
            onProgress: { progressUpdates.append($0) }
        )

        guard case .success(let snapshotPath, let filesTransferred, _) = result else {
            XCTFail("expected .success, got \(result)")
            return
        }
        XCTAssertEqual(filesTransferred, 6)
        XCTAssertTrue(SnapshotNaming.isComplete(snapshotPath, fileManager: fileManager))
        XCTAssertFalse(progressUpdates.values.isEmpty)
        // Jeder verarbeitete Eintrag (auch Verzeichnisse) zählt zum Fortschritt; am Ende
        // sollte die verarbeitete Zahl exakt der im Vorab-Scan ermittelten Gesamtzahl entsprechen.
        XCTAssertEqual(progressUpdates.values.last?.filesProcessed, progressUpdates.values.last?.totalFiles)
    }

    func testCancelledRunReturnsCancelledAndLeavesSnapshotIncomplete() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        fileManager.createFile(atPath: source.appendingPathComponent("file.txt").path, contents: Data("hello".utf8))

        let engine = BackupEngine()
        engine.cancel()
        let result = try await engine.run(
            source: source.path,
            targetDir: target.path,
            previousSnapshotPath: nil,
            excludePatterns: [],
            includeExtendedAttributes: false,
            timestamp: "2030-01-02_00-00-00",
            onProgress: { _ in }
        )

        guard case .cancelled = result else {
            XCTFail("expected .cancelled, got \(result)")
            return
        }
        let snapshotPath = target.appendingPathComponent("2030-01-02_00-00-00").path
        XCTAssertFalse(SnapshotNaming.isComplete(snapshotPath, fileManager: fileManager))
    }
}

/// Kleiner Thread-sicherer Sammler für Fortschritts-Callbacks, die von einem Hintergrund-Task
/// aus aufgerufen werden, während der Test selbst auf `main`/dem Test-Executor läuft.
private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
