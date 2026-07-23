# PhotoBackup

Menüleisten-App für macOS: sichert die externe Festplatte `MeineFestplatte` inkrementell
(Time-Machine-artige Snapshots via `rsync --link-dest`) auf ein NAS per SMB. Ersetzt das
bisherige `~/bin/backup-external.sh` + launchd-Setup — siehe
`/Users/gdol/.claude/plans/ich-m-chte-eine-app-wise-orbit.md` für den vollständigen Plan.

Kein Xcode installiert → dieses Projekt ist ein Swift Package statt eines `.xcodeproj`.
Xcode kann jederzeit nachträglich installiert werden; das Package lässt sich dann direkt öffnen.

## Bauen & starten

```bash
./build.sh                                  # baut build/PhotoBackup.app
open build/PhotoBackup.app                  # zum Ausprobieren
cp -R build/PhotoBackup.app /Applications/   # für dauerhaften Betrieb / Login-Start
```

`swift build` / `swift test` funktionieren auch direkt (Debug-Build ohne App-Bundle,
für schnelle Iteration an der Logik in `PhotoBackupCore`).

## Erste Einrichtung

1. App starten, über das Menüleisten-Icon → „Einstellungen…" öffnen.
2. Tab **Allgemein**: NAS-Passwort eintragen und „Passwort speichern" klicken (landet im
   Schlüsselbund, nicht im Klartext). Die übrigen Felder sind bereits mit den bisherigen
   Werten (`MeineFestplatte`, `nas`, `Backup`, `admin`, `/Volumes/NAS-Backup`) vorbelegt.
3. **Vor dem ersten echten Backup**: prüfen, ob Hardlinks über die SMB-Freigabe des NAS
   funktionieren (siehe Verifikationsschritt 0 im Plan) — sonst funktioniert das Backup zwar,
   spart aber keinen NAS-Speicher.
4. Externe Platte anschließen, „Backup jetzt starten" wird aktiv, sobald Platte gemountet
   und NAS erreichbar sind.
5. Erst wenn ein manueller Lauf erfolgreich war: „Automatisches Backup" und „Bei Login
   starten" aktivieren, danach ggf. das alte launchd-Setup deaktivieren (siehe Plan, Abschnitt
   „Migration").

## Signierung

`build.sh` signiert automatisch mit dem kostenlosen „Apple Development"-Zertifikat aus dem
Schlüsselbund, sofern eines vorhanden ist (in Xcode über Settings → Accounts → Team →
Manage Certificates → „+" → Apple Development einrichten). Dadurch bleibt die
Code-Signatur über Neubauten hinweg stabil, und macOS fragt nicht bei jedem Rebuild erneut
nach dem Schlüsselbund-Zugriff. Ist kein solches Zertifikat installiert, fällt der Build
automatisch auf eine Ad-hoc-Signatur zurück (Signatur wechselt dann bei jedem Build).

## Bekannte Einschränkungen dieses Builds

- **Benachrichtigungen**: Die Berechtigungsanfrage für `UNUserNotificationCenter` kann bei
  einer nicht in `/Applications` installierten App fehlschlagen (kein Absturz, Backups
  funktionieren trotzdem — es fehlen nur die macOS-Benachrichtigungen). Nach
  `cp -R build/PhotoBackup.app /Applications/` und Neustart der App erneut prüfen.
