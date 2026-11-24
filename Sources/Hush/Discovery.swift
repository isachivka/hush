import Foundation
import Network

/// Finds LG webOS TVs on the local network. They announce themselves over Bonjour as AirPlay
/// receivers with `manufacturer=LG Electronics`; the TV's MAC (`deviceid`) identifies it across
/// DHCP address changes.
final class Discovery: ObservableObject {
    struct TV: Identifiable, Hashable {
        let id: String  // deviceid from the TXT record
        let name: String
        var host: String?
    }

    @Published private(set) var tvs: [TV] = []
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    private let q = DispatchQueue(label: "hush.discovery")

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        b.start(queue: q)
        browser = b
    }

    func host(of id: String) -> String? { tvs.first { $0.id == id }?.host }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [(TV, NWEndpoint)] = []
        for r in results {
            guard case let .bonjour(txt) = r.metadata,
                  txt["manufacturer"]?.hasPrefix("LG") == true,
                  let id = txt["deviceid"],
                  case let .service(name, _, _, _) = r.endpoint else { continue }
            let clean = name.replacingOccurrences(of: "[LG] ", with: "")
            found.append((TV(id: id, name: clean, host: nil), r.endpoint))
        }
        DispatchQueue.main.async {
            let old = Dictionary(self.tvs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.tvs = found.map { tv, _ in
                var t = tv
                t.host = old[tv.id]?.host
                return t
            }.sorted { $0.name < $1.name }
        }
        for (tv, endpoint) in found { resolve(tv.id, endpoint) }
    }

    /// Bonjour gives a service name; connect once to learn the TV's IPv4 address.
    private func resolve(_ id: String, _ endpoint: NWEndpoint) {
        guard resolving[id] == nil else { return }
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        resolving[id] = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                if case let .hostPort(h, _)? = c.currentPath?.remoteEndpoint {
                    let ip = "\(h)".components(separatedBy: "%")[0]
                    DispatchQueue.main.async {
                        if let i = self.tvs.firstIndex(where: { $0.id == id }) { self.tvs[i].host = ip }
                    }
                }
                c.cancel()
            case .failed, .cancelled:
                self.q.asyncAfter(deadline: .now() + 30) { self.resolving[id] = nil }
            default: break
            }
        }
        c.start(queue: q)
    }
}
