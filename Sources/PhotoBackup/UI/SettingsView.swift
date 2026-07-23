import SwiftUI
import PhotoBackupCore

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            ScheduleTab()
                .tabItem { Label("Zeitplan", systemImage: "clock") }
            RetentionTab()
                .tabItem { Label("Aufbewahrung", systemImage: "archivebox") }
            AdvancedTab()
                .tabItem { Label("Erweitert", systemImage: "wrench.and.screwdriver") }
        }
        .padding()
    }
}

private struct GeneralTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var password: String = ""
    @State private var passwordStatus: String = ""
    private let keychain = KeychainStore()

    var body: some View {
        Form {
            Section("Externe Platte") {
                HStack {
                    TextField("Laufwerksname", text: $settings.sourceVolumeName)
                    Menu {
                        let volumes = AvailableVolumes.externalVolumeNames()
                        if volumes.isEmpty {
                            Text("Keine externen Laufwerke gefunden")
                        } else {
                            ForEach(volumes, id: \.self) { name in
                                Button(name) { settings.sourceVolumeName = name }
                            }
                        }
                    } label: {
                        Image(systemName: "externaldrive")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text("Erwarteter Pfad: /Volumes/\(settings.sourceVolumeName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("NAS") {
                TextField("Host", text: $settings.nasHost)
                TextField("Freigabe", text: $settings.nasShare)
                TextField("Benutzer", text: $settings.nasUser)
                SecureField("Passwort", text: $password)
                HStack {
                    Button("Passwort speichern") {
                        do {
                            try keychain.savePassword(password)
                            passwordStatus = "Gespeichert."
                        } catch {
                            passwordStatus = error.localizedDescription
                        }
                    }
                    .disabled(password.isEmpty)
                    if !passwordStatus.isEmpty {
                        Text(passwordStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Mount-Punkt", text: $settings.nasMountPoint)
                TextField("Ziel-Unterordner", text: $settings.targetSubpath)
            }
        }
        .onAppear {
            if let stored = try? keychain.readPassword() {
                password = stored
            }
        }
    }
}

private struct ScheduleTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Automatisches Backup aktivieren", isOn: $settings.autoBackupEnabled)
            HStack {
                Text("Intervall")
                Spacer()
                TextField("Stunden", value: $settings.autoBackupIntervalHours, format: .number)
                    .frame(width: 80)
                Text("Stunden")
            }
            if let lastBackup = settings.lastBackupDate {
                Text("Letztes erfolgreiches Backup: \(lastBackup.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Noch kein erfolgreiches Backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RetentionTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Picker("Aufbewahrung", selection: $settings.retentionMode) {
                Text("Unbegrenzt").tag(RetentionMode.unlimited)
                Text("Anzahl begrenzen").tag(RetentionMode.count)
                Text("Alter begrenzen").tag(RetentionMode.age)
            }
            .pickerStyle(.radioGroup)

            if settings.retentionMode == .count {
                Stepper("Snapshots behalten: \(settings.retentionCount)", value: $settings.retentionCount, in: 1...365)
            }
            if settings.retentionMode == .age {
                Stepper("Max. Alter (Tage): \(settings.retentionAgeDays)", value: $settings.retentionAgeDays, in: 1...3650)
            }
        }
    }
}

private struct AdvancedTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var newPattern: String = ""
    @State private var loginItemEnabled: Bool = LoginItemManager.isEnabled

    var body: some View {
        Form {
            Toggle("Bei Login starten", isOn: $loginItemEnabled)
                .onChange(of: loginItemEnabled) { _, newValue in
                    settings.launchAtLoginEnabled = newValue
                    LoginItemManager.setEnabled(newValue)
                }

            Toggle("Erweiterte Attribute sichern (-E)", isOn: $settings.includeExtendedAttributes)
            Text("Achtung: legt zusätzliche ._-Sidecar-Dateien an, die bei jedem Lauf neu übertragen werden und das Hardlink-Sharing zwischen Snapshots verhindern können.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Ausschlussmuster") {
                ForEach(settings.rsyncExcludePatterns, id: \.self) { pattern in
                    Text(pattern)
                }
                .onDelete { indexSet in
                    settings.rsyncExcludePatterns.remove(atOffsets: indexSet)
                }
                HStack {
                    TextField("Neues Muster, z.B. *.tmp", text: $newPattern)
                    Button("Hinzufügen") {
                        guard !newPattern.isEmpty else { return }
                        settings.rsyncExcludePatterns.append(newPattern)
                        newPattern = ""
                    }
                }
            }
        }
    }
}
