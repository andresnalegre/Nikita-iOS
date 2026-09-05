import SwiftUI
import Peripheral

struct FlipperDeviceImage: View {
    // The Flipper's actual screen, when one is being streamed. Without it the
    // artwork's own dolphin stands in, which is what this always showed.
    var screen: ScreenFrame?

    // The artboard both the body and the content asset are drawn on.
    private static let artboard = CGSize(width: 238, height: 100)

    // Where the screen sits on that artboard, as fractions of it. Measured from
    // the orange screen fill in the body artwork (x 60.65..146.09,
    // y 10.54..57.49) and then squared off to the 2:1 the real 128x64 display
    // has, centred in what is a slightly taller opening.
    private enum Screen {
        static let x = 60.65 / 238
        static let width = 85.45 / 238
        static let height = (85.45 / 2) / 100
        static let y = (10.54 + (46.96 - 85.45 / 2) / 2) / 100
    }

    var body: some View {
        ZStack {
            FlipperTemplate()

            if let screen, let image = UIImage(frame: screen) {
                GeometryReader { proxy in
                    // The artwork is scaledToFit inside whatever box we are
                    // given, so it is letterboxed and its drawn rect is NOT the
                    // proxy's size. Placing the screen against the proxy put it
                    // off the display and over the case; everything below is
                    // measured against the drawn artwork instead.
                    let box = proxy.size
                    let aspect = Self.artboard.width / Self.artboard.height
                    let drawnWidth = min(box.width, box.height * aspect)
                    let drawnHeight = drawnWidth / aspect
                    let originX = (box.width - drawnWidth) / 2
                    let originY = (box.height - drawnHeight) / 2

                    // interpolation: .none -- the frame is 128x64 blown up
                    // several times over, and smoothing it turns crisp pixel
                    // art into a grey smear.
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: drawnWidth * Screen.width,
                            height: drawnHeight * Screen.height)
                        .offset(
                            x: originX + drawnWidth * Screen.x,
                            y: originY + drawnHeight * Screen.y)
                }
            } else {
                Image("FZDeviceContent")
                    .resizable()
                    .scaledToFit()
            }
        }
    }
}
