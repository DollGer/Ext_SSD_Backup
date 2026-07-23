import Foundation
import Network
import Combine

/// Prüft, ob das NAS auf dem SMB-Port (445) erreichbar ist — unabhängig davon,
/// ob die Freigabe bereits gemountet ist. Da es keine Betriebssystem-Benachrichtigung
/// für "Host X wurde erreichbar" gibt, wird hier bewusst leicht gepollt (Default alle
/// 20s), getrennt von der Auto-Backup-Intervall-Logik in `BackupScheduler`.
@MainActor
public final class NASReachabilityMonitor: ObservableObject {
    @Published public private(set) var isReachable: Bool = false

    private var host: String
    private let port: UInt16
    private var timer: Timer?
    private let timeout: TimeInterval

    public init(host: String, port: UInt16 = 445, timeout: TimeInterval = 3) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    public func updateHost(_ host: String) {
        self.host = host
        checkNowImmediately()
    }

    public func startMonitoring(interval: TimeInterval = 20) {
        stopMonitoring()
        checkNowImmediately()
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNowImmediately() }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func checkNowImmediately() {
        Task { [weak self] in
            guard let self else { return }
            let reachable = await self.checkOnce()
            self.isReachable = reachable
        }
    }

    public func checkOnce() async -> Bool {
        let hostSnapshot = host
        let portSnapshot = port
        let timeoutSnapshot = timeout
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(hostSnapshot),
                port: NWEndpoint.Port(rawValue: portSnapshot) ?? 445,
                using: .tcp
            )
            let resultBox = ResultBox()

            let timeoutWorkItem = DispatchWorkItem {
                if resultBox.finish() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSnapshot, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resultBox.finish() {
                        timeoutWorkItem.cancel()
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if resultBox.finish() {
                        timeoutWorkItem.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    public func stop() {
        stopMonitoring()
    }

    /// Stellt sicher, dass Timeout- und Ready-Pfad einander nur genau einmal auslösen.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}
