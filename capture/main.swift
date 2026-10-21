// meet-capture: records a mic and all system audio output into two 16 kHz mono
// WAV files, without touching the output device.
//
//   meet-capture <out-dir>
//   meet-capture --list-inputs     (input device names; * = default)
//
// Mic: the default input, or the first input whose name contains $MEET_MIC.
// Writes <out-dir>/mic.wav, system.wav, capture.json (timing) and levels.json
// (live peaks). Prints "ready" on stdout once both streams run. Stops on
// SIGTERM/SIGINT, always within ~2 s.
//
// Both tracks use plain Core Audio IOProcs and are rebuilt whenever the device,
// sample rate or format changes (e.g. Bluetooth earbuds switching to headset
// mode at 16 kHz when a call opens their mic). As a safety net, the real
// incoming sample rate is measured and corrected if it disagrees with the
// format Core Audio reported.

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let logClock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) { FileHandle.standardError.write(Data((logClock.string(from: Date()) + " " + s + "\n").utf8)) }
func fail(_ s: String) -> Never { log("error: " + s); exit(1) }

let sampleRate = 16000.0
let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
var stopping = false

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    return f.string(from: Date())
}

func hostNow() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

func writeJSON(_ obj: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    let tmp = url.appendingPathExtension("tmp")
    try? data.write(to: tmp)
    _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
}

func meetError(_ msg: String, _ code: OSStatus = 1) -> NSError {
    NSError(domain: "meet", code: Int(code), userInfo: [NSLocalizedDescriptionKey: msg])
}

// MARK: - Track writer (resample to 16 kHz mono, fill gaps, track peaks)

final class TrackWriter {
    let name: String
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let lock = NSLock()
    private(set) var firstHostSeconds: Double?
    private(set) var framesWritten: Int64 = 0
    private var peakRecent: Float = 0
    private var peakMax: Float = 0
    private var filledRecent: Int64 = 0
    private var writtenRecent: Int64 = 0

    init(name: String, url: URL) throws {
        self.name = name
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let file, buffer.frameLength > 0 else { return }

        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converter?.downmix = true
            converterInput = buffer.format
        }
        guard let converter else { return }

        // Keep the track on a wall-clock timeline: if buffers stopped arriving
        // (device switch, rebuild), pad the hole with silence.
        if hostTime != 0 {
            let t = AVAudioTime.seconds(forHostTime: hostTime)
            if let first = firstHostSeconds {
                let gap = Int64((t - first) * sampleRate) - framesWritten
                if gap > Int64(sampleRate / 10) { writeSilence(gap, to: file) }
            } else {
                firstHostSeconds = t
            }
        }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { log("\(name): convert error \(error)"); return }
        guard out.frameLength > 0 else { return }

        if let ch = out.floatChannelData?[0] {
            var peak: Float = 0
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[i])) }
            peakRecent = max(peakRecent, peak)
            peakMax = max(peakMax, peak)
        }
        do {
            try file.write(from: out)
            framesWritten += Int64(out.frameLength)
            writtenRecent += Int64(out.frameLength)
        } catch {
            log("\(name): write error \(error)")
        }
    }

    private func writeSilence(_ frames: Int64, to file: AVAudioFile) {
        var left = min(frames, Int64(sampleRate * 3600))
        filledRecent += left
        writtenRecent += left
        while left > 0 {
            let n = AVAudioFrameCount(min(left, 16000))
            guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: n) else { return }
            buf.frameLength = n // zero-filled
            try? file.write(from: buf)
            framesWritten += Int64(n)
            left -= Int64(n)
        }
    }

    /// Peaks and gap-filled share since the last call, plus the max peak since start.
    func takeLevels() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let r: [String: Any] = [
            "peak_recent": Double(peakRecent),
            "peak_max": Double(peakMax),
            "filled_recent": writtenRecent > 0 ? Double(filledRecent) / Double(writtenRecent) : 0,
            "seconds": Double(framesWritten) / sampleRate,
        ]
        peakRecent = 0
        filledRecent = 0
        writtenRecent = 0
        return r
    }

    /// Pad to `endHost` so both tracks end together, then finalize the WAV.
    func close(endHost: Double) {
        lock.lock(); defer { lock.unlock() }
        if let file, let first = firstHostSeconds {
            let gap = Int64((endHost - first) * sampleRate) - framesWritten
            if gap > 0 { writeSilence(gap, to: file) }
        }
        file = nil // AVAudioFile finalizes the WAV header on deinit
    }
}

// MARK: - Core Audio helpers

let globalScope = kAudioObjectPropertyScopeGlobal
let inputScope = kAudioObjectPropertyScopeInput

func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = globalScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = globalScope, _ value: inout T) -> OSStatus {
    var addr = address(sel, scope)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
}

func getIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = globalScope) -> [AudioObjectID] {
    var addr = address(sel, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var s: Unmanaged<CFString>?
    guard getProp(obj, sel, globalScope, &s) == noErr, let s else { return nil }
    return s.takeRetainedValue() as String
}

func defaultDevice(_ sel: AudioObjectPropertySelector) throws -> AudioDeviceID {
    var dev = AudioDeviceID(kAudioObjectUnknown)
    let err = getProp(AudioObjectID(kAudioObjectSystemObject), sel, globalScope, &dev)
    guard err == noErr, dev != kAudioObjectUnknown else { throw meetError("no default device (\(err))", err) }
    return dev
}

/// Input device to record: first one whose name contains `match`, else the default input.
func pickInputDevice(_ match: String?, quiet: Bool = false) throws -> AudioDeviceID {
    if let match, !match.isEmpty {
        for dev in getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        where !getIDs(dev, kAudioDevicePropertyStreams, inputScope).isEmpty {
            if let name = getString(dev, kAudioObjectPropertyName), name.localizedCaseInsensitiveContains(match) { return dev }
        }
        if !quiet { log("mic: no input device matching \"\(match)\", using the default input") }
    }
    return try defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
}

/// Property listeners that are removed together.
final class Listeners {
    private var items: [(AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, AudioObjectPropertyListenerBlock)] = []

    func add(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = globalScope,
             queue: DispatchQueue, _ handler: @escaping () -> Void) {
        var addr = address(sel, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(obj, &addr, queue, block) == noErr { items.append((obj, addr, queue, block)) }
    }

    func removeAll() {
        for (obj, addr, queue, block) in items {
            var a = addr
            // Must pass the same queue the block was added with, or it isn't removed.
            AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
        }
        items.removeAll()
    }
}

let standardRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]
func snapRate(_ r: Double) -> Double {
    let best = standardRates.min { abs($0 - r) < abs($1 - r) }!
    return abs(best / r - 1) < 0.05 ? best : r.rounded()
}

// MARK: - Capture base: one IOProc, rebuilt on any device/format change

class HALCapture {
    let name: String
    let writer: TrackWriter
    let control: DispatchQueue  // serial; all start/stop/rebuild work happens here
    let ioQueue: DispatchQueue
    let listeners = Listeners()

    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    var rateOverride: Double?
    private var mismatches = 0
    private var rebuildScheduled = false
    private var activeSignature: String?
    private var rebuildTimes: [Double] = []
    private(set) var rebuilds = 0

    // Rate check state (ioQueue only)
    private var rcStart = 0.0, rcLast = 0.0, rcFrames = 0.0, rcIgnoreUntil = 0.0

    init(name: String, writer: TrackWriter, control: DispatchQueue) {
        self.name = name
        self.writer = writer
        self.control = control
        self.ioQueue = DispatchQueue(label: "meet.\(name).io", qos: .userInitiated)
    }

    // Subclass hooks
    func makeDevice() throws -> (AudioDeviceID, AudioStreamBasicDescription) { fatalError() }
    func destroyDevice() {}
    func addListeners() {}
    /// Identity of what we're recording (device, rate, channels). A notification
    /// that leaves this unchanged is ignored, so spurious device chatter (e.g.
    /// from Teams' audio driver) can't make us toggle the mic on and off.
    func signature() -> String? { nil }
    /// Which buffer of the IOProc input holds our audio.
    func pickBuffer(_ abl: UnsafeMutableAudioBufferListPointer) -> AudioBuffer { abl[0] }

    func start() throws {
        var (dev, asbd) = try makeDevice()
        if let r = rateOverride { asbd.mSampleRate = r }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            destroyDevice()
            throw meetError("\(name): unsupported format \(asbd)")
        }
        device = dev
        format = fmt
        rcStart = 0; rcFrames = 0; rcIgnoreUntil = hostNow() + 1.0

        var err = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, ioQueue) { [unowned self] _, inData, inTime, _, _ in
            self.handle(inData, inTime.pointee)
        }
        if err == noErr { err = AudioDeviceStart(dev, procID) }
        if err != noErr {
            stop()
            throw meetError("\(name): cannot start audio device (OSStatus \(err))", err)
        }
        addListeners()
        activeSignature = signature()
        log("\(name): recording at \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch")
    }

    func stop() {
        listeners.removeAll()
        if device != kAudioObjectUnknown, let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        device = AudioDeviceID(kAudioObjectUnknown)
        destroyDevice()
    }

    /// Debounced stop + start on the control queue (device or format changed).
    /// `force`: rebuild even if the device/rate/channels look unchanged (used when
    /// the audio itself shows the format is wrong).
    func scheduleRebuild(_ reason: String, force: Bool = false) {
        control.async { [self] in
            guard !rebuildScheduled else { return }
            rebuildScheduled = true
            // Back off if rebuilds keep coming: at most one per 5 s after 3 in a minute.
            let now = hostNow()
            rebuildTimes = rebuildTimes.filter { now - $0 < 60 }
            let delay = rebuildTimes.count >= 3 ? 5.0 : 0.5
            control.asyncAfter(deadline: .now() + delay) { [self] in
                rebuildScheduled = false
                guard !stopping else { return }
                if !force, let sig = signature(), sig == activeSignature { return } // nothing changed
                if !force { rateOverride = nil; mismatches = 0 }
                rebuildTimes.append(hostNow())
                rebuilds += 1
                log("\(name): rebuilding (\(reason))")
                stop()
                for attempt in 1...6 {
                    do { try start(); return } catch {
                        log("\(name): restart attempt \(attempt) failed: \(error.localizedDescription)")
                        Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
                    }
                }
            }
        }
    }

    private func handle(_ inData: UnsafePointer<AudioBufferList>, _ ts: AudioTimeStamp) {
        guard let fmt = format else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count > 0 else { return }

        let buffer: AVAudioPCMBuffer?
        if !fmt.isInterleaved && fmt.channelCount > 1 {
            buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil)
        } else {
            var one = AudioBufferList(mNumberBuffers: 1, mBuffers: pickBuffer(abl))
            buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: &one, deallocator: nil)
        }
        guard let buffer else { scheduleRebuild("buffer does not match format", force: true); return }

        let hostValid = ts.mFlags.contains(.hostTimeValid)
        if hostValid { checkRate(AVAudioTime.seconds(forHostTime: ts.mHostTime), Double(buffer.frameLength), fmt.sampleRate) }
        writer.append(buffer, hostTime: hostValid ? ts.mHostTime : 0)
    }

    /// Compare frames received against elapsed host time; a mismatch means the
    /// format we were told is stale (the original Bluetooth bug).
    private func checkRate(_ t: Double, _ frames: Double, _ expected: Double) {
        if t < rcIgnoreUntil { return }
        if rcStart == 0 || t - rcLast > 0.5 { // start, or a pause: restart the window
            rcStart = t; rcLast = t; rcFrames = frames
            return
        }
        rcLast = t
        let elapsed = t - rcStart
        if elapsed >= 3 {
            let measured = rcFrames / elapsed
            rcStart = t; rcFrames = frames
            if abs(measured / expected - 1) > 0.15 {
                rcIgnoreUntil = .infinity // until rebuilt
                control.async { [self] in
                    mismatches += 1
                    log("\(name): format says \(Int(expected)) Hz but audio arrives at ~\(Int(measured)) Hz")
                    if mismatches >= 2 { rateOverride = snapRate(measured) }
                    scheduleRebuild("sample-rate mismatch", force: true)
                }
            }
        } else {
            rcFrames += frames
        }
    }
}

// MARK: - System audio via a Core Audio process tap

final class SystemCapture: HALCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)

    override func makeDevice() throws -> (AudioDeviceID, AudioStreamBasicDescription) {
        func check(_ err: OSStatus, _ what: String) throws {
            if err != noErr { destroyDevice(); throw meetError("\(what) failed (OSStatus \(err))", err) }
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "meet-capture"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted // you keep hearing everything
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create process tap")

        // Tap-only aggregate: no output sub-device, so Bluetooth headsets aren't
        // pulled into the device (and their mic isn't opened by us).
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meet-capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "create aggregate device")

        var asbd = AudioStreamBasicDescription()
        try check(getProp(tapID, kAudioTapPropertyFormat, globalScope, &asbd), "read tap format")
        return (aggID, asbd)
    }

    override func destroyDevice() {
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    override func addListeners() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        listeners.add(sys, kAudioHardwarePropertyDefaultOutputDevice, queue: control) { [unowned self] in scheduleRebuild("output device changed") }
        listeners.add(tapID, kAudioTapPropertyFormat, queue: control) { [unowned self] in scheduleRebuild("tap format changed") }
        listeners.add(aggID, kAudioDevicePropertyNominalSampleRate, queue: control) { [unowned self] in scheduleRebuild("sample rate changed") }
        if let out = try? defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            listeners.add(out, kAudioDevicePropertyNominalSampleRate, queue: control) { [unowned self] in scheduleRebuild("output sample rate changed") }
            listeners.add(out, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, queue: control) { [unowned self] in scheduleRebuild("output channels changed") }
        }
    }

    override func signature() -> String? {
        var asbd = AudioStreamBasicDescription()
        guard tapID != kAudioObjectUnknown, getProp(tapID, kAudioTapPropertyFormat, globalScope, &asbd) == noErr else { return nil }
        let out = (try? defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) ?? 0
        return "\(out)/\(asbd.mSampleRate)/\(asbd.mChannelsPerFrame)/\(asbd.mFormatFlags)"
    }

    // The tap is the aggregate's last input stream.
    override func pickBuffer(_ abl: UnsafeMutableAudioBufferListPointer) -> AudioBuffer { abl[abl.count - 1] }
}

// MARK: - Microphone via an IOProc on the input device (shared; other apps unaffected)

final class MicCapture: HALCapture {
    let match: String?
    private var micID = AudioDeviceID(kAudioObjectUnknown)

    init(writer: TrackWriter, control: DispatchQueue, match: String?) {
        self.match = match
        super.init(name: "mic", writer: writer, control: control)
    }

    override func makeDevice() throws -> (AudioDeviceID, AudioStreamBasicDescription) {
        let dev = try pickInputDevice(match)
        guard let stream = getIDs(dev, kAudioDevicePropertyStreams, inputScope).first else {
            throw meetError("input device has no input streams")
        }
        var asbd = AudioStreamBasicDescription()
        let err = getProp(stream, kAudioStreamPropertyVirtualFormat, globalScope, &asbd)
        guard err == noErr else { throw meetError("cannot read mic format (OSStatus \(err))", err) }
        micID = dev
        log("mic: using \"\(getString(dev, kAudioObjectPropertyName) ?? "?")\"")
        return (dev, asbd)
    }

    override func signature() -> String? {
        guard let dev = try? pickInputDevice(match, quiet: true),
              let stream = getIDs(dev, kAudioDevicePropertyStreams, inputScope).first else { return nil }
        var asbd = AudioStreamBasicDescription()
        guard getProp(stream, kAudioStreamPropertyVirtualFormat, globalScope, &asbd) == noErr else { return nil }
        return "\(dev)/\(asbd.mSampleRate)/\(asbd.mChannelsPerFrame)/\(asbd.mFormatFlags)"
    }

    override func addListeners() {
        if match == nil || match!.isEmpty {
            listeners.add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, queue: control) { [unowned self] in
                scheduleRebuild("default input changed")
            }
        }
        listeners.add(micID, kAudioDevicePropertyNominalSampleRate, queue: control) { [unowned self] in scheduleRebuild("mic sample rate changed") }
        listeners.add(micID, kAudioDevicePropertyStreamConfiguration, inputScope, queue: control) { [unowned self] in scheduleRebuild("mic channels changed") }
        listeners.add(micID, kAudioDevicePropertyDeviceIsAlive, queue: control) { [unowned self] in scheduleRebuild("mic disconnected") }
    }
}

// MARK: - `meet-capture --list-inputs`: input device names, for MEET_MIC

if CommandLine.arguments.dropFirst().first == "--list-inputs" {
    let def = try? defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    for dev in getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    where !getIDs(dev, kAudioDevicePropertyStreams, inputScope).isEmpty {
        print((dev == def ? "* " : "  ") + (getString(dev, kAudioObjectPropertyName) ?? "?"))
    }
    exit(0)
}

// MARK: - Responsibility disclaim
// macOS normally attributes mic/system-audio permission to the app that launched
// us (Terminal, iTerm2, Raycast...). Re-spawning ourselves with "disclaim"
// makes meet-capture its own responsible process, so the grant belongs to
// meet-capture (via its embedded Info.plist) no matter who launches it.

var childPid: pid_t = 0

func runDisclaimedChild() -> Bool {
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim"),
          let exe = Bundle.main.executablePath else { return false }
    let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    guard setDisclaim(&attr, 1) == 0 else { return false }

    var env = ProcessInfo.processInfo.environment
    env["MEET_CAPTURE_DISCLAIMED"] = "1"
    let argv = CommandLine.arguments.map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    guard posix_spawn(&childPid, exe, nil, &attr, argv, envp) == 0 else { return false }

    for sig in [SIGTERM, SIGINT] { signal(sig) { s in kill(childPid, s) } }
    var status: Int32 = 0
    while waitpid(childPid, &status, 0) == -1 && errno == EINTR {}
    exit((status & 0x7f) == 0 ? (status >> 8) & 0xff : 1)
}

if ProcessInfo.processInfo.environment["MEET_CAPTURE_DISCLAIMED"] == nil {
    _ = runDisclaimedChild() // only returns if disclaiming isn't possible; then run in-process
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 2 else { fail("usage: meet-capture <out-dir>") }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized: break
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
    sem.wait()
    if !granted { fail("microphone permission denied. Grant it in System Settings > Privacy & Security > Microphone.") }
default:
    fail("microphone permission denied. Grant it in System Settings > Privacy & Security > Microphone.")
}

let micWriter: TrackWriter
let sysWriter: TrackWriter
do {
    micWriter = try TrackWriter(name: "mic", url: outDir.appendingPathComponent("mic.wav"))
    sysWriter = try TrackWriter(name: "system", url: outDir.appendingPathComponent("system.wav"))
} catch {
    fail("cannot create output files: \(error.localizedDescription)")
}

let control = DispatchQueue(label: "meet.control")
let refHostSeconds = hostNow()
let startedAt = isoNow()
let sys = SystemCapture(name: "system", writer: sysWriter, control: control)
let mic = MicCapture(writer: micWriter, control: control, match: ProcessInfo.processInfo.environment["MEET_MIC"])

// Mic first: it's quick, and a stall in system audio must not lose your side too.
var startError: String?
control.sync {
    do { try mic.start() } catch { startError = "microphone: \(error.localizedDescription)" }
}
if let startError { fail(startError) }

// System audio: macOS's audio service occasionally takes tens of seconds to start
// a tap. Wait briefly so quick hard failures (no tap support...) still abort the
// start; otherwise report "ready" now and let it finish in the background.
let sysStarted = DispatchSemaphore(value: 0)
var sysError: String?
control.async {
    let t0 = hostNow()
    do { try sys.start() } catch { sysError = "system audio: \(error.localizedDescription)" }
    if hostNow() - t0 > 3 { log("system: start took \(Int(hostNow() - t0)) s (macOS audio service was slow)") }
    sysStarted.signal()
}
if sysStarted.wait(timeout: .now() + 3) == .success {
    if let sysError { control.sync { mic.stop() }; fail(sysError) }
} else {
    log("system: still starting after 3 s; recording the mic meanwhile")
    DispatchQueue.global().async {
        sysStarted.wait()
        if let sysError { log(sysError + " (the system track will be empty)") }
    }
}

let captureURL = outDir.appendingPathComponent("capture.json")
let levelsURL = outDir.appendingPathComponent("levels.json")

func trackInfo(_ w: TrackWriter) -> [String: Any] {
    var d: [String: Any] = ["file": "\(w.name).wav", "seconds": Double(w.framesWritten) / sampleRate]
    if let first = w.firstHostSeconds { d["offset_sec"] = max(0, first - refHostSeconds) }
    return d
}

writeJSON(["started_at": startedAt, "pid": Int(getpid())], to: captureURL)

// Live levels for `meet status`
let levelsTimer = DispatchSource.makeTimerSource(queue: .main)
levelsTimer.schedule(deadline: .now() + 2, repeating: 2)
levelsTimer.setEventHandler {
    var m = micWriter.takeLevels(), y = sysWriter.takeLevels()
    m["rebuilds"] = mic.rebuilds
    y["rebuilds"] = sys.rebuilds
    writeJSON(["updated_at": isoNow(), "mic": m, "system": y], to: levelsURL)
}
levelsTimer.resume()

/// Finalize the files first, then try to release the devices; never hang.
func shutdown() {
    if stopping { return }
    stopping = true
    levelsTimer.cancel()
    let end = hostNow()
    micWriter.close(endHost: end)
    sysWriter.close(endHost: end)
    writeJSON([
        "started_at": startedAt,
        "ended_at": isoNow(),
        "tracks": ["mic": trackInfo(micWriter), "system": trackInfo(sysWriter)],
    ], to: captureURL)
    print("stopped")
    fflush(stdout)
    let done = DispatchSemaphore(value: 0)
    control.async { mic.stop(); sys.stop(); done.signal() }
    if done.wait(timeout: .now() + 2) == .timedOut { log("devices did not release in 2s; exiting anyway") }
    _exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler(handler: shutdown)
    src.resume()
    signalSources.append(src)
}

print("ready")
dispatchMain()
