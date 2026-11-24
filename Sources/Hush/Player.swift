import AVFoundation
import AudioToolbox
import CoreAudio
import os

let log = Logger(subsystem: "hush", category: "player")
let sampleRate = 48000.0

/// Interleaved stereo float ring; one writer (network), one reader (audio thread).
final class Ring {
    private var buf: [Float]
    private var r = 0, w = 0  // absolute frame counters
    private var lock = os_unfair_lock()
    let capacity: Int
    private(set) var jumps = 0

    init(frames: Int) {
        capacity = frames
        buf = [Float](repeating: 0, count: frames * 2)
    }

    var count: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return w - r
    }

    /// Big-endian interleaved stereo PCM16, as the TV sends it.
    func write(bigEndian samples: UnsafePointer<Int16>, frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<frames {
            let j = ((w + i) % capacity) * 2
            buf[j] = Float(Int16(bigEndian: samples[i * 2])) / 32768
            buf[j + 1] = Float(Int16(bigEndian: samples[i * 2 + 1])) / 32768
        }
        w += frames
        if w - r > capacity { r = w - capacity }
    }

    /// Fills L/R, keeping the buffer between `target` and `maxFrames`; returns frames of real audio.
    func read(_ l: UnsafeMutablePointer<Float>, _ rr: UnsafeMutablePointer<Float>, frames: Int,
              target: Int, maxFrames: Int, gain: Float) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if w - r > maxFrames { r = w - target; jumps += 1 }  // fell behind (network burst): jump to live
        let n = min(frames, w - r)
        for i in 0..<n {
            let j = ((r + i) % capacity) * 2
            l[i] = buf[j] * gain
            rr[i] = buf[j + 1] * gain
        }
        for i in n..<frames { l[i] = 0; rr[i] = 0 }
        r += n
        return n
    }

    func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        r = w
    }
}

/// Plays what `feed` gets to the current output device with as little delay as it can: a small
/// adaptive jitter buffer and a 128-frame hardware I/O buffer, nothing else in between.
final class Player: ObservableObject {
    @Published var bufferMs = 0
    @Published var underruns = 0
    @Published var device = ""
    @Published var outputLatencyMs = 0
    @Published var volume: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(volume, forKey: "volume"); gain = Float(volume) }
    }
    @Published var targetMs: Double = UserDefaults.standard.object(forKey: "targetMs") as? Double ?? 40 {
        didSet { UserDefaults.standard.set(targetMs, forKey: "targetMs"); target = Int(targetMs / 1000 * sampleRate) }
    }

    private let ring = Ring(frames: Int(sampleRate) * 2)
    private var gain: Float = 1
    private var target = 1920
    private var starving = false
    private var pending = Data()  // touched only on the feeding queue
    private let engine = AVAudioEngine()

    init() {
        gain = Float(volume)
        target = Int(targetMs / 1000 * sampleRate)
        setupEngine()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.restartEngine() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.bufferMs = Int(Double(self.ring.count) / sampleRate * 1000)
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            let line = "buffer=\(self.bufferMs)ms underruns=\(self.underruns) jumps=\(self.ring.jumps) output=\(self.outputLatencyMs)ms device=\(self.device)"
            log.notice("\(line, privacy: .public)")
        }
    }

    /// Raw big-endian stereo PCM16 from the TV, any chunking.
    func feed(_ data: Data) {
        pending.append(data)
        let frames = pending.count / 4
        guard frames > 0 else { return }
        pending.withUnsafeBytes { raw in
            ring.write(bigEndian: raw.bindMemory(to: Int16.self).baseAddress!, frames: frames)
        }
        pending.removeFirst(frames * 4)
    }

    func reset() { ring.clear() }

    private func setupEngine() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let src = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            let l = bufs[0].mData!.assumingMemoryBound(to: Float.self)
            let r = bufs[1].mData!.assumingMemoryBound(to: Float.self)
            let n = Int(frameCount)
            // after a gap, wait until the target is buffered again instead of stuttering
            if self.starving && self.ring.count < self.target {
                for i in 0..<n { l[i] = 0; r[i] = 0 }
                return noErr
            }
            let got = self.ring.read(l, r, frames: n, target: self.target, maxFrames: self.target * 3,
                                     gain: self.gain)
            if got < n {
                if !self.starving && got > 0 { DispatchQueue.main.async { self.underruns += 1 } }
                self.starving = true
            } else {
                self.starving = false
            }
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)
        startEngine()
    }

    private func startEngine() {
        setSmallIOBuffer()
        do { try engine.start() } catch { log.error("engine start failed: \(error.localizedDescription, privacy: .public)") }
        refreshDevice()
    }

    private func restartEngine() {
        engine.stop()
        ring.clear()
        startEngine()
    }

    /// 128-frame (2.7 ms) hardware I/O buffer on the output device instead of the default 512.
    private func setSmallIOBuffer() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames: UInt32 = 128
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
    }

    private func refreshDevice() {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name)
        func u32(_ sel: AudioObjectPropertySelector) -> UInt32 {
            var v: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)
            AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v)
            return v
        }
        let frames = u32(kAudioDevicePropertyLatency) + u32(kAudioDevicePropertySafetyOffset)
            + u32(kAudioDevicePropertyBufferFrameSize)
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let label = (name?.takeRetainedValue() as String?) ?? "?"
        DispatchQueue.main.async {
            self.device = label
            self.outputLatencyMs = sr > 0 ? Int(Double(frames) / sr * 1000) : 0
        }
    }
}
