import Core
import SwiftUI

// Tools entry for the apps already on the Flipper. Self-contained (SF Symbols
// only), styled to match the other Hub cards.
struct InstalledAppsHubCard: View {
    @EnvironmentObject var applications: Applications

    private var count: Int { applications.installed.count }
    private var outdated: Int { applications.outdatedCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)

                Text("Installed Apps")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                // Only worth a badge when there is something to act on.
                if outdated > 0 {
                    Text("\(outdated) update\(outdated == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundColor(.a2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 30)
                                .stroke(Color.a2, lineWidth: 1))
                }

                Image("ChevronRight")
                    .resizable()
                    .frame(width: 14, height: 14)
            }

            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 30))
                    .foregroundColor(.a1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(count > 0
                         ? "\(count) app\(count == 1 ? "" : "s") on your Flipper"
                         : "Apps on your Flipper")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)

                    Text("What is installed on the SD card: update or "
                         + "remove it without opening the catalog")
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.black30)
                }
                Spacer()
            }
        }
        .padding([.bottom, .leading, .top], 12)
        .padding(.trailing, 8)
        .background(Color.groupedBackground)
        .cornerRadius(10)
    }
}

// The installed list on its own screen, rather than as a segment of the Apps
// tab. Same view, so the two never drift apart.
struct InstalledAppsHubView: View {
    @EnvironmentObject var applications: Applications
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        InstalledAppsView()
            .background(Color.background)
            .navigationBarBackground(Color.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LeadingToolbarItems {
                    BackButton { dismiss() }
                    Title("Installed Apps")
                }
            }
            .navigationBarBackButtonHidden(true)
            .task {
                // The Apps tab may never have been opened this session.
                try? await applications.loadInstalled()
            }
    }
}
