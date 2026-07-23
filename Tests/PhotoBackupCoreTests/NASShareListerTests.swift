import XCTest
@testable import PhotoBackupCore

final class NASShareListerTests: XCTestCase {
    func testParsesDiskSharesAndFiltersOthers() {
        let output = """
        Share                                     Type       Comments
        -------------------------------------------------------------
        Backup                                    Disk
        Time Machine Backups                      Disk
        IPC$                                      Pipe       Remote IPC
        """
        XCTAssertEqual(
            NASShareLister.parseShareNames(from: output),
            ["Backup", "Time Machine Backups"]
        )
    }

    func testEmptyWithoutSeparatorLine() {
        XCTAssertEqual(NASShareLister.parseShareNames(from: "no separator here"), [])
    }

    func testEmptyOutput() {
        XCTAssertEqual(NASShareLister.parseShareNames(from: ""), [])
    }
}
