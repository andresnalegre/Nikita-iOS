import Core
import Catalog

import SwiftUI

struct HubView: View {
    @AppStorage(.selectedTab) var selectedTab: TabView.Tab = .device
    @AppStorage(.hasReaderLog) var hasReaderLog = false

    @State private var showDetectReader = false
    @State private var path = NavigationPath()

    enum Destination: Hashable {
        case infrared
        case nikita
        case cli
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 14) {
                    Button { showDetectReader = true } label: {
                        DetectReaderCard(hasNotification: hasReaderLog)
                    }
                    InfraredLibraryCardButton {
                        path.append(Destination.infrared)
                    }
                    Button {
                        path.append(Destination.nikita)
                    } label: {
                        NikitaHubCard()
                    }
                    Button {
                        path.append(Destination.cli)
                    } label: {
                        CLIHubCard()
                    }
                }
                .padding(14)
            }
            .background(Color.background)
            .navigationBarBackground(Color.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LeadingToolbarItems {
                    Title("Tools")
                        .padding(.leading, 8)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .infrared: InfraredView()
                case .nikita: NikitaView()
                case .cli: FlipperCLIView()
                }
            }
        }
        .environment(\.path, $path)
        .onOpenURL { url in
            if url == .mfkey32Link {
                selectedTab = .hub
                showDetectReader = true
            }
        }
        .fullScreenCover(isPresented: $showDetectReader) {
            DetectReaderView()
        }
    }
}
