import Core

import SwiftUI

struct SelectChannel: View {
    @EnvironmentObject var updateModel: UpdateModel

    let version: Update.Version
    let onChannelSelected: (Update.Channel) -> Void

    // Read off the feed rather than assumed: a channel is on the menu only if
    // it has a build in it.
    private var availableChannels: [Update.Channel] {
        guard let manifest = updateModel.manifest else { return [] }
        var out: [Update.Channel] = []
        if manifest.release != nil { out.append(.release) }
        if manifest.candidate != nil { out.append(.candidate) }
        if manifest.development != nil { out.append(.development) }
        return out
    }

    @State private var showChannelSelector = false
    @State private var channelSelectorOffset = 0.0
    @State private var showImport = false

    var body: some View {
        SelectChannelButton(version: version) {
            showChannelSelector = true
        }
        .fullScreenCover(isPresented: $showImport) {
            FirmwareImportView()
        }
        .background(GeometryReader {
            Color.clear.preference(
                key: OffsetKey.self,
                value: $0.frame(in: .global).origin.y)
        })
        .onPreferenceChange(OffsetKey.self) {
            channelSelectorOffset = $0
        }
        .popup(isPresented: $showChannelSelector) {
            SelectChannelPopup(available: availableChannels, onChannelSelected: {
                showChannelSelector = false
                onChannelSelected($0)
            }, onImport: {
                showChannelSelector = false
                showImport = true
            })
            .offset(y: channelSelectorOffset + platformOffset)
            .padding(.trailing, 14)
        }
    }
}

struct SelectChannelButton: View {
    let version: Update.Version
    var action: () -> Void

    public var text: String {
        switch version.channel {
        case .development: return "Dev \(version.name)"
        case .candidate: return "RC \(version.name.dropLast(3))"
        case .release: return "Release \(version.name)"
        // Imported firmware reads by its own name, never "Custom" -- that named
        // the mechanism, not the firmware. The firmware family comes from the
        // version tag (Nikita, Momentum, ...); an unnamed hand-picked file
        // falls back to a neutral word rather than the internal channel name.
        case .custom:
            if version.name.isEmpty || version.name == "unknown" {
                return "Firmware"
            }
            if let fw = FirmwareIdentity.identify(
                fork: nil, version: version.name) {
                return "\(fw.displayName) \(version.name)"
            }
            return version.name
        }
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Spacer()

                Text(text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(version.color)

                Image(systemName: "chevron.down")
                    .foregroundColor(.black30)
            }
            .frame(height: 44)
        }
    }
}
