// Meet Transcriber.app: menu bar front end for the `meet` CLI.
//
// URL scheme (for Raycast, Shortcuts, hotkeys):
//   open "meetbar://start?name=Pricing%20sync"    open "meetbar://stop?tags=pricing,q4"
//
// Shows a red dot + timer in the menu bar while recording, and a panel to start
// (with a name), watch levels, stop (with tags), retry failed transcriptions and
// open recent transcripts. Every action runs the `meet` CLI, so the app and the
// terminal always agree. Warns when a recording seems to have outlived its
// meeting (no meeting audio for a while, or very long).

import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - `meet status --json`

struct Levels: Decodable {
    let peak_recent: Double
    let peak_max: Double
    let filled_recent: Double?
    let seconds: Double?
}

struct LevelsFile: Decodable {
    let mic: Levels
    let system: Levels
}

struct Recording: Decodable {
    let id: String
    let name: String
    let started_at: String
    let alive: Bool
    let levels: LevelsFile?
}

struct Job: Decodable, Identifiable {
    let id: String
    let name: String
    let state: String // stopping | transcribing | awaiting-tags | interrupted | stopped | failed
    let error: String?
    let stopped_at: String?
    let awaiting_tags: Bool?
}

struct Recent: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let finished_at: String
}

struct Status: Decodable {
    let recording: Recording?
    let jobs: [Job]
    let recent: [Recent]
    let inbox: String
    let known_tags: [String]?
}

// MARK: - CLI bridge

enum CLI {
    /// The `meet` script: path baked in at build time, else the usual install locations.
    static let path: String? = {
        var candidates: [String] = []
        if let baked = Bundle.main.object(forInfoDictionaryKey: "MeetCLIPath") as? String { candidates.append(baked) }
        candidates += ["/opt/homebrew/bin/meet", "/usr/local/bin/meet", NSHomeDirectory() + "/.local/bin/meet"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs `meet <args>` and returns (exit code, stdout, stderr). Kept apart so a
    /// warning on stderr can never corrupt `status --json` on stdout.
    static func run(_ args: [String]) -> (code: Int32, out: String, err: String) {
        guard let path else { return (127, "", "Can't find the meet command. Run install.sh from the meet repo.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment // GUI apps get a minimal PATH
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        p.standardInput = FileHandle.nullDevice // no TTY: `meet stop` won't prompt
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (126, "", error.localizedDescription) }
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus, text(outData), text(errData))
    }
}

func notify(_ message: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                   "-e", "end run", "Meet Transcriber", message]
    try? p.run()
}

func hms(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Model

final class Model: ObservableObject {
    static let shared = Model()

    @Published var status: Status?
    @Published var busy: String?          // "Starting…" / "Stopping…"
    @Published var message: String?       // last error from the CLI
    @Published var doctor: String?        // `meet doctor` output, when shown
    @Published var now = Date()
    @Published var quietFor: TimeInterval = 0

    static let quietAlert: TimeInterval = 15 * 60   // no meeting audio for this long -> warn
    static let quietRepeat: TimeInterval = 30 * 60
    static let longAlert: TimeInterval = 3 * 3600   // then hourly reminders

    private var timer: Timer?
    private var ticks = 0
    private var lastSound = Date()
    private var lastQuietAlert = Date.distantPast
    private var longAlertsSent = 0
    private var recordingID: String?
    private let iso = ISO8601DateFormatter()

    init() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    var recording: Recording? { status?.recording }
    var isRecording: Bool { recording?.alive == true }
    /// A stopped recording whose transcript is waiting for tags (the step after Stop).
    var awaitingTags: Job? { status?.jobs.first { $0.awaiting_tags == true } }
    /// No transcripts folder configured yet (first run): the panel asks for one.
    var needsInbox: Bool { status?.inbox.isEmpty == true }
    /// Brings up the panel: the tags step after a stop, the folder step on first run.
    var showPanel: (() -> Void)?
    private var askedForTags: Set<String> = []
    private var askedForInbox = false

    /// Seconds since the recording was stopped (transcription starts then).
    func sinceStop(_ job: Job) -> TimeInterval? {
        guard let s = job.stopped_at, let stopped = iso.date(from: s) else { return nil }
        return now.timeIntervalSince(stopped)
    }

    /// Seconds until the transcript is written without tags.
    func tagsDeadline(_ job: Job) -> TimeInterval? { sinceStop(job).map { max(0, 600 - $0) } }

    var isTranscribing: Bool { status?.jobs.contains { $0.state == "transcribing" || $0.state == "stopping" } == true }
    var isQuiet: Bool { isRecording && quietFor >= Model.quietAlert }

    var elapsed: TimeInterval {
        guard let r = recording, let start = iso.date(from: r.started_at) else { return 0 }
        return now.timeIntervalSince(start)
    }

    private func tick() {
        now = Date()
        ticks += 1
        if ticks % ((isRecording || isTranscribing || busy != nil) ? 2 : 5) == 0 { refresh() }
    }

    private var refreshing = false
    private var statusError: String?  // shown while `meet status` fails; cleared when it works again

    func refresh() {
        guard !refreshing else { return } // a slow `meet status` must not pile up
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let r = CLI.run(["status", "--json"])
            let decoded = try? JSONDecoder().decode(Status.self, from: Data(r.out.utf8))
            DispatchQueue.main.async {
                self.refreshing = false
                if let decoded {
                    if self.message != nil, self.message == self.statusError { self.message = nil }
                    self.statusError = nil
                    self.apply(decoded)
                } else {
                    self.statusError = r.err.isEmpty ? "Couldn't read meet status." : r.err
                    self.message = self.statusError
                }
            }
        }
    }

    private func apply(_ s: Status) {
        status = s
        if let job = awaitingTags, !askedForTags.contains(job.id) {
            askedForTags.insert(job.id)
            showPanel?()
        }
        if needsInbox, !askedForInbox {
            askedForInbox = true
            showPanel?()
        }
        guard let r = s.recording, r.alive else {
            recordingID = nil
            quietFor = 0
            return
        }
        if r.id != recordingID { // new recording: reset the watchdog
            recordingID = r.id
            lastSound = Date()
            lastQuietAlert = .distantPast
            longAlertsSent = 0
        }
        // "Meeting audio" = the system track; the mic hears the room even after a call ends.
        if let lv = r.levels, lv.system.peak_recent > 0.003 { lastSound = Date() }
        quietFor = Date().timeIntervalSince(lastSound)
        if quietFor >= Model.quietAlert, Date().timeIntervalSince(lastQuietAlert) >= Model.quietRepeat {
            lastQuietAlert = Date()
            notify("No meeting audio for \(Int(quietFor / 60)) min. Still recording '\(r.name)'?")
        }
        let hoursOver = Int((elapsed - Model.longAlert) / 3600) + 1
        if elapsed >= Model.longAlert, hoursOver > longAlertsSent {
            longAlertsSent = hoursOver
            notify("'\(r.name)' has been recording for \(hms(elapsed)). Forgot to stop?")
        }
    }

    private func perform(_ label: String, _ args: [String], onSuccess: (() -> Void)? = nil) {
        busy = label
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CLI.run(args)
            DispatchQueue.main.async {
                self.busy = nil
                if r.code == 0 { onSuccess?() } else {
                    self.message = r.err.isEmpty ? (r.out.isEmpty ? "meet \(args[0]) failed (\(r.code))" : r.out) : r.err
                }
                self.refresh()
            }
        }
    }

    func start(_ name: String, done: @escaping () -> Void) { perform("Starting…", ["start", "--", name], onSuccess: done) }
    /// Stop now; tags are asked for in the next step (the transcript waits for them).
    func stop(done: @escaping () -> Void = {}) { perform("Stopping…", ["stop", "--tags-later"], onSuccess: done) }
    func stop(tags: String) { perform("Stopping…", ["stop", "--tags=\(tags)"]) }
    func tag(_ id: String, _ tags: String, done: @escaping () -> Void = {}) {
        perform("Saving tags…", ["tag", id, "--tags=\(tags)"], onSuccess: done)
    }
    func retry(_ id: String) { perform("Retrying…", ["retry", id]) }

    /// meetbar://start?name=…  /  meetbar://stop?tags=…
    func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        switch url.host {
        case "start":
            let name = value("name").trimmingCharacters(in: .whitespaces)
            if name.isEmpty { message = "meetbar://start needs ?name=…" } else { start(name) {} }
        case "stop":
            if items.contains(where: { $0.name == "tags" }) { stop(tags: value("tags")) } else { stop() }
        default: message = "Unknown URL: \(url.absoluteString)"
        }
    }

    func runDoctor() {
        doctor = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CLI.run(["doctor"])
            DispatchQueue.main.async { self.doctor = [r.out, r.err].filter { !$0.isEmpty }.joined(separator: "\n") }
        }
    }

    /// Folder picker for where transcripts go; saved with `meet config --inbox`.
    func chooseInbox() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose where transcripts (.md) are saved, e.g. a folder in your Obsidian vault."
        if let inbox = status?.inbox, !inbox.isEmpty { panel.directoryURL = URL(fileURLWithPath: inbox) }
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.perform("Saving…", ["config", "--inbox=\(url.path)"]) { self.showPanel?() }
        }
    }

    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    func openLog() { open(NSHomeDirectory() + "/Library/Logs/meet/meet.log") }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { message = "Open at login: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }
}

// MARK: - Menu bar label

func coloredSymbol(_ name: String, _ color: NSColor) -> NSImage {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    let img = base.withSymbolConfiguration(.init(paletteColors: [color])) ?? base
    img.isTemplate = false // keep the color in the menu bar
    return img
}

func menuSymbol(_ name: String) -> NSImage {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "meet") ?? NSImage()
    img.isTemplate = true // adapts to light/dark menu bars
    return img
}

/// What the status item shows: icon + optional timer.
func menuBarContent(_ m: Model) -> (NSImage, String) {
    if m.isRecording {
        return (coloredSymbol(m.isQuiet ? "exclamationmark.circle.fill" : "record.circle.fill",
                              m.isQuiet ? .systemOrange : .systemRed), " " + hms(m.elapsed))
    }
    if m.recording != nil { return (coloredSymbol("exclamationmark.triangle.fill", .systemOrange), "") }
    if m.awaitingTags != nil { return (coloredSymbol("tag.fill", .systemOrange), "") }
    if m.isTranscribing { return (menuSymbol("hourglass"), "") }
    return (menuSymbol("mic"), "")
}

// MARK: - Panel

struct LevelRow: View {
    let label: String
    let levels: Levels?
    let elapsed: TimeInterval

    var db: Double {
        guard let p = levels?.peak_recent, p > 0 else { return -80 }
        return max(-80, 20 * log10(p))
    }

    enum State { case ok, warning, pending }

    var note: (String, State) {
        guard let l = levels else { return ("waiting…", .pending) }
        if (l.seconds ?? 0) == 0 { return ("starting…", .pending) }
        if l.peak_max == 0 { return elapsed > 15 ? ("silent", .warning) : ("silent", .pending) }
        if (l.filled_recent ?? 0) > 0.2 { return ("dropping audio", .warning) }
        return ("ok", .ok)
    }

    var body: some View {
        let (text, state) = note
        HStack(spacing: 8) {
            Text(label).frame(width: 50, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(state == .warning ? Color.orange : Color.green)
                        .frame(width: g.size.width * CGFloat((db + 80) / 80))
                }
            }
            .frame(height: 6)
            HStack(spacing: 3) {
                switch state {
                case .ok:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(text).foregroundStyle(.secondary)
                case .warning:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(text).foregroundStyle(.primary)
                case .pending:
                    Text(text).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .frame(width: 96, alignment: .trailing)
        }
        .help(state == .warning && text == "silent" ? "No audio at all: check the permission for meet-capture (System Audio Recording / Microphone)." : "")
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    @State private var name = ""
    @State private var tags = ""
    @State private var picked = 0 // highlighted tag suggestion
    @FocusState private var focus: Field?
    enum Field { case name, tags }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let r = model.recording {
                if r.alive { recordingSection(r) } else { crashedSection(r) }
            }
            if let job = model.awaitingTags {
                tagsSection(job)
            } else if model.recording == nil {
                if model.needsInbox { inboxSection } else { idleSection }
            }
            if let busy = model.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
            }
            if let msg = model.message {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            jobsSection
            recentSection
            if let doc = model.doctor { doctorSection(doc) }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true) // report the real height to the popover
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New recording").font(.headline)
            TextField("Meeting name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .name)
            Button(action: startIfValid) {
                Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.busy != nil)
        }
        .onAppear { focus = .name }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { _ in
            if model.awaitingTags == nil { focus = .name }
        }
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where should transcripts go?").font(.headline)
            Text("Pick a folder for the .md files, e.g. one in your Obsidian vault. You can change it later in the ⋯ menu.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { model.chooseInbox() } label: {
                Label("Choose folder…", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil)
        }
    }

    /// Starts with the typed name, or "Meeting" when it's empty (the filename already has the date and time).
    private func startIfValid() {
        guard model.busy == nil else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        model.start(n.isEmpty ? "Meeting" : n) { name = "" }
    }

    private func recordingSection(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text(r.name).font(.headline).lineLimit(1)
                Spacer()
                Text(hms(model.elapsed)).monospacedDigit().foregroundStyle(.secondary)
            }
            LevelRow(label: "Mic", levels: r.levels?.mic, elapsed: model.elapsed)
            LevelRow(label: "System", levels: r.levels?.system, elapsed: model.elapsed)
            if model.isQuiet {
                Label("No meeting audio for \(Int(model.quietFor / 60)) min. Did the meeting end?",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button {
                model.stop()
            } label: {
                Label("Stop recording", systemImage: "stop.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil)
        }
    }

    /// The step after Stop: the transcript is held until tags are saved or skipped.
    private func tagsSection(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tag.fill").foregroundStyle(.orange)
                Text("Add tags").font(.headline)
                Spacer()
                Text(job.name).foregroundStyle(.secondary).lineLimit(1)
            }
            TagField(text: $tags, onKey: tagKey)
                .onChange(of: tags) { picked = 0 }
            if !tagSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tagSuggestions.enumerated()), id: \.element) { i, tag in
                        Text("#" + tag)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(i == picked ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                            .onTapGesture { acceptTag(tag) }
                    }
                }
            }
            HStack {
                Button("Skip") { model.tag(job.id, "") { tags = "" } }
                Spacer()
                Button("Save tags") { saveTags(job) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(model.busy != nil)
            Text((job.state == "awaiting-tags" ? "Transcript ready." : "Transcribing in the background.")
                 + (model.tagsDeadline(job).map { " Saving without tags in \(hms($0))." } ?? ""))
                .monospacedDigit()
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The tag being typed: after the last comma or space (both separate tags, as in `meet tag`).
    private var tagPrefix: (head: Substring, token: String) {
        let i = tags.lastIndex { $0 == "," || $0 == " " }.map { tags.index(after: $0) } ?? tags.startIndex
        return (tags[..<i], tags[i...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "").lowercased())
    }

    /// Known tags matching what's being typed (prefix matches first), minus ones already entered.
    private var tagSuggestions: [String] {
        let (head, token) = tagPrefix
        guard !token.isEmpty else { return [] }
        let entered = Set(head.split { $0 == "," || $0 == " " }.map { $0.replacingOccurrences(of: "#", with: "").lowercased() })
        let known = (model.status?.known_tags ?? []).filter { !entered.contains($0) && $0 != token }
        return Array((known.filter { $0.hasPrefix(token) } + known.filter { !$0.hasPrefix(token) && $0.contains(token) }).prefix(6))
    }

    private func acceptTag(_ tag: String) {
        tags = tagPrefix.head + tag + ", "
    }

    /// Keys in the tags field. Return/Tab pick the highlighted suggestion; Return never saves.
    private func tagKey(_ key: TagField.Key) -> Bool {
        let list = tagSuggestions
        switch key {
        case .up, .down:
            guard !list.isEmpty else { return false }
            picked = (picked + (key == .down ? 1 : list.count - 1)) % list.count
        case .accept:
            guard !list.isEmpty else { return false }
            acceptTag(list[min(picked, list.count - 1)])
        case .cancel:
            guard !list.isEmpty else { return false } // no suggestions: Esc closes the panel
            tags = String(tagPrefix.head)
        }
        return true
    }

    private func saveTags(_ job: Job) {
        guard model.busy == nil else { return }
        model.tag(job.id, tags) { tags = "" }
    }

    private func crashedSection(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("'\(r.name)' stopped unexpectedly", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Button("Transcribe what was captured") { model.stop() }.disabled(model.busy != nil)
        }
    }

    @ViewBuilder private var jobsSection: some View {
        if let jobs = model.status?.jobs.filter({ $0.awaiting_tags != true }), !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(jobs) { job in
                    HStack(spacing: 6) {
                        if ["transcribing", "stopping", "awaiting-tags"].contains(job.state) {
                            ProgressView().controlSize(.small)
                            Text(job.state == "stopping" ? "Stopping \"\(job.name)\"…" : "Transcribing \"\(job.name)\"…")
                                .lineLimit(1).truncationMode(.middle)
                            if job.state != "stopping", let t = model.sinceStop(job) {
                                Spacer()
                                Text(hms(t)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        } else {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            Text("\(job.name): \(job.state)").lineLimit(1).help(job.error ?? "")
                            Spacer()
                            Button("Retry") { model.retry(job.id) }.controlSize(.small).disabled(model.busy != nil)
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var recentSection: some View {
        if let recent = model.status?.recent, !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(recent.prefix(3)) { item in
                    Button { model.open(item.path) } label: {
                        Label(item.name, systemImage: "doc.text").lineLimit(1)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func doctorSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Setup check").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { model.doctor = nil }.buttonStyle(.link).font(.caption)
            }
            ScrollView {
                Text(text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                if let inbox = model.status?.inbox, !inbox.isEmpty { model.open(inbox) }
            } label: { Label("Transcripts", systemImage: "folder") }
            .buttonStyle(.link)
            Spacer()
            Menu {
                Button("Check setup…") { model.runDoctor() }
                Button("Change transcripts folder…") { model.chooseInbox() }
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
                Button("Open log") { model.openLog() }
                Divider()
                Button(model.isRecording ? "Quit (recording continues)" : "Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// The tags text field. An NSTextField so arrows/Return/Tab/Esc can drive the suggestions
/// (SwiftUI's TextField doesn't hand those keys over reliably on macOS).
struct TagField: NSViewRepresentable {
    enum Key { case up, down, accept, cancel }
    @Binding var text: String
    /// Returns true when the key was handled.
    var onKey: (Key) -> Bool

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusSoon()
        }
        func focusSoon() { DispatchQueue.main.async { self.window?.makeFirstResponder(self) } }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagField
        var observer: NSObjectProtocol?
        init(_ parent: TagField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            if let f = note.object as? NSTextField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertNewline(_:)): _ = parent.onKey(.accept); return true // never submits
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.accept)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.cancel)
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let f = Field()
        f.placeholderString = "e.g. pricing, q4"
        f.bezelStyle = .roundedBezel
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingHead
        f.cell?.isScrollable = true
        // Reopening the panel: put the cursor back in the field.
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSPopover.didShowNotification, object: nil, queue: .main) { [weak f] _ in f?.focusSoon() }
        return f
    }

    func updateNSView(_ f: Field, context: Context) {
        context.coordinator.parent = self
        guard f.stringValue != text else { return }
        f.stringValue = text
        f.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0) // cursor at the end
    }

    static func dismantleNSView(_ f: Field, coordinator: Coordinator) {
        if let o = coordinator.observer { NotificationCenter.default.removeObserver(o) }
    }
}

// MARK: - App
// A plain NSStatusItem + NSPopover instead of SwiftUI's MenuBarExtra: the
// MenuBarExtra window doesn't resize or re-anchor when the content's height
// changes (ghost space, shifted panel). The popover follows the hosting
// controller's preferred size and stays attached to the icon.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var observer: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: Panel(model: Model.shared))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        // objectWillChange fires before the change lands; read the new state on the next turn.
        observer = Model.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
        // After a stop from a hotkey/URL (or with the panel closed), bring up the tags step;
        // on first run, the folder step.
        Model.shared.showPanel = { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.togglePopover()
        }
        updateButton()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Model.shared.handle($0) }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Model.shared.refresh()
            takeFocus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKeyAndOrderFront(nil)
                // Again on the next turn: the popover window only exists once it's on screen.
                DispatchQueue.main.async { self.takeFocus(); window.makeKey() }
            }
        }
    }

    /// The panel's text fields only get keystrokes while this app is active, and a
    /// menu bar app never is on its own.
    private func takeFocus() {
        NSApp.activate()
    }

    private func updateButton() {
        guard let button = item?.button else { return }
        let (image, title) = menuBarContent(Model.shared)
        button.image = image
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }
}

@main
struct MeetBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() } // UI lives in the status item's popover
    }
}
