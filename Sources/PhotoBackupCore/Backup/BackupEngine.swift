import Foundation

/// Führt den eigentlichen rsync-Lauf aus und erzeugt einen inkrementellen,
/// Time-Machine-artigen Snapshot mittels `--link-dest`.
///
/// Wichtig: dieses System nutzt Apples `openrsync` (kein klassisches rsync 3.x) —
/// `--info=progress2` wird NICHT unterstützt. Ebenso liefert `--progress` bei openrsync
/// pro Datei erst *nach* deren Abschluss eine einzelne Zeile (immer "100%", nie
/// Zwischenwerte) und unveränderte, nur hartverlinkte Dateien lösen gar keine Zeile aus —
/// als Live-Fortschritt ist das irreführend. Stattdessen: `--itemize-changes` zeigt
/// *jede* verarbeitete Datei (auch Hardlinks), was in Kombination mit einem vorherigen
/// `--dry-run`-Scan (liefert die echte Gesamtzahl über `Number of files:`) einen
/// korrekten Gesamtfortschritt ermöglicht.
///
/// `-E`/Extended Attributes ist standardmäßig aus: openrsync legt dafür
/// AppleDouble-Sidecar-Dateien (`._name`) an, die bei jedem Lauf neu übertragen
/// werden, auch ohne echte Änderung — das würde das Hardlink-Sharing gegen
/// `--link-dest` durchbrechen.
public final class BackupEngine: @unchecked Sendable {
    private static let rsyncPath = "/usr/bin/rsync"
    /// `script` hängt ein Pseudo-Terminal vor `rsync`. Ohne das puffert die libc-`stdio` des
    /// Kindprozesses die Ausgabe vollständig, sobald stdout eine Pipe statt ein Terminal ist —
    /// gemessen: Bei einem 51 Sekunden dauernden gedrosselten Transfer kamen *alle*
    /// `--itemize-changes`-Zeilen erst am Ende auf einmal an, keine einzige währenddessen.
    /// Mit `script` treffen sie live pro fertiger Datei ein. Nebenwirkung: `script` mischt
    /// stderr des Kindprozesses in denselben (jetzt als stdout gelesenen) Strom, daher wird
    /// die Fehlermeldung bei Misserfolg aus `lastStatsText` statt aus stderr gewonnen.
    private static let scriptPath = "/usr/bin/script"

    private static let totalFilesRegex = try! NSRegularExpression(
        pattern: #"Number of files:\s*([\d,]+)"#
    )
    private static let statsFilesRegex = try! NSRegularExpression(
        pattern: #"Number of (?:regular )?files transferred:\s*([\d,]+)"#
    )

    private var process: Process?
    private var isCancelled = false

    public init() {}

    public func run(
        source: String,
        targetDir: String,
        previousSnapshotPath: String?,
        excludePatterns: [String],
        includeExtendedAttributes: Bool,
        timestamp: String = SnapshotNaming.timestampString(),
        fileManager: FileManager = .default,
        onProgress: @escaping (BackupProgress) -> Void
    ) async throws -> BackupResult {
        try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        let destination = (targetDir as NSString).appendingPathComponent(timestamp)
        let source = source.hasSuffix("/") ? source : source + "/"
        let destinationWithSlash = destination.hasSuffix("/") ? destination : destination + "/"

        func baseArguments() -> [String] {
            var arguments = ["-a"]
            if includeExtendedAttributes {
                arguments.append("--extended-attributes")
            }
            if let previousSnapshotPath {
                arguments.append("--link-dest=\(previousSnapshotPath)")
            }
            for pattern in excludePatterns {
                arguments.append("--exclude=\(pattern)")
            }
            return arguments
        }

        onProgress(BackupProgress(phase: .scanning))
        let totalFiles = await preScanFileCount(baseArguments: baseArguments(), source: source, destination: destinationWithSlash)
        guard !isCancelled else { return .cancelled }

        onProgress(BackupProgress(phase: .transferring, totalFiles: totalFiles))
        var arguments = baseArguments()
        arguments.append("--itemize-changes")
        arguments.append("--stats")
        arguments.append(source)
        arguments.append(destinationWithSlash)

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: Self.scriptPath)
        process.arguments = ["-q", "/dev/null", Self.rsyncPath] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startDate = Date()
        var lastStatsText = ""
        var filesProcessed = 0

        do {
            try process.run()
        } catch {
            self.process = nil
            throw BackupEngineError.launchFailed(error.localizedDescription)
        }

        let outputTask = Task {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                lastStatsText += line + "\n"
                if let path = Self.parseItemizeLine(line) {
                    filesProcessed += 1
                    onProgress(BackupProgress(phase: .transferring, currentFile: path, filesProcessed: filesProcessed, totalFiles: totalFiles))
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        _ = try? await outputTask.value

        self.process = nil
        let duration = Date().timeIntervalSince(startDate)

        if process.terminationStatus == 0 {
            let filesTransferred = Self.parseFilesTransferred(from: lastStatsText)
            let markerPath = (destination as NSString).appendingPathComponent(SnapshotNaming.completionMarkerFileName)
            fileManager.createFile(atPath: markerPath, contents: nil)
            return .success(snapshotPath: destination, filesTransferred: filesTransferred, duration: duration)
        } else if isCancelled || process.terminationReason == .uncaughtSignal {
            return .cancelled
        } else {
            // `script` mischt stderr des Kindprozesses in den pty-Strom, den wir bereits als
            // stdout lesen (siehe lastStatsText) — die separate stderrPipe bleibt daher leer
            // und dient nur noch als Fallback für Fehler von `script` selbst.
            let stderrMessage = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tailMessage = lastStatsText
                .split(separator: "\n")
                .suffix(5)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let message: String
            if !stderrMessage.isEmpty {
                message = stderrMessage
            } else if !tailMessage.isEmpty {
                message = tailMessage
            } else {
                message = "rsync beendet mit Status \(process.terminationStatus)"
            }
            return .failure(message: message)
        }
    }

    public func cancel() {
        isCancelled = true
        process?.terminate()
    }

    /// Ermittelt die echte Gesamtzahl der zu verarbeitenden Dateien über einen `--dry-run`.
    /// Bei bestehendem `--link-dest` gibt openrsync im Dry-Run harmlose
    /// "hard link ... No such file or directory"-Meldungen auf stderr aus (da der
    /// Zielordner mangels echtem Schreiben nicht existiert) — die werden bewusst verworfen,
    /// der Exit-Code bleibt davon unberührt.
    private func preScanFileCount(baseArguments: [String], source: String, destination: String) async -> Int? {
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: Self.rsyncPath)
        process.arguments = baseArguments + ["-n", "--stats", source, destination]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            process.terminationHandler = { _ in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: Self.parseTotalFiles(from: text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Erste Zeichen gültiger `--itemize-changes`-Update-Codes (siehe rsync-Manpage:
    /// `<`, `>`, `c`, `h`, `.`, `*`). Wichtig zur Abgrenzung von der `--stats`-Zusammenfassung,
    /// die im selben stdout-Stream direkt danach folgt ("Number of files: …", "sent … bytes …")
    /// — ohne diesen Filter würden deren Zeilen fälschlich als verarbeitete Dateien gezählt.
    private static let itemizeLeadCharacters = Set("<>ch.*")

    /// Simuliert, was ein echtes Terminal beim Rendern von Backspace-Zeichen tut: das
    /// vorangehende Zeichen entfernen. Nötig, weil das Pseudo-Terminal von `script` vor der
    /// allerersten Zeile ein sichtbares Artefakt schreibt — die zwei druckbaren Zeichen `^D`
    /// gefolgt von zwei Backspaces, die auf einem echten Terminal genau dieses `^D` wieder
    /// löschen würden. Ohne diese Simulation bleiben die rohen Bytes `^D` vor der Zeile stehen.
    private static func collapsingBackspaces(_ line: String) -> String {
        var result: [Character] = []
        for char in line {
            if char == "\u{08}" {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(char)
            }
        }
        return String(result)
    }

    /// Parst eine `--itemize-changes`-Zeile, z.B. `>f.s..... file1.bin` oder
    /// `hf        sub/s1.bin` (Hardlink, unverändert) — der Code selbst enthält nie ein
    /// Leerzeichen, daher reicht das erste Leerzeichen als Trenner zum Pfad.
    static func parseItemizeLine(_ line: String) -> String? {
        let line = collapsingBackspaces(line)
        guard let first = line.first, itemizeLeadCharacters.contains(first) else { return nil }
        guard let spaceIndex = line.firstIndex(of: " ") else { return nil }
        let path = line[line.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    static func parseTotalFiles(from statsText: String) -> Int? {
        let range = NSRange(statsText.startIndex..<statsText.endIndex, in: statsText)
        guard let match = totalFilesRegex.firstMatch(in: statsText, range: range),
              let r = Range(match.range(at: 1), in: statsText) else {
            return nil
        }
        return Int(statsText[r].replacingOccurrences(of: ",", with: ""))
    }

    static func parseFilesTransferred(from statsText: String) -> Int {
        let range = NSRange(statsText.startIndex..<statsText.endIndex, in: statsText)
        guard let match = statsFilesRegex.firstMatch(in: statsText, range: range),
              let r = Range(match.range(at: 1), in: statsText) else {
            return 0
        }
        return Int(statsText[r].replacingOccurrences(of: ",", with: "")) ?? 0
    }
}
