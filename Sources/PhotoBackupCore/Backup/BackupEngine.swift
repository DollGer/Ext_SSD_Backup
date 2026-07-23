import Foundation

/// Führt den eigentlichen rsync-Lauf aus und erzeugt einen inkrementellen,
/// Time-Machine-artigen Snapshot mittels `--link-dest`.
///
/// Wichtig: dieses System nutzt Apples `openrsync` (kein klassisches rsync 3.x) —
/// `--info=progress2` wird NICHT unterstützt, daher `--progress` verwenden.
/// `-E`/Extended Attributes ist standardmäßig aus: openrsync legt dafür
/// AppleDouble-Sidecar-Dateien (`._name`) an, die bei jedem Lauf neu übertragen
/// werden, auch ohne echte Änderung — das würde das Hardlink-Sharing gegen
/// `--link-dest` durchbrechen.
public final class BackupEngine: @unchecked Sendable {
    private static let rsyncPath = "/usr/bin/rsync"

    private static let progressLineRegex = try! NSRegularExpression(
        pattern: #"^\s*[\d,]+\s+(\d+)%\s+\S+/s\s+\S+\s+\(xfer#\d+,\s+to-check=(\d+)/(\d+)\)"#
    )
    private static let statsFilesRegex = try! NSRegularExpression(
        pattern: #"Number of (?:regular )?files transferred:\s*([\d,]+)"#
    )

    private var process: Process?

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
        arguments.append("--progress")
        arguments.append("--stats")
        arguments.append(source.hasSuffix("/") ? source : source + "/")
        arguments.append(destination.hasSuffix("/") ? destination : destination + "/")

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: Self.rsyncPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startDate = Date()
        var pendingFilename: String?
        var lastStatsText = ""

        do {
            try process.run()
        } catch {
            self.process = nil
            throw BackupEngineError.launchFailed(error.localizedDescription)
        }

        let outputTask = Task {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                lastStatsText += line + "\n"
                if let progress = Self.parseProgressLine(line, currentFile: pendingFilename) {
                    onProgress(progress)
                } else {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        pendingFilename = trimmed
                    }
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
            return .success(snapshotPath: destination, filesTransferred: filesTransferred, duration: duration)
        } else if process.terminationReason == .uncaughtSignal {
            return .cancelled
        } else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message: (message?.isEmpty == false ? message! : "rsync beendet mit Status \(process.terminationStatus)"))
        }
    }

    public func cancel() {
        process?.terminate()
    }

    private static func parseProgressLine(_ line: String, currentFile: String?) -> BackupProgress? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = progressLineRegex.firstMatch(in: line, range: range) else { return nil }

        func group(_ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: line) else { return nil }
            return String(line[r])
        }

        let percentOfFile = group(1).flatMap { Int($0) }
        let checked = group(2).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        let total = group(3).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }

        var overallEstimate: Double?
        if let checked, let total, total > 0 {
            overallEstimate = Double(total - checked) / Double(total)
        }

        return BackupProgress(
            currentFile: currentFile,
            percentOfFile: percentOfFile,
            overallPercentEstimate: overallEstimate
        )
    }

    private static func parseFilesTransferred(from statsText: String) -> Int {
        let range = NSRange(statsText.startIndex..<statsText.endIndex, in: statsText)
        guard let match = statsFilesRegex.firstMatch(in: statsText, range: range),
              let r = Range(match.range(at: 1), in: statsText) else {
            return 0
        }
        return Int(statsText[r].replacingOccurrences(of: ",", with: "")) ?? 0
    }
}
