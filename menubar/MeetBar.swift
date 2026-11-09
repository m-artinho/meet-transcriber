// Meet Transcriber.app: menu bar front end for the `meet` CLI.
//
// URL scheme (for Raycast, Shortcuts, hotkeys):
//   open "meetbar://start?name=Pricing%20sync"    open "meetbar://stop?tags=pricing,q4"
//
// Shows a red dot + timer in the menu bar while recording, and a panel to start
// (with a name), watch levels, stop (with tags), retry failed transcriptions and
// open recent transcripts. Every action runs the `meet` CLI, so the app and the
// terminal always agree. Warns when a recording seems to have outlived its
// meeting (no meeting audio for a while, or very long), and suggests recording
// when a meeting app (Teams, Zoom, FaceTime, Slack, a browser) starts using the mic.
// Optionally (⋯ → Name meetings from Calendar, off by default) that suggestion
// fills in the name of the calendar event you're joining.

import AppKit
import Combine
import CoreAudio
import EventKit
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

    private func perform(_ label: String, _ args: [String], onSuccess: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        busy = label
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = CLI.run(args)
            DispatchQueue.main.async {
                self.busy = nil
                if r.code == 0 { onSuccess?() } else {
                    self.message = r.err.isEmpty ? (r.out.isEmpty ? "meet \(args[0]) failed (\(r.code))" : r.out) : r.err
                    onFailure?()
                }
                self.refresh()
            }
        }
    }

    func start(_ name: String, done: @escaping () -> Void, failed: (() -> Void)? = nil) {
        perform("Starting…", ["start", "--", name], onSuccess: done, onFailure: failed)
    }
    /// The panel's Start recording (and the meeting suggestion's Record): the typed name,
    /// or "Meeting" when it's empty (the filename already has the date and time).
    func start(typed name: String, done: @escaping () -> Void = {}, failed: (() -> Void)? = nil) {
        let n = name.trimmingCharacters(in: .whitespaces)
        start(n.isEmpty ? "Meeting" : n, done: done, failed: failed)
    }
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
            self.perform("Saving…", ["config", "--inbox=\(url.path)"], onSuccess: { self.showPanel?() })
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

    /// ⋯ → Name meetings from Calendar (see `CalendarNames`).
    var calendarState: CalendarNames.State { CalendarNames.shared.state }
    func setCalendarNames(_ on: Bool) { CalendarNames.shared.setEnabled(on) { [weak self] in self?.objectWillChange.send() } }
    func allowCalendar() { CalendarNames.shared.requestAccess { [weak self] in self?.objectWillChange.send() } }
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

    private func startIfValid() {
        guard model.busy == nil else { return }
        model.start(typed: name, done: { name = "" })
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
                // Rebuilt every second with the panel, so it shows the live Calendar permission.
                let calendar = model.calendarState
                Toggle("Name meetings from Calendar", isOn: Binding(get: { calendar != .off },
                                                                     set: { model.setCalendarNames($0) }))
                if calendar == .needsAccess {
                    Button("Allow Calendar access…") { model.allowCalendar() }
                } else if calendar == .denied {
                    Button("Calendar access is off: Open Privacy Settings…") { CalendarNames.shared.openPrivacySettings() }
                }
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

// MARK: - Recording safeguards
// "Don't forget it's recording" reminders on top of the menu bar timer: a thin bar
// along the bottom of every screen; a check-in panel after an hour (then every 30 min
// after the last answer) or when the watchdog finds no meeting audio; and a "call
// ended?" banner when a meeting app that was on the mic lets go of it.
// Stop & save is the panel's Stop recording (`model.stop()`).

/// A panel that never takes focus from the app the user is in (e.g. Teams).
final class PassivePanel: NSPanel {
    var focusable = false
    override var canBecomeKey: Bool { focusable }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {} // Esc does nothing
}

/// The check-in and meeting-suggestion window: a small panel in the top-right corner of
/// the main screen, on every Space, that doesn't activate the app. Buttons work without
/// it becoming key, so keystrokes stay with the meeting app; a text field makes it key
/// only when clicked. `borderless`: no title bar, the view draws its own rounded card
/// (the suggestion, styled like a notification banner).
func showFloatingPanel(_ view: NSView, delegate: NSWindowDelegate, borderless: Bool = false) -> PassivePanel {
    let p = PassivePanel(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                         styleMask: borderless ? [.borderless, .nonactivatingPanel]
                                               : [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    p.focusable = true
    p.becomesKeyOnlyIfNeeded = true
    p.contentView = view
    if borderless {
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
    } else {
        p.title = "Meet Transcriber"
    }
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.delegate = delegate
    let inset: CGFloat = borderless ? 12 : 16
    if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
        p.setFrameTopLeftPoint(NSPoint(x: vf.maxX - p.frame.width - inset, y: vf.maxY - inset))
    }
    p.orderFrontRegardless()
    if borderless { p.invalidateShadow() } // shadow follows the rounded card, not the square window
    return p
}

/// 3 pt bar pinned to the bottom edge of each screen while recording; clicks pass through.
final class EdgeBars {
    private var bars: [NSPanel] = []
    private var color = NSColor.systemRed
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.bars.isEmpty else { return }
            self.hide()
            self.show(self.color)
        }
    }

    func show(_ color: NSColor) {
        self.color = color
        if bars.isEmpty {
            bars = NSScreen.screens.map { screen in
                let f = screen.frame
                let p = PassivePanel(contentRect: NSRect(x: f.minX, y: f.minY, width: f.width, height: 3),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.level = .statusBar
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                p.ignoresMouseEvents = true
                p.isOpaque = false
                p.hasShadow = false
                p.hidesOnDeactivate = false
                p.isExcludedFromWindowsMenu = true
                p.isReleasedWhenClosed = false
                p.orderFrontRegardless()
                return p
            }
        }
        let fill = color.withAlphaComponent(0.85)
        for p in bars where p.backgroundColor != fill { p.backgroundColor = fill }
    }

    func hide() {
        bars.forEach { $0.orderOut(nil) }
        bars = []
    }
}

/// The meeting banners' look (shown with `showFloatingPanel(borderless: true)`): a rounded
/// material card like a notification, an icon with caption, headline and subtitle, then `content`.
struct BannerCard<Content: View>: View {
    let symbol: String
    let tint: Color
    let headline: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meet Transcriber").font(.caption).foregroundStyle(.secondary)
                    Text(headline).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .monospacedDigit().lineLimit(1).truncationMode(.middle)
                }
            }
            content
        }
        .controlSize(.regular)
        .environment(\.controlActiveState, .key) // the panel never becomes key; keep the red button red, not inactive gray
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}

/// While recording, a meeting app that was on the mic has let go of it: the call is probably over.
struct CallEnded: View {
    @ObservedObject var model: Model
    let app: String
    let keep: () -> Void
    let stop: () -> Void

    var body: some View {
        BannerCard(symbol: "phone.down.fill", tint: .red, headline: "\(app) call ended?",
                   subtitle: "Still recording \"\(model.recording?.name ?? "")\" · \(hms(model.elapsed))") {
            HStack(spacing: 8) {
                Spacer()
                Button("Keep recording", action: keep).buttonStyle(.bordered)
                Button("Stop & save", action: stop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.busy != nil)
            }
        }
    }
}

struct CheckIn: View {
    @ObservedObject var model: Model
    let quiet: Bool
    let keep: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("Still recording \"\(model.recording?.name ?? "")\"")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
            }
            Text(quiet ? "No meeting audio for 15 min." : "Running for \(hms(model.elapsed))")
                .monospacedDigit()
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Keep recording", action: keep).buttonStyle(.bordered)
                Button("Stop & save", action: stop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.busy != nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

final class Safeguards: NSObject, NSWindowDelegate {
    static let firstCheckIn: TimeInterval = 3600  // recording time of the first check-in
    static let checkInRepeat: TimeInterval = 1800 // after each answer

    private let model = Model.shared
    private let bars = EdgeBars()
    private var panel: PassivePanel?
    private var recordingID: String?
    private var nextCheckIn = Safeguards.firstCheckIn
    private var wasQuiet = false

    // Call ended: every `micCheck` the mic is read (on the Model's 1 s tick, no timer of its
    // own). A meeting app seen on the mic during this recording that's gone is re-read after
    // `micConfirm` (rides out device switches), then the CallEnded banner asks to save.
    static let micCheck: TimeInterval = 5
    static let micConfirm: TimeInterval = 2
    private var callApps: [String: String] = [:] // bundle ID → name, on the mic during this recording
    private var lastMicCheck = Date.distantPast
    private var leaving = false                  // a call app was gone at the last read; confirming
    private var askedCallEnded = false           // the open panel is CallEnded
    /// Stop & save from CallEnded: the next meeting may already be on the mic, so keep suggesting it.
    var onCallEndedStop: (() -> Void)?

    /// Called after every Model change.
    func update() {
        // Hide as soon as Stop is pressed in the app, not only once `meet stop` returns.
        guard model.isRecording, model.busy != "Stopping…", let r = model.recording else {
            bars.hide()
            closeCheckIn()
            recordingID = nil
            return
        }
        if r.id != recordingID {
            recordingID = r.id
            nextCheckIn = Safeguards.firstCheckIn
            wasQuiet = false
            callApps = [:]
            lastMicCheck = .distantPast
            leaving = false
        }
        bars.show(model.isQuiet ? .systemOrange : .systemRed)
        if model.isQuiet, !wasQuiet { showCheckIn(quiet: true) }
        wasQuiet = model.isQuiet
        if model.elapsed >= nextCheckIn { showCheckIn(quiet: false) }
        checkCall()
    }

    private func checkCall() {
        let now = Date()
        guard now.timeIntervalSince(lastMicCheck) >= (leaving ? Self.micConfirm : Self.micCheck) else { return }
        lastMicCheck = now
        let onMic = MeetingDetector.micUse().apps
        callApps.merge(onMic) { a, _ in a }
        let gone = callApps.keys.filter { onMic[$0] == nil }.sorted()
        guard let app = gone.first.flatMap({ callApps[$0] }) else { leaving = false; return }
        if !leaving { leaving = true; return } // read again shortly before asking
        leaving = false
        gone.forEach { callApps[$0] = nil }    // asked once; asks again only if it's back on the mic and leaves
        showCallEnded(app: app)
    }

    /// Takes over an open check-in (same choice, better reason); one CallEnded at a time.
    private func showCallEnded(app: String) {
        guard !askedCallEnded else { return }
        closeCheckIn()
        let view = NSHostingView(rootView: CallEnded(model: model, app: app,
                                                     keep: { [weak self] in self?.keepRecording() },
                                                     stop: { [weak self] in
                                                         self?.onCallEndedStop?()
                                                         self?.model.stop()
                                                         self?.closeCheckIn()
                                                     }))
        panel = showFloatingPanel(view, delegate: self, borderless: true)
        askedCallEnded = true
    }

    private func showCheckIn(quiet: Bool) {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: CheckIn(model: model, quiet: quiet,
                                                   keep: { [weak self] in self?.keepRecording() },
                                                   stop: { [weak self] in self?.model.stop(); self?.closeCheckIn() }))
        panel = showFloatingPanel(view, delegate: self)
    }

    private func keepRecording() {
        nextCheckIn = model.elapsed + Safeguards.checkInRepeat
        closeCheckIn()
    }

    /// The close button = Keep recording.
    func windowWillClose(_ notification: Notification) {
        guard panel != nil else { return }
        nextCheckIn = model.elapsed + Safeguards.checkInRepeat
        panel = nil
    }

    private func closeCheckIn() {
        askedCallEnded = false
        guard let p = panel else { return }
        panel = nil
        p.orderOut(nil)
    }
}

// MARK: - Meeting detection
// Suggests recording when a meeting app starts using the mic while nothing is being
// recorded. Core Audio lists every process doing audio I/O (macOS 14.2+), with its
// bundle ID and whether it's using an input. Browsers and Teams do their audio in
// helper processes (Chrome's audio service, WebKit's GPU process), so each one is
// traced to the app it works for (its "responsible" process). Reads no audio and
// needs no permission.
//
// Event-driven: the process list and every device's "running somewhere" state have
// listeners. Core Audio doesn't notify when a process starts using the mic on its own,
// so while any app has the mic (and nothing is recording) the list is re-read every
// 2 s. That times the 5 s debounce and catches a meeting app joining a mic another
// app already had open. With the mic idle, nothing runs.

// MARK: - Calendar ranking (pure: plain values, no EventKit, so a test harness compiles it alone)

/// Video services a calendar event can link to (in its URL, location or notes).
enum VideoService: CaseIterable {
    case teams, zoom, meet, facetime, webex, slack

    var hosts: [String] {
        switch self {
        case .teams: return ["teams.microsoft.com", "teams.live.com"]
        case .zoom: return ["zoom.us", "zoomgov.com"]
        case .meet: return ["meet.google.com"]
        case .facetime: return ["facetime.apple.com"]
        case .webex: return ["webex.com"]
        case .slack: return ["slack.com/huddle"] // app.slack.com/huddle/<team>/<channel>
        }
    }

    static func found(in text: String) -> Set<VideoService> {
        let t = text.lowercased()
        return Set(allCases.filter { $0.hosts.contains(where: t.contains) })
    }

    /// What a meeting app (bundle ID) can be the client for. Browsers join any web meeting;
    /// an app we don't know never contradicts a link.
    static func services(forApp app: String) -> Set<VideoService> {
        switch app {
        case "com.microsoft.teams2", "com.microsoft.teams": return [.teams]
        case "us.zoom.xos": return [.zoom]
        case "com.apple.FaceTime": return [.facetime]
        case "com.tinyspeck.slackmacgap": return [.slack]
        case "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser",
             "org.mozilla.firefox": return [.teams, .zoom, .meet, .webex, .slack]
        default: return Set(allCases)
        }
    }
}

/// My answer to an invite, best first. An event with no attendees, or one I organize, counts as accepted.
enum MyResponse: Int { case accepted, tentative, pending, declined }

/// A calendar event, copied out of EventKit into plain values.
struct CalendarEvent {
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var isCanceled = false
    var isBirthday = false
    var response = MyResponse.accepted
    var links: Set<VideoService> = []
}

struct CalendarCandidate: Equatable {
    let title: String
    let start: Date
    let end: Date
}

enum CalendarMatch: Equatable {
    case none                         // today's banner
    case prefill(CalendarCandidate)   // one clear match: the name field starts with its title
    case choices([CalendarCandidate]) // several: empty field, up to `maxChoices` rows to pick from
}

enum CalendarRank {
    /// An event matches when you joined up to `joinEarly` before its start or up to `joinLate` after it.
    static let joinEarly: TimeInterval = 5 * 60
    static let joinLate: TimeInterval = 5 * 60
    /// An event already in progress counts if it ends at least this long after you join (not one wrapping up)
    /// and isn't longer than `maxInProgress` (all-afternoon blocks aren't calls).
    static let endMargin: TimeInterval = 5 * 60
    static let maxInProgress: TimeInterval = 4 * 3600
    static let maxChoices = 3
    static let canceledPrefixes = ["canceled:", "cancelled:", "cancelado:", "cancelada:"] // Exchange keeps these
    static let placeholderTitles: Set<String> = ["new event", "novo evento"]

    private struct Scored {
        let title: String
        let event: CalendarEvent
        let matchesApp: Bool  // links to a service the app on the mic can be in
        let contradicts: Bool // has links, none of them for that app
    }

    /// Which name (if any) to offer for a call `app` joined at `joined`. A wrong name is worse than
    /// none, so a title is prefilled only when one event is clearly it; otherwise the candidates are
    /// offered with nothing picked.
    ///
    /// Two groups, decided the same way: events *starting* around `joined` (within `joinEarly`/`joinLate`),
    /// and events *already in progress* (joined late, or the app opened mid-call): started earlier, ending
    /// at least `endMargin` after `joined`, at most `maxInProgress` long (longer = a block, not a call).
    /// Starting events win; in-progress ones are used when none start now, or fill up a list of rows.
    static func rank(_ events: [CalendarEvent], joined: Date, app: String) -> CalendarMatch {
        let services = VideoService.services(forApp: app)
        var starting: [Scored] = [], ongoing: [Scored] = []
        for e in events {
            guard let found = eligible(e, joined) else { continue }
            let title = found.title, key = title.lowercased(), startsNow = found.startsNow
            let s = Scored(title: title, event: e, matchesApp: !e.links.isDisjoint(with: services),
                           contradicts: !e.links.isEmpty && e.links.isDisjoint(with: services))
            // The same invite synced into two accounts: one candidate, the better copy.
            func add(_ list: inout [Scored]) {
                if let i = list.firstIndex(where: { $0.title.lowercased() == key && $0.event.start == e.start }) {
                    if better(s, list[i], joined) { list[i] = s }
                } else {
                    list.append(s)
                }
            }
            if startsNow { add(&starting) } else { add(&ongoing) }
        }
        starting.sort { better($0, $1, joined) }
        ongoing.sort { better($0, $1, joined) }
        func candidate(_ s: Scored) -> CalendarCandidate { .init(title: s.title, start: s.event.start, end: s.event.end) }
        switch decide(starting) ?? decide(ongoing) ?? .none {
        case .prefill(let s): return .prefill(candidate(s))
        case .list(let list):
            let rows = starting.isEmpty ? list : list + ongoing // starting ones first, then those already going
            return .choices(rows.prefix(maxChoices).map(candidate))
        case .none: return .none
        }
    }

    /// The event's cleaned title and group when it counts for a call joined at `joined`, else nil.
    private static func eligible(_ e: CalendarEvent, _ joined: Date) -> (title: String, startsNow: Bool)? {
        let title = e.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let key = title.lowercased()
        guard !title.isEmpty, !placeholderTitles.contains(key), !canceledPrefixes.contains(where: key.hasPrefix),
              !e.isAllDay, !e.isCanceled, !e.isBirthday, e.response != .declined else { return nil }
        let startsNow = e.start >= joined.addingTimeInterval(-joinLate) && e.start <= joined.addingTimeInterval(joinEarly)
        let inProgress = e.start < joined.addingTimeInterval(-joinLate) && e.end >= joined.addingTimeInterval(endMargin)
            && e.end.timeIntervalSince(e.start) <= maxInProgress
        return startsNow || inProgress ? (title, startsNow) : nil
    }

    /// Identity of a meeting for the snooze: same title and start time.
    static func key(_ title: String, _ start: Date) -> String {
        title.lowercased() + "|" + String(Int(start.timeIntervalSince1970))
    }

    /// Every event `rank` considers for a call joined at `joined` (both groups), as `key`s. A snoozed app
    /// that comes back to the mic is a new meeting when this holds a key its snooze didn't.
    static func keys(_ events: [CalendarEvent], joined: Date) -> Set<String> {
        Set(events.compactMap { e in eligible(e, joined).map { key($0.title, e.start) } })
    }

    enum Return: Equatable { case sameMeeting, newMeeting(ambiguous: Bool) }

    /// A snoozed app is back on the mic: `keys` are the events around now, `covered` those its snooze
    /// was for. Any new event = a new meeting. If a covered event is also still going, it may be a
    /// rejoin of the old call while another event started (`ambiguous`: offer it, don't prefill).
    static func afterSnooze(covered: Set<String>, now keys: Set<String>) -> Return {
        if keys.subtracting(covered).isEmpty { return .sameMeeting }
        return .newMeeting(ambiguous: !keys.isDisjoint(with: covered))
    }

    private enum Decision { case prefill(Scored), list([Scored]), none }

    /// One group, best first: prefill when exactly one fits the app's link, or it's the only one and
    /// its link doesn't contradict the app; otherwise a list. nil when the group is empty.
    private static func decide(_ kept: [Scored]) -> Decision? {
        if kept.isEmpty { return nil }
        let matching = kept.filter(\.matchesApp)
        if matching.count == 1 { return .prefill(matching[0]) }
        if kept.count == 1, !kept[0].contradicts { return .prefill(kept[0]) }
        return .list(kept)
    }

    private static func better(_ a: Scored, _ b: Scored, _ joined: Date) -> Bool {
        if a.matchesApp != b.matchesApp { return a.matchesApp }
        if a.contradicts != b.contradicts { return !a.contradicts }
        if a.event.response != b.event.response { return a.event.response.rawValue < b.event.response.rawValue }
        let da = abs(a.event.start.timeIntervalSince(joined)), db = abs(b.event.start.timeIntervalSince(joined))
        if da != db { return da < db }
        return a.title < b.title
    }
}

// MARK: - Calendar access (EventKit; only used once the user turns it on)

extension CalendarEvent {
    init?(_ e: EKEvent) {
        guard let start = e.startDate, let end = e.endDate else { return nil }
        var response = MyResponse.accepted
        if let me = e.attendees?.first(where: { $0.isCurrentUser }) {
            switch me.participantStatus {
            case .declined: response = .declined
            case .tentative: response = .tentative
            case .pending, .unknown: response = .pending
            default: response = .accepted
            }
        } else if let attendees = e.attendees, !attendees.isEmpty, e.organizer?.isCurrentUser != true {
            response = .pending // invited, but my own entry isn't marked
        }
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: "\n")
        self.init(title: e.title ?? "", start: start, end: end, isAllDay: e.isAllDay,
                  isCanceled: e.status == .canceled, isBirthday: e.calendar?.type == .birthday,
                  response: response, links: VideoService.found(in: text))
    }
}

/// ⋯ → Name meetings from Calendar. Off by default; while it's off (or access is missing,
/// revoked, failing or slow) the suggestion banner is exactly the plain one. Event titles are
/// only held in memory for the banner: never logged or stored.
final class CalendarNames {
    static let shared = CalendarNames()
    static let enabledKey = "calendarNames"
    static let timeout: TimeInterval = 0.5 // lookup budget before the banner shows without it

    enum State { case off, on, needsAccess, denied }

    private let queue = DispatchQueue(label: "local.meet.bar.calendar")
    private var store: EKEventStore?      // only touched on `queue`
    private var requester: EKEventStore?  // kept alive while the permission prompt is up

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Read live every time: a rebuilt (re-signed) app can silently lose its grant. Off: EventKit isn't asked.
    var state: State {
        guard enabled else { return .off }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .on
        case .notDetermined: return .needsAccess
        default: return .denied // denied, restricted, write-only
        }
    }

    /// The menu toggle. Turning it on asks for access the first time; after that the only other prompt
    /// is at launch of a new build that lost the grant (`launched`), and only while this is on.
    func setEnabled(_ on: Bool, changed: @escaping () -> Void) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        queue.async { self.store = nil }
        if on, EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            requestAccess(changed)
        } else {
            warmUp()
        }
        changed()
    }

    func requestAccess(_ changed: @escaping () -> Void) {
        guard requester == nil else { return }
        let s = EKEventStore()
        requester = s
        NSApp.activate() // the prompt comes up in front
        s.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async {
                self.requester = nil
                self.queue.async { self.store = nil }
                self.warmUp()
                changed()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the event store ahead of the first banner (only when on and allowed).
    /// At launch. With Calendar names on and macOS reporting "not yet asked" (a new build: the grant is
    /// tied to the code hash, and a changed app can lose it), ask right away rather than leaving the
    /// banner plain until ⋯ → Allow Calendar access. Off, allowed or denied: no prompt.
    func launched(_ changed: @escaping () -> Void) {
        if state == .needsAccess { requestAccess(changed) } else { warmUp() }
    }

    func warmUp() {
        guard state == .on else { return }
        queue.async { if self.store == nil { self.store = EKEventStore() } }
    }

    /// The banner's match for `app`, joined at `joined`. `done` runs once on the main queue: right
    /// away with `.none` when not on, else with the result, or `.none` after `timeout`.
    func lookup(joined: Date, app: String, done: @escaping (CalendarMatch) -> Void) {
        run(fallback: .none, done: done) {
            CalendarRank.rank(self.events(around: joined), joined: joined, app: app)
        }
    }

    /// A snoozed app is back on the mic: compares the events around `snoozed` (when the snoozed call
    /// started) with those around `returned`. Both are read now, so a snooze set while access was
    /// missing still works once it's there. `done` runs once on main; nil = unknown (not on, timed out).
    func afterSnooze(snoozed: Date, returned: Date, done: @escaping (CalendarRank.Return?) -> Void) {
        run(fallback: nil, done: done) {
            CalendarRank.afterSnooze(covered: CalendarRank.keys(self.events(around: snoozed), joined: snoozed),
                                     now: CalendarRank.keys(self.events(around: returned), joined: returned))
        }
    }

    /// `work` on `queue`; `done` on main exactly once: `fallback` right away when not on, else the
    /// result, or `fallback` after `timeout` (a late result is dropped).
    private func run<T>(fallback: T, done: @escaping (T) -> Void, _ work: @escaping () -> T) {
        guard state == .on else { done(fallback); return }
        var answered = false // main queue only
        let answer: (T) -> Void = { value in
            guard !answered else { return }
            answered = true
            done(value)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { answer(fallback) }
        queue.async {
            let value = work()
            DispatchQueue.main.async { answer(value) }
        }
    }

    /// On `queue`. Events overlapping the match window; [] without access.
    private func events(around joined: Date) -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: joined.addingTimeInterval(-CalendarRank.joinLate - 60),
                                                 end: joined.addingTimeInterval(CalendarRank.joinEarly + 60),
                                                 calendars: nil)
        return store.events(matching: predicate).compactMap(CalendarEvent.init)
    }
}

// MARK: - Meeting suggestion banner

struct MeetingSuggestion: View {
    @ObservedObject var model: Model
    let app: String
    let match: CalendarMatch
    let record: (String) -> Void
    let notNow: () -> Void
    @State private var name: String

    init(model: Model, app: String, match: CalendarMatch = .none,
         record: @escaping (String) -> Void, notNow: @escaping () -> Void) {
        self.model = model
        self.app = app
        self.match = match
        self.record = record
        self.notNow = notNow
        // Set once, before anything can be typed; after that only the user changes the field.
        if case .prefill(let c) = match { _name = State(initialValue: c.title) } else { _name = State(initialValue: "") }
    }

    var body: some View {
        BannerCard(symbol: "mic.fill", tint: .orange, headline: "\(app) is using your mic",
                   subtitle: "Looks like a call. Record it?") {
            // Each state has a fixed height: the floating panel is sized once, when it's shown.
            switch match {
            case .none:
                TextField("Meeting name (optional)", text: $name) // no onSubmit: Enter does nothing
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 38) // lines up with the headline (icon 28 + spacing 10)
            case .prefill(let event):
                VStack(alignment: .leading, spacing: 4) {
                    nameField
                    Text("From Calendar · " + Self.span(event))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .opacity(name == event.title ? 1 : 0) // hidden once edited; keeps its space
                        .accessibilityHidden(name != event.title)
                }
                .padding(.leading, 38)
            case .choices(let events):
                VStack(alignment: .leading, spacing: 4) {
                    nameField
                    Text("Matching events").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(events.indices, id: \.self) { i in choiceRow(events[i]) }
                    }
                }
                .padding(.leading, 38)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Not now", action: notNow).buttonStyle(.bordered)
                Button("Record") { record(name) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.busy != nil)
            }
        }
    }

    /// The name field with a clear button (calendar states only).
    private var nameField: some View {
        HStack(spacing: 6) {
            TextField("Meeting name (optional)", text: $name) // no onSubmit: Enter does nothing
                .textFieldStyle(.roundedBorder)
            Button { name = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear the name")
                .accessibilityLabel("Clear name")
                .opacity(name.isEmpty ? 0 : 1) // keeps its space
                .disabled(name.isEmpty)
        }
    }

    /// One matching event: start time and title. Clicking puts the title in the field (still editable).
    private func choiceRow(_ event: CalendarCandidate) -> some View {
        Button { name = event.title } label: {
            HStack(spacing: 8) {
                Text(Self.time(event.start)).foregroundStyle(.secondary).monospacedDigit()
                Text(event.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(name == event.title ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.title)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func span(_ event: CalendarCandidate) -> String {
        let f = DateIntervalFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: event.start, to: event.end)
    }
}

final class MeetingDetector: NSObject, NSWindowDelegate {
    /// Meeting apps, by bundle ID (their helper processes resolve to these).
    static let apps: [String: String] = [
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams", // classic
        "us.zoom.xos": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.tinyspeck.slackmacgap": "Slack", // huddles; its audio runs in a helper that resolves to Slack
    ]
    static let ours: Set<String> = ["local.meet.capture", "local.meet.bar"] // the recorder, this app
    static let debounce: TimeInterval = 5   // on the mic this long before suggesting (skips dictation, blips)
    static let quietGap: TimeInterval = 120 // after Not now: off the mic this long before asking again
    static let recheck: TimeInterval = 2

    private let model = Model.shared
    private let queue = DispatchQueue(label: "local.meet.bar.mic-watch") // Core Audio listeners
    private var watchedDevices = Set<AudioObjectID>()                   // only touched on `queue`
    private var since: [String: Date] = [:]    // app → on the mic continuously since
    private var offSince: [String: Date] = [:] // app → left the mic at
    private var snoozed = Set<String>()        // answered (or recorded): not again until quietGap off the mic
    // Calendar-aware snooze (only with Calendar names on): a snoozed app back on the mic within quietGap
    // is in a new meeting when the calendar has an event around its return that wasn't around the
    // snoozed call's start (CalendarNames.afterSnooze).
    private var snoozedJoined: [String: Date] = [:] // when the snoozed call started (compared on return)
    private var panelJoined: Date?             // when the open banner's call started
    private var checkingReturn = Set<String>() // apps whose return to the mic is being checked
    private var ambiguous = Set<String>()      // un-snoozed while the old meeting still runs: no prefill
    private var recordingSince: Date?
    private var timer: Timer?
    private var panel: PassivePanel?
    private var panelApp: String?
    private var pendingApp: String?            // its banner waits for the calendar lookup (≤ CalendarNames.timeout)
    private var pendingToken = 0               // bumped to drop a lookup that's no longer wanted
    private var ready = false                  // the first `meet status` arrived
    private var wasRecording = false
    private var stoppedAfterCall = false       // stopped from the CallEnded banner

    /// The recording was stopped because its call ended: the apps on the mic now are the next
    /// meeting, not the one just recorded, so they're suggested as usual.
    func callEndedStop() { stoppedAfterCall = true }

    func start() {
        queue.async {
            var list = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(Self.system, &list, self.queue) { [weak self] _, _ in self?.changed() }
            var devices = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectAddPropertyListenerBlock(Self.system, &devices, self.queue) { [weak self] _, _ in
                self?.watchDevices()
                self?.changed()
            }
            self.watchDevices()
        }
    }

    /// On `queue`: a mic starting or stopping flips its device's "running somewhere".
    private func watchDevices() {
        for device in Self.objects(kAudioHardwarePropertyDevices) where !watchedDevices.contains(device) {
            watchedDevices.insert(device)
            var a = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectAddPropertyListenerBlock(device, &a, queue) { [weak self] _, _ in self?.changed() }
        }
    }

    private func changed() { DispatchQueue.main.async { [weak self] in self?.scan() } }

    /// Called after every Model change. Reads Core Audio only when a recording starts or ends.
    func update() {
        guard model.status != nil else { return }
        let first = !ready
        ready = true
        if model.recording != nil || model.busy == "Starting…" {
            if !wasRecording {
                wasRecording = true
                stoppedAfterCall = false
                recordingSince = Date()
                closePanel()
                stopTimer()
                since = [:]
            }
            return
        }
        if wasRecording {
            // Apps still on the mic were in the meeting just recorded: don't ask about them again.
            wasRecording = false
            if !stoppedAfterCall {
                for app in Self.micUse().apps.keys {
                    snoozeApp(app, joined: recordingSince ?? Date()) // the meeting just recorded
                    offSince[app] = nil
                }
            }
            stoppedAfterCall = false
            scan()
        } else if first {
            scan(atLaunch: true) // a call already going when the app opens: suggest right away
        }
    }

    private func scan(atLaunch: Bool = false) {
        guard ready, !wasRecording, !model.needsInbox else { stopTimer(); return }
        let (onMic, anyInput) = Self.micUse()
        let now = Date()
        for app in Array(since.keys) where onMic[app] == nil {
            since[app] = nil
            offSince[app] = now
            ambiguous.remove(app)
        }
        for app in onMic.keys where since[app] == nil {
            if snoozed.contains(app), let off = offSince[app], now.timeIntervalSince(off) >= Self.quietGap {
                snoozed.remove(app)
                snoozedJoined[app] = nil
            }
            since[app] = atLaunch ? .distantPast : now
            if snoozed.contains(app), let j = snoozedJoined[app] { checkNewMeeting(app, snoozedJoined: j, returned: now) }
        }
        if let app = panelApp, onMic[app] == nil { closePanel() } // it left the mic: the call is over
        if let app = pendingApp, onMic[app] == nil { cancelPending() }
        if panel == nil, pendingApp == nil, let hit = onMic.sorted(by: { $0.key < $1.key }).first(where: {
            !snoozed.contains($0.key) && now.timeIntervalSince(since[$0.key] ?? now) >= Self.debounce
        }) {
            show(app: hit.key, name: hit.value)
        }
        if anyInput { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.recheck, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// With Calendar names off (or no access) the lookup answers `.none` right away and the banner
    /// shows at once, as before; when on, it waits for the lookup or its timeout.
    private func show(app: String, name: String) {
        // When the app took the mic; unknown for a call already going at launch (`distantPast`).
        let joined = since[app].flatMap { $0 == .distantPast ? nil : $0 } ?? Date()
        pendingToken += 1
        let token = pendingToken
        pendingApp = app
        CalendarNames.shared.lookup(joined: joined, app: app) { [weak self] match in
            guard let self, self.pendingToken == token, self.pendingApp == app else { return }
            self.pendingApp = nil
            // Still wanted? (A recording may have started, or the call ended, meanwhile.)
            guard self.panel == nil, !self.wasRecording, self.since[app] != nil, !self.snoozed.contains(app) else { return }
            var match = match
            // Back after a snooze while the snoozed meeting is still going: offer, don't guess.
            if self.ambiguous.remove(app) != nil, case .prefill(let event) = match { match = .choices([event]) }
            self.present(app: app, name: name, match: match, joined: joined)
        }
    }

    private func present(app: String, name: String, match: CalendarMatch, joined: Date) {
        let view = NSHostingView(rootView: MeetingSuggestion(model: model, app: name, match: match,
                                                             record: { [weak self] in self?.record($0) },
                                                             notNow: { [weak self] in self?.snooze() }))
        panelApp = app
        panelJoined = joined
        panel = showFloatingPanel(view, delegate: self, borderless: true)
    }

    /// Snoozes `app`; `joined` = when that call started, for the calendar check if it comes back.
    private func snoozeApp(_ app: String, joined: Date?) {
        snoozed.insert(app)
        snoozedJoined[app] = joined
        ambiguous.remove(app)
    }

    /// A snoozed app is back on the mic within quietGap. With Calendar names on, one check decides: an
    /// event around now that wasn't around the snoozed call's start means a new meeting (back-to-back
    /// calls in the same app), so the snooze is lifted and the banner follows the usual debounce.
    /// Unknown (off, no access, timed out) = still snoozed, as before.
    private func checkNewMeeting(_ app: String, snoozedJoined joined: Date, returned: Date) {
        guard CalendarNames.shared.state == .on, !checkingReturn.contains(app) else { return }
        checkingReturn.insert(app)
        CalendarNames.shared.afterSnooze(snoozed: joined, returned: returned) { [weak self] result in
            guard let self else { return }
            self.checkingReturn.remove(app)
            guard self.snoozed.contains(app), self.since[app] != nil, !self.wasRecording,
                  case .newMeeting(let ambiguous)? = result else { return }
            self.snoozed.remove(app)
            self.snoozedJoined[app] = nil
            if ambiguous { self.ambiguous.insert(app) }
            self.scan()
        }
    }

    private func cancelPending() {
        pendingApp = nil
        pendingToken += 1
    }

    /// The panel's Start recording path; a failed start opens the panel, where the error shows.
    private func record(_ name: String) {
        snooze()
        model.start(typed: name, failed: { [weak self] in self?.model.showPanel?() })
    }

    /// Not now: closes, and this app isn't suggested again until it's been off the mic for quietGap
    /// (or, with Calendar names on, it comes back for a different calendar event).
    private func snooze() {
        if let app = panelApp { snoozeApp(app, joined: panelJoined) }
        closePanel()
    }

    /// The close button = Not now.
    func windowWillClose(_ notification: Notification) {
        guard panel != nil else { return }
        if let app = panelApp { snoozeApp(app, joined: panelJoined) }
        panel = nil
        panelApp = nil
        panelJoined = nil
    }

    private func closePanel() {
        cancelPending()
        guard let p = panel else { return }
        panel = nil
        panelApp = nil
        panelJoined = nil
        p.orderOut(nil)
    }

    // Core Audio reads

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var a = address(selector)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? v : nil
    }

    private static func bundleID(_ object: AudioObjectID) -> String {
        guard let s = value(object, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none) ?? nil else { return "" }
        return s.takeRetainedValue() as String // Core Audio hands over a +1 reference
    }

    /// The app a helper process works for (a libsystem call without a public header).
    private static let responsible: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// Meeting apps using a mic right now (bundle ID → name), and whether any process is.
    static func micUse() -> (apps: [String: String], any: Bool) {
        var found: [String: String] = [:]
        var any = false
        for object in objects(kAudioHardwarePropertyProcessObjectList)
        where (value(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0 {
            guard let pid = value(object, kAudioProcessPropertyPID, pid_t(-1)), pid > 0, pid != getpid() else { continue }
            any = true
            let own = bundleID(object)
            var ids = [own]
            if let r = responsible?(pid), r > 0, let b = NSRunningApplication(processIdentifier: r)?.bundleIdentifier {
                ids.insert(b, at: 0)
            }
            if let helper = own.range(of: ".helper") { ids.append(String(own[..<helper.lowerBound])) } // fallback
            // FaceTime calls run their audio in the avconferenced daemon.
            if own == "com.apple.avconferenced",
               !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").isEmpty {
                ids.append("com.apple.FaceTime")
            }
            if ids.contains(where: ours.contains) { continue }
            if let app = ids.first(where: { apps[$0] != nil }) { found[app] = apps[app] }
        }
        return (found, any)
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
    private let safeguards = Safeguards()
    private let detector = MeetingDetector()

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
            DispatchQueue.main.async { self?.updateButton(); self?.safeguards.update(); self?.detector.update() }
        }
        safeguards.onCallEndedStop = { [weak self] in self?.detector.callEndedStop() }
        detector.start()
        // Calendar names on but a new build reads as "not yet asked": ask now. Off (default): nothing.
        CalendarNames.shared.launched { Model.shared.objectWillChange.send() }
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

    /// Opening the app again (Spotlight, Finder, `open`) while it runs shows the panel,
    /// so it can be found even when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
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
