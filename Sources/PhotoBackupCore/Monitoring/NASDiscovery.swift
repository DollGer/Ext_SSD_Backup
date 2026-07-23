import Foundation

/// Findet SMB-Server im lokalen Netzwerk per Bonjour (`_smb._tcp`), analog zu
/// `AvailableVolumes` für externe Laufwerke. Nutzt bewusst die klassische
/// `NetServiceBrowser`/`NetService`-API statt `NWBrowser`: Sie liefert über
/// `NetService.hostName` direkt einen auflösbaren Hostnamen, den `SMBMounter`
/// unverändert in der `smb://`-URL verwenden kann.
@MainActor
public final class NASDiscovery: NSObject, ObservableObject {
    public struct DiscoveredHost: Identifiable, Hashable {
        public let id: String
        public let displayName: String
        public let hostname: String
    }

    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []

    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []

    public override init() {
        super.init()
        browser.delegate = self
    }

    public func start() {
        discoveredHosts = []
        browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
    }

    public func stop() {
        browser.stop()
        resolvingServices.forEach { $0.stop() }
        resolvingServices.removeAll()
    }
}

@MainActor
extension NASDiscovery: NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        discoveredHosts.removeAll { $0.id == service.name }
    }
}

@MainActor
extension NASDiscovery: NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard var hostname = sender.hostName else { return }
        if hostname.hasSuffix(".") {
            hostname.removeLast()
        }
        guard !discoveredHosts.contains(where: { $0.id == sender.name }) else { return }
        discoveredHosts.append(DiscoveredHost(id: sender.name, displayName: sender.name, hostname: hostname))
        discoveredHosts.sort { $0.displayName < $1.displayName }
    }
}
