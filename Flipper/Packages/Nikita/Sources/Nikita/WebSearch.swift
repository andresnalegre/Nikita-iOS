import Foundation

// Web search and page fetch for Nikita on the phone -- the same two tools
// Claude Code has, and the same shape as the desktop's. Read-only, keyless, and
// identical on every account: DuckDuckGo's HTML endpoint for search, a plain
// GET for fetch. No local model, no third-party key -- just HTTPS from the
// phone. Kept out of the agent so it stays a small, testable unit.
enum NikitaWeb {

    // A real browser User-Agent, or DuckDuckGo serves a bot page instead of
    // results.
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
        + "Mobile/15E148 Safari/604.1"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: cfg)
    }()

    struct Result {
        let title: String
        let url: String
        let snippet: String
    }

    // MARK: Search

    static func search(_ query: String) async throws -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var comps = URLComponents(
            string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        let (data, _) = try await session.data(from: comps.url!)
        let html = String(decoding: data, as: UTF8.self)
        return parseResults(html)
    }

    private static func parseResults(_ html: String) -> [Result] {
        var out: [Result] = []
        // <a class="result__a" href="...">title</a> for each hit, with a
        // sibling <a class="result__snippet">summary</a>.
        let links = matches(
            in: html,
            pattern: "result__a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>")
        let snippets = matches(
            in: html, pattern: "result__snippet[^>]*>(.*?)</a>")
        for (i, link) in links.enumerated() where out.count < 8 {
            let title = htmlToText(link.1)
            let url = unwrapDDG(link.0)
            guard !title.isEmpty, !url.isEmpty else { continue }
            let snippet = i < snippets.count ? htmlToText(snippets[i].0) : ""
            out.append(.init(
                title: String(title.prefix(200)),
                url: url,
                snippet: String(snippet.prefix(300))))
        }
        return out
    }

    // MARK: Fetch

    static func fetch(_ urlString: String) async throws -> (String, Bool) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw NikitaWebError.badURL(trimmed) }

        let (data, response) = try await session.data(from: url)
        let ctype = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let capped = data.prefix(2 * 1024 * 1024)
        var text: String
        if ctype.contains("text/html") || ctype.contains("xhtml")
            || ctype.isEmpty {
            text = htmlToText(String(decoding: capped, as: UTF8.self))
        } else {
            text = String(decoding: capped, as: UTF8.self)
        }
        var truncated = false
        if text.count > 12000 {
            text = String(text.prefix(12000))
            truncated = true
        }
        return (text, truncated)
    }

    enum NikitaWebError: LocalizedError {
        case badURL(String)
        var errorDescription: String? {
            switch self {
            case .badURL(let u): return "Not a valid http/https URL: \(u)"
            }
        }
    }

    // MARK: Helpers

    // DuckDuckGo wraps links as //duckduckgo.com/l/?uddg=<encoded>. Pull the
    // real destination back out.
    private static func unwrapDDG(_ href: String) -> String {
        guard let r = href.range(of: "uddg=") else {
            return href.hasPrefix("//") ? "https:" + href : href
        }
        let after = href[r.upperBound...]
        let enc = after.prefix { $0 != "&" }
        return String(enc).removingPercentEncoding ?? String(enc)
    }

    private static func htmlToText(_ input: String) -> String {
        var s = input
        for tag in ["script", "style"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&nbsp;": " "
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "\\n\\s*\\n\\s*\\n+", with: "\n\n",
            options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(
        in text: String, pattern: String
    ) -> [(String, String)] {
        guard let re = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let ns = text as NSString
        return re.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ).map { m in
            let r1 = m.range(at: 1)
            let a = m.numberOfRanges > 1 && r1.location != NSNotFound
                ? ns.substring(with: r1) : ""
            let r2 = m.numberOfRanges > 2 ? m.range(at: 2)
                : NSRange(location: NSNotFound, length: 0)
            let b = r2.location != NSNotFound ? ns.substring(with: r2) : ""
            return (a, b)
        }
    }
}
