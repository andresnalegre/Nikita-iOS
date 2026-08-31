import Core
import Logging
import SwiftUI
import UniformTypeIdentifiers

struct LogView: View {
    @EnvironmentObject var logs: Logs
    @Environment(\.dismiss) private var dismiss

    let name: String
    @State private var messages: [Message] = []
    // nil = show everything; otherwise show this severity and above.
    @State private var filter: Logger.Level?

    @State private var showExporter = false
    @State private var showNikita = false

    private var fullText: String {
        messages.map { $0.text }.joined(separator: "\n")
    }

    public struct Message: Identifiable {
        public let id = UUID()
        public let text: String
        public let level: Logger.Level?

        // Log lines look like: [12:34:56][debug]: message. Continuation lines
        // (no prefix) inherit the previous line's level.
        init(_ text: String, previous: Logger.Level?) {
            self.text = text
            self.level = Self.parseLevel(text) ?? previous
        }

        static func parseLevel(_ line: String) -> Logger.Level? {
            guard line.hasPrefix("[") else { return nil }
            let parts = line.components(separatedBy: "]")
            guard parts.count >= 2 else { return nil }
            let raw = parts[1].hasPrefix("[")
                ? String(parts[1].dropFirst())
                : parts[1]
            return Logger.Level(rawValue: raw)
        }
    }

    private var filtered: [Message] {
        guard let filter else { return messages }
        return messages.filter { ($0.level ?? .trace) >= filter }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if filtered.isEmpty {
                    Text("No entries for this filter.")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
                ForEach(filtered) { message in
                    row(message)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.background)
        .navigationBarBackground(Color.background)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LeadingToolbarItems {
                BackButton {
                    dismiss()
                }
            }
            PrincipalToolbarItems(alignment: .leading) {
                Title(name)
            }
            TrailingToolbarItems {
                NavBarMenu {
                    Button {
                        filter = nil
                    } label: {
                        levelRow("All", selected: filter == nil)
                    }
                    ForEach(Logger.Level.allCases.reversed(), id: \.self) { lvl in
                        Button {
                            filter = lvl
                        } label: {
                            levelRow(lvl.rawValue, selected: filter == lvl)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(filter?.rawValue ?? "All")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 4)
                }

                NavBarMenu {
                    Button {
                        UIPasteboard.general.string = fullText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        share()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showExporter = true
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    Button {
                        showNikita = true
                    } label: {
                        Label("Check with Nikita", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 4)
                }
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: LogTextDocument(text: fullText),
            contentType: .plainText,
            defaultFilename: name
        ) { _ in }
        .sheet(isPresented: $showNikita) {
            NavigationView {
                NikitaView(initialMessage: nikitaPrompt)
            }
        }
        .task {
            var previous: Logger.Level?
            messages = await logs.read(name).map {
                let message = Message($0, previous: previous)
                previous = message.level
                return message
            }
        }
    }

    @ViewBuilder
    private func levelRow(_ text: String, selected: Bool) -> some View {
        HStack {
            Text(text)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func row(_ message: Message) -> some View {
        Text(message.text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(color(for: message.level))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
    }

    private func color(for level: Logger.Level?) -> Color {
        switch level {
        case .critical, .error: return .sRed
        case .warning: return .sYellow
        case .notice, .info: return .a2
        case .debug, .trace: return .secondary
        case .none: return .primary.opacity(0.85)
        }
    }

    func share() {
        shareFile(name: name + ".txt", content: fullText)
    }

    // The log handed to Nikita for analysis. Capped so a huge file doesn't blow
    // the prompt; the tail is the most recent (usually most relevant) part.
    private var nikitaPrompt: String {
        let limit = 8000
        let body = fullText.count > limit
            ? "…(truncated)\n" + String(fullText.suffix(limit))
            : fullText
        return """
        Analyze this Flipper log (\(name)). Point out any errors, warnings or \
        anomalies and what likely caused them, in short bullet points.

        \(body)
        """
    }
}

// A plain-text document so the log can be saved to Files via the exporter.
struct LogTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(
            data: configuration.file.regularFileContents ?? Data(),
            encoding: .utf8) ?? ""
    }

    func fileWrapper(
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
