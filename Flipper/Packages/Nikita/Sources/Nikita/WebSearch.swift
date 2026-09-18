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

    static func search(_ query: String, braveKey: String = "") async throws
        -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Brave Search API first when a key is set: real ranked results, no
        // captcha. Falls through to the keyless chain on any failure.
        if !braveKey.isEmpty, let brave = try? await braveSearch(trimmed, key: braveKey),
           !brave.isEmpty {
            return brave
        }
        var comps = URLComponents(
            string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        let (data, _) = try await session.data(from: comps.url!)
        let html = String(decoding: data, as: UTF8.self)
        let scraped = parseResults(html)
        if !scraped.isEmpty { return scraped }
        // The HTML endpoint serves a bot-wall to scripted requests; fall back to
        // the keyless Instant Answer JSON API, which never captchas (but only
        // covers notable entities/topics, not private individuals).
        return (try? await instantAnswer(trimmed)) ?? []
    }

    private static func braveSearch(_ query: String, key: String) async throws
        -> [Result] {
        var comps = URLComponents(
            string: "https://api.search.brave.com/res/v1/web/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "8")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let web = obj["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]]
        else { return [] }
        return results.prefix(8).compactMap { r in
            guard let title = r["title"] as? String,
                  let url = r["url"] as? String else { return nil }
            return Result(
                title: String(title.prefix(200)),
                url: url,
                snippet: String(((r["description"] as? String) ?? "").prefix(300)))
        }
    }

    private static func instantAnswer(_ query: String) async throws -> [Result] {
        var comps = URLComponents(string: "https://api.duckduckgo.com/")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1")
        ]
        let (data, _) = try await session.data(from: comps.url!)
        guard let obj = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else { return [] }
        var out: [Result] = []
        if let abstract = obj["AbstractText"] as? String, !abstract.isEmpty {
            out.append(.init(
                title: (obj["Heading"] as? String) ?? query,
                url: (obj["AbstractURL"] as? String) ?? "",
                snippet: String(abstract.prefix(500))))
        }
        func take(_ arr: [[String: Any]]) {
            for t in arr where out.count < 8 {
                if let topics = t["Topics"] as? [[String: Any]] {
                    take(topics); continue
                }
                guard let text = t["Text"] as? String, !text.isEmpty else {
                    continue
                }
                out.append(.init(
                    title: String(text.prefix(80)),
                    url: (t["FirstURL"] as? String) ?? "",
                    snippet: String(text.prefix(300))))
            }
        }
        if let rt = obj["RelatedTopics"] as? [[String: Any]] { take(rt) }
        return out
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
