import Foundation
import AppKit
import Combine

/// Erkennt, ob die externe Platte gemountet ist. Event-getrieben über
/// `NSWorkspace`-Mount/Unmount-Notifications statt Polling; der tatsächliche
/// Zustand wird jeweils über `FileManager.fileExists` am erwarteten Pfad neu
/// abgeleitet (robuster als das Parsen des Notification-`userInfo`), was auch
/// `checkNow()` beim App-Start oder nach einer Einstellungsänderung erlaubt.
@MainActor
public final class VolumeMonitor: ObservableObject {
    @Published public private(set) var isMounted: Bool = false

    private var volumeName: String
    private let fileManager: FileManager
    private var observers: [NSObjectProtocol] = []

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
        checkNow()
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    /// Muss aufgerufen werden, wenn der Nutzer den Laufwerksnamen in den Einstellungen ändert.
    public func updateVolumeName(_ name: String) {
        volumeName = name
        checkNow()
    }

    public func checkNow() {
        var isDirectory: ObjCBool = false
        let path = "/Volumes/\(volumeName)"
        isMounted = fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }
}
