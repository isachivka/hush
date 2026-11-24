import Foundation
import Network

/// The sound of an LG webOS TV, taken the way the LG ThinQ app takes it for "listen to TV sound
/// privately" (see docs/protocol.md):
///
/// 1. SSAP websocket `wss://<tv>:3001`, registered with ThinQ's manifest (first time: the TV asks).
/// 2. Subscribe `soundshare/getStreamOutStatus` — without it the TV refuses to start.
/// 3. `soundshare/startStreamOut` → the TV mutes its speakers and serves TCP :9000.
/// 4. Read raw 48 kHz stereo 16-bit big-endian PCM from <tv>:9000.
/// 5. `soundshare/stopStreamOut` gives the sound back to the speakers.
///
/// Reconnects by itself (TV switched off and on, Wi-Fi drop, Mac asleep) while running.
final class SoundShare {
    enum State: Equatable {
        case off, connecting, pairing, starting, streaming
        case unreachable(String), refused(String)
    }

    var onAudio: ((Data) -> Void)?
    var onState: ((State) -> Void)?
    /// A client key the TV issued (first pairing) — store it and pass it next time.
    var onKey: ((String) -> Void)?

    private let host: String
    private var key: String?
    private let deviceName: String
    private let q = DispatchQueue(label: "hush.tv", qos: .userInteractive)
    private var ws: NWConnection?
    private var audio: NWConnection?
    private var running = false
    private var generation = 0
    private var state = State.off {
        didSet { if state != oldValue { let s = state; DispatchQueue.main.async { self.onState?(s) } } }
    }

    init(host: String, key: String?, deviceName: String) {
        self.host = host
        self.key = key
        self.deviceName = deviceName
    }

    func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            self.connect()
        }
    }

    /// Stops the stream on the TV (its speakers play again) and closes everything.
    func stop(wait: Bool = false) {
        let done = DispatchSemaphore(value: 0)
        q.async {
            let wasRunning = self.running
            self.running = false
            self.generation += 1
            self.audio?.cancel()
            self.audio = nil
            guard wasRunning, let ws = self.ws, let key = self.key else {
                self.teardown(); done.signal(); return
            }
            self.send(ws, ["id": "stop", "type": "request", "uri": "\(Self.soundshare)/stopStreamOut",
                           "payload": ["deviceParam": ["key": key]]]) {
                self.q.asyncAfter(deadline: .now() + 0.2) { self.teardown(); done.signal() }
            }
        }
        if wait { _ = done.wait(timeout: .now() + 1.5) }
    }

    private static let soundshare = "ssap://com.webos.service.soundshare"

    // ── control channel ──

    private func teardown() {
        ws?.cancel(); ws = nil
        audio?.cancel(); audio = nil
        state = .off
    }

    private func retry(_ failure: State, after: Double = 3) {
        guard running else { return }
        generation += 1
        audio?.cancel(); audio = nil
        ws?.cancel(); ws = nil
        state = failure
        let gen = generation
        q.asyncAfter(deadline: .now() + after) { if self.running && self.generation == gen { self.connect() } }
    }

    /// Pairing was declined or cancelled on the TV: don't keep asking.
    private func giveUp(_ failure: State) {
        running = false
        generation += 1
        ws?.cancel(); ws = nil
        audio?.cancel(); audio = nil
        state = failure
    }

    private func connect() {
        generation += 1
        let gen = generation
        state = .connecting
        let tls = NWProtocolTLS.Options()
        // the TV's certificate is self-signed
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, ok in ok(true) }, q)
        let params = NWParameters(tls: tls)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let c = NWConnection(to: .url(URL(string: "wss://\(host):3001")!), using: params)
        ws = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.generation == gen else { return }
            switch st {
            case .ready:
                self.register(c)
                self.receive(c, gen)
            case .failed, .waiting: self.retry(.unreachable("TV is off or unreachable"))
            default: break
            }
        }
        c.start(queue: q)
    }

    private func register(_ c: NWConnection) {
        var manifest = try! JSONSerialization.jsonObject(with: Data(lgMobileManifest.utf8)) as! [String: Any]
        manifest["deviceName"] = deviceName
        send(c, ["id": "reg", "type": "register",
                 "payload": ["client-key": key ?? "", "pairingType": "PROMPT", "manifest": manifest]])
    }

    private func receive(_ c: NWConnection, _ gen: Int) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, self.generation == gen else { return }
            if let data, let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(c, m) }
            if err != nil { self.retry(.unreachable("Lost the connection to the TV")); return }
            self.receive(c, gen)
        }
    }

    private func handle(_ c: NWConnection, _ m: [String: Any]) {
        let type = m["type"] as? String
        let id = m["id"] as? String
        let payload = m["payload"] as? [String: Any] ?? [:]
        switch (type, id) {
        case ("response", "reg"):
            if payload["pairingType"] != nil && key == nil { state = .pairing }  // the TV asks on screen
        case ("registered", _):
            guard let k = payload["client-key"] as? String else { return }
            if k != key { key = k; DispatchQueue.main.async { self.onKey?(k) } }
            startStream(c, k)
        case ("error", "reg"):
            if key == nil {
                giveUp(.refused("Pairing was declined on the TV"))
            } else {
                key = nil  // the TV forgot us: ask again
                retry(.connecting, after: 0.5)
            }
        case ("response", "go"):
            if payload["returnValue"] as? Bool == true && payload["errorText"] == nil {
                openAudio()
            } else {
                retry(.refused("The TV refused: \(payload["errorText"] as? String ?? "unknown error")"))
            }
        case ("error", "go"):
            retry(.refused(Self.explain(payload)))
        default:
            break
        }
    }

    /// The TV's reasons, from ThinQ's own list.
    private static func explain(_ payload: [String: Any]) -> String {
        let params = payload["params"] as? [String: Any]
        let result = (params?["typeParams"] as? [String: Any])?["result"] as? String
        switch result {
        case "BT_SINK": return "The TV is playing to Bluetooth"
        case "MIRACAST_PLAYING", "MIRACAST_TX_PLAYING": return "The TV is screen mirroring"
        case "MINIMAL_APP": return "The current TV app does not allow it"
        case "MAX_CONNECTION": return "Too many listeners on the TV"
        default: return "The TV refused: \(payload["errorText"] as? String ?? result ?? "unknown error")"
        }
    }

    private func startStream(_ c: NWConnection, _ key: String) {
        state = .starting
        var addr = "0.0.0.0"
        if case let .hostPort(h, _)? = c.currentPath?.localEndpoint {
            addr = "\(h)".components(separatedBy: "%")[0]
        }
        send(c, ["id": "status", "type": "subscribe", "uri": "\(Self.soundshare)/getStreamOutStatus",
                 "payload": ["deviceParam": ["key": key], "subscribe": true]])
        send(c, ["id": "go", "type": "request", "uri": "\(Self.soundshare)/startStreamOut",
                 "payload": ["deviceParam": ["key": key, "addr": addr, "port": "9000"]]])
    }

    private func send(_ c: NWConnection, _ obj: [String: Any], then: (() -> Void)? = nil) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ssap", metadata: [meta])
        c.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in then?() })
    }

    // ── audio ──

    private func openAudio() {
        let gen = generation
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        params.serviceClass = .interactiveVoice
        let a = NWConnection(host: NWEndpoint.Host(host), port: 9000, using: params)
        audio = a
        a.stateUpdateHandler = { [weak self] st in
            guard let self, self.generation == gen else { return }
            switch st {
            case .ready: self.state = .streaming
            case .failed, .waiting: self.retry(.unreachable("The sound stream dropped"), after: 1)
            default: break
            }
        }
        a.start(queue: q)
        readAudio(a, gen)
    }

    private func readAudio(_ a: NWConnection, _ gen: Int) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, self.generation == gen else { return }
            if let data, !data.isEmpty { self.onAudio?(data) }
            if done || err != nil { self.retry(.unreachable("The sound stream dropped"), after: 1); return }
            self.readAudio(a, gen)
        }
    }
}
