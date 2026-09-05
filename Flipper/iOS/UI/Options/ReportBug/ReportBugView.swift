import Core
import SwiftUI
import UIKit

struct ReportBugView: View {
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject var device: Device

    @State var status: Status = .edit

    var feedback: Feedback = .init(
        loggerStorage: Dependencies.shared.loggerStorage
    )

    struct Report {
        let title: String
        let description: String
        let attachLogs: Bool
    }

    enum Status {
        case edit
        case submit
        case success(String)
        // Carries why, so the screen can tell "nowhere to send it" apart
        // from "sending it did not work".
        case failure(FailureView.Reason)
    }

    var body: some View {
        Group {
            switch status {
            case .edit:
                EditorView(onSubmit: sendReport)
            case .submit:
                SubmitView()
            case .success:
                SuccessView()
            case .failure(let reason):
                FailureView(reason: reason)
            }
        }
        .navigationBarBackground(Color.background)
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LeadingToolbarItems {
                BackButton {
                    dismiss()
                }
            }
            PrincipalToolbarItems(alignment: .leading) {
                Title("Report Bug")
            }
        }
    }

    // Submit sends it. No second screen, no mail app, nothing else for the
    // reporter to do -- and everything they filled in travels with it, plus the
    // build and device details a report is useless without.
    func sendReport(_ report: Report) {
        Task {
            status = .submit
            do {
                try await BugReportSender().send(
                    title: report.title,
                    description: report.description,
                    logs: report.attachLogs ? await feedback.logFiles : [],
                    appVersion: Self.appVersion,
                    deviceModel: UIDevice.current.model,
                    firmwareVersion: device.flipper?
                        .information?.firmwareVersion?.name)
                status = .success("")
            } catch BugReportSender.Error.notConfigured {
                status = .failure(.notConfigured)
            } catch let BugReportSender.Error.rejected(why) {
                status = .failure(.failed(why))
            } catch {
                status = .failure(.failed(error.localizedDescription))
            }
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
