import Foundation

/// Listet aktuell gemountete externe Laufwerke für die Auswahl in den Einstellungen.
/// Bewusst zustandslos (kein Observer/Cache) — wird bei Bedarf direkt beim Öffnen
/// des Auswahlmenüs abgefragt, da sich der Satz externer Laufwerke selten während
/// einer Settings-Sitzung ändert.
public enum AvailableVolumes {
    public static func externalVolumeNames(fileManager: FileManager = .default) -> [String] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        guard let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        return urls.compactMap { url -> String? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.volumeIsRootFileSystem != true, values.volumeIsInternal != true else { return nil }
            return values.volumeName
        }
        .sorted()
    }
}
