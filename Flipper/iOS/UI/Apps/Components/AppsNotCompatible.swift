import SwiftUI

struct AppsNotCompatibleFirmware: View {
    @AppStorage(.selectedTab) var selectedTab: TabView.Tab = .device

    var description: AttributedString {
        // Not "install the release firmware": on this fork that is advice to
        // stop using the firmware the app exists to serve. The catalog simply
        // has no builds for the SDK this Flipper reports.
        var string: AttributedString = "Flipper's app catalog has no builds " +
            "for the firmware on your Flipper. Apps already installed still work."

        if let range = string.range(of: "already installed") {
            string[range].foregroundColor = .sGreenUpdate
        }

        return string
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Catalog Doesn't Cover this Firmware")
                    .font(.system(size: 14, weight: .bold))

                Text(description)
                    .font(.system(size: 14, weight: .medium))
            }
            .multilineTextAlignment(.center)

            Button {
                selectedTab = .device
            } label: {
                Text("Go to Firmware Update")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.a2)
            }
        }
    }
}

// Shown above the installed list when the catalog could not be asked about
// this firmware. The list itself is read from the Flipper's SD card and is
// unaffected, so this is a note rather than a replacement for it.
struct AppsCatalogUnavailable: View {
    var body: some View {
        VStack(alignment: .center) {
            Text("Catalog unavailable for this firmware — installed apps still work")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundColor(.black40)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black4)
        }
    }
}
