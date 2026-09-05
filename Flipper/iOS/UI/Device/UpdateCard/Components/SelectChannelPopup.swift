import Core

import SwiftUI

struct SelectChannelPopup: View {
    // Only the channels this firmware actually publishes. A feed fills its
    // channels as builds are tagged, so the list is different per firmware and
    // changes over time: Nikita ships release only today, the Official feed
    // carries all three. Offering an empty channel was offering a dead end --
    // picking it left the card saying "no updates in selected channel" about a
    // channel that has never had anything in it.
    let available: [Update.Channel]
    let onChannelSelected: (Update.Channel) -> Void
    var onImport: () -> Void = {}

    private struct Entry {
        let channel: Update.Channel
        let title: String
        let color: Color
        let description: String
    }

    private let entries: [Entry] = [
        .init(channel: .release, title: "Release", color: .release,
              description: "Stable firmware (recommended)"),
        .init(channel: .candidate, title: "Release-Candidate", color: .candidate,
              description: "Firmware under testing"),
        .init(channel: .development, title: "Development", color: .development,
              description: "Build from the tip, lots of bugs")
    ]

    private var shown: [Entry] {
        entries.filter { available.contains($0.channel) }
    }

    var body: some View {
        HStack {
            Spacer()
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.channel) { entry in
                        ChannelMenuRow(
                            title: entry.title,
                            color: entry.color,
                            description: entry.description,
                            onPress: { onChannelSelected(entry.channel) }
                        )
                        .padding(12)

                        Divider()
                            .padding(0)
                    }

                    // Always offered, whatever the feed holds: these are how
                    // you leave this firmware rather than pick a stream of it.
                    ChannelMenuRow(
                        title: "Custom",
                        color: .custom,
                        description: "Upload file with custom firmware",
                        onPress: { onChannelSelected(.custom) }
                    )
                    .padding(12)

                    Divider()
                        .padding(0)

                    ChannelMenuRow(
                        title: "Import",
                        color: .a1,
                        description: "Official & other community firmwares",
                        onPress: { onImport() }
                    )
                    .padding(12)
                }
            }
            .frame(width: 220)
        }
    }
}

struct ChannelMenuRow: View {
    let title: String
    let color: Color
    let description: String
    var onPress: () -> Void

    var body: some View {
        Button {
            onPress()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(color)
                    Text(description)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.black40)
                }
                Spacer()
            }
        }
    }
}
