//
// NikitaExtras.swift
//
// The "+" menu store, mirroring qFlipper: a catalog of QUICK COMMANDS (ready
// prompts the user picks instead of typing), LEARNED SKILLS (GitHub repos
// Nikita has read and distilled into skill cards she keeps), and PLUGINS
// (external HTTP APIs she can call via the call_plugin tool). Persisted to a
// JSON file in Application Support so it survives across launches.
//

import Foundation

public struct NikitaQuickCommand: Identifiable, Codable, Equatable {
    public var id: String
    public var label: String
    public var prompt: String
    public var builtin: Bool
}

public struct NikitaLearnedSkill: Identifiable, Codable, Equatable {
    public var id: String { name }
    public var name: String
    public var repo: String
    public var summary: String
    public var when: String
    public var how: String
    public var install: String
}

public struct NikitaPlugin: Identifiable, Codable, Equatable {
    public var id: String { name }
    public var name: String
    public var baseUrl: String
    public var authHeader: String
    public var authValue: String
    public var description: String
}

@MainActor
public final class NikitaExtras: ObservableObject {
    public static let shared = NikitaExtras()

    @Published public private(set) var quickCommands: [NikitaQuickCommand] = []
    @Published public private(set) var skills: [NikitaLearnedSkill] = []
    @Published public private(set) var plugins: [NikitaPlugin] = []
    // Progress of a running "learn skill" request, shown by the sheet.
    @Published public private(set) var learnStatus = ""
    @Published public private(set) var learnBusy = false

    private struct Store: Codable {
        var quickCommands: [NikitaQuickCommand]
        var skills: [NikitaLearnedSkill]
        var plugins: [NikitaPlugin]
    }

    private var url: URL {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nikita", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("extras.json")
    }

    public init() {
        load()
        seedIfEmpty()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Store.self, from: data)
        else { return }
        quickCommands = s.quickCommands
        skills = s.skills
        plugins = s.plugins
    }

    private func save() {
        let s = Store(
            quickCommands: quickCommands, skills: skills, plugins: plugins)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: url)
        }
    }

    private func seedIfEmpty() {
        guard quickCommands.isEmpty else { return }
        let seeds: [(String, String)] = [
            ("Flipper snapshot", "Give me a full snapshot of the connected "
                + "Flipper: firmware, free SD space, installed apps, and "
                + "anything that looks off."),
            ("Free up SD space", "Find the biggest files and any junk on the "
                + "Flipper SD card and suggest what is safe to delete."),
            ("Make a BadUSB script", "Ask me the target OS, then write a clean "
                + "BadUSB DuckyScript for it and save it to /ext/badusb."),
            ("Research a person", "I will give you a name; do a thorough, "
                + "sourced web lookup and hand me an organised summary."),
            ("Nice PDF report", "Turn what we just discussed into a clean, "
                + "good-looking PDF report and save it."),
            ("Explain this repo", "I will paste a GitHub URL; read it and "
                + "explain what it does, how it is built, and how to use it."),
            ("Health check", "Check that all your tools and skills work right "
                + "now, and fix anything you can.")
        ]
        quickCommands = seeds.map {
            .init(id: UUID().uuidString, label: $0.0, prompt: $0.1,
                  builtin: true)
        }
        save()
    }

    // MARK: quick commands

    public func addQuickCommand(label: String, prompt: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        quickCommands.append(.init(
            id: UUID().uuidString,
            label: l.isEmpty ? String(p.prefix(30)) : l,
            prompt: p, builtin: false))
        save()
    }

    public func removeQuickCommand(id: String) {
        quickCommands.removeAll { $0.id == id }
        save()
    }

    // MARK: plugins

    public func addPlugin(
        name: String, baseUrl: String, authHeader: String,
        authValue: String, description: String
    ) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !u.isEmpty else { return }
        plugins.removeAll { $0.name == n }
        plugins.append(.init(
            name: n, baseUrl: u,
            authHeader: authHeader.trimmingCharacters(in: .whitespaces),
            authValue: authValue.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces)))
        save()
    }

    public func removePlugin(name: String) {
        plugins.removeAll { $0.name == name }
        save()
    }

    public func plugin(named name: String) -> NikitaPlugin? {
        plugins.first { $0.name == name }
    }

    // MARK: skills

    public func removeSkill(name: String) {
        skills.removeAll { $0.name == name }
        save()
    }

    // Learn a skill from a GitHub repo: fetch its README, ask Kimi to distil a
    // compact skill card, and keep it. Honest and best-effort -- a fetch or key
    // failure is reported through learnStatus, not swallowed.
    public func learnSkill(
        repoURL: String, apiKey: String, model: String
    ) async {
        let url = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            setLearn("No API key set.", busy: false); return
        }
        guard let (owner, repo) = Self.parseRepo(url) else {
            setLearn("That does not look like a GitHub repo URL.", busy: false)
            return
        }
        setLearn("Reading \(owner)/\(repo)…", busy: true)
        guard let readme = await Self.fetchReadme(owner: owner, repo: repo) else {
            setLearn("Could not read a README for that repo.", busy: false)
            return
        }
        setLearn("Learning the skill from \(owner)/\(repo)…", busy: true)

        let sys = "You turn a GitHub project's README into a COMPACT skill card "
            + "for an AI assistant named Nikita. Reply with ONLY compact JSON: "
            + "{\"name\":\"short name\",\"summary\":\"one sentence\",\"when\":"
            + "\"when to use it\",\"how\":\"how to use it, 2-5 short lines\","
            + "\"install\":\"install command or empty\"}. Be accurate; do not "
            + "invent features."
        let user = "REPO: github.com/\(owner)/\(repo)\n\nREADME:\n"
            + String(readme.prefix(12000))

        let client = KimiClient(apiKey: apiKey, model: model)
        do {
            let reply = try await client.complete(
                messages: [
                    ["role": "system", "content": sys],
                    ["role": "user", "content": user]
                ], tools: [])
            guard let card = Self.parseCard(reply.content) else {
                setLearn("Could not understand the skill.", busy: false)
                return
            }
            var skill = card
            skill = NikitaLearnedSkill(
                name: card.name.isEmpty ? repo : card.name,
                repo: "github.com/\(owner)/\(repo)",
                summary: card.summary, when: card.when,
                how: card.how, install: card.install)
            skills.removeAll { $0.name == skill.name }
            skills.append(skill)
            save()
            setLearn("Learned \"\(skill.name)\". It is now part of me.",
                     busy: false)
        } catch {
            setLearn("Kimi could not distil the skill: "
                + error.localizedDescription, busy: false)
        }
    }

    private func setLearn(_ msg: String, busy: Bool) {
        learnStatus = msg
        learnBusy = busy
    }

    // MARK: prompt injection

    // The section appended to the system prompt so Nikita knows her learned
    // skills and registered plugins. Empty when there are none.
    public func promptSection() -> String {
        var s = ""
        if !skills.isEmpty {
            s += "\n\nLEARNED SKILLS -- projects you have studied and can use. "
                + "Reach for the right one when a request matches; run it with "
                + "your shell/web tools."
            for k in skills {
                s += "\n- \(k.name) (\(k.repo)): \(k.summary) WHEN: \(k.when) "
                    + "HOW: \(k.how)"
                if !k.install.isEmpty { s += " INSTALL: \(k.install)" }
            }
        }
        if !plugins.isEmpty {
            s += "\n\nPLUGINS -- external HTTP APIs registered for you. Call "
                + "one with the call_plugin tool (name + path + method + "
                + "optional json body); base URL and auth are added for you."
            for p in plugins {
                s += "\n- \(p.name): \(p.description) (base \(p.baseUrl))"
            }
        }
        return s
    }

    // MARK: helpers

    private static func parseRepo(_ url: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(
            pattern: "github\\.com[:/]+([^/]+)/([^/#?]+)") else { return nil }
        let range = NSRange(url.startIndex..., in: url)
        guard let m = re.firstMatch(in: url, range: range),
              let oR = Range(m.range(at: 1), in: url),
              let rR = Range(m.range(at: 2), in: url) else { return nil }
        var repo = String(url[rR])
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        return (String(url[oR]), repo)
    }

    private static func fetchReadme(
        owner: String, repo: String
    ) async -> String? {
        for branch in ["main", "master"] {
            let raw = "https://raw.githubusercontent.com/\(owner)/\(repo)/"
                + "\(branch)/README.md"
            guard let u = URL(string: raw) else { continue }
            if let (data, resp) = try? await URLSession.shared.data(from: u),
               let http = resp as? HTTPURLResponse,
               http.statusCode == 200,
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func parseCard(_ content: String) -> NikitaLearnedSkill? {
        guard let a = content.firstIndex(of: "{"),
              let b = content.lastIndex(of: "}") else { return nil }
        let json = String(content[a...b])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        return NikitaLearnedSkill(
            name: (obj["name"] as? String) ?? "",
            repo: "",
            summary: (obj["summary"] as? String) ?? "",
            when: (obj["when"] as? String) ?? "",
            how: (obj["how"] as? String) ?? "",
            install: (obj["install"] as? String) ?? "")
    }
}
