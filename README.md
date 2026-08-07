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
- **Schutz vor versehentlichem Totalverlust** (drei unabhängige Ebenen, siehe unten):
  echte Mount-Erkennung, Vorabprüfung auf leere Quelle und ein `--max-delete`-Limit.
- **Trockenlauf-Vorschau**: zeigt vor dem Start „X neu, Y geändert, Z werden gelöscht"
  inklusive Beispielpfaden — erst danach wird auf Wunsch wirklich gestartet.
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
  Ein abgebrochener Lauf wird nicht automatisch wieder aufgenommen, ein wiederholt
  scheiternder mit wachsendem Abstand (15 min → 1 h → 4 h) statt im Minutentakt.
- Ereignis-Protokoll unter `~/Library/Logs/PhotoBackup/backup.log`, im Reiter „Erweitert"
  direkt einsehbar.

## Schutz gegen versehentlichen Totalverlust

Der Spiegel-Modus arbeitet mit `--delete`. Das birgt eine unangenehme Eigenschaft von
rsync: Ist die **Quelle leer**, löscht ein Lauf das komplette Ziel — und beendet sich dabei
mit Status 0, meldet also „Erfolg". Der Schaden wäre nicht einmal als Fehler erkennbar.
Dagegen greifen drei voneinander unabhängige Ebenen:

1. **Echte Mount-Erkennung.** Ob die Platte angeschlossen ist, wird über die Liste der
   tatsächlich gemounteten Volumes bestimmt, nicht über „Verzeichnis existiert". Sonst
   würde ein nach unsauberem Auswerfen zurückgebliebenes leeres Verzeichnis unter
   `/Volumes` — oder ein leerer Laufwerksname, der den immer existierenden Pfad
   `/Volumes/` ergibt — als angeschlossene Platte durchgehen.
2. **Vorabprüfung.** Unmittelbar vor dem Lauf wird abgelehnt, wenn die Quelle leer ist,
   das Ziel aber nicht.
3. **`--max-delete`-Limit** (Reiter „Erweitert", Standard 1000). Sollen mehr Dateien
   gelöscht werden, bricht rsync ab, statt weiterzumachen. Wer regelmäßig große Mengen
   an der Quelle löscht, muss den Wert erhöhen — oder mit `0` abschalten.

Zusätzlich zeigt die **Vorschau** vor dem Start, wie viele Dateien gelöscht würden.

## Bauen & starten

```bash
./build.sh                                  # baut build/PhotoBackup.app
open build/PhotoBackup.app                  # zum Ausprobieren
cp -R build/PhotoBackup.app /Applications/   # für dauerhaften Betrieb / Login-Start
```

`swift build` / `swift test` funktionieren auch direkt (Debug-Build ohne App-Bundle,
für schnelle Iteration an der Logik in `PhotoBackupCore`). Die Tests decken die reine
Business-Logik ab (Fortschritts-Parsing, Zeitplan-Fälligkeit und -Sperren, Mount-Erkennung,
Vorabprüfung) sowie echte End-to-End-Läufe von `BackupEngine` gegen temporäre Verzeichnisse
— darunter das Spiegel-Verhalten (Datei an der Quelle löschen → nach dem nächsten Lauf auch
am Ziel weg), das greifende `--max-delete`-Limit und der Trockenlauf.

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

- **Keine Versionshistorie**: reiner Spiegel. Die Schutzebenen oben verhindern den
  versehentlichen *Total*verlust, aber nicht, dass eine einzeln gelöschte Datei beim
  nächsten Lauf auch aus dem Backup verschwindet. Wer das braucht, sollte zusätzlich
  z.B. Time Machine oder ein separates Snapshot-Tool einsetzen.
- **Benachrichtigungen**: Die Berechtigungsanfrage für `UNUserNotificationCenter` kann bei
  einer nicht in `/Applications` installierten App fehlschlagen (kein Absturz, Backups
  funktionieren trotzdem — es fehlen nur die macOS-Benachrichtigungen). Nach
  `cp -R build/PhotoBackup.app /Applications/` und Neustart der App erneut prüfen.
- **Kein Abbrechen während des NAS-Mountens**: Der „Backup abbrechen“-Button wirkt ab dem
  Vorab-Scan, aber nicht in der kurzen Phase davor, in der die Freigabe eingebunden wird.
