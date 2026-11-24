import AppKit
import Combine
import SwiftUI

/// A TV this Mac has paired with. `id` is the TV's Bonjour deviceid (its MAC), or `ip:<address>`
/// for a TV added by address.
struct PairedTV: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var host: String
    var key: String?
}

final class Model: ObservableObject {
    let player = Player()
    let discovery = Discovery()

    @Published var state = SoundShare.State.off
    @Published private(set) var paired: [PairedTV] = Model.load()
    @Published var selectedID: String? = UserDefaults.standard.string(forKey: "selectedTV") {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedTV"); if !batching { restart() } }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); if !batching { restart() } }
    }

    private var session: SoundShare?
    private var sessionHost: String?
    private let deviceName = "Hush · " + (Host.current().localizedName ?? "Mac")

    var selected: PairedTV? { paired.first { $0.id == selectedID } ?? paired.first }

    init() {
        discovery.start()
        // follow a paired TV to its new address after a DHCP change
        discovery.$tvs.receive(on: DispatchQueue.main).sink { [weak self] tvs in
            guard let self else { return }
            for tv in tvs {
                if let host = tv.host, let i = self.paired.firstIndex(where: { $0.id == tv.id }),
                   self.paired[i].host != host {
                    self.paired[i].host = host
                    self.save()
                    if self.paired[i].id == self.selected?.id { self.restart() }
                }
            }
        }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: nil) { [weak self] _ in self?.session?.stop(wait: true) }
        restart()
    }

    private var bag = Set<AnyCancellable>()
    private var batching = false

    func pair(id: String, name: String, host: String) {
        if let i = paired.firstIndex(where: { $0.id == id }) {
            paired[i].host = host
            paired[i].key = nil  // pair again
        } else {
            paired.append(PairedTV(id: id, name: name, host: host, key: nil))
        }
        save()
        batching = true
        enabled = true
        selectedID = id
        batching = false
        restart()
    }

    func forget(_ id: String) {
        if selected?.id == id { session?.stop(); session = nil }
        paired.removeAll { $0.id == id }
        save()
        batching = true
        selectedID = paired.first?.id
        batching = false
        restart()
    }

    /// (Re)connects to the selected TV, or stops when disabled.
    func restart() {
        session?.stop()
        session = nil
        player.reset()
        guard enabled, let tv = selected else { state = .off; return }
        let s = SoundShare(host: tv.host, key: tv.key, deviceName: deviceName)
        s.onState = { [weak self] st in
            guard let self, self.session === s else { return }
            if st == .streaming && self.state != .streaming { self.player.reset() }
            self.state = st
        }
        s.onAudio = { [weak self] data in self?.player.feed(data) }
        s.onKey = { [weak self] key in
            guard let self, let i = self.paired.firstIndex(where: { $0.id == tv.id }) else { return }
            self.paired[i].key = key
            self.save()
        }
        session = s
        s.start()
    }

    var status: String {
        guard enabled else { return "Off" }
        guard let tv = selected else { return "Pair a TV below" }
        switch state {
        case .off: return "Off"
        case .connecting: return "Connecting to \(tv.name)…"
        case .pairing: return "Accept the request on the TV"
        case .starting: return "Starting the sound…"
        case .streaming: return "Playing \(tv.name)"
        case .unreachable(let why), .refused(let why): return why
        }
    }

    var live: Bool { enabled && state == .streaming }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(paired), forKey: "pairedTVs")
    }

    private static func load() -> [PairedTV] {
        guard let d = UserDefaults.standard.data(forKey: "pairedTVs") else { return [] }
        return (try? JSONDecoder().decode([PairedTV].self, from: d)) ?? []
    }
}

struct Panel: View {
    @ObservedObject var m: Model
    @ObservedObject var p: Player
    @ObservedObject var d: Discovery
    @State private var pairing = false
    @State private var address = ""

    init(m: Model) {
        self.m = m
        p = m.player
        d = m.discovery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hush").font(.headline)
                Spacer()
                Circle().fill(m.live ? .green : (m.enabled && m.selected != nil ? .orange : .secondary))
                    .frame(width: 8, height: 8)
                Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !m.paired.isEmpty {
                Toggle("Play the TV's sound on this Mac", isOn: $m.enabled)
                Text("Off, or quitting Hush, gives the sound back to the TV's speakers.")
                    .font(.caption2).foregroundStyle(.secondary)
                if m.paired.count > 1 {
                    Picker("TV", selection: Binding(get: { m.selected?.id ?? "" }, set: { m.selectedID = $0 })) {
                        ForEach(m.paired) { Text($0.name).tag($0.id) }
                    }
                }
                slider("Volume", "\(Int(p.volume * 100))%", $p.volume, 0...2, step: nil)
                slider("Buffer", "\(Int(p.targetMs)) ms", $p.targetMs, 10...200, step: 5)
                Text("Lower is less delay; raise it if the sound stutters.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("→ \(p.device) · output \(p.outputLatencyMs) ms · buffered \(p.bufferMs) ms · underruns \(p.underruns)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if pairing || m.paired.isEmpty { pairSection } else {
                Button("Pair a TV…") { pairing = true }.buttonStyle(.link)
            }
            Divider()
            HStack {
                if let tv = m.selected {
                    Button("Forget \(tv.name)") { m.forget(tv.id) }.buttonStyle(.link).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var pairSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LG TVs on this network").font(.subheadline)
            if d.tvs.isEmpty {
                Text("Looking… The TV has to be on and on the same network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(d.tvs) { tv in
                HStack {
                    Text(tv.name)
                    Text(tv.host ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(m.paired.contains { $0.id == tv.id } ? "Pair again" : "Pair") {
                        if let host = tv.host { m.pair(id: tv.id, name: tv.name, host: host); pairing = false }
                    }.disabled(tv.host == nil)
                }
            }
            HStack {
                TextField("or the TV's IP address", text: $address).textFieldStyle(.roundedBorder)
                Button("Pair") {
                    let a = address.trimmingCharacters(in: .whitespaces)
                    m.pair(id: "ip:\(a)", name: "LG TV \(a)", host: a)
                    address = ""; pairing = false
                }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("The TV asks to allow the connection the first time; accept it with the remote.")
                .font(.caption2).foregroundStyle(.secondary)
            if !m.paired.isEmpty { Button("Cancel") { pairing = false }.buttonStyle(.link) }
        }
    }

    private func slider(_ title: String, _ value: String, _ binding: Binding<Double>,
                        _ range: ClosedRange<Double>, step: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            if let step { Slider(value: binding, in: range, step: step) } else { Slider(value: binding, in: range) }
        }
    }
}

@main
struct HushApp: App {
    @StateObject private var m = Model()

    var body: some Scene {
        MenuBarExtra {
            Panel(m: m)
        } label: {
            Image(systemName: m.live ? "headphones.circle.fill" : "headphones.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
