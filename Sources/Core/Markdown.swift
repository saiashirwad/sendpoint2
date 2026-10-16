public func compose(_ notes: [Note]) -> String {
    notes.map { note in
        [blockquote(note.quote), note.body].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }.joined(separator: "\n\n---\n\n")
}

func blockquote(_ quote: String) -> String {
    guard !quote.isEmpty else { return "" }
    return quote.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? ">" : "> \($0)" }
        .joined(separator: "\n")
}

/// The file `open` shows: the stack's name, then exactly what `paste` would send.
public func stackDocument(name: String, notes: [Note]) -> String {
    "# \(name)\n\n" + (notes.isEmpty ? "_No notes yet._" : compose(notes)) + "\n"
}

/// The notes in a stack file the user edited: the inverse of `stackDocument`.
/// The `# name` line is skipped, a line of `---` ends a note, leading `>` lines are its quote.
public func parseStackDocument(_ text: String) -> [Note] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
    var notes: [Note] = []
    var chunk: [String] = []
    for line in lines + ["---"] {
        guard trimmed(line) == "---" else {
            chunk.append(line)
            continue
        }
        if let note = parseNote(chunk) { notes.append(note) }
        chunk = []
    }
    return notes
}

private func parseNote(_ lines: [String]) -> Note? {
    var rest = lines.drop { trimmed($0).isEmpty }
    var quote: [String] = []
    while let line = rest.first, line.hasPrefix(">") {
        quote.append(String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1)))
        rest = rest.dropFirst()
    }
    let body = trimmed(rest.joined(separator: "\n"))
    let note = Note(quote: trimmed(quote.joined(separator: "\n")), body: body == "_No notes yet._" ? "" : body)
    return note.quote.isEmpty && note.body.isEmpty ? nil : note
}
