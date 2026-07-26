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

    /// Regression: bei einem rsync-Teilfehler (Exitcode 23/24) enthält die Ausgabe eine echte
    /// Fehlermeldung *vor* der abschließenden Statistik — die Statistik allein darf nicht als
    /// "Fehlermeldung" durchgereicht werden (genau das ist live passiert: "419GB gesendet,
    /// speedup 1.00" wurde als Fehlertext angezeigt, obwohl fast alles erfolgreich lief).
    func testExtractErrorLinesFindsRealErrorNotJustStats() {
        let output = """
        >f+++++++ file1.bin
        rsync: mkstemp "/Volumes/NAS/target/weird:name.jpg" failed: Permission denied (13)
        >f+++++++ file2.bin
        Number of files: 8
        Number of files transferred: 6
        Total file size: 47 B
        Total transferred file size: 47 B
        Unmatched data: 47 B
        Matched data: 0 B
        File list size: 285 B
        Total sent: 640 B
        Total received: 164 B

        sent 640 bytes  received 164 bytes  730909 bytes/sec
        total size is 41  speedup is 0.05
        """
        let errors = BackupEngine.extractErrorLines(from: output)
        XCTAssertEqual(errors, [#"rsync: mkstemp "/Volumes/NAS/target/weird:name.jpg" failed: Permission denied (13)"#])
    }

    func testExtractErrorLinesEmptyWhenOnlyStatsAndItemizeLines() {
        let output = """
        >f+++++++ file1.bin
        cd+++++++ sub/
        Number of files: 8
        Number of files transferred: 6
        sent 640 bytes  received 164 bytes  730909 bytes/sec
        total size is 41  speedup is 0.05
        """
        XCTAssertEqual(BackupEngine.extractErrorLines(from: output), [])
    }

    func testFullRunMirrorsSourceWithAccurateProgress() async throws {
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
            excludePatterns: [],
            includeExtendedAttributes: false,
            onProgress: { progressUpdates.append($0) }
        )

        guard case .success(let filesTransferred, _) = result else {
            XCTFail("expected .success, got \(result)")
            return
        }
        XCTAssertEqual(filesTransferred, 6)
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("file0.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("sub/nested.txt").path))
        XCTAssertFalse(progressUpdates.values.isEmpty)
        // Jeder verarbeitete Eintrag (auch Verzeichnisse) zählt zum Fortschritt; am Ende
        // sollte die verarbeitete Zahl exakt der im Vorab-Scan ermittelten Gesamtzahl entsprechen.
        XCTAssertEqual(progressUpdates.values.last?.filesProcessed, progressUpdates.values.last?.totalFiles)
    }

    /// Kernverhalten des Spiegel-Modells: eine an der Quelle gelöschte Datei muss beim
    /// nächsten Lauf auch am Ziel verschwinden (`--delete`) — keine Versionshistorie.
    func testSecondRunPropagatesSourceDeletionAndAddition() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let keepPath = source.appendingPathComponent("keep.txt").path
        let deleteMePath = source.appendingPathComponent("delete-me.txt").path
        fileManager.createFile(atPath: keepPath, contents: Data("keep".utf8))
        fileManager.createFile(atPath: deleteMePath, contents: Data("delete me".utf8))

        let firstEngine = BackupEngine()
        _ = try await firstEngine.run(
            source: source.path, targetDir: target.path,
            excludePatterns: [], includeExtendedAttributes: false, onProgress: { _ in }
        )
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("delete-me.txt").path))

        try fileManager.removeItem(atPath: deleteMePath)
        fileManager.createFile(atPath: source.appendingPathComponent("new.txt").path, contents: Data("new".utf8))

        let secondEngine = BackupEngine()
        let result = try await secondEngine.run(
            source: source.path, targetDir: target.path,
            excludePatterns: [], includeExtendedAttributes: false, onProgress: { _ in }
        )

        guard case .success = result else {
            XCTFail("expected .success, got \(result)")
            return
        }
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("new.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: target.appendingPathComponent("delete-me.txt").path))
    }

    func testCancelledRunReturnsCancelled() async throws {
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
            excludePatterns: [],
            includeExtendedAttributes: false,
            onProgress: { _ in }
        )

        guard case .cancelled = result else {
            XCTFail("expected .cancelled, got \(result)")
            return
        }
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
