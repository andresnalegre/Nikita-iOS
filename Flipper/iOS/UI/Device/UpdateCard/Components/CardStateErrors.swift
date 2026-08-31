import Core
import SwiftUI

extension DeviceUpdateCard {
    struct CardNoSDError: View {
        let retry: () -> Void

        var body: some View {
            VStack(spacing: 2) {
                Image("NoSDCard")
                Text("No SD сard")
                    .font(.system(size: 14, weight: .medium))
                HStack {
                    Text("Insert microSD card in Flipper to update firmware")
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.black30)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 4)

            Button {
                retry()
            } label: {
                Text("Retry")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.a2)
            }
            .padding(.bottom, 8)
        }
    }

    struct CardNoInternetError: View {
        let retry: () -> Void

        var body: some View {
            VStack(spacing: 2) {
                Image("NoInternet")
                Text("No Internet connection")
                    .font(.system(size: 14, weight: .medium))
                HStack {
                    Text("Can’t connect to update server")
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.black30)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 4)

            Button {
                retry()
            } label: {
                Text("Retry")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.a2)
            }
            .padding(.bottom, 8)
        }
    }

    struct CardCantConnectError: View {
        let retry: () -> Void

        var body: some View {
            VStack(spacing: 2) {
                Image("ServerError")
                Text("Unable to download firmware")
                    .font(.system(size: 14, weight: .medium))
                HStack {
                    Text("Can’t connect to update server")
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.black30)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 4)

            Button {
                retry()
            } label: {
                Text("Retry")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.a2)
            }
            .padding(.bottom, 8)
        }
    }

    // The feed was read and has nothing on this channel. Not a failure of the
    // network, so it does not borrow the network's artwork or its wording.
    struct CardNoReleasesError: View {
        let retry: () -> Void

        var body: some View {
            VStack(spacing: 2) {
                Text("No firmware in this channel yet")
                    .font(.system(size: 14, weight: .medium))
                HStack {
                    Text(
                        "Nothing has been published here. " +
                        "Pick another channel, or use Import for other firmwares."
                    )
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black30)
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 12)
            .padding(.vertical, 4)

            Button {
                retry()
            } label: {
                Text("Retry")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.a2)
            }
            .padding(.bottom, 8)
        }
    }

    struct CardNoDeviceError: View {
        var body: some View {
            VStack(spacing: 2) {
                Image("UpdateNoDevice")
                Text("Connect to Flipper to see available updates")
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black30)
                    .padding(.horizontal, 12)
            }
            .padding(.top, 26)
            .padding(.bottom, 26)
        }
    }
}
