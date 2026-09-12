import SwiftUI

struct TabViewItem: View {
    let image: AnyView
    let name: String
    let isSelected: Bool
    // Shared with every sibling item so the selection pill can travel from one
    // tab to the next as a single moving shape, rather than fading out here and
    // in again there. This is the "easy movement" the bar was missing.
    let namespace: Namespace.ID
    let onItemSelected: () -> Void

    // Selection now reads three ways at once, each doing a different job:
    //
    //   * a soft magenta pill that SLIDES between tabs (matchedGeometryEffect),
    //     carrying the eye from the old tab to the new one;
    //   * depth -- the pill sits on a faint magenta glow and a hairline top
    //     highlight, so the selected tab looks lifted rather than painted flat;
    //   * the small spring lift and the caller's colour tint, kept from before.
    //
    // The pill is deliberately low-contrast (a tint, not a slab): it says which
    // tab you are on without shouting over the four grey ones.

    var body: some View {
        VStack(spacing: 2) {
            image

            Text(name)
                .lineLimit(1)
                .font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 69, minHeight: 46)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.a1.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .a1.opacity(0.55),
                                        .a1.opacity(0.05)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom),
                                lineWidth: 1)
                    }
                    .shadow(color: .a1.opacity(0.45), radius: 8, y: 2)
                    .matchedGeometryEffect(id: "tabIndicator", in: namespace)
            }
        }
        .scaleEffect(isSelected ? 1.06 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            onItemSelected()
        }
        .animation(
            .spring(response: 0.34, dampingFraction: 0.7),
            value: isSelected)
    }
}
