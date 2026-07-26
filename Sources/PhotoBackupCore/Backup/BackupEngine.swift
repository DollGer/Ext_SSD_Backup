import Foundation

/// Führt den eigentlichen rsync-Lauf aus: ein reiner 1:1-Spiegel des Quelllaufwerks im
/// konfigurierten Zielordner. Kein Snapshot-Verlauf, keine Versionen — `--delete` sorgt
/// dafür, dass am Quelllaufwerk gelöschte Dateien auch aus dem Backup verschwinden. Bewusste
/// Design-Entscheidung: wer eine Datei aus Versehen löscht, verliert sie auch im Backup: es
/// gibt keine ältere Version zum Wiederherstellen.
///
/// Wichtig: dieses System nutzt Apples `openrsync` (kein klassisches rsync 3.x) —
/// `--info=progress2` wird NICHT unterstützt. Ebenso liefert `--progress` bei openrsync
/// pro Datei erst *nach* deren Abschluss eine einzelne Zeile (immer "100%", nie
/// Zwischenwerte) und unveränderte Dateien lösen gar keine Zeile aus — als Live-Fortschritt
/// ist das irreführend. Stattdessen: `--itemize-changes` zeigt *jede* verarbeitete Datei
/// (auch unveränderte und gelöschte), was in Kombination mit einem vorherigen
/// `--dry-run`-Scan (liefert die echte Gesamtzahl über `Number of files:`) einen
/// korrekten Gesamtfortschritt ermöglicht.
///
/// `-E`/Extended Attributes ist standardmäßig aus: openrsync legt dafür
/// AppleDouble-Sidecar-Dateien (`._name`) an, die bei jedem Lauf neu übertragen würden.
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
        excludePatterns: [String],
        includeExtendedAttributes: Bool,
        fileManager: FileManager = .default,
        onProgress: @escaping (BackupProgress) -> Void
    ) async throws -> BackupResult {
        try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        let source = source.hasSuffix("/") ? source : source + "/"
        let destinationWithSlash = targetDir.hasSuffix("/") ? targetDir : targetDir + "/"

        func baseArguments() -> [String] {
            var arguments = ["-a", "--delete"]
            if includeExtendedAttributes {
                arguments.append("--extended-attributes")
            }
            for pattern in excludePatterns {
                arguments.append("--exclude=\(pattern)")
            }
            return arguments
        }

        onProgress(BackupProgress(phase: .scanning))
        // -1: Mit `--delete` überspringt openrsync beim `--itemize-changes`-Log konsequent
        // den Eintrag für das Sync-Wurzelverzeichnis selbst (Unterordner werden normal
        // gemeldet, nur die Wurzel nicht) — gemessen, kein Sonderfall, kein Zufall. Ohne diese
        // Korrektur bliebe der Fortschrittsbalken für immer bei (Gesamtzahl - 1) hängen.
        let totalFiles = await preScanFileCount(baseArguments: baseArguments(), source: source, destination: destinationWithSlash)
            .map { max($0 - 1, 0) }
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
            return .success(filesTransferred: filesTransferred, duration: duration)
        } else if isCancelled || process.terminationReason == .uncaughtSignal {
            return .cancelled
        } else {
            // `script` mischt stderr des Kindprozesses in den pty-Strom, den wir bereits als
            // stdout lesen (siehe lastStatsText) — die separate stderrPipe bleibt daher leer
            // und dient nur noch als Fallback für Fehler von `script` selbst.
            let stderrMessage = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorLines = Self.extractErrorLines(from: lastStatsText)
            let filesTransferred = Self.parseFilesTransferred(from: lastStatsText)

            let message: String
            if !stderrMessage.isEmpty {
                message = stderrMessage
            } else if !errorLines.isEmpty {
                // rsync kann bei einem Teilfehler (z.B. einzelne Dateien mit ungültigen Namen
                // fürs Zieldateisystem) trotzdem den Großteil erfolgreich übertragen — die
                // reine Statistik-Zeile am Ende wäre hier keine hilfreiche Fehlermeldung.
                message = "\(filesTransferred) Dateien übertragen, aber einzelne Fehler (Status \(process.terminationStatus)):\n" + errorLines.joined(separator: "\n")
            } else {
                let tailMessage = lastStatsText
                    .split(separator: "\n")
                    .suffix(5)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                message = tailMessage.isEmpty ? "rsync beendet mit Status \(process.terminationStatus)" : tailMessage
            }
            return .failure(message: message)
        }
    }

    public func cancel() {
        isCancelled = true
        process?.terminate()
    }

    /// Ermittelt die echte Gesamtzahl der zu verarbeitenden Dateien über einen `--dry-run`.
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
    /// `<`, `>`, `c`, `h`, `.`, `*` — `*` deckt u.a. `*deleting` ab). Wichtig zur Abgrenzung
    /// von der `--stats`-Zusammenfassung, die im selben stdout-Stream direkt danach folgt
    /// ("Number of files: …", "sent … bytes …") — ohne diesen Filter würden deren Zeilen
    /// fälschlich als verarbeitete Dateien gezählt.
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

    /// Prefixe der `--stats`-Zusammenfassung, die trotz Schlüsselwörtern wie "error" in
    /// Dateinamen o.ä. niemals eine echte Fehlermeldung sind.
    private static let statsLinePrefixes = [
        "Number of", "Total ", "Unmatched data", "Matched data", "File list size",
        "sent ", "total size is"
    ]

    /// Filtert echte Fehlermeldungen (z.B. "rsync: mkstemp ... failed: Permission denied")
    /// aus dem kompletten Ausgabe-Mitschnitt heraus. Wichtig bei einem Teilfehler (rsync-
    /// Exitcode 23/24): der Großteil kann erfolgreich übertragen worden sein, während die
    /// eigentliche Fehlerursache irgendwo *vor* der abschließenden Statistik steht — ein
    /// simples "letzte paar Zeilen" würde dann nur die Statistik zeigen, nicht den Fehler.
    static func extractErrorLines(from statsText: String) -> [String] {
        statsText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty, parseItemizeLine(line) == nil else { return false }
                guard !statsLinePrefixes.contains(where: { line.hasPrefix($0) }) else { return false }
                let lower = line.lowercased()
                return lower.contains("rsync:") || lower.contains("rsync error") || lower.contains("error")
                    || lower.contains("denied") || lower.contains("failed") || lower.contains("cannot")
                    || lower.contains("no such file")
            }
    }
}
