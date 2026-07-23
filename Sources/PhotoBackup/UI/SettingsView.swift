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
    @StateObject private var nasDiscovery = NASDiscovery()
    @State private var availableShares: [String] = []
    @State private var isLoadingShares = false
    @State private var shareLoadError: String?
    @State private var availableTargetFolders: [String] = []
    @State private var isLoadingTargetFolders = false
    @State private var targetFolderLoadError: String?
    private let keychain = KeychainStore()
    private let shareLister = NASShareLister()
    private let smbMounter = SMBMounter()

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
                HStack {
                    TextField("Host", text: $settings.nasHost)
                    Menu {
                        if nasDiscovery.discoveredHosts.isEmpty {
                            Text("Suche im Netzwerk läuft…")
                        } else {
                            ForEach(nasDiscovery.discoveredHosts) { host in
                                Button("\(host.displayName) (\(host.hostname))") {
                                    settings.nasHost = host.hostname
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "network")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                HStack {
                    TextField("Freigabe", text: $settings.nasShare)
                    Menu {
                        if isLoadingShares {
                            Text("Lädt…")
                        } else if availableShares.isEmpty {
                            Text("Noch nicht geladen")
                        } else {
                            ForEach(availableShares, id: \.self) { share in
                                Button(share) { settings.nasShare = share }
                            }
                        }
                        Divider()
                        Button("Freigaben laden") { Task { await loadShares() } }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if let shareLoadError {
                    Text(shareLoadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                HStack {
                    TextField("Ziel-Unterordner", text: $settings.targetSubpath)
                    Menu {
                        if isLoadingTargetFolders {
                            Text("Lädt…")
                        } else if availableTargetFolders.isEmpty {
                            Text("Noch nicht geladen")
                        } else {
                            ForEach(availableTargetFolders, id: \.self) { folder in
                                Button(folder) { settings.targetSubpath = folder }
                            }
                        }
                        Divider()
                        Button("Ordner laden") { Task { await loadTargetFolders() } }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if let targetFolderLoadError {
                    Text(targetFolderLoadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if let stored = try? keychain.readPassword() {
                password = stored
            }
            nasDiscovery.start()
        }
        .onDisappear {
            nasDiscovery.stop()
        }
    }

    @MainActor
    private func loadShares() async {
        shareLoadError = nil
        guard !settings.nasHost.isEmpty else {
            shareLoadError = "Bitte zuerst einen Host eintragen."
            return
        }
        guard !password.isEmpty else {
            shareLoadError = "Bitte zuerst das Passwort eintragen."
            return
        }
        isLoadingShares = true
        defer { isLoadingShares = false }
        do {
            availableShares = try await shareLister.listShares(
                host: settings.nasHost,
                user: settings.nasUser,
                password: password
            )
        } catch {
            shareLoadError = error.localizedDescription
        }
    }

    @MainActor
    private func loadTargetFolders() async {
        targetFolderLoadError = nil
        guard !settings.nasHost.isEmpty, !settings.nasShare.isEmpty else {
            targetFolderLoadError = "Bitte zuerst Host und Freigabe eintragen."
            return
        }
        guard !password.isEmpty else {
            targetFolderLoadError = "Bitte zuerst das Passwort eintragen."
            return
        }
        isLoadingTargetFolders = true
        defer { isLoadingTargetFolders = false }
        do {
            if !smbMounter.isMounted(mountPoint: settings.nasMountPoint) {
                try await smbMounter.mount(
                    host: settings.nasHost,
                    share: settings.nasShare,
                    user: settings.nasUser,
                    password: password,
                    mountPoint: settings.nasMountPoint
                )
            }
            let folders = NASFolderLister.subdirectories(under: settings.nasMountPoint)
            guard !folders.isEmpty else {
                targetFolderLoadError = "Keine Unterordner in dieser Freigabe gefunden."
                return
            }
            availableTargetFolders = folders
        } catch {
            targetFolderLoadError = error.localizedDescription
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
