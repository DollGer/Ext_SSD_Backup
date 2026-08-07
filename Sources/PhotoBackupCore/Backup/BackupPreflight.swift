import Foundation

/// Letzte Plausibilitätsprüfung unmittelbar vor dem `rsync`-Lauf.
///
/// Hintergrund: Der Spiegel-Modus läuft mit `--delete`. Ist die Quelle leer, löscht rsync
/// das komplette Ziel — und beendet sich dabei mit Status 0, meldet also "Erfolg". Ein
/// solcher Lauf wäre also nicht einmal als Problem erkennbar. `VolumeMonitor` fängt den
/// häufigsten Auslöser (Quelle gar nicht gemountet) bereits ab; diese Prüfung ist die
/// zweite, unabhängige Ebene für den Fall "gemountet, aber leer" — etwa bei einem
/// versehentlich formatierten oder falsch ausgewählten Laufwerk.
public enum BackupPreflight {
    /// `nil`, wenn der Lauf starten darf — sonst der Grund für die Ablehnung.
    ///
    /// Bewusst nur bei *nicht* leerem Ziel abgelehnt: Ein leerer Lauf auf ein ohnehin
    /// leeres Ziel richtet keinen Schaden an, und ein legitim leeres Quelllaufwerk soll
    /// nicht dauerhaft blockieren.
    public static func refusalReason(sourceIsEmpty: Bool, targetIsEmpty: Bool) -> String? {
        guard sourceIsEmpty, !targetIsEmpty else { return nil }
        return """
            Abgebrochen: Das Quelllaufwerk ist leer, das Backup-Ziel aber nicht. \
            Ein Lauf würde das gesamte Backup löschen. Bitte prüfen, ob das richtige \
            Laufwerk angeschlossen und ausgewählt ist.
            """
    }

    /// Zählt nur, ob überhaupt ein Eintrag vorhanden ist — bewusst kein rekursives
    /// Durchzählen, das über eine SMB-Freigabe je nach Dateimenge viele Minuten dauern kann.
    public static func isEmptyDirectory(atPath path: String, fileManager: FileManager = .default) -> Bool {
        let entries = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        return entries.isEmpty
    }
}
