import SwiftUI

// Shown after Forget Flipper. The app drops its own pairing immediately, but
// iPhone keeps its one and no app can remove that: iOS has no API for it, and
// no URL an app may open reaches Settings > Bluetooth on iOS 26 -- every
// spelling opens the Apps list or is refused outright. So this is a notice with
// one acknowledgement rather than a button that would only land somewhere else.
//
// Built on the app's own alert style rather than SwiftUI's .alert, which
// left-aligns its title on iOS 26 and gives no control over the spacing.
struct RemovePairingAlert: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("Remove Pairing")
                    .font(.system(size: 18, weight: .bold))
                    .multilineTextAlignment(.center)

                // Composed rather than one string: the ⓘ is the actual iOS
                // glyph in iOS blue, so it matches what the person is looking
                // for on the Bluetooth screen, and the thing they have to tap
                // is bold so it stands out of the sentence.
                (
                    Text("Open Settings > Bluetooth, tap the ")
                    + Text(Image(systemName: "info.circle.fill"))
                        .foregroundColor(.blue)
                    + Text(" next to your Flipper and choose ")
                    + Text("Forget This Device").fontWeight(.bold)
                    + Text(".")
                )
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundColor(.black40)
                .padding(.horizontal, 12)
            }
            .padding(.top, 25)

            Button {
                isPresented = false
            } label: {
                Text("OK")
                    .frame(height: 41)
                    .frame(maxWidth: .infinity)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .background(Color.a1)
                    .cornerRadius(30)
            }
        }
        .padding(.top, 13)
    }
}
