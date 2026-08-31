import Foundation

// Durable facts about the user, one per line, in a plain text file under the
// app's Documents. Hand-edits stick: the store always reads the file fresh
// before it appends, so an external change (or a clear) is never clobbered by an
// in-memory copy -- the lesson the desktop learned the hard way.
public final class NikitaMemory {
    private let url: URL

    public init(filename: String = "nikita-memory.txt") {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        self.url = docs.appendingPathComponent(filename)
    }

    public func all() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func remember(_ fact: String) {
        let clean = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var facts = all()
        // Don't store a duplicate (case-insensitive) -- the model is told not to,
        // but belt and braces.
        guard !facts.contains(where: {
            $0.compare(clean, options: .caseInsensitive) == .orderedSame
        }) else { return }
        facts.append(clean)
        write(facts)
    }

    /// Returns how many facts were removed. `match == "all"` clears everything.
    @discardableResult
    public func forget(_ match: String) -> Int {
        let needle = match.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.lowercased() == "all" {
            let n = all().count
            write([])
            return n
        }
        let before = all()
        let after = before.filter {
            $0.range(of: needle, options: .caseInsensitive) == nil
        }
        write(after)
        return before.count - after.count
    }

    private func write(_ facts: [String]) {
        let text = facts.joined(separator: "\n") + (facts.isEmpty ? "" : "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
