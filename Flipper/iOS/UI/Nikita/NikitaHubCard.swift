import SwiftUI

// The Hub entry point for Nikita. Self-contained (SF Symbols only) so it needs
// no asset-catalog additions, styled to sit alongside the other Hub cards.
struct NikitaHubCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)

                Text("Nikita")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                Text("AI")
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundColor(.sGreen)
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(Color.sGreen, lineWidth: 1))

                Image("ChevronRight")
                    .resizable()
                    .frame(width: 14, height: 14)
            }

            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat-drive your Flipper")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Text("Read the SD card, write scripts, open apps and "
                         + "drive the screen — over Bluetooth")
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
