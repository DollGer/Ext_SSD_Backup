import Foundation
import AppKit
import Combine

/// Erkennt, ob die externe Platte gemountet ist. Event-getrieben über
/// `NSWorkspace`-Mount/Unmount-Notifications statt Polling; der tatsächliche
/// Zustand wird jeweils neu abgeleitet (robuster als das Parsen des
/// Notification-`userInfo`), was auch `checkNow()` beim App-Start oder nach einer
/// Einstellungsänderung erlaubt.
/// Zusätzlich ein grober 30-Sekunden-Fallback-Timer: manche Laufwerke (z.B.
/// exFAT über FSKit) lösen `didMountNotification` nicht zuverlässig aus, sodass
/// sich der Zustand sonst dauerhaft festfressen kann.
///
/// Bewusst über die Liste tatsächlich gemounteter Volumes statt über
/// `FileManager.fileExists` am erwarteten Pfad: Letzteres kann einen echten Mount nicht
/// von einem gleichnamigen leeren Verzeichnis unterscheiden. Beide Fälle sind real und
/// gefährlich, weil der Backup-Lauf mit `--delete` bei leerer Quelle das komplette Ziel
/// löschen würde: macOS lässt nach unsauberem Auswerfen mitunter ein leeres Verzeichnis
/// in `/Volumes` zurück, und ein leerer Laufwerksname ergibt den Pfad `/Volumes/` —
/// der immer existiert.
@MainActor
public final class VolumeMonitor: ObservableObject {
    @Published public private(set) var isMounted: Bool = false

    private var volumeName: String
    private let fileManager: FileManager
    private var observers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?

    public init(volumeName: String, fileManager: FileManager = .default) {
        self.volumeName = volumeName
        self.fileManager = fileManager
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        let mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        let unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        observers = [mountObserver, unmountObserver]

        fallbackTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer

        checkNow()
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    /// Muss aufgerufen werden, wenn der Nutzer den Laufwerksnamen in den Einstellungen ändert.
    public func updateVolumeName(_ name: String) {
        volumeName = name
        checkNow()
    }

    public func checkNow() {
        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        isMounted = Self.isMounted(volumeName: volumeName, mountedVolumeURLs: volumes)
    }

    /// Reine Kernprüfung ohne I/O — trennbar testbar.
    nonisolated static func isMounted(volumeName: String, mountedVolumeURLs: [URL]) -> Bool {
        let trimmed = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let target = URL(fileURLWithPath: "/Volumes/\(trimmed)").standardizedFileURL
        return mountedVolumeURLs.contains { $0.standardizedFileURL == target }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }
}
