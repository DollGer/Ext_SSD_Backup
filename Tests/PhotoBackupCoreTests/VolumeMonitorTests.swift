import XCTest
@testable import PhotoBackupCore

final class VolumeMonitorTests: XCTestCase {
    private let mounted = [
        URL(fileURLWithPath: "/"),
        URL(fileURLWithPath: "/Volumes/GDO_SSD_1TB"),
        URL(fileURLWithPath: "/Volumes/D-NAS-share")
    ]

    func testRecognizesMountedVolume() {
        XCTAssertTrue(VolumeMonitor.isMounted(volumeName: "GDO_SSD_1TB", mountedVolumeURLs: mounted))
    }

    func testUnmountedVolumeIsNotRecognized() {
        XCTAssertFalse(VolumeMonitor.isMounted(volumeName: "nicht-angeschlossen", mountedVolumeURLs: mounted))
    }

    /// Kernregression: Ein leerer Laufwerksname ergibt den Pfad `/Volumes/`, der immer
    /// existiert. Die frühere `fileExists`-Prüfung meldete deshalb "Platte verbunden",
    /// obwohl gar keine Platte da war — ein Backup-Lauf hätte dann mit einer faktisch
    /// leeren Quelle das komplette Ziel per `--delete` gelöscht.
    func testEmptyVolumeNameIsNeverMounted() {
        XCTAssertFalse(VolumeMonitor.isMounted(volumeName: "", mountedVolumeURLs: mounted))
        XCTAssertFalse(VolumeMonitor.isMounted(volumeName: "   ", mountedVolumeURLs: mounted))
    }

    /// Zweite Variante desselben Risikos: macOS lässt nach unsauberem Auswerfen mitunter
    /// ein leeres Verzeichnis unter `/Volumes` zurück. Es taucht dann nicht mehr in der
    /// Mount-Liste auf und darf nicht als angeschlossen gelten.
    func testLeftoverDirectoryWithoutMountIsNotRecognized() {
        let withoutDrive = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Volumes/D-NAS-share")]
        XCTAssertFalse(VolumeMonitor.isMounted(volumeName: "GDO_SSD_1TB", mountedVolumeURLs: withoutDrive))
    }

    func testTrailingSlashesAndWhitespaceAreTolerated() {
        XCTAssertTrue(VolumeMonitor.isMounted(volumeName: " GDO_SSD_1TB ", mountedVolumeURLs: mounted))
        XCTAssertTrue(
            VolumeMonitor.isMounted(
                volumeName: "GDO_SSD_1TB",
                mountedVolumeURLs: [URL(fileURLWithPath: "/Volumes/GDO_SSD_1TB/")]
            )
        )
    }
}
