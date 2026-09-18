import Foundation

// The working plan: what Nikita is in the middle of.
//
// This is the piece that turns a one-shot errand into work that continues. The
// model writes it through the update_plan tool; the loop reads it to decide
// whether a turn is actually finished; and it is stored on disk, so closing the
// app pauses the job instead of ending it. Reopening tomorrow, the open items
// are still there and still Nikita's to finish.
//
// Same shape as the desktop's and the same shape Claude Code's todo list has --
// a flat list of short imperatives with exactly one in progress -- because that
// shape is what keeps a model working rather than summarising: at any moment
// there is precisely one next thing, named, with the rest visible behind it.
public struct NikitaPlanItem: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, inProgress = "in_progress", done
    }
    public var text: String
    public var status: Status
    public var id: String { text }

    public init(text: String, status: Status = .pending) {
        self.text = text
        self.status = status
    }
}

public final class NikitaPlan {
    private struct Stored: Codable {
        var items: [NikitaPlanItem]
        var note: String
        var touched: Date
    }

    private let url: URL

    public private(set) var items: [NikitaPlanItem] = []
    public private(set) var note: String = ""
    public private(set) var touched: Date?

    public init(filename: String = "nikita-plan.json") {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        self.url = docs.appendingPathComponent(filename)
        load()
    }

    public var openCount: Int { items.filter { $0.status != .done }.count }

    public var isEmpty: Bool { items.isEmpty }

    /// The in-progress item, or the first thing still waiting.
    public var current: String {
        if let doing = items.first(where: { $0.status == .inProgress }) {
            return doing.text
        }
        return items.first { $0.status == .pending }?.text ?? ""
    }

    // MARK: Writing

    /// Replaces the plan wholesale (that is the tool's contract) and
    /// returns the JSON the model gets back.
    @discardableResult
    public func apply(
        items raw: [[String: Any]], note newNote: String?
    ) -> String {
        var clean: [NikitaPlanItem] = []
        var sawInProgress = false

        for entry in raw {
            let text = ((entry["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let raw = (entry["status"] as? String)?.lowercased() ?? ""
            var status = NikitaPlanItem.Status(rawValue: raw) ?? .pending
            // Exactly one "next": a plan with three items in progress is a plan
            // with no next step, and the next step is the whole point.
            if status == .inProgress {
                if sawInProgress { status = .pending }
                sawInProgress = true
            }
            clean.append(.init(text: String(text.prefix(200)), status: status))
            if clean.count >= 20 { break }   // a plan, not a backlog
        }

        items = clean
        if let newNote, !newNote.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = newNote.trimmingCharacters(in: .whitespaces)
            note = String(trimmed.prefix(300))
        }
        if clean.isEmpty { note = "" }
        touched = Date()
        save()

        let open = openCount
        var payload: [String: Any] = [
            "ok": true,
            "items": clean.count,
            "done": clean.filter { $0.status == .done }.count,
            "open": open,
            "next": current
        ]
        // Said back in the result, because the result is what the model
        // reliably reads: an open plan is the reason it gets another round.
        payload["note"] = open > 0
            ? "Plan saved. \(open) item(s) still open — keep working, "
              + "starting "
              + "with the next one. Do not stop to summarise."
            : "Plan saved and every item is done. Wrap up in one or two lines."

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8)
        else { return "{\"ok\":true}" }
        return s
    }

    public func clear() {
        items = []
        note = ""
        touched = Date()
        save()
    }

    // MARK: The block the system prompt carries

    /// Kept at the very end of the prompt: it is the one part that
    /// legitimately changes every round, so everything before it stays
    /// byte-identical and the provider's prefix cache keeps hitting.
    public func promptBlock() -> String {
        guard !items.isEmpty else {
            return "\n\nYOUR PLAN: empty. For anything that takes more "
                + "than one tool call, write the steps down with update_plan "
                + "before you start — it is what lets you keep working "
                + "across rounds and across restarts "
                + "instead of finishing one call and stopping."
        }

        var out = "\n\nYOUR PLAN (yours, persistent — update it with "
            + "update_plan):\n"
        for item in items {
            let mark: String
            switch item.status {
            case .done: mark = "[x]"
            case .inProgress: mark = "[>]"
            case .pending: mark = "[ ]"
            }
            out += "\(mark) \(item.text)\n"
        }
        if !note.isEmpty { out += "Where it stands: \(note)\n" }

        if openCount > 0 {
            out += "\(openCount) item(s) are still open. [>] is what you "
                + "are on; [ ] is waiting. Work the next one NOW with a tool "
                + "call, mark it done the moment it lands, and only answer in "
                + "words when the list "
                + "is clear or you genuinely need something from the user."
            // The gap matters: picking up a day-old plan without acknowledging
            // it reads as amnesia, and reintroducing a five-minute-old one
            // reads as worse.
            if let touched {
                let minutes = Int(Date().timeIntervalSince(touched) / 60)
                if minutes > 30 {
                    let age = minutes > 1440
                        ? "\(minutes / 1440) day(s)"
                        : "\(minutes) minute(s)"
                    out += "\nThis plan is \(age) old — it is from an "
                        + "earlier session. Pick it up where it stands: say "
                        + "in one line what is left, then continue. Do not "
                        + "start over, and do not ask permission to resume "
                        + "something you already agreed to do."
                }
            }
        } else {
            out += "Every item is done. Clear the plan with an empty list "
                + "when you "
                + "report back, so the next job starts from a clean one."
        }
        return out
    }

    // MARK: Shared SD-card format
    //
    // The card copy at /ext/nikita/plan.json is the shared plan across all three
    // clients, so its shape must match byte-for-byte what qFlipper writes:
    // { "items": [ {"text","status"} ], "note", "touched": ISO-8601 }. These two
    // are the only place that shape is produced/consumed on iOS.

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public func exportJSON() -> String {
        let itemsJSON = items.map {
            ["text": $0.text, "status": $0.status.rawValue]
        }
        let obj: [String: Any] = [
            "items": itemsJSON,
            "note": note,
            "touched": Self.iso.string(from: touched ?? Date())
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted]),
            let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    /// Adopt the card's plan when it is genuinely newer than this one. Returns
    /// true if it replaced the local plan, so the caller knows to refresh the UI.
    @discardableResult
    public func adoptFromJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rawItems = obj["items"] as? [[String: Any]],
              let touchedStr = obj["touched"] as? String,
              let cardTouched = Self.iso.date(from: touchedStr)
        else { return false }
        // The card wins only when it is newer; ties keep what is loaded.
        if let mine = touched, cardTouched <= mine { return false }

        items = rawItems.compactMap { entry in
            guard let text = entry["text"] as? String, !text.isEmpty else {
                return nil
            }
            let status = NikitaPlanItem.Status(
                rawValue: (entry["status"] as? String) ?? "") ?? .pending
            return NikitaPlanItem(text: text, status: status)
        }
        note = (obj["note"] as? String) ?? ""
        touched = cardTouched
        save()
        return true
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        items = stored.items
        note = stored.note
        touched = stored.touched
    }

    private func save() {
        let stored = Stored(
            items: items, note: note, touched: touched ?? Date())
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
