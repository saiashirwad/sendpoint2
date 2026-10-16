import AppKit
import Core

// The whole app loop: Event → step → render → effects.

let dataDir = URL.applicationSupportDirectory.appending(path: "Sendpoint")
let configURL = URL(filePath: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config")
    .appending(path: "sendpoint/config.toml")
/// What the app last wrote to, or read from, each stack file. Disk queue only.
nonisolated(unsafe) var stackFiles = [Data?](repeating: nil, count: stackCount)

var world = loadWorld()

func send(_ event: Event) {
    let effects = step(&world, event)
    render()
    for effect in effects { perform(effect) }
}

func render() {
    panel.render(world)
    readout.render(world)
    menu.render(world)
}

func perform(_ effect: Effect) {
    switch effect {
    case .micStart(let take): speech.start(take: take)
    case .micStop(let take): speech.stop(take: take)
    case .micCancel: speech.cancel()
    case .paste(let markdown): Selection.paste(markdown)
    case .save: save()
    case .open(let i):
        let url = stackURL(i)
        let doc = Data(stackDocument(name: world.config.names[i], notes: world.stacks[i]).utf8)
        diskQueue.async {
            writeStack(i, doc, to: url)
            DispatchQueue.main.async { openFile(url) }
        }
    case .bindKeys:
        Keys.bind(world.config.keys)
        render()
    case .expireReadout(let n):
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { send(.readoutElapsed(n)) }
    }
}

// MARK: Disk

let diskQueue = DispatchQueue(label: "app.sendpoint.disk", qos: .utility)

func stackURL(_ i: Int) -> URL { dataDir.appending(path: "stack-\(i + 1).md") }

/// The stack-N.md files are the only store. Edits saved to them come back through `pollStacks`.
func save() {
    let docs = (0..<stackCount).map { Data(stackDocument(name: world.config.names[$0], notes: world.stacks[$0]).utf8) }
    let urls = (0..<stackCount).map(stackURL)
    diskQueue.async {
        for i in docs.indices { writeStack(i, docs[i], to: urls[i]) }
    }
}

/// The notes in the stack files, read once at launch. A missing file is an empty stack.
func loadWorld() -> World {
    var w = World()
    for i in 0..<stackCount {
        guard let data = try? Data(contentsOf: stackURL(i)) else { continue }
        stackFiles[i] = data
        w.stacks[i] = parseStackDocument(String(decoding: data, as: UTF8.self))
    }
    return w
}

nonisolated func writeStack(_ i: Int, _ doc: Data, to url: URL) {
    write(doc, to: url)
    stackFiles[i] = doc
}

/// Reads the stack files back once a second. It runs on the disk queue behind any write still pending,
/// so a file only counts as edited when it differs from what the app last put there.
func pollStacks() {
    let urls = (0..<stackCount).map(stackURL)
    diskQueue.async {
        for i in urls.indices {
            guard let data = try? Data(contentsOf: urls[i]), data != stackFiles[i] else { continue }
            stackFiles[i] = data
            let notes = parseStackDocument(String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async { send(.edited(stack: i, notes)) }
        }
    }
}

nonisolated func write(_ data: Data, to url: URL) {
    if (try? Data(contentsOf: url)) == data { return }   // don't poke editors with no-op writes
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

/// The file's default app, or TextEdit when nothing claims .md / .toml.
func openFile(_ url: URL) {
    let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        ?? URL(filePath: "/System/Applications/TextEdit.app")
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}

// MARK: Config

/// Polled once a second: a stat is nothing, and it catches every way an editor saves.
/// Starts as a date no file has, so a missing file (nil) still counts as a change on the first poll.
var configStamp: Date? = .distantPast

func pollConfig() {
    let stamp = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    guard stamp != configStamp else { return }
    configStamp = stamp
    guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
        write(Data(defaultConfigText.utf8), to: configURL)   // first launch, or deleted: start from the defaults
        return
    }
    let config = parseConfig(text)
    if config != world.config { send(.configure(config)) }
}

// MARK: Keys → Events

func onKey(_ action: Action, down: Bool) {
    let idle = world.mode == .idle
    switch (action, down) {
    case (.note, true):
        let selection = idle ? Selection.read() : ""
        if selection == nil { Selection.copyViaKeystroke(timeout: 0.3) { send(.quoted($0)) } }   // before the card takes focus
        send(.capture(selection: selection ?? ""))
    case (.speak, true):
        let selection = idle ? Selection.read() : ""
        if selection == nil { Selection.copyViaKeystroke(timeout: 0.3) { send(.quoted($0)) } }   // before the card takes focus
        send(.speakDown(selection: selection ?? ""))
    case (.speak, false):
        send(.speakUp)
    case (.paste, true): send(.paste)
    case (.open, true): send(.open)
    case (.clear, true): send(.clear)
    case (_, true) where action.rawValue >= Action.stack1.rawValue:
        send(.select(action.rawValue - Action.stack1.rawValue))
    default: break
    }
}

// MARK: Launch

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let panel = Panel()
let readout = Readout()
let menu = StatusMenu()
let speech = Speech()
Keys.install(onKey)
Keys.bind(world.config.keys)   // defaults; the first poll swaps in the file's keys if they differ
pollConfig()
pollConfig()   // picks up the defaults file the first call may have just written
RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { _ in
    MainActor.assumeIsolated {
        pollConfig()
        pollStacks()
        menu.render(world)   // picks up an Accessibility grant made in System Settings
    }
}, forMode: .common)
_ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
speech.prewarm()
render()
app.run()
