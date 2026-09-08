import SwiftUI

// Tools entry for the Scan Viewer. Styled to match the other Hub cards.
struct ScanViewerHubCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)

                Text("Scan Viewer")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                Text("USB")
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundColor(.a2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(Color.a2, lineWidth: 1))

                Image("ChevronRight")
                    .resizable()
                    .frame(width: 14, height: 14)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 30))
                    .foregroundColor(.a1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify the host")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Text("Read the OS of the machine the Flipper is plugged "
                         + "into (macOS / Windows / Linux), so a Bad USB is "
                         + "built for the real target.")
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
