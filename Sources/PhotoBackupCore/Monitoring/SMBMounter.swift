import Foundation

/// Mountet die NAS-SMB-Freigabe per `mount_smbfs`. Anders als im ursprünglichen
/// Bash-Skript werden die Prozess-Argumente als Array übergeben (kein Shell-String),
/// wodurch Sonderzeichen in Nutzername/Passwort kein Injection-Risiko darstellen;
/// Nutzername und Passwort werden zusätzlich für die smb://-URL percent-encoded,
/// da das Original bei Zeichen wie `@`, `/`, `:` oder `#` im Passwort gescheitert wäre.
///
/// Bekannte Einschränkung (aus dem Originalskript übernommen, nicht neu eingeführt):
/// Das Passwort ist kurzzeitig als Prozessargument für andere Prozesse desselben
/// Nutzers (z.B. via `ps`/Activity Monitor) sichtbar, solange `mount_smbfs` läuft.
/// Eine robustere Alternative wäre das NetFS-Framework (`NetFSMountURLSync`), das
/// Zugangsdaten über ein Options-Dictionary statt Kommandozeile entgegennimmt —
/// hier bewusst nicht verwendet, um bei der einfacheren, bereits bewährten
/// `mount_smbfs`-Variante zu bleiben.
public struct SMBMounter {
    private static let mountSmbfsPath = "/sbin/mount_smbfs"
    private static let diskutilPath = "/usr/sbin/diskutil"

    public init() {}

    public func isMounted(mountPoint: String, fileManager: FileManager = .default) -> Bool {
        let mountPointURL = URL(fileURLWithPath: mountPoint).standardizedFileURL
        let mountedVolumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return mountedVolumes.contains { $0.standardizedFileURL == mountPointURL }
    }

    public func mount(
        host: String,
        share: String,
        user: String,
        password: String,
        mountPoint: String,
        fileManager: FileManager = .default
    ) async throws {
        do {
            try fileManager.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        } catch {
            throw SMBMountError.createMountPointFailed(error.localizedDescription)
        }

        guard
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed),
            let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed)
        else {
            throw SMBMountError.mountFailed("Nutzername/Passwort konnten nicht kodiert werden.")
        }

        let smbURL = "smb://\(encodedUser):\(encodedPassword)@\(host)/\(share)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.mountSmbfsPath)
        process.arguments = [smbURL, mountPoint]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unbekannter Fehler"
                    continuation.resume(throwing: SMBMountError.mountFailed(message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: SMBMountError.mountFailed(error.localizedDescription))
            }
        }
    }

    /// Für Troubleshooting in den Einstellungen — nicht Teil des normalen Backup-Flows.
    public func unmount(mountPoint: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.diskutilPath)
        process.arguments = ["unmount", mountPoint]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unbekannter Fehler"
                    continuation.resume(throwing: SMBMountError.mountFailed(message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: SMBMountError.mountFailed(error.localizedDescription))
            }
        }
    }
}
