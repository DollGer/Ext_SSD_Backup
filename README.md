# PhotoBackup

Menüleisten-App für macOS: spiegelt eine externe Festplatte 1:1 (`rsync -a --delete`) auf
ein NAS per SMB. Ersetzt das ursprüngliche `~/bin/backup-external.sh` + launchd-Setup.

Swift Package statt `.xcodeproj` — lässt sich aber auch in Xcode öffnen (`Package.swift`
doppelklicken oder den Projektordner in Xcode öffnen).

## Funktionsumfang

- **Reiner 1:1-Spiegel, keine Versionen**: Neue/geänderte Dateien an der Quelle werden
  ergänzt, am Quelllaufwerk gelöschte Dateien werden auch aus dem Backup entfernt
  (`--delete`). Bewusste Design-Entscheidung — wer eine Datei aus Versehen löscht, verliert
  sie auch im Backup. Es gibt keine Snapshot-Historie und keine Aufbewahrungs-Policy.
- Laufwerks-, NAS-Host-, Freigabe- und Zielordner-Auswahl über kleine Picker-Menüs in den
  Einstellungen statt blindem Eintippen (NAS-Host-Suche per Bonjour, Freigaben über
  `smbutil view`, Zielordner durch Browsen der gemounteten Freigabe).
- Live-Fortschrittsanzeige mit echtem Prozentwert und geschätzter Restdauer (basiert auf
  einem `--dry-run`-Vorab-Scan, da Apples `openrsync` keine Gesamtzahl vorab kennt und pro
  Datei erst nach Abschluss überhaupt eine Meldung ausgibt — der Balken für die *aktuell*
  laufende Datei ist deshalb bewusst unbestimmt, kein erfundener Prozentwert).
- Verhindert den Leerlauf-Ruhezustand während eines laufenden Backups (nicht bei
  zugeklapptem Deckel ohne externen Bildschirm — das erzwingt macOS hardwareseitig).
- macOS-Benachrichtigungen bei Erfolg/Fehlschlag, konfigurierbarer automatischer Zeitplan.

## Bauen & starten

```bash
./build.sh                                  # baut build/PhotoBackup.app
open build/PhotoBackup.app                  # zum Ausprobieren
cp -R build/PhotoBackup.app /Applications/   # für dauerhaften Betrieb / Login-Start
```

`swift build` / `swift test` funktionieren auch direkt (Debug-Build ohne App-Bundle,
für schnelle Iteration an der Logik in `PhotoBackupCore`). Die Tests decken die reine
Business-Logik ab (Fortschritts-Parsing, Zeitplan-Fälligkeit) sowie ein paar echte
End-to-End-Läufe von `BackupEngine` gegen temporäre Verzeichnisse — inklusive eines Tests,
der genau das Spiegel-Verhalten prüft: Datei an der Quelle löschen → nach dem nächsten Lauf
auch am Ziel weg.

## Erste Einrichtung

1. App starten, über das Menüleisten-Icon → „Einstellungen…" öffnen (öffnet standardmäßig
   im Tab **Status**).
2. Tab **Allgemein**: Laufwerksname (Auswahl über das Festplatten-Icon, falls die Platte
   gerade angeschlossen ist) sowie NAS-Host/Freigabe/Benutzer/Passwort eintragen. Host und
   Freigabe lassen sich über die Icons daneben aus dem Netzwerk suchen bzw. vom NAS abrufen,
   sobald Host + Benutzer + Passwort gesetzt sind. Passwort landet über „Passwort speichern"
   im Schlüsselbund, nicht im Klartext. Beim ersten Öffnen fragt macOS einmalig nach der
   Berechtigung für die lokale Netzwerksuche — ohne Bestätigung bleibt die Host-Suche leer.
3. Externe Platte anschließen, „Backup jetzt starten" (Tab Status oder Menüleisten-Dropdown)
   wird aktiv, sobald Platte gemountet und NAS erreichbar sind.
4. Erst wenn ein manueller Lauf erfolgreich war: „Automatisches Backup" (Tab Zeitplan) und
   „Bei Login starten" (Tab Erweitert) aktivieren.

## Signierung

`build.sh` signiert automatisch mit dem kostenlosen „Apple Development"-Zertifikat aus dem
Schlüsselbund, sofern eines vorhanden ist (in Xcode über Settings → Accounts → Team →
Manage Certificates → „+" → Apple Development einrichten). Dadurch bleibt die
Code-Signatur über Neubauten hinweg stabil, und macOS fragt nicht bei jedem Rebuild erneut
nach dem Schlüsselbund-Zugriff. Ist kein solches Zertifikat installiert, fällt der Build
automatisch auf eine Ad-hoc-Signatur zurück (Signatur wechselt dann bei jedem Build).

## Bekannte Einschränkungen

- **Kein Schutz vor versehentlichem Löschen**: siehe oben — reiner Spiegel, keine
  Versionshistorie. Wer das braucht, sollte zusätzlich z.B. Time Machine oder ein separates
  Snapshot-Tool einsetzen.
- **Benachrichtigungen**: Die Berechtigungsanfrage für `UNUserNotificationCenter` kann bei
  einer nicht in `/Applications` installierten App fehlschlagen (kein Absturz, Backups
  funktionieren trotzdem — es fehlen nur die macOS-Benachrichtigungen). Nach
  `cp -R build/PhotoBackup.app /Applications/` und Neustart der App erneut prüfen.
- **Kein Abbrechen während „Scanne…“**: Der „Backup abbrechen“-Button wirkt erst, sobald
  die eigentliche Übertragung läuft, nicht während des Vorab-Scans davor.
