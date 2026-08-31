import Core
import SwiftUI

// A firmware store, like nikita-qflipper's "CUSTOM FIRMWARE" panel: pick a
// community firmware, choose its channel, and Import flashes it through the
// app's existing custom-firmware update path. Resolution is real -- DirJson
// sources (Official / Momentum) and GitHub releases (the community forks) --
// so each row shows the actual latest version and date.

// MARK: Model

struct FirmwareSource: Identifiable {
    enum Kind { case dirJson, github }
    let id = UUID()
    let name: String
    let blurb: String
    let kind: Kind
    let locator: String          // directory.json URL, or owner/repo
    let channels: [String]       // "release" / "dev"
    let defaultChannel: String
}

struct ResolvedFirmware: Equatable {
    var version: String
    var date: String
    var url: URL
}

// MARK: Catalog / resolver

@MainActor
final class FirmwareCatalog: ObservableObject {
    enum Status: Equatable {
        case idle, loading, ready(ResolvedFirmware), failed(String)
    }

    @Published var channel: [UUID: String] = [:]
    @Published var status: [UUID: Status] = [:]

    // Nikita first: this is the Nikita app, so its own firmware is the default
    // offer here as it is on the update card. Everything under it is what
    // "import" means -- leaving Nikita for something else, and back again.
    let sources: [FirmwareSource] = [
        .init(name: "Nikita",
              blurb: "This ecosystem's own firmware. Unleashed, plus the Nikita agent.",
              kind: .dirJson,
              locator: URL.firmwareManifestURL.absoluteString,
              channels: ["release", "rc", "dev"], defaultChannel: "release"),
        .init(name: "Official", blurb: "The original Flipper Devices firmware.",
              kind: .dirJson,
              locator: URL.officialFirmwareManifestURL.absoluteString,
              channels: ["release", "dev"], defaultChannel: "release"),
        .init(name: "Momentum", blurb: "A feature rich community firmware.",
              kind: .dirJson,
              locator: "https://up.momentum-fw.dev/firmware/directory.json",
              channels: ["release", "dev"], defaultChannel: "release"),
        .init(name: "Unleashed",
              blurb: "A popular community firmware with expanded features.",
              kind: .github, locator: "DarkFlippers/unleashed-firmware",
              channels: ["release", "dev"], defaultChannel: "release"),
        .init(name: "RogueMaster", blurb: "A feature packed community firmware.",
              kind: .github,
              locator: "RogueMaster/flipperzero-firmware-wPlugins",
              channels: ["release", "dev"], defaultChannel: "dev"),
        .init(name: "ARF",
              blurb: "A firmware for automotive and Sub GHz research.",
              kind: .github, locator: "D4C1-Labs/Flipper-ARF",
              channels: ["dev"], defaultChannel: "dev"),
        .init(name: "Xero", blurb: "A lightweight firmware based on the official.",
              kind: .github, locator: "noproto/xero-firmware",
              channels: ["release"], defaultChannel: "release")
    ]

    func channelFor(_ source: FirmwareSource) -> String {
        channel[source.id] ?? source.defaultChannel
    }

    func setChannel(_ source: FirmwareSource, _ value: String) {
        channel[source.id] = value
        Task { await resolve(source) }
    }

    func resolveAll() {
        for source in sources { Task { await resolve(source) } }
    }

    func resolve(_ source: FirmwareSource) async {
        status[source.id] = .loading
        do {
            let resolved: ResolvedFirmware
            switch source.kind {
            case .dirJson:
                resolved = try await resolveDirJson(source)
            case .github:
                resolved = try await resolveGitHub(source)
            }
            status[source.id] = .ready(resolved)
        } catch {
            status[source.id] = .failed(short(error))
        }
    }

    // MARK: DirJson (Flipper directory.json format)

    private func resolveDirJson(_ source: FirmwareSource) async throws
        -> ResolvedFirmware {
        let wanted = channelId(channelFor(source))
        guard let url = URL(string: source.locator) else {
            throw Err.badURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let channels = root["channels"] as? [[String: Any]],
            let ch = channels.first(where: { ($0["id"] as? String) == wanted }),
            let versions = ch["versions"] as? [[String: Any]]
        else { throw Err.notFound }
        guard let latest = versions.first else { throw Err.noReleases }

        let version = (latest["version"] as? String) ?? "?"
        let ts = (latest["timestamp"] as? Double)
            ?? (latest["timestamp"] as? Int).map(Double.init)
        let files = (latest["files"] as? [[String: Any]]) ?? []
        guard let tgz = files.first(where: {
            let target = ($0["target"] as? String) ?? ""
            let urlStr = ($0["url"] as? String) ?? ""
            return target == "f7" && urlStr.hasSuffix(".tgz")
                && urlStr.contains("update")
        }) ?? files.first(where: {
            ($0["url"] as? String)?.hasSuffix(".tgz") ?? false
        }), let tgzURL = URL(string: (tgz["url"] as? String) ?? "") else {
            throw Err.noBundle
        }
        return .init(version: version, date: dateString(ts), url: tgzURL)
    }

    // MARK: GitHub releases

    private func resolveGitHub(_ source: FirmwareSource) async throws
        -> ResolvedFirmware {
        let wantDev = channelFor(source) == "dev"
        guard let url = URL(string:
            "https://api.github.com/repos/\(source.locator)"
            + "/releases?per_page=15") else { throw Err.badURL }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json",
                         forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let releases = try JSONSerialization.jsonObject(with: data)
            as? [[String: Any]] else { throw Err.notFound }

        guard !releases.isEmpty else { throw Err.noReleases }

        // release channel -> first non-prerelease; dev -> newest of any kind.
        let picked = wantDev
            ? releases.first
            : releases.first(where: { ($0["prerelease"] as? Bool) == false })
        guard let release = picked ?? releases.first else { throw Err.noReleases }

        let tag = (release["tag_name"] as? String) ?? "?"
        let published = release["published_at"] as? String
        let assets = (release["assets"] as? [[String: Any]]) ?? []
        // Prefer the f7 update bundle.
        let asset = assets.first(where: {
            let n = (($0["name"] as? String) ?? "").lowercased()
            return n.contains("f7") && n.contains("update") && n.hasSuffix(".tgz")
        }) ?? assets.first(where: {
            let n = (($0["name"] as? String) ?? "").lowercased()
            return n.contains("update") && n.hasSuffix(".tgz")
        }) ?? assets.first(where: {
            (($0["name"] as? String) ?? "").hasSuffix(".tgz")
        })
        guard
            let asset,
            let urlStr = asset["browser_download_url"] as? String,
            let tgzURL = URL(string: urlStr)
        else { throw Err.noBundle }

        return .init(version: tag,
                     date: (published?.prefix(10)).map(String.init) ?? "",
                     url: tgzURL)
    }

    // MARK: Helpers

    private enum Err: LocalizedError {
        case badURL, notFound, noBundle, noReleases
        var errorDescription: String? {
            switch self {
            case .badURL: return "bad url"
            case .notFound: return "not found"
            case .noBundle: return "no .tgz bundle"
            // A channel that exists and is empty, which is how a firmware looks
            // before its first release on that channel -- not a lookup failure.
            case .noReleases: return "no releases yet"
            }
        }
    }

    private func channelId(_ channel: String) -> String {
        switch channel {
        case "dev": return "development"
        case "rc": return "release-candidate"
        default: return "release"
        }
    }

    private func dateString(_ ts: Double?) -> String {
        guard let ts else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private func short(_ error: Error) -> String {
        String(error.localizedDescription.prefix(60))
    }
}

// MARK: View

struct FirmwareImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = FirmwareCatalog()
    @State private var confirming: (FirmwareSource, ResolvedFirmware)?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(catalog.sources) { source in
                        FirmwareRow(
                            source: source,
                            channel: catalog.channelFor(source),
                            status: catalog.status[source.id] ?? .idle,
                            onChannel: { catalog.setChannel(source, $0) },
                            onImport: { resolved in
                                confirming = (source, resolved)
                            })
                    }
                }
                .padding(14)
            }
            footer
        }
        .background(Color.background)
        .onAppear { catalog.resolveAll() }
        .alert(
            "Flash \(confirming?.0.name ?? "") \(confirming?.1.version ?? "")?",
            isPresented: .init(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } })
        ) {
            Button("Cancel", role: .cancel) { confirming = nil }
            Button("Flash", role: .destructive) {
                if let (source, resolved) = confirming {
                    startImport(source: source, resolved: resolved)
                }
                confirming = nil
            }
        } message: {
            Text("Flashing replaces the firmware currently on your Flipper.")
        }
    }

    private var header: some View {
        HStack {
            Text("Firmware")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.a1)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.sYellow)
            Text("Flashing replaces your current firmware")
                .foregroundColor(.black40)
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func startImport(
        source: FirmwareSource, resolved: ResolvedFirmware
    ) {
        let deps = Core.Dependencies.shared
        let firmware = Update.Firmware(
            version: .init(name: resolved.version, channel: .custom),
            changelog: "\(source.name) \(resolved.version)",
            url: resolved.url)
        deps.updateModel.customFirmware = firmware
        deps.updateModel.updateChannel = .custom
        deps.updateModel.install(firmware)
        dismiss()
    }
}

private struct FirmwareRow: View {
    let source: FirmwareSource
    let channel: String
    let status: FirmwareCatalog.Status
    let onChannel: (String) -> Void
    let onImport: (ResolvedFirmware) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.a1)
                Text(source.blurb)
                    .font(.system(size: 12))
                    .foregroundColor(.black40)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if source.channels.count > 1 {
                    Menu {
                        ForEach(source.channels, id: \.self) { ch in
                            Button(ch) { onChannel(ch) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(channel)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.a2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.a2.opacity(0.6), lineWidth: 1))
                    }
                } else {
                    Text(channel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.a2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.a2.opacity(0.6), lineWidth: 1))
                }

                statusView
            }

            Button {
                if case .ready(let r) = status { onImport(r) }
            } label: {
                Text("IMPORT")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isReady ? .a1 : .black30)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(isReady ? Color.a1 : Color.black20,
                                lineWidth: 1))
            }
            .disabled(!isReady)
        }
        .padding(12)
        .background(Color.groupedBackground)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.a1.opacity(0.25), lineWidth: 1))
    }

    private var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle, .loading:
            ProgressView().scaleEffect(0.6)
        case .ready(let r):
            VStack(alignment: .trailing, spacing: 1) {
                Text(r.version)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.a2)
                    .lineLimit(1)
                Text(r.date)
                    .font(.system(size: 10))
                    .foregroundColor(.black40)
            }
        case .failed(let why):
            Text(why)
                .font(.system(size: 10))
                .foregroundColor(.sRed)
                .lineLimit(2)
        }
    }
}
