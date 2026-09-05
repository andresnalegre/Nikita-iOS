import Foundation

// Delivers a bug report without involving the reporter's mail app.
//
// The Submit button used to hand off to MFMailComposeViewController, which
// meant the report only went out if the person had Mail configured and then
// pressed Send in a second screen. Before that it POSTed to Flipper Devices'
// Sentry with a key this project never defined, so it reached nobody at all.
//
// Formspree relays a plain JSON POST to a fixed address. No server to run, and
// -- unlike an email API key -- nothing secret ships in the binary: a form id
// can only submit to that one form, which is rate limited and revocable.
public struct BugReportSender {
    public enum Error: Swift.Error {
        case notConfigured
        case rejected(String)
    }

    // Formspree caps a submission's size. Logs are the only part that can grow
    // without bound, so they are the part that gets trimmed -- and the newest
    // lines are kept, since those are the ones next to the failure.
    private static let logBudget = 120_000

    public init() {}

    public func send(
        title: String,
        description: String,
        logs: [Feedback.LogFile],
        appVersion: String,
        deviceModel: String,
        firmwareVersion: String?
    ) async throws {
        guard let url = URL.bugReportEndpoint else {
            throw Error.notConfigured
        }

        var payload: [String: String] = [
            // Formspree reads these two by name: they become the subject line
            // and the body of the mail it sends on.
            "_subject": "Nikita bug report: \(title)",
            "message": description,
            "title": title,
            "app version": appVersion,
            "phone": deviceModel,
            "flipper firmware": firmwareVersion ?? "not connected"
        ]

        if !logs.isEmpty {
            payload["logs"] = Self.trimmed(logs)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.rejected("no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Formspree explains itself in the body; carrying that through
            // beats reporting a bare status code nobody can act on.
            let reason = String(data: data, encoding: .utf8) ?? ""
            throw Error.rejected(
                reason.isEmpty ? "HTTP \(http.statusCode)" : reason)
        }
    }

    private static func trimmed(_ logs: [Feedback.LogFile]) -> String {
        let joined = logs
            .map { "===== \($0.filename) =====\n\($0.content)" }
            .joined(separator: "\n\n")
        guard joined.count > logBudget else { return joined }
        let kept = joined.suffix(logBudget)
        return "[earlier lines trimmed]\n" + kept
    }
}
