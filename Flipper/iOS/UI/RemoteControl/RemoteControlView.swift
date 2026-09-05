import Core
import Peripheral

import SwiftUI

struct RemoteControlView: View {
    // When shown as a tab this view is always in the hierarchy, so it must only
    // grab landscape / start streaming while its tab is actually selected.
    // As a pushed screen (Tools card) it is created on demand, so the default
    // `true` activates it immediately. `showsBack` hides the back chevron in
    // tab mode, where there is nothing to dismiss.
    // Only stream / go landscape while the tab is actually selected (or pushed).
    var isActive: Bool = true
    var showsBack: Bool = true
    // Tab mode has nothing to dismiss to, so the caller passes an explicit exit
    // (switch tab). Pushed screens leave it nil and use the environment dismiss.
    var onExit: (() -> Void)?

    @EnvironmentObject var device: Device
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var uiImage: UIImage? {
        guard device.status == .connected else { return nil }
        guard let frame = device.frame else { return nil }
        guard let image = UIImage(frame: frame) else { return nil }
        switch frame.orientation {
        case .horizontalFlipped: return image.withOrientation(.down)
        case .verticalFlipped: return image.withOrientation(.down)
        default: return image
        }
    }

    var screenshotImage: UIImage? {
        uiImage?.resized(to: .init(width: 512, height: 256))
    }

    var screenshotName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: .now)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: .now)
        return "Screenshot \(date) at \(time)"
    }

    // ------------------------------------------------------------------------
    public enum Control {
        case lock
        case unlock
        case inputKey(InputKey, Bool)
    }
    @State var controlsQueue: [(UUID, Control)] = []
    @State var controlsStream: AsyncStream<Control>?
    @State var controlsStreamContinuation: AsyncStream<Control>.Continuation?
    // ------------------------------------------------------------------------

    @Namespace var namespace

    @State private var isHorizontal = false
    @State private var showOutdatedAlert = false

    // How deep into menus the user has navigated from the desktop: OK/enter goes
    // one level in, Back one level out. Lock uses this to climb all the way back
    // to the root before locking (a fixed guess never worked from arbitrary
    // depth). We over-count by one as an error margin -- extra Backs at the root
    // are harmless.
    @State private var menuDepth = 0


    // The app is portrait-locked, so we rotate the gamepad by hand to match the
    // way the phone is physically held -- +90 or -90 for the two landscape
    // sides, so it reads upright whichever way you turn it.
    @State private var landscapeAngle: Double = -90

    // Keeps the screen stream alive. A BLE hiccup restarts the RPC session and
    // the Flipper forgets it was streaming; nothing used to re-assert it, so the
    // mirror froze until you reconnected. This re-sends screenStream(true) every
    // couple of seconds while connected, so any drop self-heals.
    @State private var streamKeepAlive: Task<Void, Never>?

    @State private var deviceSize: CGSize = .zero
    @State private var screenRect: CGRect = .zero

    var displayOffset: Double { 0.6 }
    var buttonSide: Double { 90 }
    var buttonPadding: Double { 12 }

    // The mirrored Flipper screen (or a placeholder while connecting).
    @ViewBuilder
    var screenView: some View {
        if device.status == .disconnected {
            Image("RemoteScreenNotConnected")
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            DeviceScreen {
                if let uiImage = uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                } else {
                    AnimatedPlaceholder()
                }
            }
        }
    }

    // A small controller-style face button (Select / Start), sitting under the
    // D-pad. Keeps the screenshot / lock actions but presents them like a pad.
    @ViewBuilder
    func padButton<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 3) {
            content()
                .frame(width: 46, height: 46)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.black40)
        }
    }

    // Landscape gamepad: screen large on the LEFT, D-pad on the RIGHT, with
    // Screenshot / Lock in the top-right corner and back top-left. The app's
    // tab bar below stays visible -- it is not hidden here.
    var gamepad: some View {
        HStack(alignment: .center, spacing: 22) {
            screenView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            VStack(spacing: 12) {
                Spacer(minLength: 0)

                DeviceControls { key, isLong in
                    trackDepth(key)
                    controlTapped(.inputKey(key, isLong))
                }

                ControlsQueue($controlsQueue)
                    .frame(maxWidth: 240)

                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.background)
        // Screenshot + Lock/Unlock, top-right. The tab bar below is the
        // navigation, so there is no back button here.
        .overlay(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 22) {
                padButton("Screenshot") {
                    Button {
                        screenshot()
                    } label: {
                        Image("RemoteScreenshot").resizable().scaledToFit()
                    }
                }
                padButton(device.isLocked ? "Unlock" : "Lock") {
                    Button {
                        toggleLock()
                    } label: {
                        Image(device.isLocked ? "RemoteUnlock" : "RemoteLock")
                            .resizable().scaledToFit()
                    }
                }
            }
            .padding(16)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                gamepad
            } else {
                // During the brief portrait -> landscape flip, show a clean dark
                // screen instead of the landscape layout squeezed into portrait.
                Color.background
            }
        }
        .background(Color.background)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if isActive { activate() }
        }
        .onChange(of: isActive) { active in
            active ? activate() : deactivate()
        }
        .onReceive(device.$status) { status in
            if status == .connected, scenePhase == .active {
                device.updateLockStatus()
                device.startScreenStreaming()
            }
        }
        .onDisappear {
            deactivate()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: device.startScreenStreaming()
            case .inactive: device.stopScreenStreaming()
            case .background: break
            @unknown default: break
            }
        }
        .alert(isPresented: $showOutdatedAlert) {
            OutdatedVersionAlert(isPresented: $showOutdatedAlert)
        }
        .task {
            isHorizontal = device.frame?.orientation.isHorizontal ?? true
            await runLoop()
        }
    }

    // Called when this screen becomes the visible/selected one: go landscape,
    // start mirroring, and keep the stream alive. Idempotent enough to be safe
    // from both onAppear and the isActive change.
    func activate() {
        AppOrientation.lock(.landscape)
        device.startScreenStreaming()
        startStreamKeepAlive()
    }

    // Called when leaving the screen or deselecting the tab: stop mirroring and
    // hand orientation back to portrait for the rest of the app.
    func deactivate() {
        streamKeepAlive?.cancel()
        streamKeepAlive = nil
        device.stopScreenStreaming()
        AppOrientation.lock(.portrait)
    }

    // Toggle the Flipper lock, driven entirely by button presses over RPC input
    // (the real device state comes back from updateLockStatus, so the button
    // never desyncs). Lock: Up opens the desktop lock menu, OK confirms Lock.
    // Unlock: send the on-screen unlock combo -- a locked Flipper only responds
    // to the buttons, so a bare RPC unlock does nothing; pressing Back clears
    // the default (no-PIN) lock screen.
    // Track how deep the user is in the menus so Lock knows how far to climb
    // back. OK/enter goes in, Back goes out; Up/Down/Left/Right stay on the same
    // level of a vertical menu.
    func trackDepth(_ key: InputKey) {
        switch key {
        case .enter: menuDepth += 1
        case .back: menuDepth = max(0, menuDepth - 1)
        default: break
        }
    }

    func toggleLock() {
        if device.isLocked {
            controlTapped(.inputKey(.back, false))
            controlTapped(.inputKey(.back, false))
            controlTapped(.inputKey(.back, false))
            menuDepth = 0
        } else {
            // Lock only works from the desktop: inside a menu, Up+OK just
            // navigates and selects (it "acts like Enter"). Climb back exactly
            // as far as we went in, plus one for slop, then open the lock menu
            // (Up) and confirm (OK).
            let backs = menuDepth + 1
            for _ in 0..<backs {
                controlTapped(.inputKey(.back, false))
            }
            controlTapped(.inputKey(.up, false))
            controlTapped(.inputKey(.enter, false))
            menuDepth = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            device.updateLockStatus()
        }
    }

    func runLoop() async {
        let controlsStream = AsyncStream<Control> { continuation in
            controlsStreamContinuation = continuation
        }
        self.controlsStream = controlsStream
        for await next in controlsStream {
            await processControl(next)
            withAnimation {
                controlsQueue = .init(controlsQueue.dropFirst())
            }
        }
    }

    func lockUnlockTapped() {
        guard
            let protobufVersion = device.flipper?.information?.protobufRevision,
            protobufVersion >= .v0_16
        else {
            showOutdatedAlert = true
            return
        }
        device.isLocked
            ? controlTapped(.unlock)
            : controlTapped(.lock)
    }

    func controlTapped(_ control: Control) {
        controlsQueue.append((.init(), control))
        controlsStreamContinuation?.yield(control)
    }

    func processControl(_ control: Control) async {
        switch control {
        case .lock: await lock()
        case .unlock: await unlock()
        case let .inputKey(key, isLong): await pressButton(key, isLong)
        }
    }

    func pressButton(_ button: InputKey, _ isLong: Bool) async {
        feedback(style: .light)
        try? await device.pressButton(button, isLong: isLong)
        feedback(style: .light)
    }

    func lock() async {
        feedback(style: .light)
        try? await device.lock()
        device.updateLockStatus()
        feedback(style: .light)
    }

    func unlock() async {
        feedback(style: .light)
        try? await device.unlock()
        device.updateLockStatus()
        feedback(style: .light)
    }

    func screenshot() {
        guard let image = screenshotImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        feedback(style: .medium)
    }

    // Re-assert the screen stream while the remote is open and the Flipper is
    // connected, so a BLE/pairing hiccup that restarts the RPC session (and
    // clears the Flipper's streaming state) self-heals within a couple seconds
    // instead of freezing until a manual reconnect.
    func startStreamKeepAlive() {
        streamKeepAlive?.cancel()
        streamKeepAlive = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                if device.status == .connected, scenePhase == .active {
                    device.startScreenStreaming()
                }
            }
        }
    }

    // Rotate the gamepad to stay upright for whichever landscape side the phone
    // is turned to. Portrait / flat orientations keep the last landscape angle.
    func updateAngle(_ orientation: UIDeviceOrientation) {
        switch orientation {
        case .landscapeLeft: landscapeAngle = 90
        case .landscapeRight: landscapeAngle = -90
        default: break
        }
    }
}

private extension UIImage {
    func scaled(by scale: Double) -> UIImage {
        resized(to: .init(
            width: size.width * scale,
            height: size.height * scale))
    }

    func resized(
        to size: CGSize,
        interpolationQuality: CGInterpolationQuality = .none,
        isOpaque: Bool = true
    ) -> UIImage {
        let format = imageRendererFormat
        format.opaque = isOpaque
        return UIGraphicsImageRenderer(size: size, format: format).image {
            $0.cgContext.interpolationQuality = interpolationQuality
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func withOrientation(_ orientation: Orientation) -> UIImage {
        guard let cgImage = self.cgImage else {
            return .init()
        }
        return .init(cgImage: cgImage, scale: 1.0, orientation: orientation)
    }
}

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private extension View {
    func captureSize(in binding: Binding<CGSize>) -> some View {
        overlay(GeometryReader { proxy in
            Color.clear.preference(key: SizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(SizeKey.self) { binding.wrappedValue = $0 }
    }
}

private struct RectKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private extension View {
    func captureFrame(
        in binding: Binding<CGRect>,
        space: CoordinateSpace
    ) -> some View {
        overlay(GeometryReader { proxy in
            Color.clear.preference(
                key: RectKey.self,
                value: proxy.frame(in: space))
        })
        .onPreferenceChange(RectKey.self) { binding.wrappedValue = $0 }
    }
}
