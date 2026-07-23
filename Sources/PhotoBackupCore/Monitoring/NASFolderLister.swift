import Foundation

/// Listet vorhandene Unterordner innerhalb einer bereits gemounteten NAS-Freigabe
/// auf, damit der Ziel-Unterordner in den Einstellungen aus bestehenden Ordnern
/// gewählt statt blind eingetippt werden kann. Reine Verzeichnis-Traversierung —
/// das Mounten selbst übernimmt `SMBMounter`.
public enum NASFolderLister {
    public static func subdirectories(
        under root: String,
        maxDepth: Int = 2,
        fileManager: FileManager = .default
    ) -> [String] {
        var results: [String] = []

        func walk(_ relativePath: String, depth: Int) {
            let fullPath = relativePath.isEmpty ? root : (root as NSString).appendingPathComponent(relativePath)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: fullPath) else { return }

            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let entryFullPath = (fullPath as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entryFullPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                let relativeEntryPath = relativePath.isEmpty ? entry : "\(relativePath)/\(entry)"
                results.append(relativeEntryPath)
                if depth < maxDepth {
                    walk(relativeEntryPath, depth: depth + 1)
                }
            }
        }

        walk("", depth: 1)
        return results
    }
}
