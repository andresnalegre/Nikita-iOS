import Core

import SwiftUI

struct SelectChannelPopup: View {
    let onChannelSelected: (Update.Channel) -> Void
    var onImport: () -> Void = {}

    var body: some View {
        HStack {
            Spacer()
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    // These three are Nikita's channels -- this app's default
                    // firmware. "Import" below is how you leave it.
                    ChannelMenuRow(
                        title: "Release",
                        color: .release,
                        description: "Stable Nikita firmware (recommended)",
                        onPress: { onChannelSelected(.release) }
                    )
                    .padding(12)

                    Divider()
                        .padding(0)

                    ChannelMenuRow(
                        title: "Release-Candidate",
                        color: .candidate,
                        description: "Nikita firmware under testing",
                        onPress: { onChannelSelected(.candidate) }
                    )
                    .padding(12)

                    Divider()
                        .padding(0)

                    ChannelMenuRow(
                        title: "Development",
                        color: .development,
                        description: "Nikita build from the tip, lots of bugs",
                        onPress: { onChannelSelected(.development) }
                    )
                    .padding(12)

                    Divider()
                        .padding(0)

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
