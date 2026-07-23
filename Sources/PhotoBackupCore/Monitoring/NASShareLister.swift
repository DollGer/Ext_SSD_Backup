import Foundation

/// Listet die SMB-Freigaben eines NAS über `smbutil view` auf, damit sie in den
/// Einstellungen ausgewählt statt blind eingetippt werden können. Erfordert
/// erreichbares NAS und gültige Zugangsdaten — schlägt entsprechend fehl, wenn
/// das NAS gerade nicht im Netzwerk ist.
public struct NASShareLister {
    public struct ShareListError: Error, LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    private static let smbutilPath = "/usr/bin/smbutil"

    public init() {}

    public func listShares(host: String, user: String, password: String) async throws -> [String] {
        guard
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed),
            let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed)
        else {
            throw ShareListError(message: "Nutzername/Passwort konnten nicht kodiert werden.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.smbutilPath)
        process.arguments = ["view", "//\(encodedUser):\(encodedPassword)@\(host)"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stdoutData, exitCode): (Data, Int32) = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (data, proc.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ShareListError(message: error.localizedDescription))
            }
        }

        guard exitCode == 0 else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShareListError(message: message?.isEmpty == false ? message! : "smbutil view fehlgeschlagen (Code \(exitCode)).")
        }

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let shares = Self.parseShareNames(from: output)
        guard !shares.isEmpty else {
            throw ShareListError(message: "Keine Freigaben gefunden.")
        }
        return shares
    }

    /// Parst die Tabellenausgabe von `smbutil view`, z.B.:
    /// ```
    /// Share                     Type       Comments
    /// -------------------------------------------------
    /// Backup                    Disk
    /// IPC$                      Pipe       Remote IPC
    /// ```
    /// Nur `Disk`-Freigaben sind für Backups relevant; Pipes/Printer werden ausgefiltert.
    static func parseShareNames(from output: String) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        guard let separatorIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("---") }) else {
            return []
        }
        var names: [String] = []
        for line in lines[(separatorIndex + 1)...] {
            let columns = line
                .components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let name = columns.first else { continue }
            let type = columns.count > 1 ? columns[1] : ""
            if type.isEmpty || type == "Disk" {
                names.append(name)
            }
        }
        return names.sorted()
    }
}
