import SwiftUI

// Tools entry for the Flipper CLI terminal. Self-contained (SF Symbols only),
// styled to match the other Hub cards in the Nikita theme.
struct CLIHubCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)

                Text("CLI")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                Text("BLE")
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
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 30))
                    .foregroundColor(.a1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Flipper terminal")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Text("Talk to the connected Flipper over Bluetooth: "
                         + "ls, cat, write, screen, buttons, apps, info")
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
