import SwiftUI

extension ReportBugView {
    // What actually went wrong, rather than the stock advice this used to give.
    //
    // It said "post your bug on our forum" -- linking to Flipper Devices' forum,
    // which is not this app's -- and "check the bug in TestFlight", which does
    // not exist here either. Worse, it read the same whether the report had
    // been rejected, the network was down, or the app had never been given
    // anywhere to send to, which is the case that actually keeps coming up.
    struct FailureView: View {
        let reason: Reason

        enum Reason {
            case notConfigured
            case failed(String)
        }

        private var message: String {
            switch reason {
            case .notConfigured:
                return "This build has no bug report destination set, so "
                    + "nothing was sent. That is a setting in the app, not "
                    + "something you did wrong."
            case .failed(let why):
                return why.isEmpty
                    ? "The report could not be sent. Check your connection "
                        + "and try again."
                    : "The report could not be sent: \(why)"
            }
        }

        var body: some View {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Text("Report Failed")
                        .font(.system(size: 18, weight: .bold))

                    Image("ReportFailed")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.top, 18)

                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black40)
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)

                Spacer()
            }
            .padding(.top, 14)
            .padding(.horizontal, 14)
        }
    }
}
