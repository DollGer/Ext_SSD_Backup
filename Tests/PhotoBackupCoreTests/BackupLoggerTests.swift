import XCTest
@testable import PhotoBackupCore

final class BackupLoggerTests: XCTestCase {
    func testLogAppendsTimestampedLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: url) }

        BackupLogger.log("erstes Ereignis", to: url)
        BackupLogger.log("zweites Ereignis", to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("erstes Ereignis"))
        XCTAssertTrue(lines[1].hasSuffix("zweites Ereignis"))
        // Format: "[yyyy-MM-dd HH:mm:ss] message"
        XCTAssertTrue(lines[0].hasPrefix("["))
    }
}
