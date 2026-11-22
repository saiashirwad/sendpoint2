import Foundation

/// Identifier-like and name-like words in `text` (camelCase, snake_case, digits, ACRONYMS,
/// Capitalized words mid-sentence), first-seen order, at most 100: what a transcriber is likely to mishear.
public func contextWords(_ text: String) -> [String] {
    var words: [String] = []
    var sentenceStart = true
    for chunk in text.split(whereSeparator: \.isWhitespace) {
        let pieces = chunk.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
        for (i, piece) in pieces.enumerated() {
            let letters = piece.filter(\.isLetter)
            let camel = zip(piece, piece.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
            let acronym = (2...6).contains(piece.count) && letters.count == piece.count && letters.allSatisfy(\.isUppercase)
            let name = piece.first?.isUppercase == true && !(i == 0 && sentenceStart)
            let identifier = camel || piece.contains("_") || (!letters.isEmpty && letters.count < piece.count && piece.contains(where: \.isNumber))
            if (piece.count >= 3 && (identifier || name)) || acronym, !words.contains(piece) {
                words.append(piece)
                if words.count == 100 { return words }
            }
        }
        if !pieces.isEmpty { sentenceStart = chunk.last.map { ".!?".contains($0) } ?? false }
    }
    return words
}

/// `heard` with runs of words that sound like a vocabulary term replaced by the term.
/// A one-part term (Sendpoint, Zod) must match exactly, a multi-part one (useDefaultInput) may be a few letters off.
public func respelled(_ heard: String, using words: [String]) -> String {
    let (heardWords, tail) = tokens(heard)
    let skeletons = heardWords.map { skeleton($0.core) }
    var matches: [Match] = []
    for term in words {
        let n = spokenParts(term).count
        let target = skeleton(term)
        guard n > 0, !target.isEmpty else { continue }
        for length in (n == 1 ? 1...2 : max(1, n - 1)...(n + 1)) where length <= skeletons.count {
            for start in 0...(skeletons.count - length) {
                let window = skeletons[start..<(start + length)].joined()
                guard let distance = closeness(window, target, parts: n) else { continue }
                matches.append(Match(start: start, end: start + length, term: term, distance: distance, off: abs(length - n)))
            }
        }
    }
    matches.sort { ($0.distance, $0.off, $0.start) < ($1.distance, $1.off, $1.start) }
    var chosen: [Match] = []
    for m in matches where !chosen.contains(where: { $0.start < m.end && m.start < $0.end }) { chosen.append(m) }
    chosen.sort { $0.start < $1.start }

    var out = ""
    var i = 0
    for m in chosen {
        out += heardWords[i..<m.start].map(\.text).joined()
        let (first, last) = (heardWords[m.start], heardWords[m.end - 1])
        out += first.space + first.lead + m.term + last.trail
        i = m.end
    }
    return out + heardWords[i...].map(\.text).joined() + tail
}

private struct Match {
    var start: Int, end: Int
    var term: String
    var distance: Int
    /// How far the window's word count is from the term's part count.
    var off: Int
}

/// One whitespace-separated word of the heard text: the space before it, the punctuation around it, and the rest.
private struct Heard {
    var space: String, lead: String, core: String, trail: String
    var text: String { space + lead + core + trail }
}

private func tokens(_ s: String) -> ([Heard], String) {
    var words: [Heard] = []
    var rest = Substring(s)
    while !rest.isEmpty {
        let space = rest.prefix(while: \.isWhitespace)
        rest = rest.dropFirst(space.count)
        let chunk = rest.prefix(while: { !$0.isWhitespace })
        rest = rest.dropFirst(chunk.count)
        if chunk.isEmpty { return (words, String(space)) }
        let lead = chunk.prefix(while: { !isWordCharacter($0) })
        let body = chunk.dropFirst(lead.count)
        let trail = String(String(body.reversed().prefix(while: { !isWordCharacter($0) })).reversed())
        words.append(Heard(space: String(space), lead: String(lead), core: String(body.dropLast(trail.count)), trail: trail))
    }
    return (words, "")
}

private func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

/// Lowercase letters and digits only.
private func skeleton(_ s: String) -> String {
    String(s.lowercased().filter(isWordCharacter))
}

/// "TdtDecoderV3" → ["tdt", "decoder", "v3"]: split at lower→Upper, Acronym→Word, letter→digit after
/// a lowercase letter, digit→Upper and at anything that isn't a letter or digit. A digit after capitals stays.
private func spokenParts(_ term: String) -> [String] {
    var parts: [String] = []
    var current: [Character] = []
    let chars = Array(term)
    for (i, c) in chars.enumerated() {
        guard isWordCharacter(c) else {
            if !current.isEmpty { parts.append(String(current)); current = [] }
            continue
        }
        if let p = current.last {
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            let split = (p.isLowercase && (c.isUppercase || c.isNumber))
                || (p.isNumber && c.isUppercase)
                || (p.isUppercase && c.isUppercase && next.isLowercase)
            if split { parts.append(String(current)); current = [] }
        }
        current.append(c)
    }
    if !current.isEmpty { parts.append(String(current)) }
    return parts.map { $0.lowercased() }
}

/// The edit distance if `window` may stand for `target`: equal, or a long enough skeleton with the
/// same first letter that is close. Two-part names are often plain phrases ("speech analysis"), so they
/// get one edit; three or more parts get a quarter of the letters.
private func closeness(_ window: String, _ target: String, parts: Int) -> Int? {
    if window == target { return 0 }
    guard parts > 1, target.count >= 6, window.first == target.first else { return nil }
    let distance = levenshtein(Array(window), Array(target))
    return distance <= (parts >= 3 ? target.count / 4 : 1) ? distance : nil
}

private func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    var row = Array(0...b.count)
    for i in 1...max(a.count, 1) where i <= a.count {
        var diagonal = row[0]
        row[0] = i
        for j in 1...b.count {
            let above = row[j]
            row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
            diagonal = above
        }
    }
    return row[b.count]
}
