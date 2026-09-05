import SwiftUI

extension ReportBugView {
    // Shown once the mail composer reports the report on its way.
    //
    // This used to show an "issue ID" to copy, plus a note about posting to a
    // forum and checking TestFlight. All three belonged to the Sentry service
    // this no longer uses: there is no ticket number for an email, no forum
    // behind this app, and no TestFlight build to compare against. What is
    // actually useful is where it went.
    struct SuccessView: View {
        var body: some View {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Text("Report Sent")
                        .font(.system(size: 18, weight: .bold))

                    Image("ReportSuccessful")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.top, 18)

                VStack(spacing: 8) {
                    Text(
                        "Thanks -- your report has been sent, along with the "
                        + "app version and, if you left it ticked, the logs."
                    )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.black40)
                    .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                Spacer()
            }
            .padding(.top, 14)
            .padding(.horizontal, 14)
        }
    }
}
