# PhotoBackup

Menüleisten-App für macOS: sichert eine externe Festplatte inkrementell
(Time-Machine-artige Snapshots via `rsync --link-dest`) auf ein NAS per SMB. Ersetzt das
ursprüngliche `~/bin/backup-external.sh` + launchd-Setup.

Swift Package statt `.xcodeproj` — lässt sich aber auch in Xcode öffnen (`Package.swift`
doppelklicken oder den Projektordner in Xcode öffnen).

## Funktionsumfang

- Inkrementelle Backups via `rsync --link-dest`: unveränderte Dateien werden zwischen
  Snapshots hartverlinkt statt neu übertragen — spart NAS-Speicher, jeder abgeschlossene
  Snapshot-Ordner ist trotzdem ein vollständiges Abbild des Quelllaufwerks.
- Snapshot-Ordner werden erst nach erfolgreichem Abschluss als vollständig markiert
  (`.complete`-Marker); ein abgebrochener/unterbrochener Lauf hinterlässt keinen gültigen
  Snapshot und wird beim nächsten Start automatisch entfernt.
- Laufwerks-, NAS-Host-, Freigabe- und Zielordner-Auswahl über kleine Picker-Menüs in den
  Einstellungen statt blindem Eintippen (NAS-Host-Suche per Bonjour, Freigaben über
  `smbutil view`, Zielordner durch Browsen der gemounteten Freigabe).
- Live-Fortschrittsanzeige mit echtem Prozentwert und geschätzter Restdauer (basiert auf
  einem `--dry-run`-Vorab-Scan, da Apples `openrsync` keine Gesamtzahl vorab kennt und pro
  Datei erst nach Abschluss überhaupt eine Meldung ausgibt — der Balken für die *aktuell*
  laufende Datei ist deshalb bewusst unbestimmt, kein erfundener Prozentwert).
- Verhindert den Leerlauf-Ruhezustand während eines laufenden Backups (nicht bei
  zugeklapptem Deckel ohne externen Bildschirm — das erzwingt macOS hardwareseitig).
- macOS-Benachrichtigungen bei Erfolg/Fehlschlag, automatischer Zeitplan, konfigurierbare
  Aufbewahrung (Anzahl oder Alter).

## Bauen & starten

```bash
./build.sh                                  # baut build/PhotoBackup.app
open build/PhotoBackup.app                  # zum Ausprobieren
cp -R build/PhotoBackup.app /Applications/   # für dauerhaften Betrieb / Login-Start
```

`swift build` / `swift test` funktionieren auch direkt (Debug-Build ohne App-Bundle,
für schnelle Iteration an der Logik in `PhotoBackupCore`). Die Tests decken die reine
Business-Logik ab (Snapshot-Namensschema, Aufbewahrungs-Policy, Fortschritts-Parsing) sowie
ein paar echte End-to-End-Läufe von `BackupEngine` gegen temporäre Verzeichnisse.

## Erste Einrichtung

1. App starten, über das Menüleisten-Icon → „Einstellungen…" öffnen (öffnet standardmäßig
   im Tab **Status**).
2. Tab **Allgemein**: Laufwerksname (Auswahl über das Festplatten-Icon, falls die Platte
   gerade angeschlossen ist) sowie NAS-Host/Freigabe/Benutzer/Passwort eintragen. Host und
   Freigabe lassen sich über die Icons daneben aus dem Netzwerk suchen bzw. vom NAS abrufen,
   sobald Host + Benutzer + Passwort gesetzt sind. Passwort landet über „Passwort speichern"
   im Schlüsselbund, nicht im Klartext. Beim ersten Öffnen fragt macOS einmalig nach der
   Berechtigung für die lokale Netzwerksuche — ohne Bestätigung bleibt die Host-Suche leer.
3. **Vor dem ersten echten Backup**: prüfen, ob Hardlinks über die SMB-Freigabe des NAS
   funktionieren — sonst läuft das Backup zwar durch, spart aber keinen NAS-Speicher.
4. Externe Platte anschließen, „Backup jetzt starten" (Tab Status oder Menüleisten-Dropdown)
   wird aktiv, sobald Platte gemountet und NAS erreichbar sind.
5. Erst wenn ein manueller Lauf erfolgreich war: „Automatisches Backup" (Tab Zeitplan &
   Aufbewahrung) und „Bei Login starten" (Tab Erweitert) aktivieren.

## Signierung

`build.sh` signiert automatisch mit dem kostenlosen „Apple Development"-Zertifikat aus dem
Schlüsselbund, sofern eines vorhanden ist (in Xcode über Settings → Accounts → Team →
Manage Certificates → „+" → Apple Development einrichten). Dadurch bleibt die
Code-Signatur über Neubauten hinweg stabil, und macOS fragt nicht bei jedem Rebuild erneut
nach dem Schlüsselbund-Zugriff. Ist kein solches Zertifikat installiert, fällt der Build
automatisch auf eine Ad-hoc-Signatur zurück (Signatur wechselt dann bei jedem Build).

## Bekannte Einschränkungen

- **Benachrichtigungen**: Die Berechtigungsanfrage für `UNUserNotificationCenter` kann bei
  einer nicht in `/Applications` installierten App fehlschlagen (kein Absturz, Backups
  funktionieren trotzdem — es fehlen nur die macOS-Benachrichtigungen). Nach
  `cp -R build/PhotoBackup.app /Applications/` und Neustart der App erneut prüfen.
- **Löschen großer Ordner über SMB ist langsam**: Sowohl das Entfernen eines abgebrochenen
  Snapshots als auch die Aufbewahrungs-Bereinigung löschen Datei für Datei über die
  Netzwerkfreigabe — bei Zehntausenden von Dateien kann das spürbar dauern (blockiert aber
  nicht mehr die UI). Läuft im Hintergrund, keine Aktion nötig.
- **Kein Abbrechen während „Räume auf…“/„Scanne…“**: Der „Backup abbrechen“-Button wirkt
  erst, sobald die eigentliche Übertragung läuft, nicht während des Aufräumens oder des
  Vorab-Scans davor.
