import Foundation
import Core

final class IntegrationSmoke {
    let root: URL
    var selection: String? = "Selected passage"
    let fallbackSelection = "Fallback passage"
    var renders = 0
    var pasted: [String] = []
    var opened: [URL] = []
    var bound = false
    var started: [Int] = []
    var cancelled = false

    static func fromArguments() -> IntegrationSmoke? {
        let args = CommandLine.arguments.dropFirst()
        guard args.contains(where: { $0.hasPrefix("--integration-smoke") }) else { return nil }
        guard Array(args) == ["--integration-smoke"] else {
            fputs("Invalid integration smoke arguments\n", stderr)
            exit(2)
        }
        return IntegrationSmoke()
    }

    private init() {
        var template = Array((NSTemporaryDirectory() + "sendpoint-smoke.XXXXXX").utf8CString)
        guard let path = mkdtemp(&template) else {
            fputs("Cannot create smoke directory\n", stderr)
            exit(1)
        }
        root = URL(filePath: String(cString: path))
        write(Data(stackDocument(name: "Seed", notes: [Note(quote: "Seed quote", body: "Seed body")]).utf8),
              to: root.appending(path: "notes/stack-1.md"))
        write(Data("[keys]\nnote = \"\"\n[stacks]\n1 = \"Smoke stack\"\n".utf8),
              to: root.appending(path: "config.toml"))
    }

    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { finish(1, message) }
    }

    func finish(_ code: Int32, _ message: String) -> Never {
        try? FileManager.default.removeItem(at: root)
        print("Integration smoke: \(message)")
        exit(code)
    }

    func perform(_ effect: Effect) -> Bool {
        switch effect {
        case .save, .open, .expireReadout: return false
        case .paste(let text): pasted.append(text)
        case .bindKeys: bound = true
        case .micStart(let take):
            started.append(take)
            DispatchQueue.main.async { send(.partial(take: take, "partial speech")) }
        case .micStop(let take):
            DispatchQueue.main.async { send(.final(take: take, "Spoken annotation")) }
        case .micCancel: cancelled = true
        }
        return true
    }

    func settle() async {
        await withCheckedContinuation { continuation in
            diskQueue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func run() async {
        let temporaryRoot = root
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            try? FileManager.default.removeItem(at: temporaryRoot)
            fputs("Integration smoke timed out\n", stderr)
            exit(1)
        }
        require(world.stacks[0] == [Note(quote: "Seed quote", body: "Seed body")], "launch load")
        pollConfig()
        require(bound && world.config.names[0] == "Smoke stack", "config poll and key binding")
        onKey(.note, down: true)
        send(.edit("Typed annotation"))
        send(.commit)
        await settle()
        require(loadWorld().stacks == world.stacks, "typed note persisted")
        onKey(.open, down: true)
        await settle()
        require(opened == [stackURL(0)], "open writes before opening")
        require((try? String(contentsOf: stackURL(0), encoding: .utf8))?.contains("Smoke stack") == true, "stack heading")
        let expectedPaste = compose(world.stacks[0])
        onKey(.paste, down: true)
        await settle()
        require(pasted == [expectedPaste] && loadWorld().stacks[0].isEmpty, "paste and persisted clear")

        selection = nil
        onKey(.note, down: true)
        await settle()
        require(world.mode == .drafting(Draft(quote: fallbackSelection)), "selection fallback callback")
        send(.cancel)
        selection = "Speech quote"
        send(.voice(.ready))
        onKey(.speak, down: true)
        await settle()
        let take = world.take
        require(started == [take], "mic start effect")
        require(world.mode == .listening(Draft(quote: "Speech quote"), partial: "partial speech", save: true), "partial speech callback")
        onKey(.speak, down: false)
        await settle()
        await settle()
        require(loadWorld().stacks[0] == [Note(quote: "Speech quote", body: "Spoken annotation")], "final speech persisted")
        onKey(.speak, down: true)
        send(.cancel)
        send(.final(take: world.take, "Cancelled result"))
        require(cancelled && world.stacks[0].count == 1 && world.mode == .idle, "cancelled speech ignored")

        let external = [Note(quote: "Editor quote", body: "Editor body")]
        await settle()
        write(Data(stackDocument(name: "External", notes: external).utf8), to: stackURL(0))
        pollStacks()
        await settle()
        require(world.stacks[0] == external, "external Markdown poll")
        onKey(.stack2, down: true)
        require(world.active == 1 && world.readout != nil, "stack shortcut readout")
        try? await Task.sleep(for: .seconds(0.9))
        require(world.readout == nil, "real readout timer callback")
        await settle()
        require(renders > 15 && loadWorld().stacks == world.stacks, "render routing and final disk state")
        finish(0, "passed (isolated storage, config, selection, speech, effects, polling, timer)")
    }
}
